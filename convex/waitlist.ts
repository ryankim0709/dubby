import { v } from "convex/values";
import { internalMutation } from "./_generated/server";

/** "founding" means the person asked about the paid founding plan; payment itself happens on Stripe, not here. */
export const waitlistPlans = ["free", "founding"] as const;
export type WaitlistPlan = (typeof waitlistPlans)[number];

export type WaitlistSignup = {
  email: string;
  plan: WaitlistPlan;
  language?: string;
  source?: string;
};

export type ParsedSignup =
  | { kind: "signup"; signup: WaitlistSignup }
  /** The hidden honeypot field was filled in, so a bot submitted the form. It gets a normal success reply and nothing is stored. */
  | { kind: "bot" }
  | { kind: "invalid"; error: string };

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function optionalText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim().slice(0, maxLength);
  return trimmed === "" ? undefined : trimmed;
}

/** Validates the landing page's JSON body. It's pure so the rules can be tested without a backend. */
export function parseWaitlistSignup(body: unknown): ParsedSignup {
  if (typeof body !== "object" || body === null) return { kind: "invalid", error: "Send a JSON object" };
  const fields = body as Record<string, unknown>;
  if (typeof fields.website === "string" && fields.website.trim() !== "") return { kind: "bot" };

  const email = typeof fields.email === "string" ? fields.email.trim().toLowerCase() : "";
  if (email.length > 254 || !emailPattern.test(email)) return { kind: "invalid", error: "Enter a valid email address" };

  const plan = fields.plan ?? "free";
  if (!waitlistPlans.includes(plan as WaitlistPlan)) return { kind: "invalid", error: "Choose the free or founding plan" };

  return {
    kind: "signup",
    signup: {
      email,
      plan: plan as WaitlistPlan,
      language: optionalText(fields.language, 40),
      source: optionalText(fields.source, 100),
    },
  };
}

/**
 * Adds a signup once per email. Signing up again with the founding plan upgrades the plan,
 * but going back to free doesn't downgrade it, so someone who asked to pay is never lost.
 */
export const join = internalMutation({
  args: {
    email: v.string(),
    plan: v.union(v.literal("free"), v.literal("founding")),
    language: v.optional(v.string()),
    source: v.optional(v.string()),
  },
  handler: async (ctx, args): Promise<{ created: boolean }> => {
    const existing = await ctx.db
      .query("waitlist")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();
    if (existing !== null) {
      if (args.plan === "founding" && existing.plan !== "founding") {
        await ctx.db.patch(existing._id, { plan: "founding", updatedAt: Date.now() });
      }
      return { created: false };
    }
    const now = Date.now();
    await ctx.db.insert("waitlist", { ...args, createdAt: now, updatedAt: now });
    return { created: true };
  },
});
