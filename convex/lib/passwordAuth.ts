import { appError } from "./errors";

/** The `aud` claim of password session tokens; auth.config.ts accepts tokens only for this audience. */
export const PASSWORD_TOKEN_AUDIENCE = "dubby";
/** Path of the public signing key, relative to the deployment's site URL. */
export const PASSWORD_JWKS_PATH = "/.well-known/jwks.json";

const KEY_ID = "password-auth-1";
export const TOKEN_LIFETIME_SECONDS = 30 * 24 * 60 * 60;
const PBKDF2_ITERATIONS = 100_000;
const HASH_SCHEME = "pbkdf2-sha256";
const SIGNING_ALGORITHM = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;
const USERNAME_PATTERN = /^[a-z0-9_.-]{3,32}$/;
// Short on purpose: the seeded demo accounts use four-character passwords.
const PASSWORD_MIN_LENGTH = 4;
const PASSWORD_MAX_LENGTH = 128;

export type PublicJwk = { kty: string; n: string; e: string; alg: "RS256"; use: "sig"; kid: string };

const encoder = new TextEncoder();

function toBase64(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(""));
}

function fromBase64(text: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(text), (character) => character.charCodeAt(0));
}

function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Usernames are case-insensitive, so they are stored and looked up lowercased. */
export function normalizeUsername(username: string): string {
  return username.trim().toLowerCase();
}

export function validateNewCredentials(username: string, password: string): void {
  if (!USERNAME_PATTERN.test(username)) {
    throw appError("INVALID_ARGUMENT", "Usernames are 3 to 32 letters, numbers, dots, dashes, or underscores");
  }
  if (password.length < PASSWORD_MIN_LENGTH || password.length > PASSWORD_MAX_LENGTH) {
    throw appError("INVALID_ARGUMENT", `Passwords are ${PASSWORD_MIN_LENGTH} to ${PASSWORD_MAX_LENGTH} characters`);
  }
}

async function pbkdf2(password: string, salt: Uint8Array<ArrayBuffer>, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

/** A salted PBKDF2 hash that carries its own scheme, iteration count, and salt. */
export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, PBKDF2_ITERATIONS);
  return [HASH_SCHEME, String(PBKDF2_ITERATIONS), toBase64(salt), toBase64(hash)].join("$");
}

export async function verifyPassword(password: string, storedHash: string): Promise<boolean> {
  const [scheme, iterationsText, saltText, hashText] = storedHash.split("$");
  const iterations = Number(iterationsText);
  if (scheme !== HASH_SCHEME || !Number.isInteger(iterations) || saltText === undefined || hashText === undefined) {
    throw new Error(`Stored password hash has an unrecognized format (scheme ${scheme})`);
  }
  const expected = fromBase64(hashText);
  const actual = await pbkdf2(password, fromBase64(saltText), iterations);
  // Compares every byte so the time taken doesn't reveal how much of the hash matched.
  let difference = expected.length ^ actual.length;
  for (let index = 0; index < expected.length; index += 1) difference |= expected[index] ^ (actual[index] ?? 0);
  return difference === 0;
}

/** `privateKey` is a base64 PKCS#8 RSA key, as printed by scripts/generate-password-auth-key.mjs. */
async function importSigningKey(privateKey: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey("pkcs8", fromBase64(privateKey), SIGNING_ALGORITHM, true, ["sign"]);
}

/** An RS256 JWT that Convex validates through the password provider in auth.config.ts. */
export async function signSessionToken(params: {
  privateKey: string;
  issuer: string;
  subject: string;
  issuedAtSeconds: number;
  expiresAtSeconds: number;
}): Promise<string> {
  const header = { alg: "RS256", typ: "JWT", kid: KEY_ID };
  const claims = {
    iss: params.issuer,
    sub: params.subject,
    aud: PASSWORD_TOKEN_AUDIENCE,
    iat: params.issuedAtSeconds,
    exp: params.expiresAtSeconds,
  };
  const signingInput = [header, claims].map((part) => toBase64Url(encoder.encode(JSON.stringify(part)))).join(".");
  const key = await importSigningKey(params.privateKey);
  const signature = await crypto.subtle.sign(SIGNING_ALGORITHM, key, encoder.encode(signingInput));
  return `${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
}

/** The public half of the signing key, which Convex fetches to validate session tokens. */
export async function publicJwks(privateKey: string): Promise<{ keys: PublicJwk[] }> {
  const jwk = await crypto.subtle.exportKey("jwk", await importSigningKey(privateKey));
  if (jwk.kty === undefined || jwk.n === undefined || jwk.e === undefined) {
    throw new Error("The password signing key didn't export an RSA public key");
  }
  return { keys: [{ kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", use: "sig", kid: KEY_ID }] };
}
