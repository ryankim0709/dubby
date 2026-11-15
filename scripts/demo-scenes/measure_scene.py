#!/usr/bin/env python3
"""Measures how well a demo scene's tracks reproduce its original mix and bracket its lines.

Usage: python3 scripts/demo-scenes/measure_scene.py SCENE_DIR

Quality-assurance tool, not part of the build. Needs numpy, ffmpeg and the scene's own files:
the "original mix" is the audio stream inside <sceneId>-video.mp4.
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48000


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-vn", "-ac", "2", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype="<i2").reshape(-1, 2).astype(np.float64) / 32768


def db(value: float) -> float:
    return 20 * np.log10(max(value, 1e-9))


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0


def best_lag(reference: np.ndarray, signal: np.ndarray, max_lag: int) -> int:
    n = min(len(reference), len(signal)) - max_lag
    ref = reference[:n]
    scores = {}
    for lag in range(-max_lag, max_lag + 1, 8):
        a, b = (ref, signal[max_lag + lag:max_lag + lag + n])
        scores[lag] = float(np.dot(a, b))
    return max(scores, key=scores.get)


def main() -> None:
    scene_dir = Path(sys.argv[1])
    manifest = json.loads(next(scene_dir.glob("*-manifest.json")).read_text())
    original = decode(scene_dir / manifest["video"]["file"]).mean(axis=1)
    background = decode(scene_dir / manifest["background"]["file"]).mean(axis=1)
    dialogue = {c["id"]: decode(scene_dir / c["dialogue"]["file"]).mean(axis=1) for c in manifest["characters"]}
    n = min(len(original), len(background), *(len(d) for d in dialogue.values()))
    original, background = original[:n], background[:n]
    dialogue = {k: v[:n] for k, v in dialogue.items()}
    total_dialogue = sum(dialogue.values())

    print(f"scene {manifest['sceneId']}: {n / SAMPLE_RATE:.3f} s decoded")
    center_path = sys.argv[2] if len(sys.argv) > 2 else None
    if center_path:
        excerpt = manifest["provenance"]["excerpt"]
        source = np.frombuffer(subprocess.run(
            ["ffmpeg", "-v", "error", "-ss", str(excerpt["start"]), "-t", str(manifest["durationSeconds"]), "-i", center_path,
             "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-"], check=True, capture_output=True).stdout, dtype="<i2").astype(np.float64) / 32768
        print("\nLine windows against the ungated source: level inside vs the 150 ms just outside (speech cut off would show outside close to inside)")
        for line in manifest["lines"]:
            a, b = int(line["start"] * SAMPLE_RATE), int(line["end"] * SAMPLE_RATE)
            pad = int(0.15 * SAMPLE_RATE)
            print(f"  {line['id'][-7:]} {line['characterId']:<6} inside {db(rms(source[a:b])):6.1f} dBFS  before {db(rms(source[max(0, a - pad):a])):6.1f}  after {db(rms(source[b:b + pad])):6.1f}")

    print("\nEach dialogue line against the video's own audio (best alignment within 60 ms)")
    for line in manifest["lines"]:
        a, b = int(line["start"] * SAMPLE_RATE), int(line["end"] * SAMPLE_RATE)
        track = dialogue[line["characterId"]][a:b]
        best = (0, -1.0)
        for lag in range(-2880, 2881, 16):
            lo = a + lag
            if lo < 0 or lo + (b - a) > n:
                continue
            c = float(np.corrcoef(track, original[lo:lo + (b - a)])[0, 1])
            if c > best[1]:
                best = (lag, c)
        print(f"  {line['id'][-7:]} {line['characterId']:<6} video audio is {best[0] / SAMPLE_RATE * 1000:+6.1f} ms from the track, correlation {best[1]:.2f}")

    print("\nCharacter tracks outside their own line windows (should be silent)")
    for character in manifest["characters"]:
        mask = np.ones(n, dtype=bool)
        for line in manifest["lines"]:
            if line["characterId"] == character["id"]:
                mask[int(line["start"] * SAMPLE_RATE):int(line["end"] * SAMPLE_RATE)] = False
        print(f"  {character['id']}: peak outside windows {db(float(np.max(np.abs(dialogue[character['id']][mask])))):6.1f} dBFS")

    reconstruction = background + total_dialogue
    max_lag = int(0.06 * SAMPLE_RATE)
    lag = best_lag(original, np.pad(reconstruction, (max_lag, max_lag)), max_lag)
    print(f"\nReconstruction (background + all dialogue) against the video's own audio")
    print(f"  best alignment: reconstruction is {-lag / SAMPLE_RATE * 1000:+.1f} ms from the video audio")
    seg = slice(max_lag, n - max_lag)
    ref = original[seg]
    rec = np.roll(reconstruction, -lag)[seg]
    gain = float(np.dot(ref, rec) / np.dot(rec, rec))
    for name, mask in (("whole scene", np.ones(len(ref), dtype=bool)),):
        error = ref[mask] - gain * rec[mask]
        corr = float(np.corrcoef(ref[mask], rec[mask])[0, 1])
        print(f"  {name}: gain {gain:.2f}, correlation {corr:.2f}, SNR {10 * np.log10(np.sum(ref[mask] ** 2) / np.sum(error ** 2)):.1f} dB")
    in_lines = np.zeros(n, dtype=bool)
    for line in manifest["lines"]:
        in_lines[int(line["start"] * SAMPLE_RATE):int(line["end"] * SAMPLE_RATE)] = True
    for name, mask in (("inside line windows", in_lines[seg]), ("outside line windows", ~in_lines[seg])):
        error = ref[mask] - gain * rec[mask]
        corr = float(np.corrcoef(ref[mask], rec[mask])[0, 1])
        print(f"  {name}: correlation {corr:.2f}, SNR {10 * np.log10(np.sum(ref[mask] ** 2) / np.sum(error ** 2)):.1f} dB")
    print(f"  original rms {db(rms(original)):.1f} dBFS, background rms {db(rms(background)):.1f} dBFS, dialogue rms {db(rms(total_dialogue)):.1f} dBFS")


if __name__ == "__main__":
    main()
