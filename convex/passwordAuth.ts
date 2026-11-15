import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalAction, internalMutation, internalQuery } from "./_generated/server";
import { requiredEnv } from "./lib/env";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import {
  TOKEN_LIFETIME_SECONDS,
  hashPassword,
  normalizeUsername,
  signSessionToken,
  validateNewCredentials,
  verifyPassword,
} from "./lib/passwordAuth";

const credentialsArgs = { username: v.string(), password: v.string() };
/** `expiresAt` is epoch milliseconds, matching the token's `exp`, so the app can drop a stale session without parsing the token. */
const sessionV = v.object({ token: v.string(), username: v.string(), expiresAt: v.number() });
type Session = { token: string; username: string; expiresAt: number };

// Shared demo logins for hackathon demos. Anyone who reads this file can sign in as them.
const DEMO_ACCOUNTS: readonly { username: string; password: string }[] = [
  { username: "demo", password: "demo" },
  { username: "demo1", password: "demo1" },
  { username: "maya", password: "maya" },
  { username: "theo", password: "theo" },
  { username: "jordan", password: "jordan" },
];

async function issueSession(accountId: Id<"passwordAccounts">, username: string): Promise<Session> {
  const issuedAtSeconds = Math.floor(Date.now() / 1000);
  const expiresAtSeconds = issuedAtSeconds + TOKEN_LIFETIME_SECONDS;
  const token = await signSessionToken({
    privateKey: requiredEnv("PASSWORD_AUTH_PRIVATE_KEY"),
    issuer: requiredEnv("CONVEX_SITE_URL"),
    subject: accountId,
    issuedAtSeconds,
    expiresAtSeconds,
  });
  return { token, username, expiresAt: expiresAtSeconds * 1000 };
}

export const accountByUsername = internalQuery({
  args: { username: v.string() },
  returns: v.union(v.object({ _id: v.id("passwordAccounts"), username: v.string(), passwordHash: v.string() }), v.null()),
  handler: async (ctx, { username }) => {
    const account = await ctx.db
      .query("passwordAccounts")
      .withIndex("by_username", (q) => q.eq("username", username))
      .unique();
    return account === null ? null : { _id: account._id, username: account.username, passwordHash: account.passwordHash };
  },
});

/** Returns null when the username is taken, so callers decide whether that is an error. */
export const insertAccountIfAbsent = internalMutation({
  args: { username: v.string(), passwordHash: v.string() },
  returns: v.union(v.id("passwordAccounts"), v.null()),
  handler: async (ctx, { username, passwordHash }) => {
    const existing = await ctx.db
      .query("passwordAccounts")
      .withIndex("by_username", (q) => q.eq("username", username))
      .unique();
    if (existing !== null) return null;
    return await ctx.db.insert("passwordAccounts", { username, passwordHash, createdAt: Date.now() });
  },
});

export const signIn = action({
  args: credentialsArgs,
  returns: sessionV,
  handler: async (ctx, { username, password }): Promise<Session> => {
    const account = await ctx.runQuery(internal.passwordAuth.accountByUsername, { username: normalizeUsername(username) });
    if (account === null || !(await verifyPassword(password, account.passwordHash))) {
      logEvent({ operation: "passwordAuth.signIn", status: "rejected", errorCode: "bad_credentials" });
      throw appError("UNAUTHENTICATED", "Wrong username or password");
    }
    logEvent({ operation: "passwordAuth.signIn", status: "ok" });
    return await issueSession(account._id, account.username);
  },
});

export const signUp = action({
  args: credentialsArgs,
  returns: sessionV,
  handler: async (ctx, { username, password }): Promise<Session> => {
    const normalized = normalizeUsername(username);
    validateNewCredentials(normalized, password);
    const accountId = await ctx.runMutation(internal.passwordAuth.insertAccountIfAbsent, {
      username: normalized,
      passwordHash: await hashPassword(password),
    });
    if (accountId === null) {
      logEvent({ operation: "passwordAuth.signUp", status: "rejected", errorCode: "username_taken" });
      throw appError("CONFLICT", "That username is taken");
    }
    logEvent({ operation: "passwordAuth.signUp", status: "ok" });
    return await issueSession(accountId, normalized);
  },
});

/** Creates the demo logins that don't exist yet: `npx convex run passwordAuth:seedDemoAccounts`. */
export const seedDemoAccounts = internalAction({
  args: {},
  returns: v.object({ created: v.array(v.string()) }),
  handler: async (ctx) => {
    const created: string[] = [];
    for (const { username, password } of DEMO_ACCOUNTS) {
      const accountId = await ctx.runMutation(internal.passwordAuth.insertAccountIfAbsent, {
        username,
        passwordHash: await hashPassword(password),
      });
      if (accountId !== null) created.push(username);
    }
    logEvent({ operation: "passwordAuth.seedDemoAccounts", status: "ok", count: created.length });
    return { created };
  },
});
