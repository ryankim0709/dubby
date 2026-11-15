# QA: native build, test, and verification plan

This is the QA entry point for DubIt. The canonical simulator selection and build/test command are in [README.md#build-and-test](../../README.md#build-and-test); `scripts/qa/ios-build-test.sh` is that command made repeatable, and every route below runs it.

## Fresh-checkout path

### On a Mac with Xcode 26 or newer

```sh
scripts/qa/ios-build-test.sh        # build, then run the DubbingTests unit tests
scripts/qa/ios-build-test.sh build  # build only
scripts/qa/ios-build-test.sh test   # unit tests only (also builds and stages the app)
```

The script resolves Swift packages, picks an installed iOS 26.x simulator (iPhone 17 Pro on iOS 26.5 when present, else the same model on the newest 26.x, else any iOS 26.x iPhone), builds the shared `Dubbing` scheme with `CODE_SIGNING_ALLOWED=NO` into `build/DerivedData`, runs `DubbingTests`, scans the built app (see [Verification plan](#verification-plan)), and writes everything to `build/qa/`. It exits 0 on success, 1 on a build, test, or scan failure, and 2 when the environment cannot run it (no Xcode, Xcode older than 26, no iOS 26 simulator).

| Override | Default | Meaning |
| --- | --- | --- |
| `QA_SIM_UDID` | none | Exact simulator; skips automatic selection |
| `QA_SIM_DEVICE` | `iPhone 17 Pro` | Simulator model; created on the chosen runtime when missing |
| `QA_SIM_RUNTIME` | `26.5` | Preferred iOS version; the newest installed 26.x is used when absent |
| `QA_OUT_DIR` | `build/qa` | Results directory |
| `QA_DERIVED_DATA` | `build/DerivedData` | Derived data path |
| `QA_CONFIGURATION` | `Debug` | Build configuration |
| `QA_COMMIT_SHA` | `git rev-parse HEAD` | Commit recorded in the summary when there is no `.git` |

### Outputs

Everything is under `build/qa/` (ignored by git):

| File | Content |
| --- | --- |
| `summary.txt` | Commit, Xcode version, simulator runtime and device, build and test results, test counts, failing test names, bundle scan result |
| `build.xcresult`, `test.xcresult` | Result bundles (`xcrun xcresulttool`, or open in Xcode) |
| `resolve.log`, `build.log`, `test.log`, `bundle-scan.log` | Full logs |
| `Dubbing.app`, `Dubbing.app.zip` | The simulator app at a stable path; the zip is what Revyl installs |

The unzipped app is also left at `build/DerivedData/Build/Products/Debug-iphonesimulator/Dubbing.app`.

### On Revyl's runner through Capy

Revyl's build tool archives the repository directory and runs commands on a macOS runner with Xcode 27.0 and the iOS 18.5, 26.2, 26.5, and 27.0 simulator runtimes. The Revyl app name is `dubby`. The repository's `.capyignore` keeps `landing/`, `node_modules`, and build output out of the upload (cap: 100 MB).

```js
await tools.mobile.build({
  action: "start", platform: "ios", app: "dubby",
  source: {
    type: "workspace", path: "dubby",
    commands: ["QA_COMMIT_SHA=<commit sha> scripts/qa/ios-build-test.sh all"],
    output_path: "build/qa/Dubbing.app.zip",
  },
})
```

Pass the commit SHA yourself, because the archive has no `.git`. The script prints its summary at the end of the log. A succeeded build is installable on a Revyl cloud phone with the phone tool. This route needs the organization's Revyl approval (Settings → Integrations → Revyl).

### On GitHub Actions

`.github/workflows/ios-ci.yml` runs the same script on `macos-26` (Xcode 26.6, iOS 26.5 simulator) for pull requests and pushes that touch `Dubbing/`, `DubbingTests/`, `DubbingUITests/`, `Dubbing.xcodeproj/`, `scripts/qa/`, or the workflow, and on manual dispatch. It writes `summary.txt` to the job summary and uploads the `.xcresult` bundles, logs, and zipped app as the `ios-ci-results` artifact (14 days). The repository is public, so hosted macOS minutes are free. A full run takes about 10 minutes; the unit tests take about 5.

## Where evidence goes

Per the crew rules, a verification claim names the commit SHA, Revyl build id (or Actions run), Xcode version, simulator runtime and device model, and pass or fail per step. `summary.txt` carries all of it except the build or run id. Screenshots, recordings, and logs go under `renders/<thread code>/` in the Revyl QA captain drive and never into git.

## Writing tests

`DubbingTests/Support/TestSupport.swift` holds shared helpers; behavioral tests stay with the captain that owns the code.

- `TestFixtures.twoToneVideo()` and `TestFixtures.url(named:extension:)` load files from `DubbingTests/Fixtures`. The synchronized test group copies new files into the test bundle with no project edit. Fixtures must be synthetic or properly licensed.
- `TemporaryDirectory` is a scratch folder that is deleted when the test releases it.

## Verification plan

| Check | What it proves | Where it runs | Blocks merge when it fails |
| --- | --- | --- | --- |
| iOS build and unit tests | The `Dubbing` scheme compiles for the iOS 26 simulator and `DubbingTests` pass | `ios-ci.yml`; the script on a Mac or Revyl | Yes |
| App bundle scan | The built `Dubbing.app` holds no OpenAI key (literal or the `OPENAI_API_KEY` name), no direct `api.openai.com` or Anthropic endpoint, and no other LLM vendor endpoint | Inside `ios-build-test.sh` | Yes |
| LLM provider policy | Runtime code uses OpenAI only, through the Responses API (below) | `qa-policy.yml`, job "LLM provider policy (OpenAI-only runtime)" | Yes |
| Secret scan | The commits a change adds contain no secrets (gitleaks 8.30.1, checksum-pinned, no allowlist) | `qa-policy.yml`, job "Secret scan (gitleaks 8.30.1)" | Yes |
| Physical iPhone | Microphone fidelity, audio routes and interruptions, Bluetooth, on-device speech models, share sheet | A person with a device | Not automated; a simulator cannot prove these |

### LLM provider policy check

Every AI agent in the deployed app uses OpenAI only, through the official SDK and the Responses API, with `OPENAI_API_KEY` on the Convex backend only. `scripts/qa/check-llm-provider.sh` enforces it and prints `file:line  [rule]` for each violation without printing matched values:

| Rule | Fires on | In |
| --- | --- | --- |
| `non-openai-vendor` | Anthropic or Claude references, Google, Cohere, Mistral, Groq, Vercel AI SDK, OpenRouter, Together, DeepSeek, xAI, Bedrock, and Perplexity SDKs, endpoints, or key names | `convex/`, `Dubbing/`, `Config/`, root `package.json` and `package-lock.json` |
| `openai-non-responses` | Chat completions, legacy completions, assistants, and threads | `convex/`, `Dubbing/`, `Config/` |
| `openai-in-app` | `OPENAI_API_KEY`, a literal `sk-` key, `api.openai.com`, or an OpenAI client library | `Dubbing/`, `Config/`, `DubbingTests/` (fixtures included), `DubbingUITests/`, `Dubbing.xcodeproj/` |

Docs, `.agents/`, `node_modules`, `convex/_generated`, and the check's own fixtures are not scanned. `scripts/qa/check-llm-provider.sh --self-test` runs the rules against the fixture trees in `scripts/qa/fixtures/llm-provider/` (one clean tree and one tree per rule case) and fails if a rule stops firing. The CI job runs the self-tests first, then the check, with no `continue-on-error`, so it stays red until the OpenAI migration removes every Anthropic reference from runtime code.

### Secret scan and bundle scan

The secret scan runs gitleaks over the commits a pull request or push adds. It has no allowlist, so a finding means a credential must be removed and rotated. The bundle scan (`scripts/qa/scan-app-bundle.sh <Dubbing.app>`, self-test with `--self-test`) runs on every build and checks the compiled app, including the binary, for the same provider key and endpoint patterns.

## Known gaps

- Revyl cloud builds and cloud-phone runs need the organization's Revyl approval.
- There is no UI-test target yet (Mobile App owns the Xcode project); UI flows and Revyl test plans belong to the `qa/e2e-smoke` work.
