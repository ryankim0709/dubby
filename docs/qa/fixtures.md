# QA fixtures

## Synthetic microphone input

`Dubbing/QAFixtures/qa-speech-fixture.m4a` is the audio that `-DUBIT_AUDIO_FIXTURE qa-speech-fixture` plays in place of the microphone. It is 10.4 s of synthetic speech (three short English sentences saying the audio is a synthetic test voice), mono AAC at 16 kHz, 40 KB, generated with the Flite voice `slt` through ffmpeg; it contains no human recording.

```sh
ffmpeg -f lavfi -i "flite=text='This is a synthetic test voice. It is not a person.':voice=slt" \
       -f lavfi -i "flite=text='Quality assurance fixture, line two.':voice=slt" \
       -f lavfi -i "flite=text='Nothing here is a real recording.':voice=slt" \
       -filter_complex "[0:a]apad=pad_dur=0.6[a];[1:a]apad=pad_dur=0.6[b];[2:a]apad=pad_dur=0.6[c];[a][b][c]concat=n=3:v=0:a=1,aresample=16000,aformat=channel_layouts=mono" \
       -c:a aac -b:a 32k qa-speech-fixture.m4a
```

Rules: a take made from it shows `fixtureInputBadge` and is never assessed or scored (Engine). It proves the record, keep and export plumbing, never microphone fidelity or speech scoring. The folder sits inside the app's synchronized group, so it is bundled in every build until Mobile App excludes it from Release builds (a build-setting change requested from Mobile App).

Set `TEST_RUNNER_DUBIT_QA_SCENE_ID=<sceneID>` when running the UI tests once Engine settles the demo scene id; the default `demo` is a placeholder.
