import { z } from "zod";

/** What the learner has said they want. Nothing here is inferred from practice. */
export const focusPreferences = ["any", "pronunciation", "word_accuracy", "fluency", "timing"] as const;
export type Focus = (typeof focusPreferences)[number];

export const learnerPreferences = z.strictObject({
  /** The locale to practise next, such as "en-US". Unset means the most recently practised one. */
  targetLocale: z.string().min(2).max(35).optional(),
  focus: z.enum(focusPreferences).default("any"),
  challenge: z.enum(["gentle", "standard", "stretch"]).default("standard"),
  /** Lines the learner doesn't want suggested. */
  avoidLineIds: z.array(z.string().min(1).max(200)).max(50).default([]),
  /** "off" deletes the learner's derived memory and stops writing it; practice history in Convex is unaffected. */
  memory: z.enum(["on", "off"]).default("on"),
  /** The learner's own words about their goal, kept verbatim. */
  goalNote: z.string().trim().min(1).max(280).optional(),
});
export type LearnerPreferences = z.infer<typeof learnerPreferences>;

export const defaultPreferences: LearnerPreferences = learnerPreferences.parse({});
