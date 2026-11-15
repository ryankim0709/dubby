# Grading contract

Status: proposed v1. This document defines the intended grading response and progress semantics. The app records and exports dubs locally but does not grade language performance. No grading endpoint, provider integration, or runtime schema implements this contract yet. All example results are illustrative.

## Unit of grading and ownership

One attempt is one original recording of one character's line. A retry creates a new attempt. Grade the original audio before character-voice conversion, and preserve its link to the recording, user, project, scene, character, and reference line.

- The backend supplies identifiers, versions, validated recording metadata, and computed totals.
- A speech-assessment engine supplies acoustic measurements and word-level evidence.
- A coaching model explains that evidence in short, actionable language. It must not invent measurements, phoneme errors, or progress deltas.
- Convex stores attempts and assessments and computes history and progress. Which take the user accepts is separate project state, not a grader decision.

The response is an API contract assembled by the backend, not a JSON object that a language model generates in its entirety.

## Response envelope

Both `scored` and `unscorable` responses contain these fields:

- `schemaVersion`: integer `1`, identifying the response shape.
- `rubricVersion`: string `language-v1`, identifying metric definitions, text normalization, aggregation, and rounding rules.
- `assessmentId`: nonempty string identifying this evaluation. Reassessing an existing recording creates a new assessment, not a new practice attempt.
- `attemptId`: nonempty string identifying the immutable original recording attempt.
- `lineId`: nonempty string identifying the reference dialogue line.
- `referenceVersion`: positive integer identifying the immutable transcript, tokenization, and source-timing revision.
- `locale`: the target speech locale, such as `en-US`. It is distinct from the learner's native language and time zone.
- `recordedAt`: RFC 3339 recording timestamp copied from validated attempt metadata. The coaching model never chooses it.
- `status`: `scored` or `unscorable`.
- `referenceText`: the reference transcript for the recorded revision.
- `recognizedText`: the recognized utterance, or `null` when no transcript is available. Preserve the display transcript separately from normalized tokens used for alignment.
- `scores`, `unavailableMetrics`, `wordResults`, and `coaching`: defined below.

The backend verifies ownership and resolves the reference from stored project data. It must not accept client-supplied scores, user identity, or arbitrary reference text as grading authority.

## Scored response

`status: "scored"` means usable speech yielded at least one language measurement: pronunciation, word accuracy, or fluency. Timing alone does not make a language attempt scorable. When alignment is available, return it in full, including correctly matched words, so the UI can highlight the sentence and replay specific words.

```json
{
  "schemaVersion": 1,
  "rubricVersion": "language-v1",
  "assessmentId": "assessment_001",
  "attemptId": "take_003",
  "lineId": "scene_001_line_02",
  "referenceVersion": 1,
  "locale": "en-US",
  "recordedAt": "2026-11-14T18:00:00-08:00",
  "status": "scored",
  "referenceText": "You underestimate my power.",
  "recognizedText": "You underestimate my power.",
  "scores": {
    "languageOverall": 88,
    "pronunciation": 82,
    "wordAccuracy": 100,
    "fluency": 80,
    "timingFit": 90
  },
  "unavailableMetrics": [],
  "wordResults": [
    {
      "referenceWordIndex": 0,
      "expected": "You",
      "recognized": "You",
      "textStatus": "matched",
      "pronunciationScore": 96,
      "startMs": 200,
      "endMs": 420
    },
    {
      "referenceWordIndex": 1,
      "expected": "underestimate",
      "recognized": "underestimate",
      "textStatus": "matched",
      "pronunciationScore": 64,
      "startMs": 430,
      "endMs": 1550
    },
    {
      "referenceWordIndex": 2,
      "expected": "my",
      "recognized": "my",
      "textStatus": "matched",
      "pronunciationScore": 93,
      "startMs": 1650,
      "endMs": 1880
    },
    {
      "referenceWordIndex": 3,
      "expected": "power",
      "recognized": "power",
      "textStatus": "matched",
      "pronunciationScore": 91,
      "startMs": 2000,
      "endMs": 2900
    }
  ],
  "coaching": {
    "summary": "You included every word. Focus next on 'underestimate'.",
    "strengths": [
      "You followed the complete script."
    ],
    "focus": [
      {
        "kind": "pronunciation",
        "referenceWordIndex": 1,
        "instruction": "Listen to 'underestimate', repeat it slowly, then retry the sentence.",
        "practiceText": "underestimate"
      }
    ]
  }
}
```

In this example the spoken span lasts 2,700 ms and the source line's target window lasts 3,000 ms, producing the illustrated timing score. The utterance pronunciation score is a separate engine measurement; it is not required to equal the arithmetic mean of the word scores.

## Scores and missing measurements

Every property in `scores` is present and is either a finite number from 0 through 100 or `null`:

- `pronunciation`: the speech engine's acoustic pronunciation measurement, normalized to the contract's scale. Transcript similarity cannot substitute for it.
- `wordAccuracy`: script agreement after locale-specific, versioned normalization and tokenization. It measures the expected words, not grammar knowledge or comprehension.
- `fluency`: the speech engine's measurement of smoothness, hesitation, and pauses.
- `timingFit`: the fit between the user's spoken duration and the reference line's dialogue window. It is a dubbing measurement and remains outside the language total.
- `languageOverall`: the backend-computed language practice score, using the formula below.

The proposed initial weights are:

```text
languageOverall = round(0.45 × pronunciation + 0.35 × wordAccuracy + 0.20 × fluency)
```

Calculate using the component values before display rounding, then round the total to the nearest integer, with halves rounded up. The example yields `round(87.9) = 88`. These are initial product weights to calibrate against real recordings, not a validated language-proficiency scale.

For word accuracy, align normalized reference and recognized tokens, counting substitutions `S`, omissions `D`, and insertions `I` against `N` reference tokens:

```text
wordAccuracy = 100 × max(0, 1 - (S + D + I) / N)
```

The reference must contain at least one token. Ignore case and punctuation when appropriate for the locale, preserve the display text, and version any tokenizer or normalization changes. Script substitutions count as script mismatches, not automatically as grammar mistakes.

For timing fit, let `d` be the time from the first spoken word's start to the last spoken word's end, including pauses between them, and `t` be the source line's end minus start. Both use milliseconds:

```text
timingFit = round(100 × max(0, 1 - abs(d - t) / t))
```

The target window must be positive. Recording silence before or after the utterance does not count as spoken duration. Use `null` when reliable speech boundaries cannot be measured.

For every null score, `unavailableMetrics` contains exactly one object with:

- `metric`: one of the five score property names.
- `reason`: `unsupported_locale`, `insufficient_evidence`, or `missing_components`.

Use `missing_components` only for `languageOverall`, which is null whenever pronunciation, word accuracy, or fluency is unavailable. Never substitute zero or silently redistribute the weights. A measured metric has no unavailable entry. Known provider capability limits can produce unavailable metrics; malformed or unexpectedly missing required provider fields are errors, not a reason to fabricate a partial success.

Prosody and actor-style similarity are outside this initial response. Adding them requires measured evidence, an explicit contract revision, and a decision about their role in the product; they must not silently change the language total.

## Word alignment and coaching

`wordResults` is an ordered alignment of reference tokens and recognized tokens. In an available alignment, each reference token appears once; inserted tokens appear in their spoken position with no reference index. If a reliable alignment cannot be produced, return an empty array and a null `wordAccuracy` with an `insufficient_evidence` reason. Missing transcription must not be treated as evidence that the learner omitted every word.

- `referenceWordIndex`: zero-based reference token index, or `null` for an insertion.
- `expected`: reference token, or `null` for an insertion.
- `recognized`: recognized token, or `null` for an omission.
- `textStatus`: `matched`, `substituted`, `omitted`, or `inserted`.
- `pronunciationScore`: a measured word-level value from 0 through 100, or `null`. When null, include `pronunciationUnavailableReason` with `omitted_word`, `unaligned_word`, `unsupported_locale`, or `insufficient_evidence`.
- `startMs` and `endMs`: integer recording-relative boundaries, with an exclusive end. For measured spans, `0 <= startMs < endMs <= recording duration`. Omissions have null boundaries; other unmeasurable boundaries also stay null rather than being invented.

A word may be `matched` while its pronunciation score is low, as the example demonstrates. Do not use one field to replace the other. A substitution has both an expected and a recognized token; an omission has no recognized token or pronunciation score; an insertion has no expected token or reference index.

`coaching` contains a nonempty `summary`, a `strengths` array of short strings, and a `focus` array of at most three suggestions. Each suggestion contains:

- `kind`: `pronunciation`, `word_accuracy`, `fluency`, or `timing`.
- `referenceWordIndex`: a valid reference index, or `null` for whole-line advice or an insertion.
- `instruction`: a short, actionable practice instruction grounded in the measurements.
- `practiceText`: the word or phrase to practice.

Empty strengths or focus arrays are valid when the evidence does not support a useful item. Do not manufacture praise, a problem, a phoneme-level diagnosis, or an improvement claim to fill them. Differences in voice identity or acting style do not themselves establish a language error.

## Unscorable audio and processing failures

When no meaningful grade can be produced, return the same response envelope with:

- `status: "unscorable"`.
- `reason`: `no_speech`, `excessive_noise`, `insufficient_speech`, or `unsupported_locale`, based on observed evidence or a known service capability.
- `scores: null`, `wordResults: []`, and `unavailableMetrics: []`.
- `recognizedText`: the actual transcript if one exists, otherwise `null`.
- `coaching`: a clear explanation and recording guidance, with empty strengths and focus arrays. This is not a low language score.

Queued and processing states belong to the assessment job, not to a completed grading result. A provider outage, authentication failure, invalid response, invalid reference, or coaching-service failure makes that job explicitly fail; it must not become an `unscorable` result or a fabricated successful grade. Retain the original recording so the operation can be retried.

## Persistence, versions, and progress

Persist each attempt's authenticated owner, project/scene/character/line references, original recording reference, validated capture time, server receipt time, and measured speaking duration. Preserve reference revisions and assessment results. Store the evaluator provider, reported model version when available, evaluator configuration version, and completion time as assessment provenance; do not invent a provider version when it is not disclosed.

Backend retries of the same operation must not create extra practice attempts. A deliberate regrade receives a new `assessmentId` while retaining the original `attemptId`; progress calculations choose the applicable assessment version once per attempt. Store the user's accepted take separately so accepting a retry does not erase prior measurements.

Derive progress in Convex rather than asking a coaching model to generate historical totals:

- **First-attempt performance:** for each displayed metric and distinct line/reference revision practiced on a local calendar day, use the earliest scorable attempt with that metric available, and average those per-line values equally. This is first-scorable performance; earlier unusable recordings contribute no score. Repeated retries of one easy line must not dominate the daily average.
- **Best-attempt performance:** select the highest non-null `languageOverall` per line/day, breaking ties by the earliest recording time. Keep that take's component scores together rather than combining peaks from different takes. Label accepted-take performance separately if shown; the user's chosen take need not have the highest score.
- **Repeated-line improvement:** compare the same learner, reference line/revision, locale, rubric, and evaluator configuration using a consistent attempt-selection rule across days. Show this separately from averages over different scenes.
- **Practice volume:** count unique attempts and lines and sum measured speaking time. Regrading never adds speaking time; silence is not speaking time.
- **Recurring difficulties:** group evidence-backed word issues by locale and normalized reference word, retaining the supporting attempts.

Use validated capture times and the learner's IANA time zone for local-day grouping, not assessment completion times. Exclude unscorable results and failed jobs from score averages. Exclude unavailable metrics from that metric's average and report its contributing sample count; do not turn missing data into zero.

Keep different locales, rubrics, and evaluator configurations in separate progress series unless a deliberate calibration or regrading process makes them comparable. Record the time-zone policy used for a daily summary so a profile time-zone change does not silently reinterpret historical results.

These signals describe performance on practiced language material. They do not establish vocabulary comprehension, general grammar ability, or a CEFR level from repeating movie dialogue. Scene summaries and streak policies are separate derived features, not fields that the line-grading model invents.

## Validation and implementation boundary

Validate required response fields, enum values, score bounds, null reasons, reference indices, alignment coverage, timestamps, and recording bounds at the service boundary. Ignore unrelated extra provider fields while requiring the fields the chosen integration depends on. Keep transport and provider-specific payloads behind typed adapters.

The contract does not select an assessment vendor or implement Swift models, Convex tables, endpoints, coaching prompts, or daily-summary queries. Those are follow-on implementation work. The existing saved-dub records and practice totals do not implement this grading contract.

For an example of a speech service exposing acoustic and word-level measurements, see [Microsoft's pronunciation assessment documentation](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment). Its provider-specific scoring formula is separate from the proposed Dubby rubric above.
