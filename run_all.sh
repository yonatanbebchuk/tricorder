#!/usr/bin/env bash
# Compatibility wrapper: environment + recording + scan run from a video, executed in the foreground.
#   ./run_all.sh data/backyard.MOV "Backyard noon"
# Env: FPS, MAXF, RES_LEVEL, FEATURES, MATCHER, MATCHING, MEASURES (same names as before).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
VIDEO=${1:?usage: run_all.sh <video> [name]}
NAME=${2:-$(basename "${VIDEO%.*}")}
exec "$ROOT/.venv/bin/python" -m tricorder.pipeline new "$VIDEO" --name "$NAME" \
  --fps "${FPS:-2}" --max-frames "${MAXF:-400}" --res-level "${RES_LEVEL:-2}" \
  --features "${FEATURES:-SIFT}" --matcher "${MATCHER:-BRUTEFORCE}" --matching "${MATCHING:-vocab}" \
  --measures "${MEASURES:-4}" --start
