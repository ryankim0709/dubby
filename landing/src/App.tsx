import type { JSX } from 'react';
import { Coaching } from './components/Coaching';
import { Arrow, Github } from './components/Icons';
import { Waveform } from './components/Waveform';
import { Walkthrough } from './components/Walkthrough';
import { REPO_URL, barHeights } from './content';

const heroBars: readonly number[] = barHeights(32, 0.62, 0.27);

function App(): JSX.Element {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header shell" id="top">
        <a className="wordmark" href="#top" aria-label="dub.it, back to top">
          dub.it
        </a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <a href="#coaching">Coaching</a>
          <a className="nav-cta" href={REPO_URL} rel="noreferrer noopener">
            Source <Github size={18} />
          </a>
        </nav>
      </header>

      <main id="main" tabIndex={-1}>
        <section className="hero shell" aria-labelledby="hero-title">
          <div className="hero-copy">
            <h1 id="hero-title">
              <span className="h1-line">Your voice.</span>
              <span className="h1-line">
                A new <span>language.</span>
              </span>
            </h1>
            <p className="hero-lede">
              Pick a short scene, take over one character’s lines, and dub them in your own voice.
              Coaching works from the take you recorded. Then watch the scene play back with you in
              it.
            </p>
            <div className="hero-actions">
              <a className="button" href="#how-it-works">
                See how it works <Arrow />
              </a>
              <a className="button button-quiet" href={REPO_URL} rel="noreferrer noopener">
                Follow the build on GitHub <Github size={18} />
              </a>
            </div>
            <p className="status-note">
              <span className="status-dot" aria-hidden="true" />
              In development for iPhone · iOS 26 and later · not available to download yet
            </p>
          </div>

          <div
            className="hero-art"
            data-illustrative
            role="group"
            aria-label="Illustration of a sample line and a sample waveform"
          >
            <p className="illustrative-label">Illustration · sample line, not a recording</p>
            <p className="scene-line">
              “We leave at dawn, <em>with or without</em> a plan.”
            </p>
            <div className="audio-strip">
              <span>SAMPLE LINE</span>
              <Waveform heights={heroBars} className="hero-wave" />
              <span>ILLUSTRATIVE</span>
            </div>
            <div className="art-caption">
              <span>A little practice. A lot of character.</span>
              <span className="diagonal-arrow" aria-hidden="true">
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
            <p>
              Practise speaking by becoming part of the story. Choose a step to see what it looks
              like.
            </p>
          </div>
          <Walkthrough />
        </section>

        <Coaching />

        <section className="closing shell" aria-labelledby="closing-title">
          <h2 id="closing-title">
            Every language
            <br />
            has a story.
            <br />
            <span>Find your voice in it.</span>
          </h2>
          <ul className="facts">
            <li>Native iPhone app, iOS 26 and later</li>
            <li>In development</li>
            <li>Source code is public on GitHub</li>
          </ul>
          <div className="hero-actions">
            <a className="button" href={REPO_URL} rel="noreferrer noopener">
              Follow the build on GitHub <Github size={18} />
            </a>
            <a className="text-link" href="#how-it-works">
              Take another look <Arrow />
            </a>
          </div>
        </section>
      </main>

      <footer className="site-footer shell">
        <a className="wordmark" href="#top" aria-label="dub.it, back to top">
          dub.it
        </a>
        <p>
          Every scene, line, waveform, and piece of feedback on this page is an illustration made
          for it. No film footage or real recordings appear here.
        </p>
        <a className="back-to-top" href="#top">
          Back to top <Arrow />
        </a>
      </footer>
    </>
  );
}

export default App;
