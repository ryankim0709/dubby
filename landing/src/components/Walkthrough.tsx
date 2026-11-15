import { useRef, useState, type JSX, type KeyboardEvent } from 'react';
import { steps, type StepId, type WalkthroughStep } from '../content';
import { Arrow } from './Icons';
import { CoachingPreview, LinesPreview, ReplayPreview, ScenePreview } from './Previews';

const previews: Record<StepId, () => JSX.Element> = {
  scene: ScenePreview,
  lines: LinesPreview,
  coaching: CoachingPreview,
  replay: ReplayPreview,
};

const lastIndex = steps.length - 1;

export function Walkthrough(): JSX.Element {
  const [active, setActive] = useState<number>(1);
  const [announcement, setAnnouncement] = useState<string>('');
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const select = (index: number, announce: boolean): void => {
    const step: WalkthroughStep | undefined = steps[index];
    if (step === undefined) return;
    setActive(index);
    setAnnouncement(announce ? `Step ${index + 1} of ${steps.length}: ${step.title}` : '');
  };

  const onTabKeyDown = (event: KeyboardEvent<HTMLElement>): void => {
    const keys: Record<string, number> = {
      ArrowDown: Math.min(active + 1, lastIndex),
      ArrowRight: Math.min(active + 1, lastIndex),
      ArrowUp: Math.max(active - 1, 0),
      ArrowLeft: Math.max(active - 1, 0),
      Home: 0,
      End: lastIndex,
    };
    const next: number | undefined = keys[event.key];
    if (next === undefined) return;
    event.preventDefault();
    select(next, false);
    tabRefs.current[next]?.focus();
  };

  return (
    <div className="demo-layout" id="walkthrough">
      <div
        className="steps"
        role="tablist"
        aria-label="Four steps of dubbing a scene"
        aria-orientation="vertical"
        onKeyDown={onTabKeyDown}
      >
        {steps.map((step: WalkthroughStep, index: number): JSX.Element => (
          <div key={step.id} className="step">
            <span className="step-number" aria-hidden="true">
              {step.number}
            </span>
            <button
              ref={(node: HTMLButtonElement | null): void => {
                tabRefs.current[index] = node;
              }}
              className="step-tab"
              type="button"
              role="tab"
              id={`tab-${step.id}`}
              aria-selected={index === active}
              aria-controls={`panel-${step.id}`}
              aria-describedby={`tab-summary-${step.id}`}
              tabIndex={index === active ? 0 : -1}
              onClick={(): void => select(index, false)}
            >
              {step.title}
            </button>
            <Arrow />
            <p className="step-summary" id={`tab-summary-${step.id}`}>
              {step.summary}
            </p>
          </div>
        ))}
      </div>

      <div className="panels">
        {steps.map((step: WalkthroughStep, index: number): JSX.Element => {
          const Preview: () => JSX.Element = previews[step.id];
          return (
            <div
              key={step.id}
              className="panel"
              role="tabpanel"
              id={`panel-${step.id}`}
              aria-labelledby={`tab-${step.id}`}
              hidden={index !== active}
            >
              <h3>{step.title}</h3>
              <p className="panel-detail">{step.detail}</p>
              <Preview />
              <div className="panel-nav">
                <button
                  type="button"
                  className="nav-button"
                  aria-disabled={index === 0}
                  onClick={(): void => select(Math.max(index - 1, 0), index > 0)}
                >
                  Previous step
                </button>
                <span className="panel-count">
                  Step {index + 1} of {steps.length}
                </span>
                <button
                  type="button"
                  className="nav-button"
                  aria-disabled={index === lastIndex}
                  onClick={(): void => select(Math.min(index + 1, lastIndex), index < lastIndex)}
                >
                  Next step
                </button>
              </div>
            </div>
          );
        })}
        <p className="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
          {announcement}
        </p>
      </div>
    </div>
  );
}
