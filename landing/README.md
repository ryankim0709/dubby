# DubIt landing frontend

A standalone React + TypeScript + Vite app. The page includes an illustrative dubbing walkthrough; recording, playback, signup, and backend services are not connected.

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

`npm run check` runs all checks and the production build. Use `npm run test:watch` while developing interactions, and `npm run format` to apply the frontend's Prettier configuration.

`build` typechecks and generates static files in `dist/`. `preview` serves that build locally. Tests use Vitest, jsdom, and Testing Library.

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

- `src/App.tsx`: landing page and frontend walkthrough.
- `src/styles.css`: responsive styles and shared DubIt color tokens.
- `src/App.test.tsx`: interaction smoke test.
- `vite.config.ts`, `tsconfig*.json`, `eslint.config.js`: build, test, and lint configuration.
- `Dockerfile`, `nginx.conf`: development and production container stages.
- `../compose.yaml`: local Docker development and file watching.
- `../.github/workflows/landing.yml`: frontend checks and a production image build on pushes and pull requests affecting the frontend.

No environment variables or credentials are required. Browser code and `VITE_*` variables are public; keep secrets in a backend when one is added.
