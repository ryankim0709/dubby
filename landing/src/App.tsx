import { useState, type JSX } from 'react';

type StepId = 'scene' | 'voice' | 'replay';

interface DemoStep {
  readonly id: StepId;
  readonly number: string;
  readonly title: string;
  readonly description: string;
  readonly previewLabel: string;
  readonly line: string;
  readonly note: string;
}

const steps = [
  {
    id: 'scene',
    number: '01',
    title: 'Find your scene.',
    description: 'Pick a short scene and step into a character’s shoes.',
    previewLabel: 'Choose your character',
    line: 'Every good story needs a voice.',
    note: 'A short scene. A character. Your next challenge.',
  },
  {
    id: 'voice',
    number: '02',
    title: 'Make every line yours.',
    description: 'Listen, record, and work on your pronunciation, one line at a time.',
    previewLabel: 'Inside the dubbing studio',
    line: '“Where do we go from here?”',
    note: 'Listen to the original. Practice the line. Try another take.',
  },
  {
    id: 'replay',
    number: '03',
    title: 'Play it back.',
    description: 'Hear your performance in the scene, then keep the dub or share it.',
    previewLabel: 'Your scene, your performance',
    line: 'Same scene. A whole new you.',
    note: 'The goal: a scene you can watch, hear, and make your own.',
  },
] as const satisfies readonly DemoStep[];

function Arrow(): JSX.Element {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M5 12h14m-6-6 6 6-6 6"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function Waveform(): JSX.Element {
  const heights: readonly number[] = [
    18, 28, 46, 32, 54, 70, 44, 30, 60, 82, 62, 38, 54, 74, 94, 64, 44, 60, 76, 48, 28, 46, 64, 40,
    24, 36, 52, 30, 18,
  ];

  return (
    <svg className="waveform" viewBox="0 0 300 100" fill="none" aria-hidden="true">
      {heights.map((height: number, index: number): JSX.Element => (
        <path
          key={index}
          d={`M${10 + index * 10} ${(100 - height) / 2}v${height}`}
          stroke="currentColor"
          strokeWidth="4"
          strokeLinecap="round"
        />
      ))}
    </svg>
  );
}

function App(): JSX.Element {
  const [activeStep, setActiveStep] = useState<DemoStep>(steps[1]);

  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header shell">
        <a className="wordmark" href="#" aria-label="DubIt home">
          dub.it
        </a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <a className="nav-cta" href="#demo">
            Explore DubIt <Arrow />
          </a>
        </nav>
      </header>

      <main id="main">
        <section className="hero shell" aria-labelledby="hero-title">
          <div className="hero-copy">
            <h1 id="hero-title">
              Your voice.
              <br />A new
              <br />
              <span>language.</span>
            </h1>
            <p>
              Step into a scene. Take over the dialogue. Turn language practice into a performance
              worth replaying.
            </p>
            <a className="button" href="#demo">
              See how it works <Arrow />
            </a>
            <p className="platform-note">Made for iPhone. Built around your voice.</p>
          </div>

          <div className="hero-art" aria-label="Illustration of a line becoming your performance">
            <div className="scene-line">
              “Where do
              <br />
              we go
              <br />
              <em>from here?</em>”
            </div>
            <div className="audio-strip">
              <span>YOUR VOICE</span>
              <Waveform />
              <span>TAKE 01</span>
            </div>
            <div className="art-caption">
              <span>A little practice. A lot of character.</span>
              <span className="diagonal-arrow">
                <Arrow />
              </span>
            </div>
          </div>
        </section>

        <section className="experience shell" id="how-it-works" aria-labelledby="experience-title">
          <div className="section-heading">
            <h2 id="experience-title">
              Less memorizing.
              <br />
              More main character.
            </h2>
            <p>The idea is simple: practice speaking by becoming part of the story.</p>
          </div>

          <div className="demo-layout" id="demo">
            <div className="steps" role="group" aria-label="Explore the dubbing experience">
              {steps.map((step: DemoStep): JSX.Element => (
                <button
                  key={step.id}
                  className="step"
                  type="button"
                  aria-pressed={activeStep.id === step.id}
                  aria-controls="demo-preview"
                  onClick={(): void => setActiveStep(step)}
                >
                  <span className="step-number">{step.number}</span>
                  <span>
                    <span className="step-title">{step.title}</span>
                    <span className="step-description">{step.description}</span>
                  </span>
                  <Arrow />
                </button>
              ))}
            </div>
            <div
              className="demo-preview"
              id="demo-preview"
              role="region"
              aria-label="Experience preview"
              aria-live="polite"
              aria-atomic="true"
            >
              <div className="preview-top">
                <span>{activeStep.previewLabel}</span>
                <span>dub.it</span>
              </div>
              <p className="preview-line">{activeStep.line}</p>
              <Waveform />
              <p className="preview-note">{activeStep.note}</p>
              <span className="preview-disclaimer">
                Illustrative walkthrough · no recording or playback
              </span>
            </div>
          </div>
        </section>

        <section className="closing shell" aria-labelledby="closing-title">
          <h2 id="closing-title">
            Every language
            <br />
            has a story.
            <br />
            <span>Find your voice in it.</span>
          </h2>
          <a className="text-link" href="#demo">
            Take another look <Arrow />
          </a>
        </section>
      </main>

      <footer className="site-footer shell">
        <a className="wordmark" href="#" aria-label="DubIt home">
          dub.it
        </a>
        <p>Language learning. With a little more drama.</p>
        <a className="back-to-top" href="#main">
          Back to top <Arrow />
        </a>
      </footer>
    </>
  );
}

export default App;
