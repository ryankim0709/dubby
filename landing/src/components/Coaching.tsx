import type { JSX } from 'react';
import { GRADING_CONTRACT_URL } from '../content';
import { Arrow } from './Icons';

const signals = [
  {
    name: 'Pronunciation',
    body: 'How the words sounded, measured from your audio. Saying the right words is not the same as saying them well, so a word can match the script and still be the one to practise.',
  },
  {
    name: 'Fluency',
    body: 'How smoothly the line came out: hesitations and pauses. It is its own signal, not a side effect of pronunciation.',
  },
  {
    name: 'Timing',
    body: 'How your take fits the line’s window in the scene. It is a dubbing measure, kept apart from your language practice so a perfect fit never hides a word that needs work.',
  },
] as const;

const principles = [
  'Built from your take. Feedback is meant to come from an assessment of the recording you made, not from a template.',
  'No invented numbers. When something could not be measured, the app says so instead of guessing.',
  'Unusable audio is not a low grade. A silent or noisy take gets recording tips, not a failing mark.',
  'You are not graded on sounding like the actor. Voice and acting style are not language errors.',
] as const;

const sampleWords = ['We', 'leave', 'at', 'dawn', 'with', 'or', 'without', 'a', 'plan'] as const;

export function Coaching(): JSX.Element {
  return (
    <section className="coaching shell" id="coaching" aria-labelledby="coaching-title">
      <div className="section-heading">
        <h2 id="coaching-title">
          Coaching that listens
          <br />
          to your own take.
        </h2>
        <p>
          This is the part still in development. Here is how it is designed to work, and what it
          will not pretend to do.
        </p>
      </div>

      <div className="coaching-grid">
        <dl className="signals">
          {signals.map((signal: { readonly name: string; readonly body: string }): JSX.Element => (
            <div key={signal.name}>
              <dt>{signal.name}</dt>
              <dd>{signal.body}</dd>
            </div>
          ))}
        </dl>

        <figure className="lanes" data-illustrative>
          <figcaption className="preview-label">
            <strong>Illustrative diagram</strong>
            <span>Three separate signals for one sample line. Nothing here was measured.</span>
          </figcaption>
          <div className="lane">
            <span className="lane-name">Pronunciation</span>
            <span className="lane-words" aria-hidden="true">
              {sampleWords.map((word: string): JSX.Element => (
                <span key={word} className={word === 'without' ? 'word-flag' : undefined}>
                  {word}
                </span>
              ))}
            </span>
            <span className="lane-note">One word flagged to practise: “without”.</span>
          </div>
          <div className="lane">
            <span className="lane-name">Fluency</span>
            <span className="lane-flow" aria-hidden="true">
              <i style={{ width: '24%' }} />
              <b />
              <i style={{ width: '52%' }} />
            </span>
            <span className="lane-note">A pause after “leave” is marked as a gap.</span>
          </div>
          <div className="lane">
            <span className="lane-name">Timing</span>
            <span className="lane-time" aria-hidden="true">
              <span className="lane-window" />
              <span className="lane-take" />
            </span>
            <span className="lane-note">Your take against the line’s window in the scene.</span>
          </div>
        </figure>
      </div>

      <ul className="principles">
        {principles.map((text: string): JSX.Element => (
          <li key={text}>{text}</li>
        ))}
      </ul>

      <a className="text-link" href={GRADING_CONTRACT_URL} rel="noreferrer noopener">
        Read the proposed grading contract <Arrow />
      </a>
    </section>
  );
}
