#!/usr/bin/env python3
"""Measures a demo scene's tracks against the pinned upstream files.

Usage: python3 scripts/demo-scenes/measure_scene.py SCENE_DIR CACHE_DIR

CACHE_DIR is the prepare script's download cache (default ~/.cache/dubit-demo-scenes/<sceneId>). This is a
quality-assurance tool, not part of the build. It needs numpy and ffmpeg and reports:

1. Score check: per 0.2 s block of the shipped background, level, spectral flatness and tonal prominence,
   next to the same figures for the film's score cues in the upstream music-and-effects file.
2. Line windows against the ungated center channel (is speech cut off?) and character-track leakage.
3. Background plus dialogue against the film's stereo mix, which is the audio of the pinned video release.
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48000
BLOCK = int(0.2 * SAMPLE_RATE)
MAX_BLOCK_RMS_DB = -38.0
MIN_FLATNESS = 0.01
MAX_PROMINENCE_DB = 40.0
SCORE_REFERENCES = {"opening cue (source 15.0-18.5 s)": (15.0, 3.5), "title cue (source 40.4-45.4 s)": (40.4, 5.0)}


def decode(path: Path, start: float = 0.0, duration: float | None = None, channels: int = 1) -> np.ndarray:
    command = ["ffmpeg", "-v", "error", "-ss", str(start)]
    if duration is not None:
        command += ["-t", str(duration)]
    command += ["-i", str(path), "-vn", "-ac", str(channels), "-ar", str(SAMPLE_RATE), "-f", "s16le", "-"]
    raw = subprocess.run(command, check=True, capture_output=True).stdout
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768
    return samples.reshape(-1, channels).mean(axis=1) if channels > 1 else samples


def db(value: float) -> float:
    return 20 * np.log10(max(value, 1e-9))


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0


def block_stats(x: np.ndarray) -> list[tuple[float, float, float]]:
    stats = []
    freqs = np.fft.rfftfreq(BLOCK, 1 / SAMPLE_RATE)
    band = (freqs > 50) & (freqs < 4000)
    for k in range(len(x) // BLOCK):
        seg = x[k * BLOCK:(k + 1) * BLOCK]
        power = np.abs(np.fft.rfft(seg * np.hanning(BLOCK))) ** 2 + 1e-20
        p = power[band]
        flatness = float(np.exp(np.mean(np.log(p))) / np.mean(p))
        prominence = float(10 * np.log10(p.max() / np.median(p)))
        stats.append((db(rms(seg)), flatness, prominence))
    return stats


def third_octave_levels(x: np.ndarray) -> np.ndarray:
    n = 8192
    power = np.mean([np.abs(np.fft.rfft(x[i:i + n] * np.hanning(n))) ** 2 for i in range(0, len(x) - n + 1, n // 2)], axis=0)
    freqs = np.fft.rfftfreq(n, 1 / SAMPLE_RATE)
    edges = [40 * 2 ** (k / 3) for k in range(20)]
    return np.array([10 * np.log10(power[(freqs >= lo) & (freqs < hi)].sum() + 1e-20) for lo, hi in zip(edges[:-1], edges[1:])])


def summarize(label: str, stats: list[tuple[float, float, float]]) -> None:
    rms_db, flatness, prominence = (np.array(column) for column in zip(*stats))
    print(f"  {label}: loudest block {rms_db.max():6.1f} dBFS, lowest flatness {flatness.min():.3f}, highest tonal prominence {prominence.max():5.1f} dB")


def main() -> int:
    scene_dir, cache_dir = Path(sys.argv[1]), Path(sys.argv[2])
    manifest = json.loads(next(scene_dir.glob("*-manifest.json")).read_text())
    start, duration = manifest["provenance"]["excerpt"]["start"], manifest["durationSeconds"]
    background = decode(scene_dir / manifest["background"]["file"], channels=2)
    dialogue = {c["id"]: decode(scene_dir / c["dialogue"]["file"], channels=2) for c in manifest["characters"]}
    musicfx_source = cache_dir / "TOS_MUSIC+FX_NO_DIALOGUE.aif"
    center_source = cache_dir / "TOS_DVDSURROUND.C.aif"
    mix_source = cache_dir / "tears_of_steel_720p.mov"
    n = min(len(background), *(len(d) for d in dialogue.values()), int(duration * SAMPLE_RATE))
    print(f"scene {manifest['sceneId']}: {n / SAMPLE_RATE:.3f} s decoded")

    print("\nScore check on the shipped background (0.2 s blocks)")
    stats = block_stats(background[:n])
    summarize("shipped background", stats)
    for label, (ref_start, ref_duration) in SCORE_REFERENCES.items():
        summarize(label, block_stats(decode(musicfx_source, ref_start, ref_duration)))
    violations = [k for k, (r, f, p) in enumerate(stats) if r > MAX_BLOCK_RMS_DB or f < MIN_FLATNESS or p > MAX_PROMINENCE_DB]
    print(f"  thresholds: block level <= {MAX_BLOCK_RMS_DB} dBFS, flatness >= {MIN_FLATNESS}, tonal prominence <= {MAX_PROMINENCE_DB} dB")
    print(f"  blocks over a threshold: {len(violations)} of {len(stats)}")

    print("\nSource music-and-effects file over the excerpt: level and spectral resemblance to the opening score cue (1 s blocks)")
    reference = third_octave_levels(decode(musicfx_source, 15.0, 3.4))
    reference = reference - reference.mean()
    source_window = decode(musicfx_source, start, duration)
    for k in range(int(duration)):
        block = source_window[k * SAMPLE_RATE:(k + 1) * SAMPLE_RATE]
        levels = third_octave_levels(block)
        print(f"  source {start + k:6.2f}-{start + k + 1:6.2f} s: {db(rms(block)):6.1f} dBFS, resemblance to the cue {float(np.corrcoef(levels - levels.mean(), reference)[0, 1]):5.2f}")

    print("\nLine windows against the ungated center channel (speech cut off would show outside close to inside)")
    center = decode(center_source, start, duration)
    pad = int(0.15 * SAMPLE_RATE)
    for line in manifest["lines"]:
        a, b = int(line["start"] * SAMPLE_RATE), int(line["end"] * SAMPLE_RATE)
        print(f"  {line['id'][-7:]} {line['characterId']:<6} inside {db(rms(center[a:b])):6.1f} dBFS  before {db(rms(center[max(0, a - pad):a])):6.1f}  after {db(rms(center[b:b + pad])):6.1f}")

    print("\nCharacter tracks outside their own line windows (should be silent)")
    for character in manifest["characters"]:
        mask = np.ones(n, dtype=bool)
        for line in manifest["lines"]:
            if line["characterId"] == character["id"]:
                mask[int(line["start"] * SAMPLE_RATE):int(line["end"] * SAMPLE_RATE)] = False
        track = dialogue[character["id"]][:n]
        print(f"  {character['id']}: peak outside windows {db(float(np.max(np.abs(track[mask])))):6.1f} dBFS")

    print("\nBackground plus all dialogue against the film's stereo mix (audio of the pinned video release)")
    original = decode(mix_source, start, duration)[:n]
    reconstruction = background[:n] + sum(d[:n] for d in dialogue.values())
    max_lag = int(0.06 * SAMPLE_RATE)
    padded = np.pad(reconstruction, (max_lag, max_lag))
    lags = range(-max_lag, max_lag + 1, 8)
    best = max(lags, key=lambda lag: float(np.dot(original, padded[max_lag + lag:max_lag + lag + n])))
    rec = padded[max_lag + best:max_lag + best + n]
    gain = float(np.dot(original, rec) / np.dot(rec, rec))
    error = original - gain * rec
    print(f"  best alignment {-best / SAMPLE_RATE * 1000:+.1f} ms, gain {gain:.2f}, correlation {float(np.corrcoef(original, rec)[0, 1]):.2f}, SNR {10 * np.log10(np.sum(original ** 2) / np.sum(error ** 2)):.1f} dB")
    print(f"  stereo mix rms {db(rms(original)):.1f} dBFS, background rms {db(rms(background)):.1f} dBFS, dialogue rms {db(rms(sum(d[:n] for d in dialogue.values()))):.1f} dBFS")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
