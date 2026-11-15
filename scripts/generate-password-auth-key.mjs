// Prints a new base64 PKCS#8 RSA key for PASSWORD_AUTH_PRIVATE_KEY:
//   npx convex env set PASSWORD_AUTH_PRIVATE_KEY "$(node scripts/generate-password-auth-key.mjs)"
// Replacing the key signs everyone out, because existing session tokens no longer validate.
import { generateKeyPairSync } from "node:crypto";

const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
process.stdout.write(privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"));
