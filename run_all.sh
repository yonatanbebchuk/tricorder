#!/usr/bin/env bash
# Unattended end-to-end run: video -> frames -> COLMAP -> OpenMVS -> (unscaled) preview plan.
#
#   ./run_all.sh data/backyard.MOV            # work/backyard/...
#   ./run_all.sh data/clip.mov basement       # work/basement/...
#
# Safe to re-run: finished stages are skipped. Everything is logged to work/<name>/run_all.log and
# a DONE or FAILED marker file is written at the end. Run it under caffeinate so the Mac stays awake:
#   caffeinate -i -s ./run_all.sh data/backyard.MOV
#
# Env overrides: FPS (2), MAXF (400), RES_LEVEL (2), MEASURES (4), FEATURES (SIFT|ALIKED), MATCHER (BRUTEFORCE|LIGHTGLUE),
# MATCHING (vocab|sequential|exhaustive), RELAXED (1), plus everything 02_sfm.sh / 03_dense.sh accept.
set -uo pipefail
VIDEO=${1:?usage: run_all.sh <video> [name]}
NAME=${2:-$(basename "${VIDEO%.*}")}
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK="$ROOT/work/$NAME"
PY="$ROOT/.venv/bin/python"
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
FPS=${FPS:-2}; MAXF=${MAXF:-400}; export RES_LEVEL=${RES_LEVEL:-2}
export PYTHONUNBUFFERED=1   # so the Python stages stream into the log instead of dumping at exit
mkdir -p "$WORK"
exec > >(tee -a "$WORK/run_all.log") 2>&1
rm -f "$WORK/DONE" "$WORK/FAILED"
echo $$ > "$WORK/run.pid"        # lets the web UI tell "still running" from "interrupted" even for terminal launches
T0=$(date +%s)
stage() { printf '\n######## %s  [%s, +%dm] ########\n' "$1" "$(date '+%H:%M:%S')" $(( ($(date +%s) - T0) / 60 )); }
fail() { echo "FAILED at stage: $1 (see $WORK/run_all.log)"; echo "$1" > "$WORK/FAILED"; exit 1; }

stage "0. input"
echo "video: $VIDEO"
echo "settings: fps=$FPS max_frames=$MAXF res_level=$RES_LEVEL features=${FEATURES:-SIFT} matcher=${MATCHER:-BRUTEFORCE} matching=${MATCHING:-vocab} relaxed=${RELAXED:-1}"
TRC=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$VIDEO" 2>/dev/null || true)
case "$TRC" in
  arib-std-b67) HDR="--hdr hlg"; echo "HLG HDR video detected -> tone-mapping frames to SDR" ;;
  smpte2084)    HDR="--hdr pq";  echo "PQ HDR video detected -> tone-mapping frames to SDR" ;;
  *)            HDR="";          echo "SDR video (color_transfer=${TRC:-unknown})" ;;
esac

stage "1. frames"
if [ "$(ls "$WORK/images" 2>/dev/null | grep -c '\.jpg$')" -gt 10 ]; then
  echo "images exist, skipping"
else
  $PY "$ROOT/scripts/01_extract_frames.py" "$VIDEO" "$WORK/images" --fps "$FPS" --max-frames "$MAXF" $HDR || fail frames
fi

stage "2. sfm (COLMAP)"
if [ -f "$WORK/dense/sparse/images.txt" ]; then
  echo "dense/sparse exists, skipping"
else
  "$ROOT/scripts/02_sfm.sh" "$WORK/images" "$WORK" || fail sfm
fi

stage "3. dense (OpenMVS, resolution level $RES_LEVEL)"
if [ -f "$WORK/dense/scene_dense_mesh_texture.obj" ]; then
  echo "textured mesh exists, skipping"
else
  "$ROOT/scripts/03_dense.sh" "$WORK/dense" || fail dense
fi

stage "4. landmarks (unscaled preview plan + measurement prompts)"
$PY "$ROOT/scripts/04_scale_model.py" --cloud "$WORK/dense/scene_dense.ply" --factor 1.0 \
    --colmap-sparse "$WORK/dense/sparse" --out "$WORK/transform_preview.json" || fail preview-level
if [ -x "$BLENDER" ]; then
  "$BLENDER" --background --python "$ROOT/scripts/05_site_plan_blender.py" -- \
      --mesh "$WORK/dense/scene_dense_mesh_texture.obj" --transform "$WORK/transform_preview.json" \
      --out "$WORK/preview_plan" --px-per-m 100 2>&1 | grep -E "^wrote|Error|Traceback" || fail preview-render
  $PY "$ROOT/scripts/06_annotate_plan.py" "$WORK/preview_plan" || fail preview-grid
else
  echo "Blender not found at $BLENDER; skipping preview render"
fi
echo "==> picking landmarks to measure (${MEASURES:-4} prompts)"
$PY "$ROOT/scripts/pick_landmarks.py" "$WORK" --count "${MEASURES:-4}" || echo "landmark picking failed; you can still scale with scale_pairs.json"

stage "done in $(( ($(date +%s) - T0) / 60 )) min"
echo "images:        $(ls "$WORK/images" | grep -c '\.jpg$')"
colmap model_analyzer --path "$WORK/dense/sparse" 2>&1 | grep -E "Registered images|Points|Mean reprojection" | sed 's/^.*model.cc:[0-9]*\] /  /'
echo "dense cloud:   $WORK/dense/scene_dense.ply"
echo "textured mesh: $WORK/dense/scene_dense_mesh_texture.obj"
echo "preview plan:  $WORK/preview_plan_grid.png   (open preview_plan.blend in Blender)"
echo "next:          answer the measurement prompts in the web UI (or measure/answers.json), then scripts/make_plan.sh $WORK"
touch "$WORK/DONE"
