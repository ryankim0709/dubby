# Demo scenes

DubIt ships curated scenes in `Dubbing/DemoScenes/<sceneId>/`. Each scene is a short excerpt with a manifest, a video, a background track, one dialogue track per character and a poster, all described by Scene Manifest v1. `Media/` stays a git-ignored folder for personal clips; nothing in `Dubbing/DemoScenes/` is personal or private.

## The current scene: tears-of-steel-bridge

| | |
|---|---|
| Work | *Tears of Steel* (2012), Blender Foundation, directed by Ian Hubert; music by Joram Letwory |
| Excerpt | 22.5 s to 45.5 s of the film (23.0 s), the canal-bridge argument between Celia and Thom |
| Characters | Celia (3 lines), Thom (6 lines) |
| Language | English. The manifest says `en-US` because the product requires it; the actors' accents are not specifically American, and nobody has verified them against a US reference |
| Size | about 4.4 MB for six files |

Lines (times are seconds from the start of the excerpt):

| # | Character | Window | Text |
|---|---|---|---|
| 1 | Celia | 0.68 to 2.22 | You're a jerk, Thom. |
| 2 | Thom | 2.24 to 3.84 | Look Celia, we have to follow our passions; |
| 3 | Thom | 3.86 to 7.62 | you have your robotics, and I just want to be awesome in space. |
| 4 | Celia | 7.92 to 11.94 | Why don't you just admit that you're freaked out by my robot hand? |
| 5 | Thom | 12.08 to 13.38 | I'm not freaked out by— it's... |
| 6 | Thom | 15.08 to 15.92 | Alright! Fine! |
| 7 | Thom | 16.12 to 18.08 | I'm freaked out! I have nightmares that I'm being chased... |
| 8 | Thom | 18.10 to 20.54 | by these giant robotic claws of death. |
| 9 | Celia | 20.56 to 22.60 | Whatever, Thom. We're done. |

Celia is the natural practice character: three short lines with no overlap. Thom's lines 2 and 3 and lines 7 and 8 are one sentence split at a natural pause.

## License and attribution

The film is released under Creative Commons Attribution 3.0 (CC BY 3.0). Evidence read on the official pages: the project's sharing page (https://mango.blender.org/sharing/) and about page (https://mango.blender.org/about/) state that the film and everything published on the site is CC BY 3.0, and the CC BY 3.0 deed is at https://creativecommons.org/licenses/by/3.0/. CC BY 3.0 allows redistribution and adaptation, including commercial use, with attribution. The scene has no NonCommercial or NoDerivatives term.

Show this credit wherever the scene is shown (it is stored in the manifest as `provenance.attribution`):

> Tears of Steel (CC) Blender Foundation | mango.blender.org. Music by Joram Letwory. Licensed under CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/). This scene is an excerpt of the film, trimmed and re-encoded, with its dialogue and background audio rebuilt from the official 5.1 center channel and music and effects mix.

Changes made to the work are listed in `provenance.modifications`: trimmed to the excerpt, re-encoded, dialogue gated per character, background taken from the music and effects file, poster frame extracted.

### Open question: the score

The film's score is by Joram Letwory. The composer released the standalone soundtrack files separately under CC BY-ND 3.0 (the notice is in `copyright.txt` next to the soundtrack files at https://download.blender.org/demo/movies/ToS/), and the producer's announcement (https://mango.blender.org/production/soundtrack-files-released/) quotes him: the ND choice protects commercial sample libraries used in the music, and anyone who wants to cut up the music should message him for written permission. That limitation is about the soundtrack files, while the film (score included) is CC BY 3.0.

The background track contains the film's music, at roughly 22.5 to 25 s and from about 40.4 s onward, and it is cut from the film's music-and-effects file, not from the soundtrack files. Nothing in the files lets us confirm which side of that line this excerpt sits on, so it is recorded here and in the manifest instead of being assumed. If it is not acceptable, the options are a different excerpt without a music cue, a background track with the music removed, or the composer's written permission.

## Where the audio comes from

All audio is official release material, with no model-based separation:

- **Dialogue**: the 5.1 center channel (`TOS_DVDSURROUND.C.aif`). In this scene the left, right and surround channels sit 15 to 30 dB below the center during speech, so it behaves as a dialogue stem, but it is not a certified dry stem. Each character's track keeps only that character's line windows, with 10 ms fades, and is silent elsewhere. Tracks are dual-mono stereo so every track has the same format.
- **Background**: the official music and effects mix (`TOS_MUSIC+FX_NO_DIALOGUE.aif`), stereo.
- **Video**: the 720p release (`tears_of_steel_720p.mov`), re-encoded to H.264 1280x534 at 24 fps with its original mixed audio kept as AAC. The engine never plays that mixed audio in a dub.
- **Subtitles and timing**: the official English subtitles (`TOS-en.srt`) gave the wording. Line windows come from speech energy in the center channel, with a speech recognizer used only to cross-check the wording. Nobody has listened to the result, so the wording of Celia's last line ("Whatever, Thom.", where "Thom" is spoken quietly) matches the subtitles but is only partly confirmed by the recognizer. Word timings are not provided (`wordTimingSource: absent`).

The sources are pinned by sha256 in `scripts/demo-scenes/prepare-tears-of-steel-bridge.sh`; the video checksum is also stored as `provenance.sourceSHA256`.

### Measured quality (scripts/demo-scenes/measure_scene.py)

- Line windows bracket the speech. Against the ungated center channel, the level in the 150 ms outside each window is 17 to 24 dB below the level inside, except next to a neighbouring line (lines 1 to 3, 7 and 8, and the start of line 9) and after the last line, where the decaying tail is 10 dB below.
- Outside their own windows the character tracks peak at about -53 dBFS (AAC coding noise), against speech around -22 to -26 dBFS.
- Background plus all dialogue only approximates the video's own audio. At the best alignment (6 ms) the whole-scene waveform correlation is 0.41 and the SNR after a best-fit gain is 0.8 dB. The center channel and the stereo mix are different renders: per-line waveform correlation is 0.37 to 0.69, the level matches (best-fit gain about 1.0 against the stereo mix), but the waveforms do not. Expect the sum to sound similar, not identical, and not to null against the original.
- Alignment to the video's own audio varies by line: the dialogue is about 6 ms behind it up to the picture cut at 40.25 s and about 18 ms ahead of it after. The two renders disagree by about 24 ms across that cut; the tracks are left unshifted. The video's own audio itself trails the film's stereo mix by about 25 ms, which matches MP3 encoder delay, so sync against the picture is good to within a few tens of milliseconds, not sample-accurate.
- The music-and-effects file matches the stereo mix only loosely outside the dialogue (correlation about 0.2 over the line-free stretches).

## A fresh checkout

The scene is committed, so a fresh checkout already has it; `Dubbing/` is a file-system-synchronized group, so the files are bundled without Xcode project edits. File names all start with `tears-of-steel-bridge-` because synchronized groups may flatten resources into the bundle root.

## Regenerating and validating

```sh
scripts/demo-scenes/prepare-tears-of-steel-bridge.sh   # rebuild every file from the pinned upstream files
python3 -I scripts/demo-scenes/validate_scene.py        # validate every scene under Dubbing/DemoScenes
```

The prepare script needs curl, ffmpeg (libx264 and the native AAC encoder), ffprobe and python3. It downloads about 690 MB into `~/.cache/dubit-demo-scenes/tears-of-steel-bridge` (override with `DEMO_SCENE_CACHE`), verifies each file's sha256, builds everything in a temporary directory, validates it and only then replaces the scene folder (an optional argument chooses another output folder). Two runs on one machine (ffmpeg 6.1.1) produced byte-identical files; a different ffmpeg or x264 build may change bytes, in which case the manifest checksums change with them and the validator is the check that matters.

The validator uses only the Python standard library and ffprobe. It enforces every Scene Manifest v1 rule: schema version, kebab-case ids, file names with the scene prefix, existence and sha256 of every file, H.264 at most 1280x720 and 30 fps in a faststart MP4 of 10 to 30 s, AAC-LC 48 kHz .m4a tracks that start at 0 and match the video duration within 20 ms, total size at most 10 MB, finite sorted line times inside the duration, resolvable characters, no overlap within a character and rare overlap between characters, optional word ranges and order, at least two characters with at least one having three or more lines, and complete provenance (https URLs, 64-hex source checksum, no NonCommercial or NoDerivatives license, valid separation, transcript and word-timing source values, excerpt length equal to the duration).

`measure_scene.py` is an optional quality check (needs numpy and ffmpeg): `python3 scripts/demo-scenes/measure_scene.py Dubbing/DemoScenes/tears-of-steel-bridge ~/.cache/dubit-demo-scenes/tears-of-steel-bridge/TOS_DVDSURROUND.C.aif`.

## Adding another scene

1. Find a 10 to 30 second excerpt with at least two characters speaking clearly, at least three lines for one of them, little overlap and learner-friendly content. Use only CC0 or CC-BY material and verify the license on the official page; avoid NonCommercial and NoDerivatives terms and ask before using share-alike. Prefer official stems; if none exist, separate with an open-source model, record tool, version, weights and their license, and say in `dialogueSeparation.notes` that separation is approximate.
2. Copy `scripts/demo-scenes/tears-of-steel-bridge.template.json` and `prepare-tears-of-steel-bridge.sh` to new names for the new scene id, pin the source files and their sha256 values, set the excerpt range, and fill in characters, lines (times relative to the excerpt), provenance and attribution. The template's line windows drive the per-character gating, so they must bracket the speech.
3. Run the prepare script, then the validator, then check by ear that each window brackets its speech.
4. Commit the new folder under `Dubbing/DemoScenes/<sceneId>/` along with the script and template.

Never copy footage from `Media/` or any private or unlicensed clip into `Dubbing/DemoScenes/`. `DubbingTests/Fixtures/two-tone-3s.mp4` is a synthetic test fixture and is not a demo scene.
