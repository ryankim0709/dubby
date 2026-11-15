# DubIt landing site

The marketing page for DubIt, a native iPhone app in development that teaches languages by dubbing short scenes. It is a standalone React + TypeScript + Vite app. Nothing on the page records audio, plays media, or talks to a backend.

## What the page says

The page explains four things: choosing a scene from a small curated library, picking a character and dubbing their timed lines, coaching grounded in the learner's own recording (pronunciation, fluency, and timing kept distinct), and replaying the dub, saving it to My Dubs, and sharing it. It is for iPhone, iOS 26 and later, and says it is in development.

Rules the content follows, and the tests enforce where they can:

- Every illustration, mock UI, waveform, sample line, and piece of sample feedback is labeled as illustrative. Example coaching is labeled "Example feedback" and shows no scores.
- Links go only to in-page anchors and the public repository (`https://github.com/ryankim0709/dubby`, including its grading contract). There is no signup, waitlist, store badge, or email link.
- No film footage or real recordings are used. Scene art is CSS and SVG.
- The page names no domain we do not own, so `index.html` has no canonical URL, `og:url`, or `og:image`.

## Local development

Use Node.js 24 LTS (`.nvmrc`) and npm. From this directory:

```sh
npm ci
npm run dev
```

Open http://127.0.0.1:5173. Vite updates the page as source files change.

```sh
npm run typecheck
npm run lint
npm run format:check
npm test
npm run build
npm run preview
```

`npm run check` runs all checks and the production build. Use `npm run test:watch` while developing interactions, and `npm run format` to apply the Prettier configuration. `preview` serves the production build at http://127.0.0.1:4173.

## Tests

Tests use Vitest, jsdom, Testing Library, and axe-core.

- `src/App.test.tsx`: landmarks, heading order, skip link, and that every illustration carries a visible label.
- `src/Walkthrough.test.tsx`: the step walkthrough with mouse and keyboard, the quiet live region, and the labels and no-score rule for the preview panels.
- `src/links.test.tsx`: external links point only to the allowed repository URLs, in-page anchors resolve, and no forms, store links, or availability claims appear.
- `src/a11y.test.tsx`: axe-core finds no violations in any walkthrough step. jsdom has no layout, so axe's color-contrast rule is off here.
- `src/contrast.test.ts`: WCAG 2.2 contrast ratios computed from the color tokens in `styles.css` (4.5:1 for text pairs, 3:1 for graphics).
- `src/document.test.ts`: `index.html` metadata, and the reduced-motion and focus-ring rules in `styles.css`.

### Browser checks (manual)

jsdom cannot check layout, so check the production build in a real browser after visual changes. Run `npm run build && npm run preview`, then:

1. At 320, 375, 414, 768, 1024, and 1440 px wide, confirm `document.documentElement.scrollWidth <= document.documentElement.clientWidth`.
2. Press Tab from the top. The skip link appears first and moves focus to the main landmark. Every stop shows the violet focus ring. In the walkthrough, use the arrow keys, Home, and End to move between steps.
3. Emulate `prefers-reduced-motion: reduce`. The hero waveform draw-in, the panel transition, and smooth scrolling should all stop.
4. Run axe-core in the page, including its color-contrast rule, for each walkthrough step.

## Walkthrough accessibility

The four steps use WAI-ARIA tabs: a vertical `tablist`, a roving `tabindex`, and one `tabpanel` per step. Arrow keys, Home, and End move focus and select the step. Each panel has Previous step and Next step buttons. A polite, visually hidden live region announces "Step n of 4" only after those buttons, so moving through the tabs stays silent.

## Color tokens

The palette matches the app's `Palette` tokens. Ratios use WCAG relative luminance and are asserted in `src/contrast.test.ts`.

| Pair                               | Ratio |
| ---------------------------------- | ----- |
| text #ededed on background #100d19 | 16.40 |
| secondary #cdcdcd on background    | 12.08 |
| muted #a6a1b5 on background        | 7.67  |
| accent text #b5a0ff on background  | 8.63  |
| accent #a78bfa on background       | 7.06  |
| text on surface #252131            | 13.38 |
| secondary on surface               | 9.85  |
| muted on surface                   | 6.26  |
| accent text on surface             | 7.04  |
| accent on surface                  | 5.76  |
| on-accent #100d19 on accent        | 7.06  |
| on-accent-soft #2a2140 on accent   | 5.55  |
| graphic #7a7390 on surface         | 3.49  |

Divider and track colors are decorative rules and fills, never the only cue for a state.

## Docker

From the repository root, start development with Docker Compose (2.32+):

```sh
docker compose up --build --watch
```

Open http://127.0.0.1:5173. Compose syncs source edits and rebuilds when dependencies change. Stop with Ctrl+C; use `docker compose down` to remove the development container and network.

Build and run the production image from the repository root:

```sh
docker build -t dubit-landing ./landing
docker run --rm -p 127.0.0.1:8080:8080 dubit-landing
```

Open http://127.0.0.1:8080. The final image serves static files with unprivileged Nginx and contains no Node.js runtime or development dependencies.

## Project layout

- `src/App.tsx`: page structure, hero, and closing.
- `src/content.ts`: walkthrough copy, allowed link URLs, and the shared illustrative label.
- `src/components/`: the walkthrough tabs, the four step previews, the coaching section, icons, and the waveform.
- `src/styles.css`: responsive styles and the color tokens.
- `index.html`: document metadata.
- `vite.config.ts`, `tsconfig*.json`, `eslint.config.js`: build, test, and lint configuration.
- `Dockerfile`, `nginx.conf`: development and production container stages.
- `../compose.yaml`: local Docker development and file watching.
- `../.github/workflows/landing.yml`: frontend checks and a production image build on pushes and pull requests affecting the frontend.

No environment variables or credentials are required. Browser code and `VITE_*` variables are public; keep secrets in a backend when one is added.
