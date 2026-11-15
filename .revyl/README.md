# Revyl builds and previews

The simulator build profile in `config.yaml` builds `Dubbing.app` for cloud device previews. Set the project and app identifiers to the values from your Revyl account before building.

```sh
revyl auth login
revyl build --platform ios --profile simulator --json
```

There are no automated Revyl test plans or QA gates for the hackathon. Existing Swift test sources remain available for manual use.
