import type { AuthConfig } from "convex/server";
import { PASSWORD_JWKS_PATH, PASSWORD_TOKEN_AUDIENCE } from "./lib/passwordAuth";

type Provider = AuthConfig["providers"][number];

/**
 * - Username and password: passwordAuth.ts signs session tokens with PASSWORD_AUTH_PRIVATE_KEY, and
 *   http.ts serves the public key. CONVEX_SITE_URL is built in, so this provider is always listed;
 *   without the key, sign-in fails and no password token exists to validate.
 *
 * Other providers are added only when their deployment env vars are set, so a deployment with none set
 * still pushes cleanly and every authenticated function rejects (no identity is ever produced).
 *
 * - Clerk: CLERK_JWT_ISSUER_DOMAIN, the issuer domain of the Clerk "convex" JWT template.
 * - Test-only custom JWT: DEV_ONLY_TEST_JWT_ISSUER, DEV_ONLY_TEST_JWT_AUDIENCE and
 *   DEV_ONLY_TEST_JWT_JWKS (a data: URI holding a JWKS). Never set these on a shared or production
 *   deployment; anyone holding the matching private key can sign in as any user.
 */
const providers: Provider[] = [];

// The deployment evaluates this file at push time and throws on a read of an unset variable, which
// would fail the push. A throw is caught here so an unset variable just means "provider disabled".
function optionalEnv(name: string): string | undefined {
  try {
    const value = process.env[name];
    return value === undefined || value === "" ? undefined : value;
  } catch {
    return undefined;
  }
}

const siteUrl = optionalEnv("CONVEX_SITE_URL");
if (siteUrl !== undefined) {
  providers.push({
    type: "customJwt",
    issuer: siteUrl,
    applicationID: PASSWORD_TOKEN_AUDIENCE,
    jwks: `${siteUrl}${PASSWORD_JWKS_PATH}`,
    algorithm: "RS256",
  });
}

const clerkDomain = optionalEnv("CLERK_JWT_ISSUER_DOMAIN");
if (clerkDomain !== undefined) {
  providers.push({ domain: clerkDomain, applicationID: "convex" });
}

const testIssuer = optionalEnv("DEV_ONLY_TEST_JWT_ISSUER");
const testAudience = optionalEnv("DEV_ONLY_TEST_JWT_AUDIENCE");
const testJwks = optionalEnv("DEV_ONLY_TEST_JWT_JWKS");
if (testIssuer && testAudience && testJwks) {
  providers.push({
    type: "customJwt",
    issuer: testIssuer,
    applicationID: testAudience,
    jwks: testJwks,
    algorithm: "RS256",
  });
}

export default { providers } satisfies AuthConfig;
