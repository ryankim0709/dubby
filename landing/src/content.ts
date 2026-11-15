export const REPO_URL = 'https://github.com/ryankim0709/dubby';
export const GRADING_CONTRACT_URL = `${REPO_URL}/blob/main/docs/grading-contract.md`;

export const WALKTHROUGH_LABEL = 'Illustrative walkthrough · no recording or playback';

export type StepId = 'scene' | 'lines' | 'coaching' | 'replay';

export interface WalkthroughStep {
  readonly id: StepId;
  readonly number: string;
  readonly title: string;
  readonly summary: string;
  readonly detail: string;
}

export const steps = [
  {
    id: 'scene',
    number: '01',
    title: 'Find your scene.',
    summary: 'Pick a short scene from a small, curated library and step into a character.',
    detail:
      'The library is small on purpose: short scenes with their characters and timed dialogue prepared ahead of time. Dubby is built around that library, not a search through arbitrary films.',
  },
  {
    id: 'lines',
    number: '02',
    title: 'Make every line yours.',
    summary: 'Dub your character’s timed lines one at a time: listen, record, retry, keep.',
    detail:
      'Each line is timed to the scene. Listen to the original, record your take, retry as often as you like, and keep the one you want. There is no timeline to edit.',
  },
  {
    id: 'coaching',
    number: '03',
    title: 'Know what to work on.',
    summary:
      'Coaching grounded in your own recording, with pronunciation, fluency, and timing kept apart.',
    detail:
      'Coaching is the part still in development. It is designed to explain what was measured in the take you recorded, one short suggestion at a time.',
  },
  {
    id: 'replay',
    number: '04',
    title: 'Play it back.',
    summary: 'Replay the scene with your voice in it, keep it in My Dubs, and share it.',
    detail:
      'Your kept takes replace the character’s lines while the rest of the scene plays on. Finished dubs are saved to My Dubs on your iPhone and shared with the iOS share sheet.',
  },
] as const satisfies readonly WalkthroughStep[];

export const barHeights = (count: number, a: number, b: number): readonly number[] =>
  Array.from({ length: count }, (_, index: number): number =>
    Math.round(18 + 76 * Math.abs(Math.sin(index * a + 0.6) * Math.cos(index * b + 0.3))),
  );
