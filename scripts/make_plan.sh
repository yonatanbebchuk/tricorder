#!/usr/bin/env bash
# Stage 5: solve scale/level/north from the measurement answers and render the real site plan.
#   scripts/make_plan.sh work/backyard
# Appends its own stage markers to run_all.log so the web UI tracks it, writes PLAN_DONE / PLAN_FAILED.
set -uo pipefail
WORK=$(cd "${1:?usage: make_plan.sh <work_dir>}" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY="$ROOT/.venv/bin/python"
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
PXM=${PXM:-50}
exec > >(tee -a "$WORK/run_all.log") 2>&1
rm -f "$WORK/PLAN_DONE" "$WORK/PLAN_FAILED"
T0=$(date +%s)
printf '\n######## 5. plan (scale from measurements, level, north)  [%s, +0m] ########\n' "$(date '+%H:%M:%S')"
fail() { echo "FAILED at plan step: $1"; echo "$1" > "$WORK/PLAN_FAILED"; exit 1; }
$PY "$ROOT/scripts/solve_scale.py" "$WORK" || fail solve
$BLENDER --background --python "$ROOT/scripts/05_site_plan_blender.py" -- \
    --mesh "$WORK/dense/scene_dense_mesh_texture.obj" --transform "$WORK/transform.json" \
    --out "$WORK/plan" --px-per-m "$PXM" 2>&1 | grep -E "^wrote|Error|Traceback" || fail render
$PY "$ROOT/scripts/06_annotate_plan.py" "$WORK/plan" || fail grid
$PY - "$WORK" <<'PYEOF'
import json, sys
from pathlib import Path
import numpy as np, open3d as o3d
w = Path(sys.argv[1]); T = np.array(json.load(open(w / "transform.json"))["matrix"])
pcd = o3d.io.read_point_cloud(str(w / "dense/scene_dense.ply")); pcd.transform(T)
o3d.io.write_point_cloud(str(w / "dense/scene_dense_metric.ply"), pcd)
e = pcd.get_axis_aligned_bounding_box().get_extent(); print(f"wrote dense/scene_dense_metric.ply: {e[0]:.1f} m x {e[1]:.1f} m, height {e[2]:.1f} m")
PYEOF
printf '\n######## done in %d min  [%s, +0m] ########\n' $(( ($(date +%s) - T0) / 60 )) "$(date '+%H:%M:%S')"
echo "plan: $WORK/plan_grid.png   blend: $WORK/plan.blend   metric cloud: $WORK/dense/scene_dense_metric.ply"
touch "$WORK/PLAN_DONE"
