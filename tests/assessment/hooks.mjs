// Lets Node's built-in TypeScript type stripping run the adapter's extensionless relative imports
// (the form Convex's bundler and tsc expect) without a build step or a dependency.
export async function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith(".") && !/\.[cm]?[jt]s$/.test(specifier)) {
    try {
      return await nextResolve(`${specifier}.ts`, context);
    } catch {
      return nextResolve(`${specifier}/index.ts`, context);
    }
  }
  return nextResolve(specifier, context);
}
