#!/usr/bin/env python3
"""Validates curated demo scenes against Scene Manifest v1.

Usage: python3 -I scripts/demo-scenes/validate_scene.py [SCENE_DIR ...]

Without arguments it validates every directory under Dubbing/DemoScenes. Needs Python 3 (standard
library only) and ffprobe. Exits 0 when every scene passes, 1 otherwise.
"""
import hashlib
import json
import math
import re
import subprocess
import sys
from pathlib import Path

DURATION_TOLERANCE = 0.020
MAX_TOTAL_BYTES = 10 * 1024 * 1024
KEBAB = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RESTRICTED_LICENSE = re.compile(r"(?:^|[-_ ])(?:NC|ND)(?:$|[-_ ])|NonCommercial|NoDerivs|Non-Commercial|No-Derivatives", re.IGNORECASE)
SEPARATION_METHODS = {"official-stems", "model-separation", "original-recording"}
TRANSCRIPT_SOURCES = {"official subtitles", "manual", "asr-corrected"}
WORD_TIMING_SOURCES = {"absent", "forced-alignment", "asr-estimated"}


class Report:
    def __init__(self, scene: str):
        self.scene = scene
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def check(self, condition: bool, message: str) -> bool:
        if not condition:
            self.failures.append(message)
        return condition

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def is_text(value) -> bool:
    return isinstance(value, str) and value.strip() != ""


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe(path: Path) -> dict | None:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def top_level_atoms(path: Path) -> list[str]:
    atoms = []
    size_total = path.stat().st_size
    with path.open("rb") as handle:
        offset = 0
        while offset + 8 <= size_total:
            handle.seek(offset)
            header = handle.read(8)
            size = int.from_bytes(header[:4], "big")
            kind = header[4:8].decode("latin-1")
            if size == 1:
                size = int.from_bytes(handle.read(8), "big")
            elif size == 0:
                size = size_total - offset
            atoms.append(kind)
            if size < 8:
                break
            offset += size
    return atoms


def parse_rate(text: str) -> float:
    numerator, _, denominator = text.partition("/")
    return float(numerator) / float(denominator) if denominator and float(denominator) else float(numerator)


def validate_file_entry(report: Report, scene_dir: Path, scene_id: str, label: str, entry, expected_name: str) -> Path | None:
    if not report.check(isinstance(entry, dict), f"{label}: expected an object with file and sha256"):
        return None
    name = entry.get("file")
    if not report.check(is_text(name), f"{label}.file is missing"):
        return None
    report.check(name == expected_name, f"{label}.file is {name!r}, expected {expected_name!r}")
    report.check(name.startswith(f"{scene_id}-"), f"{label}.file {name!r} must start with '{scene_id}-'")
    report.check("/" not in name and "\\" not in name, f"{label}.file {name!r} must be a bare file name")
    digest = entry.get("sha256")
    report.check(isinstance(digest, str) and HEX64.match(digest) is not None, f"{label}.sha256 must be 64 lowercase hex characters")
    path = scene_dir / name
    if not report.check(path.is_file(), f"{label}: file {name} does not exist"):
        return None
    if isinstance(digest, str) and HEX64.match(digest):
        report.check(sha256(path) == digest, f"{label}: sha256 of {name} does not match the manifest")
    return path


def validate_video(report: Report, path: Path, duration: float) -> None:
    info = probe(path)
    if not report.check(info is not None, f"video: ffprobe cannot read {path.name}"):
        return
    streams = [s for s in info["streams"] if s.get("codec_type") == "video"]
    if not report.check(len(streams) == 1, "video: expected exactly one video stream"):
        return
    stream = streams[0]
    report.check(stream.get("codec_name") == "h264", f"video: codec is {stream.get('codec_name')}, expected h264")
    width, height = stream.get("width", 0), stream.get("height", 0)
    report.check(0 < width <= 1280 and 0 < height <= 720, f"video: size {width}x{height} exceeds 1280x720")
    fps = parse_rate(stream.get("avg_frame_rate", "0/1")) or parse_rate(stream.get("r_frame_rate", "0/1"))
    report.check(0 < fps <= 30.001, f"video: frame rate {fps:.3f} exceeds 30 fps")
    atoms = top_level_atoms(path)
    report.check("moov" in atoms and "mdat" in atoms and atoms.index("moov") < atoms.index("mdat"), "video: moov atom must precede mdat (faststart)")
    video_duration = float(info["format"]["duration"])
    report.check(10 <= video_duration <= 30, f"video: duration {video_duration:.3f}s is outside 10-30 s")
    report.check(abs(video_duration - duration) <= DURATION_TOLERANCE, f"video: duration {video_duration:.3f}s differs from durationSeconds {duration:.3f}s by more than 20 ms")


def validate_audio(report: Report, label: str, path: Path, video_duration: float) -> None:
    report.check(path.suffix == ".m4a", f"{label}: {path.name} must be an .m4a file")
    info = probe(path)
    if not report.check(info is not None, f"{label}: ffprobe cannot read {path.name}"):
        return
    streams = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    if not report.check(len(streams) == 1, f"{label}: expected exactly one audio stream"):
        return
    stream = streams[0]
    report.check(stream.get("codec_name") == "aac" and stream.get("profile") == "LC", f"{label}: codec is {stream.get('codec_name')}/{stream.get('profile')}, expected AAC LC")
    report.check(stream.get("sample_rate") == "48000", f"{label}: sample rate is {stream.get('sample_rate')}, expected 48000")
    report.check(abs(float(stream.get("start_time", 0))) <= DURATION_TOLERANCE, f"{label}: track must start at 0 (start_time {stream.get('start_time')})")
    duration = float(info["format"]["duration"])
    report.check(abs(duration - video_duration) <= DURATION_TOLERANCE, f"{label}: duration {duration:.3f}s differs from the video's {video_duration:.3f}s by more than 20 ms")


def validate_lines(report: Report, manifest: dict, duration: float, character_ids: set[str]) -> None:
    lines = manifest.get("lines")
    if not report.check(isinstance(lines, list) and lines, "lines: expected a non-empty array"):
        return
    seen_ids: set[str] = set()
    previous_start = -math.inf
    last_end_by_character: dict[str, float] = {}
    valid_lines = []
    counts: dict[str, int] = {}
    any_words = False
    for index, line in enumerate(lines):
        label = f"lines[{index}]"
        if not report.check(isinstance(line, dict), f"{label}: expected an object"):
            continue
        line_id = line.get("id")
        report.check(is_text(line_id) and line_id not in seen_ids, f"{label}: id is missing or duplicated")
        if is_text(line_id):
            seen_ids.add(line_id)
        character = line.get("characterId")
        report.check(character in character_ids, f"{label}: characterId {character!r} does not resolve to a character")
        report.check(is_text(line.get("text")), f"{label}: text is missing")
        report.check(isinstance(line.get("referenceVersion"), int) and not isinstance(line.get("referenceVersion"), bool) and line["referenceVersion"] >= 1, f"{label}: referenceVersion must be a positive integer")
        start, end = line.get("start"), line.get("end")
        if not report.check(is_number(start) and is_number(end), f"{label}: start and end must be finite numbers"):
            continue
        report.check(0 <= start < end <= duration, f"{label}: needs 0 <= start < end <= {duration:.3f}, got {start}..{end}")
        report.check(start >= previous_start, f"{label}: lines must be sorted by start")
        previous_start = start
        if character in character_ids:
            counts[character] = counts.get(character, 0) + 1
            report.check(start >= last_end_by_character.get(character, -math.inf), f"{label}: overlaps an earlier line of {character}")
            last_end_by_character[character] = max(last_end_by_character.get(character, -math.inf), end)
        valid_lines.append((start, end, character))
        words = line.get("words")
        if words is None:
            continue
        any_words = True
        if not report.check(isinstance(words, list), f"{label}.words must be an array"):
            continue
        previous_word_end = start
        for word_index, word in enumerate(words):
            word_label = f"{label}.words[{word_index}]"
            if not report.check(isinstance(word, dict) and is_text(word.get("text")) and is_number(word.get("start")) and is_number(word.get("end")), f"{word_label}: needs text, start, end"):
                continue
            report.check(start <= word["start"] < word["end"] <= end, f"{word_label}: must lie within its line")
            report.check(word["start"] >= previous_word_end - 1e-9, f"{word_label}: words must be ordered")
            previous_word_end = word["end"]
    report.check(len(character_ids) >= 2, "characters: at least two are required")
    report.check(any(2 <= count <= 4 for count in counts.values()), "lines: at least one character (the practice character) needs 2 to 4 lines")
    for character in sorted(character_ids - set(counts)):
        report.warn(f"character {character} has no lines")
    overlaps = sum(
        1
        for i, (a_start, a_end, a_char) in enumerate(valid_lines)
        for b_start, b_end, b_char in valid_lines[i + 1:]
        if a_char != b_char and b_start < a_end and a_start < b_end
    )
    report.check(overlaps <= max(1, len(valid_lines) // 4), f"lines: {overlaps} cross-character overlaps is not rare")
    if overlaps:
        report.warn(f"{overlaps} cross-character overlap(s)")
    return any_words


def validate_provenance(report: Report, manifest: dict, duration: float, any_words: bool) -> None:
    provenance = manifest.get("provenance")
    if not report.check(isinstance(provenance, dict), "provenance: expected an object"):
        return
    for key in ("work", "creator", "sourceURL", "license", "licenseURL", "attribution"):
        report.check(is_text(provenance.get(key)), f"provenance.{key} is missing")
    for key in ("sourceURL", "licenseURL"):
        report.check(str(provenance.get(key, "")).startswith("https://"), f"provenance.{key} must be an https URL")
    report.check(isinstance(provenance.get("sourceSHA256"), str) and HEX64.match(provenance["sourceSHA256"]) is not None, "provenance.sourceSHA256 must be 64 lowercase hex characters")
    license_text = f"{provenance.get('license', '')} {provenance.get('licenseURL', '')}"
    report.check(RESTRICTED_LICENSE.search(license_text) is None, "provenance.license must not carry NonCommercial or NoDerivatives terms")
    excerpt = provenance.get("excerpt")
    if report.check(isinstance(excerpt, dict) and is_number(excerpt.get("start")) and is_number(excerpt.get("end")) and 0 <= excerpt["start"] < excerpt["end"], "provenance.excerpt needs finite start < end"):
        report.check(abs((excerpt["end"] - excerpt["start"]) - duration) <= DURATION_TOLERANCE, "provenance.excerpt length differs from durationSeconds by more than 20 ms")
    modifications = provenance.get("modifications")
    report.check(isinstance(modifications, list) and modifications and all(is_text(m) for m in modifications), "provenance.modifications must list every modification")
    separation = provenance.get("dialogueSeparation")
    if report.check(isinstance(separation, dict), "provenance.dialogueSeparation is missing"):
        report.check(separation.get("method") in SEPARATION_METHODS, f"provenance.dialogueSeparation.method must be one of {sorted(SEPARATION_METHODS)}")
        report.check(is_text(separation.get("tool")) and is_text(separation.get("notes")), "provenance.dialogueSeparation needs tool and notes")
    report.check(provenance.get("transcriptSource") in TRANSCRIPT_SOURCES, f"provenance.transcriptSource must be one of {sorted(TRANSCRIPT_SOURCES)}")
    word_source = provenance.get("wordTimingSource")
    report.check(word_source in WORD_TIMING_SOURCES, f"provenance.wordTimingSource must be one of {sorted(WORD_TIMING_SOURCES)}")
    if any_words:
        report.check(word_source != "absent", "lines carry words but provenance.wordTimingSource is 'absent'")
    else:
        report.check(word_source == "absent", "no line carries words but provenance.wordTimingSource is not 'absent'")


def validate_scene(scene_dir: Path) -> Report:
    report = Report(scene_dir.name)
    manifests = sorted(scene_dir.glob("*-manifest.json"))
    if not report.check(len(manifests) == 1, f"expected exactly one *-manifest.json in {scene_dir}, found {len(manifests)}"):
        return report
    manifest_path = manifests[0]
    try:
        manifest = json.loads(manifest_path.read_text())
    except json.JSONDecodeError as error:
        report.check(False, f"manifest is not valid JSON: {error}")
        return report
    if not report.check(isinstance(manifest, dict), "manifest must be a JSON object"):
        return report
    report.check(manifest.get("schemaVersion") == 1, "schemaVersion must be 1")
    scene_id = manifest.get("sceneId")
    if not report.check(isinstance(scene_id, str) and KEBAB.match(scene_id) is not None, "sceneId must be kebab-case"):
        return report
    report.check(manifest_path.name == f"{scene_id}-manifest.json", f"manifest file must be named {scene_id}-manifest.json")
    for key in ("title", "synopsis", "locale"):
        report.check(is_text(manifest.get(key)), f"{key} is missing")
    duration = manifest.get("durationSeconds")
    if not report.check(is_number(duration) and 10 <= duration <= 30, "durationSeconds must be a finite number between 10 and 30"):
        return report

    video_path = validate_file_entry(report, scene_dir, scene_id, "video", manifest.get("video"), f"{scene_id}-video.mp4")
    if video_path:
        validate_video(report, video_path, duration)
    poster_path = validate_file_entry(report, scene_dir, scene_id, "poster", manifest.get("poster"), f"{scene_id}-poster.jpg")
    if poster_path:
        report.check(poster_path.read_bytes()[:3] == b"\xff\xd8\xff", "poster: not a JPEG file")
    audio_paths = []
    background_path = validate_file_entry(report, scene_dir, scene_id, "background", manifest.get("background"), f"{scene_id}-background.m4a")
    if background_path:
        audio_paths.append(("background", background_path))

    character_ids: set[str] = set()
    characters = manifest.get("characters")
    if report.check(isinstance(characters, list) and characters, "characters: expected a non-empty array"):
        for index, character in enumerate(characters):
            label = f"characters[{index}]"
            if not report.check(isinstance(character, dict), f"{label}: expected an object"):
                continue
            character_id = character.get("id")
            if report.check(isinstance(character_id, str) and KEBAB.match(character_id) is not None and character_id not in character_ids, f"{label}: id must be unique kebab-case"):
                character_ids.add(character_id)
            report.check(is_text(character.get("displayName")) and is_text(character.get("description")), f"{label}: displayName and description are required")
            dialogue_path = validate_file_entry(report, scene_dir, scene_id, f"{label}.dialogue", character.get("dialogue"), f"{scene_id}-dialogue-{character_id}.m4a")
            if dialogue_path:
                audio_paths.append((f"{label}.dialogue", dialogue_path))
    if video_path and probe(video_path):
        video_duration = float(probe(video_path)["format"]["duration"])
        for label, path in audio_paths:
            validate_audio(report, label, path, video_duration)

    any_words = validate_lines(report, manifest, duration, character_ids)
    validate_provenance(report, manifest, duration, bool(any_words))

    names = [p.name for p in scene_dir.iterdir() if p.is_file()]
    report.check(all(name.startswith(f"{scene_id}-") for name in names), "every file in the scene directory must start with the sceneId prefix")
    total = sum(p.stat().st_size for p in scene_dir.iterdir() if p.is_file())
    report.check(total <= MAX_TOTAL_BYTES, f"total size {total} bytes exceeds the 10 MB limit")
    report.warn(f"total size {total} bytes")
    return report


def main() -> int:
    if subprocess.run(["ffprobe", "-version"], capture_output=True).returncode != 0:
        print("ffprobe is required", file=sys.stderr)
        return 2
    arguments = [Path(a) for a in sys.argv[1:]]
    if not arguments:
        root = Path(__file__).resolve().parents[2] / "Dubbing" / "DemoScenes"
        arguments = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
        if not arguments:
            print(f"no scenes found under {root}", file=sys.stderr)
            return 2
    failed = False
    for scene_dir in arguments:
        report = validate_scene(scene_dir)
        status = "FAIL" if report.failures else "PASS"
        print(f"{status} {scene_dir}")
        for message in report.failures:
            print(f"  error: {message}")
        for message in report.warnings:
            print(f"  note: {message}")
        failed = failed or bool(report.failures)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
