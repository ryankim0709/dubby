import type { JSX, ReactNode } from 'react';
import { WALKTHROUGH_LABEL, barHeights } from '../content';
import { Check, Listen, Mic, Play, Retry, Share } from './Icons';
import { Waveform } from './Waveform';

const originalBars = barHeights(36, 0.9, 0.35);
const takeBars = barHeights(34, 0.8, 0.45);

interface PreviewFrameProps {
  readonly label: string;
  readonly note: string;
  readonly children: ReactNode;
}

function PreviewFrame({ label, note, children }: PreviewFrameProps): JSX.Element {
  return (
    <figure className="preview" data-illustrative>
      <figcaption className="preview-label">
        <strong>{label}</strong>
        <span>{note}</span>
      </figcaption>
      <div className="preview-body">{children}</div>
    </figure>
  );
}

function SceneFrame({ progress }: { readonly progress: string }): JSX.Element {
  return (
    <div className="scene-frame" aria-hidden="true">
      <span className="scene-frame-play">
        <Play size={22} />
      </span>
      <span className="scene-frame-bar">
        <i style={{ width: progress }} />
      </span>
    </div>
  );
}

const sceneTitles = ['Rooftop at midnight', 'Last train home', 'The kitchen at 2 a.m.'] as const;

export function ScenePreview(): JSX.Element {
  return (
    <PreviewFrame
      label={WALKTHROUGH_LABEL}
      note="Sample scene titles and characters, written for this page."
    >
      <p className="pv-heading">Choose a scene</p>
      <ul className="scene-list">
        {sceneTitles.map((title: string, index: number): JSX.Element => (
          <li key={title} className={index === 1 ? 'is-picked' : undefined}>
            <span className={`scene-art scene-art-${index + 1}`} aria-hidden="true" />
            <span className="scene-name">{title}</span>
            <span className="scene-state">{index === 1 ? 'Picked' : 'Sample scene'}</span>
          </li>
        ))}
      </ul>
      <p className="pv-heading">Choose a character</p>
      <ul className="character-list">
        <li>
          <span className="scene-name">Mara</span>
          <span className="scene-state">Sample character</span>
        </li>
        <li className="is-picked">
          <span className="scene-name">Jun</span>
          <span className="scene-state">Picked · you dub these lines</span>
        </li>
      </ul>
    </PreviewFrame>
  );
}

export function LinesPreview(): JSX.Element {
  return (
    <PreviewFrame
      label={WALKTHROUGH_LABEL}
      note="Sample line, waveforms, and buttons are drawn, not live."
    >
      <SceneFrame progress="38%" />
      <p className="pv-meta">Line 2 of 5 · Jun</p>
      <p className="pv-line">“We leave at dawn, with or without a plan.”</p>
      <div className="take-rows">
        <p>
          <span className="take-name">Original</span>
          <Waveform heights={originalBars} className="is-muted" />
        </p>
        <p>
          <span className="take-name">Your take</span>
          <Waveform heights={takeBars} />
        </p>
      </div>
      <ul className="action-list" aria-label="Studio actions">
        <li>
          <Listen size={18} /> Listen
        </li>
        <li>
          <Mic size={18} /> Record
        </li>
        <li>
          <Retry size={18} /> Retry
        </li>
        <li>
          <Check size={18} /> Keep
        </li>
      </ul>
    </PreviewFrame>
  );
}

const sampleWords = ['We', 'leave', 'at', 'dawn,', 'with', 'or', 'without', 'a', 'plan.'] as const;

export function CoachingPreview(): JSX.Element {
  return (
    <PreviewFrame
      label="Example feedback"
      note="Illustrative, not a measured result. No score is shown."
    >
      <p className="pv-meta">Sample line, as it would be coached</p>
      <p className="pv-line pv-line-words">
        {sampleWords.map((word: string): JSX.Element => (
          <span key={word} className={word === 'without' ? 'word-flag' : undefined}>
            {word}{' '}
          </span>
        ))}
      </p>
      <p className="pv-strength">
        <Check size={16} /> You said every word of the script.
      </p>
      <dl className="feedback">
        <div>
          <dt>Pronunciation</dt>
          <dd>
            Work on “without”: listen to the original, say just that word slowly, then retry the
            line.
          </dd>
        </div>
        <div>
          <dt>Fluency</dt>
          <dd>There was a pause after “leave”. Try carrying “We leave at dawn” in one breath.</dd>
        </div>
        <div>
          <dt>Timing</dt>
          <dd>
            Your take ran a little past the line’s window in the scene. Tighten the pause before
            “with or without”.
          </dd>
        </div>
      </dl>
    </PreviewFrame>
  );
}

const marasLines: readonly (readonly [number, number])[] = [
  [4, 20],
  [48, 18],
  [78, 14],
];
const yourLines: readonly (readonly [number, number])[] = [
  [26, 18],
  [68, 8],
];

export function ReplayPreview(): JSX.Element {
  return (
    <PreviewFrame
      label={WALKTHROUGH_LABEL}
      note="Sample timeline and share sheet, drawn for this page."
    >
      <SceneFrame progress="62%" />
      <div className="timeline" aria-hidden="true">
        <div className="timeline-row">
          <span>Other voices and sound</span>
          <span className="timeline-track">
            {marasLines.map(([left, width]: readonly [number, number]): JSX.Element => (
              <i
                key={left}
                className="is-original"
                style={{ left: `${left}%`, width: `${width}%` }}
              />
            ))}
          </span>
        </div>
        <div className="timeline-row">
          <span>Your lines</span>
          <span className="timeline-track">
            {yourLines.map(([left, width]: readonly [number, number]): JSX.Element => (
              <i key={left} style={{ left: `${left}%`, width: `${width}%` }} />
            ))}
          </span>
        </div>
      </div>
      <p className="timeline-key">
        Other voices and sound keep playing. Your kept takes fill your character’s lines.
      </p>
      <ul className="keep-list">
        <li>
          <Check size={18} /> Saved to My Dubs
        </li>
        <li>
          <Share size={18} /> Share with the iOS share sheet
        </li>
      </ul>
    </PreviewFrame>
  );
}
