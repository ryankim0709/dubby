# Provenance

This repository's baseline was imported from a read-only reference repository. This note records what came across, what did not, and why.

| | |
|---|---|
| Source repository | github.com/ryankim0709/dubbing-priv (read-only reference) |
| Source commit | `main` @ `f8ebdfb5d5385232a8882f23ba043431233841eb` |
| Import date | 2026-11-15 |
| Destination | github.com/ryankim0709/dubby `main`, one commit on top of `3bcf31a` ("Initialize empty repository") |
| Method | `git archive f8ebdfb5d5385232a8882f23ba043431233841eb`, extracted into this repository, so only tracked files came across |

## History

The development history of dubbing-priv was not carried over. The import is a single commit, and the source's commits, authors, branches, and tags are not part of this repository. To see how a file evolved before the import, read it in dubbing-priv at the commit above.

## Imported

All 150 files tracked at the source commit, byte for byte, with no source file edited:

- `Dubbing/`: the SwiftUI app source (DubFlow, Coach, Library, tab screens, Theme) and the asset catalog.
- `DubbingTests/`: the Swift Testing suites and `Fixtures/two-tone-3s.mp4`, a synthetic 3-second clip (black 64×64 H.264 video with mono AAC audio carrying 80 Hz and 1 kHz tones, generated with ffmpeg).
- `Dubbing.xcodeproj/`: `project.pbxproj`, the shared `Dubbing` scheme (`xcshareddata/xcschemes/Dubbing.xcscheme`), and the SwiftPM `Package.resolved`.
- `Config/Dubbing-Info.plist`.
- `convex/`: the coach backend HTTP actions and their `tsconfig.json`.
- `landing/`: the Vite and React landing page with its lockfile, Dockerfile, and tooling config.
- `docs/grading-contract.md`.
- `Media/README.md`.
- `.cursor/rules/`: the dubbing-pipeline, product, and swift rules.
- `.agents/skills/impeccable/`: the impeccable design skill, with its Apache License 2.0 (`LICENSE`) and third-party attribution (`NOTICE.md`) intact.
- `.github/workflows/landing.yml`.
- `AGENTS.md`, `README.md`, `.gitignore`, `package.json`, `package-lock.json`, `compose.yaml`.

## Added in the import commit

- `.gitignore`: appended `.claude/worktrees/`, `.env`, `.env.*`, `!.env.example`, and `*.xcresult`.
- `docs/PROVENANCE.md`: this file.

## Excluded

`git archive` copies only tracked files, so nothing local to a checkout of the source came across. No file tracked at the source commit matched an exclusion below, so none had to be removed. Excluded, and why:

- Untracked and ignored files from any checkout of the source, because they are local state rather than part of the project.
- `Media/*` other than `Media/README.md`, because scene clips are supplied per machine and may be copyrighted footage.
- `xcuserdata/`, `DerivedData/`, `build/`, and `*.xcresult`, because they are per-user Xcode state and build output.
- `node_modules/`, because dependencies are reproducible from the lockfiles.
- `.env`, `.env.*`, and provider tokens, because credentials belong in deployment environment variables, never in the repository.
- Personal recordings, because they are private user data.
- `.claude/worktrees/`, because those are local agent worktrees.
- Every source branch other than `main` (`erica`, `avatar-coach`, `codex/bootstrap-agent-rules`, `codex/grading-contract`, `codex/project-stack-docs`, `codex/react-landing-setup`) and all commit history.

## Secret scan

Before the commit, gitleaks v8.30.1 (`zricethezav/gitleaks`, `dir` mode) scanned the imported tree and reported no findings. A manual read of `convex/*.ts`, `Config/Dubbing-Info.plist`, `Dubbing.xcodeproj/project.pbxproj`, the landing environment usage, and `compose.yaml` found no credentials or personal data: provider keys are read from Convex deployment environment variables, `COACH_BACKEND_URL` is empty in the project, and the project sets no `DEVELOPMENT_TEAM` or provisioning profile.
