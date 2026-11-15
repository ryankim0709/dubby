import { defineConfig } from "vitest/config";

// Convex functions run in an edge-style runtime, so tests do too; convex-test must be inlined to load its modules.
export default defineConfig({
  test: {
    environment: "edge-runtime",
    server: { deps: { inline: ["convex-test"] } },
  },
});
