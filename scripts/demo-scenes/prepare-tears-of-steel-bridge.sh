#!/usr/bin/env bash
# Rebuilds Dubbing/DemoScenes/tears-of-steel-bridge from the pinned official Blender Foundation files.
#
# Usage: scripts/demo-scenes/prepare-tears-of-steel-bridge.sh [OUTPUT_DIR]
# Needs: bash, curl, ffmpeg (libx264 and the native aac encoder), ffprobe, python3, sha256sum or shasum.
# Downloads about 690 MB once into $DEMO_SCENE_CACHE (default ~/.cache/dubit-demo-scenes/tears-of-steel-bridge).
set -euo pipefail

SCENE_ID=tears-of-steel-bridge
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS=$REPO_ROOT/scripts/demo-scenes
TEMPLATE=$SCRIPTS/$SCENE_ID.template.json
OUT_DIR=${1:-$REPO_ROOT/Dubbing/DemoScenes/$SCENE_ID}
CACHE=${DEMO_SCENE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dubit-demo-scenes/$SCENE_ID}

BASE_URL=https://download.blender.org/demo/movies/ToS
EXCERPT_START=29.75
EXCERPT_DURATION=10.0
GATE_FADE_SECONDS=0.01
BACKGROUND_SILENT_UNTIL=5.25
BACKGROUND_FADE_IN=0.25

VIDEO_NAME=tears_of_steel_720p.mov
VIDEO_URL=$BASE_URL/tears_of_steel_720p.mov
VIDEO_SHA256=efa9062d9cdb7a338e40ad530dfdf234806743f29ae6a1a136b97ece4e588e8f
CENTER_NAME=TOS_DVDSURROUND.C.aif
CENTER_URL=$BASE_URL/surround/TOS_DVDSURROUND.C.aif
CENTER_SHA256=cac2e6fe39fe07d06df72fe4ce2a65ccf73c4cfbc2ba1e424dca1aaee5df53f7
MUSICFX_NAME=TOS_MUSIC+FX_NO_DIALOGUE.aif
MUSICFX_URL=$BASE_URL/TOS_MUSIC%2BFX_NO_DIALOGUE.aif
MUSICFX_SHA256=ba05dc3ae9f869170819ef9f74401e6c01ccc4afa9e8c926a076bea7b29741e0
SUBTITLES_NAME=TOS-en.srt
SUBTITLES_URL=$BASE_URL/subtitles/TOS-en.srt
SUBTITLES_SHA256=ce9578f6fe098a5821045a38884b229160f9e7ba27890448a92f5be330c6e6fe

for tool in curl ffmpeg ffprobe python3; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch_verified() {
  local name=$1 url=$2 expected=$3 path=$CACHE/$1
  mkdir -p "$CACHE"
  if [[ -f $path && $(sha256_of "$path") == "$expected" ]]; then
    echo "cached  $name"
    return
  fi
  echo "fetch   $name"
  curl -fL --retry 3 -C - -o "$path" "$url"
  local actual
  actual=$(sha256_of "$path")
  if [[ $actual != "$expected" ]]; then
    echo "checksum mismatch for $name: expected $expected, got $actual" >&2
    rm -f "$path"
    exit 1
  fi
}

fetch_verified "$VIDEO_NAME" "$VIDEO_URL" "$VIDEO_SHA256"
fetch_verified "$CENTER_NAME" "$CENTER_URL" "$CENTER_SHA256"
fetch_verified "$MUSICFX_NAME" "$MUSICFX_URL" "$MUSICFX_SHA256"
fetch_verified "$SUBTITLES_NAME" "$SUBTITLES_URL" "$SUBTITLES_SHA256"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FF=(ffmpeg -v error -y -fflags +bitexact -flags +bitexact)

echo "build   video"
"${FF[@]}" -ss "$EXCERPT_START" -i "$CACHE/$VIDEO_NAME" -t "$EXCERPT_DURATION" \
  -map 0:v:0 -an \
  -c:v libx264 -preset slow -crf 23 -profile:v high -pix_fmt yuv420p -threads 1 \
  -map_metadata -1 -movflags +faststart \
  "$WORK/$SCENE_ID-video.mp4"

echo "build   background"
"${FF[@]}" -ss "$EXCERPT_START" -t "$EXCERPT_DURATION" -i "$CACHE/$MUSICFX_NAME" \
  -af "aresample=48000,aeval='val(0)*clip((t-$BACKGROUND_SILENT_UNTIL)/$BACKGROUND_FADE_IN,0,1)|val(1)*clip((t-$BACKGROUND_SILENT_UNTIL)/$BACKGROUND_FADE_IN,0,1)':c=same" \
  -c:a aac -b:a 128k -ar 48000 -ac 2 -map_metadata -1 -movflags +faststart \
  "$WORK/$SCENE_ID-background.m4a"

for character in $(python3 -I -c "import json,sys; print(' '.join(c['id'] for c in json.load(open(sys.argv[1]))['characters']))" "$TEMPLATE"); do
  echo "build   dialogue-$character"
  expr=$(python3 -I "$SCRIPTS/gate_expression.py" "$TEMPLATE" "$character" "$GATE_FADE_SECONDS")
  "${FF[@]}" -ss "$EXCERPT_START" -t "$EXCERPT_DURATION" -i "$CACHE/$CENTER_NAME" \
    -af "aeval='$expr':c=same,pan=stereo|c0=c0|c1=c0" -c:a aac -b:a 96k -ar 48000 -ac 2 -map_metadata -1 -movflags +faststart \
    "$WORK/$SCENE_ID-dialogue-$character.m4a"
done

echo "build   poster"
"${FF[@]}" -ss 2.5 -i "$WORK/$SCENE_ID-video.mp4" -frames:v 1 -q:v 3 -map_metadata -1 "$WORK/$SCENE_ID-poster.jpg"

echo "build   manifest"
python3 -I "$SCRIPTS/assemble_manifest.py" "$TEMPLATE" "$WORK" "$VIDEO_SHA256" > "$WORK/$SCENE_ID-manifest.json"

echo "check   validate"
python3 -I "$SCRIPTS/validate_scene.py" "$WORK"

mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -type f -name "$SCENE_ID-*" -delete
cp "$WORK"/"$SCENE_ID"-* "$OUT_DIR"/
echo "wrote   $OUT_DIR"
