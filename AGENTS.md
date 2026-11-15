# Dubby agent guide

These instructions apply throughout this repository. Follow more specific nested instructions when present.

## Project context

- Dubby is an entertainment-first iOS app for learning languages by dubbing short scenes, with pronunciation coaching.
- Product reference: https://chatgpt.com/share/6af93b36-93b8-83e8-adf7-baf6326f35ac. The confirmed direction is Dubby. The `avatar-coach` branch adds a talking-character coach (a LiveAvatar video face that speaks Claude's replies); other avatar-tutor ideas stay out of scope.
- The repository contains a native SwiftUI app: `Dubbing/`, `DubbingTests/`, and the shared `Dubbing` Xcode scheme.
- The project uses Swift 6, targets iOS 26.0+, and enables default MainActor isolation for the app target. Preserve these settings unless asked.
- Read `README.md` for the selected development tools, cloud architecture, and integration status. Follow those choices; the reference chat's other stack suggestions are not adopted dependencies.
- Erica's UI merged into `Dubbing/` on `main` is the approved final design. Preserve it when adding features, fixing bugs, or integrating older branches; redesigns require an explicit user request. Read `DESIGN.md` and `.cursor/rules/ui.mdc` before UI work.

## Focused rules

Read the applicable files before implementation; they contain instructions for Codex as well as Cursor:

- `.cursor/rules/product.mdc`: MVP priorities and the user journey.
- `.cursor/rules/swift.mdc`: native architecture, types, concurrency, and UI behavior.
- `.cursor/rules/ui.mdc`: preservation of Erica's approved final UI, shared visual components, and UI verification.
- `.cursor/rules/dubbing-pipeline.mdc`: media timing, audio composition, assessment, and external services.
- `docs/grading-contract.md`: proposed line-attempt grading response, scoring rubric, and progress-tracking semantics.
- `.agents/skills/impeccable/SKILL.md`: use this project-local Impeccable skill for UI design, alignment, and review. Follow its native iOS guidance, reuse established tokens and components, and verify rendered iPhone layouts.

## Workflow

- For the hackathon, do not add or run CI workflows, automated QA jobs, provider/secret/bundle scans, or PR verification agents. Merge authorized PRs once merge conflicts are resolved; checks and test results are not merge gates. Existing test sources remain available for manual use.
- Read existing code and search for reusable logic before editing. Make the smallest change that completes the requested behavior.
- Preserve other people's edits and staging. Do not commit, push, or open a PR without explicit authorization; leave implementation changes uncommitted for review.
- Ask before destructive actions or expanding product scope. Never put credentials, recordings, or private user data in source control.
- Prefer pure functions and typed models; keep side effects in small platform or service clients. Avoid speculative abstractions and dependencies.
- Write comments in English to explain why. Do not suppress compiler or lint diagnostics, hide failures, or leave debug prints and dead code.
- Verify provider APIs against installed SDK source or current official documentation before integrating them.

## Verification

- Use Swift Testing in `DubbingTests/`. Add the minimum useful behavioral coverage; do not test static copy, prompts, or configuration.
- Prefer integration and smoke tests. Use synthetic media fixtures and non-production services; ask before tests that incur real costs or irreversible effects.
- Build and run existing tests before finishing. Compilation performs the Swift typecheck; there is no separate lint or formatter configuration in the project.
- Follow `README.md#build-and-test` for simulator selection and the canonical build/test command.
- For media changes, also check recording, playback, interruptions, export, and sharing on an actual iPhone. Report any checks or device behavior you could not verify.
- Report what changed and which checks passed. Do not claim the scaffold implements the product or that a simulator run verifies microphone quality on hardware.
