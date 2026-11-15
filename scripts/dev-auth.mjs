// Development-only sign-in for a LOCAL Convex deployment. It generates an RSA key pair under
// .convex/dev-auth/ (git-ignored), sets the three DEV_ONLY_TEST_JWT_* variables on the local
// deployment, and mints short-lived test tokens for named users. Never run `configure` against a
// shared or production deployment: anyone holding the private key could sign in as any user.
import { execFileSync } from "node:child_process";
import { createPrivateKey, createPublicKey, createSign, generateKeyPairSync } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const keyDir = join(root, ".convex", "dev-auth");
const privateKeyPath = join(keyDir, "private.pem");
export const issuer = "https://dev-only-test-issuer.invalid";
export const audience = "dubby-dev-only-test";
const keyId = "dev-only-test-key";

function ensureKeys() {
  if (existsSync(privateKeyPath)) return;
  mkdirSync(keyDir, { recursive: true });
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  writeFileSync(privateKeyPath, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
}

function jwksDataUri() {
  const jwk = createPublicKey(createPrivateKey(readFileSync(privateKeyPath))).export({ format: "jwk" });
  const jwks = JSON.stringify({ keys: [{ ...jwk, kid: keyId, alg: "RS256", use: "sig" }] });
  return "data:text/plain;charset=utf-8;base64," + Buffer.from(jwks).toString("base64");
}

const b64url = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");

export function mintToken(subject, lifetimeSeconds = 3600) {
  ensureKeys();
  const now = Math.floor(Date.now() / 1000);
  const signingInput =
    b64url({ alg: "RS256", typ: "JWT", kid: keyId }) +
    "." +
    b64url({ iss: issuer, sub: subject, aud: audience, iat: now, exp: now + lifetimeSeconds });
  const signature = createSign("RSA-SHA256").update(signingInput).sign(createPrivateKey(readFileSync(privateKeyPath)));
  return signingInput + "." + signature.toString("base64url");
}

function convexEnvSet(name, value) {
  execFileSync("npx", ["convex", "env", "set", name, "--", value], {
    cwd: root,
    stdio: ["ignore", "ignore", "inherit"],
    env: { ...process.env, CONVEX_AGENT_MODE: "anonymous" },
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [command, subject] = process.argv.slice(2);
  if (command === "configure") {
    ensureKeys();
    convexEnvSet("DEV_ONLY_TEST_JWT_ISSUER", issuer);
    convexEnvSet("DEV_ONLY_TEST_JWT_AUDIENCE", audience);
    convexEnvSet("DEV_ONLY_TEST_JWT_JWKS", jwksDataUri());
    console.log("Set DEV_ONLY_TEST_JWT_ISSUER, DEV_ONLY_TEST_JWT_AUDIENCE and DEV_ONLY_TEST_JWT_JWKS on the local deployment. Push again for them to take effect.");
  } else if (command === "mint" && subject) {
    console.log(mintToken(subject));
  } else {
    console.error("usage: node scripts/dev-auth.mjs configure | mint <subject>");
    process.exit(2);
  }
}
