import type { Coaching, CoachingInput, CoachingProvider } from "./integrations/contracts";

type FocusItem = Coaching["focus"][number];

// Initial product thresholds, to calibrate against real recordings with the grading contract's weights.
const weakScore = 70;
const strongScore = 85;
const maxFocusItems = 3;

/**
 * Coaching drawn only from the stored measurements, with no model call: each strength or focus item cites a
 * score or word result that exists. A pronunciation or fluency finding needs a non-null acoustic score for it,
 * so a transcript-only assessment, whose pronunciation and fluency are null, can only get word and timing coaching.
 */
export function coachAssessment(input: CoachingInput): Coaching {
  const base = { provider: "dubby-tutoring", configVersion: "tutoring-coaching-v1" };
  if (input.status === "unscorable" || input.scores === null) {
    return { ...base, summary: "This take couldn't be scored, so there's nothing to coach yet. Record the line again, close to the microphone in a quiet place.", strengths: [], focus: [] };
  }
  const { scores } = input;
  const strengths: string[] = [];
  if (scores.wordAccuracy !== null && scores.wordAccuracy >= strongScore) strengths.push("You got the words of the line right.");
  if (scores.timingFit !== null && scores.timingFit >= strongScore) strengths.push("Your timing matched the scene.");
  if (scores.pronunciation !== null && scores.pronunciation >= strongScore) strengths.push("Your pronunciation was clear.");
  if (scores.fluency !== null && scores.fluency >= strongScore) strengths.push("You spoke smoothly.");

  const wordFocus: FocusItem[] = [];
  for (const word of input.wordResults) {
    if (word.referenceWordIndex === null || word.expected === null) continue;
    if (word.textStatus === "substituted") {
      wordFocus.push({ kind: "word_accuracy", referenceWordIndex: word.referenceWordIndex, practiceText: word.expected, instruction: `Say "${word.expected}" clearly${word.recognized === null ? "" : `; it was heard as "${word.recognized}"`}.` });
    } else if (word.textStatus === "omitted") {
      wordFocus.push({ kind: "word_accuracy", referenceWordIndex: word.referenceWordIndex, practiceText: word.expected, instruction: `Don't skip "${word.expected}"; say it in its place in the line.` });
    } else if (scores.pronunciation !== null && word.pronunciationScore !== null && word.pronunciationScore < weakScore) {
      wordFocus.push({ kind: "pronunciation", referenceWordIndex: word.referenceWordIndex, practiceText: word.expected, instruction: `Say "${word.expected}" slowly three times, then in the whole line.` });
    }
  }
  const lineFocus: FocusItem[] = [];
  if (scores.timingFit !== null && scores.timingFit < weakScore) {
    lineFocus.push({ kind: "timing", referenceWordIndex: null, practiceText: input.referenceText, instruction: "Match the pace of the original scene: start with the actor and finish when the line ends." });
  }
  if (scores.fluency !== null && scores.fluency < weakScore) {
    lineFocus.push({ kind: "fluency", referenceWordIndex: null, practiceText: input.referenceText, instruction: "Say the line in one smooth go, without stopping between words." });
  }
  const focus = [...wordFocus, ...lineFocus].slice(0, maxFocusItems);

  const summary =
    focus.length === 0
      ? "That take matched the line well. Keep it up and try the next line."
      : "Good effort. Work on the items below, then record the line again.";
  return { ...base, summary, strengths, focus };
}

export const tutoringCoachingProvider: CoachingProvider = {
  coach: async (input) => coachAssessment(input),
};
