export class ConfigurationError extends Error {}

/** Provider keys live only in the Convex deployment's environment variables, never in the app. */
export function requiredEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new ConfigurationError(`The deployment env var ${name} isn't set`);
  }
  return value;
}
