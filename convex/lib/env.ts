/** A deployment env var the route needs is missing; routers map it to 503. */
export class ConfigurationError extends Error {}

export function requiredEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new ConfigurationError(`The deployment env var ${name} isn't set`);
  }
  return value;
}
