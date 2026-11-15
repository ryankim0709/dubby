# Demo scenes

DubIt ships curated scenes in `Dubbing/DemoScenes/<sceneId>/`. Each scene is a short excerpt with a manifest, a video, a background track, one dialogue track per character and a poster, all described by Scene Manifest v1. `Media/` stays a git-ignored folder for personal clips; nothing in `Dubbing/DemoScenes/` is personal or private.

## The current scene: tears-of-steel-bridge

| | |
|---|---|
| Work | *Tears of Steel* (2012), Blender Foundation, directed by Ian Hubert |
| Excerpt | 29.75 s to 39.75 s of the film (10.0 s), the canal-bridge argument between Celia and Thom |
| Characters | Celia (1 line), Thom (3 lines, the practice character) |
| Language | English. The manifest locale `en-US` is the assessment locale: pronunciation is scored against the reference text, not against the actors, and the actors' accents are not American |
| Size | about 1.5 MB for six files; the video has no audio track |

Lines (times are seconds from the start of the excerpt):

| # | Character | Window | Text |
|---|---|---|---|
| 1 | Celia | 0.67 to 4.69 | Why don't you just admit that you're freaked out by my robot hand? |
| 2 | Thom | 4.83 to 6.13 | I'm not freaked out by— it's... |
| 3 | Thom | 7.83 to 8.67 | Alright! Fine! |
| 4 | Thom | 8.87 to 9.35 | I'm freaked out! |

The scene is a small story: Celia asks, Thom dodges, then admits it. Thom's next words in the film ("I have nightmares...") start about 0.5 s before the title cue below, and the excerpt must end before that cue, so it ends 0.4 s after "I'm freaked out!" and Thom's continuation is left out.

## License and attribution

The film is released under Creative Commons Attribution 3.0 (CC BY 3.0). Evidence read on the official pages: the project's sharing page (https://mango.blender.org/sharing/) and about page (https://mango.blender.org/about/) state that the film and everything published on the site is CC BY 3.0, and the CC BY 3.0 deed is at https://creativecommons.org/licenses/by/3.0/. CC BY 3.0 allows redistribution and adaptation, including commercial use, with attribution. The scene has no NonCommercial or NoDerivatives term.

Show this credit wherever the scene is shown (it is stored in the manifest as `provenance.attribution`):

> Tears of Steel (CC) Blender Foundation | mango.blender.org. Music by Joram Letwory. Licensed under CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/). This scene is an excerpt of the film, trimmed and re-encoded, with its dialogue and background audio rebuilt from the official 5.1 center channel and music and effects mix.

Changes made to the work are listed in `provenance.modifications`: trimmed to the excerpt, video re-encoded without its audio, dialogue gated per character, background taken from the music and effects file and silenced where it still carried music, poster frame extracted.

### Why the excerpt avoids the score

The film's score is by Joram Letwory. He released the standalone soundtrack files separately under CC BY-ND 3.0 (the notice is in `copyright.txt` next to the soundtrack files at https://download.blender.org/demo/movies/ToS/), and the producer's announcement (https://mango.blender.org/production/soundtrack-files-released/) quotes him: the ND choice protects commercial sample libraries used in the music, and anyone who wants to cut up the music should message him for written permission. The film itself, score included, is CC BY 3.0, but we could not confirm that cutting a music-and-effects stem out of it is covered, so the excerpt was cut to contain no score. This is the reason for the range. If a scene with music is ever wanted, get the composer's written permission first.

How the excerpt was checked (`measure_scene.py`, all on the official music-and-effects file the background comes from):

- The film's two score cues bound the range. The opening cue is loud (-9.5 dBFS in a 0.2 s block) and fades out through the dialogue scene; the title cue starts at about 39.8 s and is a steady low drone (65 Hz, tonal prominence up to 86 dB, spectral flatness 0.000, -30 dBFS). The excerpt therefore ends at 39.75 s.
- Between the cues the file holds a decaying bed. Tonal statistics alone do not separate it from the opening cue (flatness 0.04 and prominence 37 dB for the cue, 0.03 and 36 dB for the bed near 29.75 s), so two more checks were used: level, and how closely each 1 s block's third-octave spectrum resembles the opening cue. The bed resembles the cue at 0.7 to 0.8 until about 29 s, 0.3 to 0.7 from 29.75 s to 34.75 s, and 0.26 or less after 34.75 s, while its level falls from -36 dBFS at 26 s to -47 dBFS at 35 s and -50 dBFS afterwards.
- So the fading end of the opening cue cannot be ruled out before about 35 s. The shipped background is therefore silent until source time 35.0 s (5.25 s into the excerpt), then fades in over 0.25 s. After 35.0 s it is quiet room ambience: its loudest 0.2 s block is -48.8 dBFS, its lowest spectral flatness 0.098 and its highest tonal prominence 29.7 dB, with none of the 50 blocks over the thresholds (level above -38 dBFS, flatness below 0.01, prominence above 40 dB). Nobody has listened to it, and a very faint remnant of the cue below about -47 dBFS cannot be excluded by these measurements.

The scene's video is silent, so no film audio other than the two derived stems ships with it.

## Where the audio comes from

All audio is official release material, with no model-based separation:

- **Dialogue**: the 5.1 center channel (`TOS_DVDSURROUND.C.aif`). In this scene the left, right and surround channels sit 15 to 30 dB below the center during speech, so it behaves as a dialogue stem, but it is not a certified dry stem. Each character's track keeps only that character's line windows, with 10 ms fades, and is silent elsewhere. Tracks are dual-mono stereo so every track has the same format.
- **Background**: the official music and effects mix (`TOS_MUSIC+FX_NO_DIALOGUE.aif`), stereo, silenced before 35.0 s as described above.
- **Video**: the 720p release (`tears_of_steel_720p.mov`), re-encoded to H.264 1280x534 at 24 fps, with no audio track.
- **Subtitles and timing**: the official English subtitles (`TOS-en.srt`) gave the wording. Line windows come from speech energy in the center channel, with a speech recognizer used only to cross-check the wording. Nobody has listened to the result. Word timings are not provided (`wordTimingSource: absent`).

The sources are pinned by sha256 in `scripts/demo-scenes/prepare-tears-of-steel-bridge.sh`; the video checksum is also stored as `provenance.sourceSHA256`.

### Measured quality (scripts/demo-scenes/measure_scene.py)

- Line windows bracket the speech. Against the ungated center channel, the level in the 150 ms outside each window is 17 to 25 dB below the level inside (-21 to -25 dBFS), except after line 4, where Thom's next words follow immediately.
- Outside their own windows the character tracks peak at -57 dBFS (Thom) and -69 dBFS (Celia), which is AAC coding noise.
- Background plus all dialogue only approximates the film's stereo mix (the audio of the pinned video release): at the best alignment (6 ms) the gain is 1.07, the waveform correlation 0.64 and the SNR 2.3 dB. The center channel and the stereo mix are different renders, so the levels match but the waveforms do not; expect the sum to sound similar, not identical, and not to null against the original. The background itself is almost silent here (-53 dBFS rms) against dialogue at -25 dBFS.
- Sync: the dialogue runs about 6 ms behind the film's own audio, and that audio trails the film's stereo mix by about 25 ms (MP3 encoder delay in the release), so sync against the picture is good to a few tens of milliseconds, not sample-accurate.

## A fresh checkout

The scene is committed, so a fresh checkout already has it; `Dubbing/` is a file-system-synchronized group, so the files are bundled without Xcode project edits. File names all start with `tears-of-steel-bridge-` because synchronized groups may flatten resources into the bundle root.

## Regenerating and validating

```sh
scripts/demo-scenes/prepare-tears-of-steel-bridge.sh   # rebuild every file from the pinned upstream files
python3 -I scripts/demo-scenes/validate_scene.py        # validate every scene under Dubbing/DemoScenes
```

The prepare script needs curl, ffmpeg (libx264 and the native AAC encoder), ffprobe and python3. It downloads about 690 MB into `~/.cache/dubit-demo-scenes/tears-of-steel-bridge` (override with `DEMO_SCENE_CACHE`), verifies each file's sha256, builds everything in a temporary directory, validates it and only then replaces the scene folder (an optional argument chooses another output folder). Two runs on one machine (ffmpeg 6.1.1) produced byte-identical files, and a rebuild matches the committed files; a different ffmpeg or x264 build may change bytes, in which case the manifest checksums change with them and the validator is the check that matters.

The validator uses only the Python standard library and ffprobe. It enforces every Scene Manifest v1 rule: schema version, kebab-case ids, file names with the scene prefix, existence and sha256 of every file, H.264 at most 1280x720 and 30 fps in a faststart MP4 of 10 to 30 s, AAC-LC 48 kHz .m4a tracks that start at 0 and match the video duration within 20 ms, total size at most 10 MB, finite sorted line times inside the duration, resolvable characters, no overlap within a character and rare overlap between characters, optional word ranges and order, at least two characters with a practice character that has 2 to 4 lines, and complete provenance (https URLs, 64-hex source checksum, no NonCommercial or NoDerivatives license, valid separation, transcript and word-timing source values, excerpt length equal to the duration).

`measure_scene.py` is an optional quality check (needs numpy and ffmpeg): `python3 scripts/demo-scenes/measure_scene.py Dubbing/DemoScenes/tears-of-steel-bridge ~/.cache/dubit-demo-scenes/tears-of-steel-bridge`. It exits 1 if any background block crosses the score thresholds.

## Adding another scene

1. Find a 10 to 30 second excerpt with at least two characters speaking clearly, a practice character with 2 to 4 short lines, little overlap and learner-friendly content. Use only CC0 or CC-BY material, verify the license on the official page and check whether the music carries a separate license; avoid NonCommercial and NoDerivatives terms and ask before using share-alike. Prefer official stems; if none exist, separate with an open-source model, record tool, version, weights and their license, and say in `dialogueSeparation.notes` that separation is approximate.
2. Copy `scripts/demo-scenes/tears-of-steel-bridge.template.json` and `prepare-tears-of-steel-bridge.sh` to new names for the new scene id, pin the source files and their sha256 values, set the excerpt range, and fill in characters, lines (times relative to the excerpt), provenance and attribution. The template's line windows drive the per-character gating, so they must bracket the speech.
3. Run the prepare script, then the validator and the measure script, then check by ear that each window brackets its speech.
4. Commit the new folder under `Dubbing/DemoScenes/<sceneId>/` along with the script and template.

Never copy footage from `Media/` or any private or unlicensed clip into `Dubbing/DemoScenes/`. `DubbingTests/Fixtures/two-tone-3s.mp4` is a synthetic test fixture and is not a demo scene.
