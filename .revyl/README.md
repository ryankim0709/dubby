# Revyl test plan for the dub loop

Tests in `tests/` mirror [docs/qa/smoke-flow.md](../docs/qa/smoke-flow.md): `dub-loop.yaml` (S-01 to S-23), `microphone-permission.yaml` (S-30, S-31), `cancel-and-interruptions.yaml` (S-41 to S-45). Steps name accessibility identifiers from [docs/qa/accessibility-ids.md](../docs/qa/accessibility-ids.md) and system buttons by role and name. They cannot pass until Mobile App and Engine implement that contract, and none has been run: this crew has no Revyl credentials.

## One-time setup (Ryan, in his Revyl account)

1. `curl -fsSL https://revyl.com/install.sh | sh`, then `revyl auth login`.
2. `revyl app create --name dubby --platform ios --json`, or reuse the existing `dubby` app, and set `build.profiles.simulator.ios.app_id` in `config.yaml` to its id. The `project.id` in `config.yaml` is a generated placeholder; replace it with the id `revyl init --project` returns if validation rejects it.
3. `revyl config validate`, then `revyl device targets` and make sure the `device` block in each test (iPhone 17 Pro, iOS 26.5) is a listed pair; edit if not.
4. Library, Launch Configurations, new **iOS argument set** named `dubit-qa` with the line: `-DUBIT_UI_TEST 1 -DUBIT_DEMO_SCENE demo -DUBIT_AUDIO_FIXTURE qa-speech-fixture`. Revyl passes the tokens unchanged to the app, which reads them as launch arguments. Attach it to each test, or add `--launch-arg-set dubit-qa` to the run. These arguments only take effect once Mobile App and Engine implement them.
5. Build: `revyl build --platform ios --profile simulator --json`, which gives a `build_version_id`.

## Run

```sh
revyl test run dub-loop --launch-arg-set dubit-qa
revyl test run microphone-permission --launch-arg-set dubit-qa
revyl test run cancel-and-interruptions --launch-arg-set dubit-qa
```

Needs from Ryan: a Revyl login with build credits and a free device slot. No credentials are stored in this repository.
