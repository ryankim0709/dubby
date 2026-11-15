import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { api, internal } from "./_generated/api";
import { newBackend } from "./test.helpers";

const SITE_URL = "https://fixture-site.convex.test";
let privateKey = "";

function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (c) => c.charCodeAt(0));
}

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  privateKey = btoa(Array.from(pkcs8, (byte) => String.fromCharCode(byte)).join(""));
});

function configure() {
  vi.stubEnv("PASSWORD_AUTH_PRIVATE_KEY", privateKey);
  vi.stubEnv("CONVEX_SITE_URL", SITE_URL);
}

afterEach(() => vi.unstubAllEnvs());

describe("password auth", () => {
  it("signs up, signs in, and issues a token the served public key verifies", async () => {
    configure();
    const t = newBackend();

    const created = await t.action(api.passwordAuth.signUp, { username: " Learner ", password: "secret" });
    expect(created.username).toBe("learner");
    const session = await t.action(api.passwordAuth.signIn, { username: "LEARNER", password: "secret" });

    const [headerText, claimsText, signatureText] = session.token.split(".");
    const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(claimsText)));
    expect(claims).toMatchObject({ iss: SITE_URL, aud: "dubit" });
    expect(claims.exp).toBeGreaterThan(claims.iat);
    expect(session.expiresAt).toBe(claims.exp * 1000);

    const jwks = await (await t.fetch("/.well-known/jwks.json")).json();
    const publicKey = await crypto.subtle.importKey("jwk", jwks.keys[0], { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      base64UrlDecode(signatureText),
      new TextEncoder().encode(`${headerText}.${claimsText}`),
    );
    expect(verified).toBe(true);

    // The token's subject is the identity users.ensure registers.
    const asLearner = t.withIdentity({ issuer: SITE_URL, subject: claims.sub, tokenIdentifier: `${SITE_URL}|${claims.sub}` });
    expect((await asLearner.mutation(api.users.ensure, {})).created).toBe(true);
  });

  it("rejects a wrong password, an unknown user, and a taken username", async () => {
    configure();
    const t = newBackend();
    await t.action(api.passwordAuth.signUp, { username: "learner", password: "secret" });

    await expect(t.action(api.passwordAuth.signIn, { username: "learner", password: "nope" })).rejects.toThrow();
    await expect(t.action(api.passwordAuth.signIn, { username: "nobody", password: "secret" })).rejects.toThrow();
    await expect(t.action(api.passwordAuth.signUp, { username: "learner", password: "other" })).rejects.toThrow();
  });

  it("seeds the demo logins once", async () => {
    configure();
    const t = newBackend();

    expect(await t.action(internal.passwordAuth.seedDemoAccounts, {})).toEqual({ created: ["demo", "demo1"] });
    expect(await t.action(internal.passwordAuth.seedDemoAccounts, {})).toEqual({ created: [] });
    await t.action(api.passwordAuth.signIn, { username: "demo", password: "demo" });
    await t.action(api.passwordAuth.signIn, { username: "demo1", password: "demo1" });
  });

  it("answers 503 for the public key when the deployment has no signing key", async () => {
    const t = newBackend();
    expect((await t.fetch("/.well-known/jwks.json")).status).toBe(503);
  });
});
