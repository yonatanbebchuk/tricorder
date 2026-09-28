#!/usr/bin/env bash
# Dense reconstruction, meshing and texturing with OpenMVS (CPU, no CUDA needed).
#
# Usage: scripts/03_dense.sh <dense_dir>      e.g. scripts/03_dense.sh work/backyard/dense
# Env:   RES_LEVEL  0 = full res (slow, RAM hungry), 1 = half, 2 = quarter (default 2, fine for a backyard)
#        REFINE=1   run RefineMesh (slow; sharper walls/edges)
#        MIN_FACES  detached mesh fragments smaller than this are dropped before texturing (default 2000)
#        MAX_FACES  decimate the cleaned mesh to at most this many faces before texturing (default 4000000; 0 = never)
#        OPENMVS_BIN  directory with the OpenMVS binaries (default tools/openmvs-install/bin/OpenMVS)
set -euo pipefail
DENSE=$(cd "${1:?usage: 03_dense.sh <dense_dir>}" && pwd)
RES_LEVEL=${RES_LEVEL:-2}
REFINE=${REFINE:-0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OPENMVS_BIN=${OPENMVS_BIN:-$ROOT/tools/openmvs-install/bin/OpenMVS}
THREADS=$(sysctl -n hw.ncpu)

if [ -x "$OPENMVS_BIN/DensifyPointCloud" ]; then
  run() { "$OPENMVS_BIN/$1" "${@:2}"; }
elif command -v docker >/dev/null && docker image inspect opendronemap/odm >/dev/null 2>&1; then
  echo "using OpenMVS from the opendronemap/odm docker image"
  run() { docker run --rm -v "$DENSE:/data" -w /data opendronemap/odm /code/SuperBuild/install/bin/OpenMVS/"$1" "${@:2}"; }
else
  echo "OpenMVS not found. Run ./setup.sh (builds it into tools/openmvs-install) or 'docker pull opendronemap/odm'." >&2
  exit 1
fi

cd "$DENSE"
log() { printf '\n==> %s\n' "$*"; }

# Resumable: each step is skipped when its output already exists (delete the file to redo it).
if [ -f scene.mvs ]; then log "scene.mvs exists, skipping InterfaceCOLMAP"; else
  log "COLMAP -> MVS scene"
  run InterfaceCOLMAP -w . -i . -o scene.mvs --image-folder images
fi

if [ -f scene_dense.ply ] && [ -f scene_dense.mvs ]; then log "scene_dense.ply exists, skipping DensifyPointCloud"; else
  log "DensifyPointCloud (resolution level $RES_LEVEL)"
  run DensifyPointCloud -w . scene.mvs --resolution-level "$RES_LEVEL" --number-views-fuse 3 --max-threads "$THREADS"
fi

if [ -f scene_dense_mesh.ply ]; then log "scene_dense_mesh.ply exists, skipping ReconstructMesh"; else
  log "ReconstructMesh"
  run ReconstructMesh -w . scene_dense.mvs --max-threads "$THREADS"
fi
MESH=scene_dense_mesh.ply

log "clean_mesh (drop detached fragments < ${MIN_FACES:-2000} faces)"
if "$ROOT/.venv/bin/python" "$ROOT/scripts/clean_mesh.py" "$MESH" --min-faces "${MIN_FACES:-2000}" --max-faces "${MAX_FACES:-4000000}" --out scene_dense_mesh_clean.ply 2>&1 | grep -v "Open3D WARNING"; then
  MESH=scene_dense_mesh_clean.ply
else
  echo "cleanup failed, texturing the raw mesh"
fi

if [ "$REFINE" = "1" ]; then
  log "RefineMesh"
  run RefineMesh -w . scene_dense.mvs -m "$MESH" -o scene_dense_mesh_refine.ply --resolution-level "$RES_LEVEL" --max-threads "$THREADS"
  MESH=scene_dense_mesh_refine.ply
fi

log "TextureMesh -> OBJ"
run TextureMesh -w . scene_dense.mvs -m "$MESH" -o scene_dense_mesh_texture.obj --export-type obj \
  --resolution-level "$RES_LEVEL" --max-threads "$THREADS"

log "outputs in $DENSE:"
ls -la scene_dense.ply scene_dense_mesh*.ply scene_dense_mesh_texture.* 2>/dev/null | sed 's/^/  /'
echo "Next: pick your scale-marker points in CloudCompare on scene_dense.ply, then run scripts/04_scale_model.py"
