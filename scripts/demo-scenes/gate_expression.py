#!/usr/bin/env python3
"""Prints an ffmpeg aeval expression that keeps one character's line windows and silences the rest.

Usage: python3 -I gate_expression.py TEMPLATE CHARACTER_ID FADE_SECONDS
"""
import json
import sys
from pathlib import Path


def main() -> None:
    template_path, character_id, fade = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
    lines = [l for l in json.loads(template_path.read_text())["lines"] if l["characterId"] == character_id]
    if not lines:
        sys.exit(f"no lines for character {character_id}")
    gain = "+".join(f"clip(min((t-{l['start']})/{fade},({l['end']}-t)/{fade}),0,1)" for l in lines)
    print(f"val(0)*min(1,{gain})")


if __name__ == "__main__":
    main()
