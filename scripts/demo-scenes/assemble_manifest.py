#!/usr/bin/env python3
"""Fills a scene manifest template with file hashes and a measured duration.

Usage: python3 -I assemble_manifest.py TEMPLATE SCENE_DIR SOURCE_SHA256 > manifest.json
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return float(json.loads(out)["format"]["duration"])


def main() -> None:
    template_path, scene_dir, source_sha = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    manifest = json.loads(template_path.read_text())
    manifest["durationSeconds"] = round(probe_duration(scene_dir / manifest["video"]["file"]), 3)
    for entry in [manifest["video"], manifest["poster"], manifest["background"]] + [c["dialogue"] for c in manifest["characters"]]:
        entry["sha256"] = sha256(scene_dir / entry["file"])
    manifest["provenance"]["sourceSHA256"] = source_sha
    json.dump(manifest, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
