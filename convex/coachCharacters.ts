/**
 * OpenAI's built-in speech voices only. The speech API also accepts a custom voice object, which would be a
 * cloned voice; the union leaves that out so a character can't be given one.
 */
export const stockVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"] as const;
export type StockVoice = (typeof stockVoices)[number];

/** A coach the learner can talk to: one LiveAvatar image avatar (video only), one OpenAI voice, and a persona for the model. */
export type CoachCharacter = {
  id: string;
  name: string;
  /** One line shown under the name in the app. */
  summary: string;
  /** Deployment env var holding this character's LiveAvatar `avatar_id`. */
  avatarIdEnv: string;
  /** One of OpenAI's built-in speech voices; the avatar's mouth follows this audio. */
  openaiVoice: StockVoice;
  /** How OpenAI's speech model should deliver the voice. */
  voiceStyle: string;
  persona: string;
};

/** What the app sees: no provider IDs, voices or prompts. */
export type PublicCoachCharacter = Pick<CoachCharacter, "id" | "name" | "summary">;

// Test characters for the bundled Star Wars clip. Their avatars must be created from original or
// licensed artwork the account is authorized to use, never from frames of the film.
export const coachCharacters: readonly CoachCharacter[] = [
  {
    id: "anakin",
    name: "Anakin",
    summary: "Intense and impatient. Pushes you to say it again, with feeling.",
    avatarIdEnv: "LIVEAVATAR_AVATAR_ID_ANAKIN",
    openaiVoice: "ash",
    voiceStyle: "Intense and a little impatient, with the warmth of someone who wants you to win.",
    persona:
      "You are Anakin, a gifted young knight: intense, proud, a little impatient, and fiercely loyal. " +
      "You coach with urgency and high standards, and you are quick to praise real effort.",
  },
  {
    id: "obi-wan",
    name: "Obi-Wan",
    summary: "Calm and dry-witted. Breaks every line into small, clear steps.",
    avatarIdEnv: "LIVEAVATAR_AVATAR_ID_OBI_WAN",
    openaiVoice: "cedar",
    voiceStyle: "Calm, patient and dryly witty, unhurried.",
    persona:
      "You are Obi-Wan, a seasoned mentor: calm, patient, and dryly witty. " +
      "You coach by breaking things into small steps and you never rush the learner.",
  },
];

export function publicCharacter(character: CoachCharacter): PublicCoachCharacter {
  return { id: character.id, name: character.name, summary: character.summary };
}

export function findCharacter(id: string): CoachCharacter | undefined {
  return coachCharacters.find((character) => character.id === id);
}
