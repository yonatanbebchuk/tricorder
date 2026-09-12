#!/usr/bin/env bash
# Structure-from-Motion with COLMAP: camera poses + sparse point cloud,
# then undistorted images laid out for OpenMVS.
#
# Usage: scripts/02_sfm.sh <images_dir> <work_dir>
#   e.g. scripts/02_sfm.sh work/backyard/images work/backyard
#
# Env overrides:
#   FEATURES         SIFT (default) or ALIKED (learned features; far better on blank walls, slower on CPU)
#   MATCHER          BRUTEFORCE (default) or LIGHTGLUE (learned matcher, more matches on weak texture)
#                    Basement test, 286 frames: SIFT+BRUTEFORCE registered 81 frames in 8 min;
#                    ALIKED+LIGHTGLUE registered 282 frames in one model but took ~3 h on the M4 (CPU only).
#   MATCHING         vocab (default: sequential + retrieval of VOCAB_NEIGHBOURS look-alike images, ~5 min/300 images),
#                    sequential (neighbours in time only), or exhaustive (every pair; ~20 min/300 images, no gain over vocab)
#   RELAXED          1 = accept images with fewer inliers (abs_pose_min_num_inliers 15, min_num_matches 10);
#                    registers noticeably more frames on texture-poor scenes at no accuracy cost (default 1)
#   MAX_IMAGE_SIZE   feature extraction size (default 3200 for SIFT, 1600 for ALIKED)
#   OVERLAP          sequential matcher overlap (default 25)
#   LOOP_DETECTION   1 to enable vocab-tree loop closure (default 1; needed when you walk overlapping loops)
#   VOCAB_TREE       vocab tree path or URL (default: COLMAP's own release file, downloaded+cached on first use)
#   UNDISTORT_SIZE   max image size handed to OpenMVS (default 2400)
set -euo pipefail
IMG=${1:?usage: 02_sfm.sh <images_dir> <work_dir>}
WORK=${2:?usage: 02_sfm.sh <images_dir> <work_dir>}
FEATURES=${FEATURES:-SIFT}
MATCHER=${MATCHER:-BRUTEFORCE}
MATCHING=${MATCHING:-vocab}
RELAXED=${RELAXED:-1}
# LightGlue is ~20x slower per pair than brute force on CPU; retrieval of 50 neighbours took 1h45 for 286 frames,
# so it defaults to 20 neighbours there
if [ "$MATCHER" = "LIGHTGLUE" ]; then VOCAB_NEIGHBOURS=${VOCAB_NEIGHBOURS:-20}; else VOCAB_NEIGHBOURS=${VOCAB_NEIGHBOURS:-50}; fi
if [ "$FEATURES" = "ALIKED" ]; then MAX_IMAGE_SIZE=${MAX_IMAGE_SIZE:-1600}; else MAX_IMAGE_SIZE=${MAX_IMAGE_SIZE:-3200}; fi
OVERLAP=${OVERLAP:-25}
LOOP_DETECTION=${LOOP_DETECTION:-1}
# COLMAP 4.x downloads and caches a vocab tree when given "<url>;<file name>;<sha256>" (its built-in registry entry)
if [ "$FEATURES" = "ALIKED" ]; then
  VOCAB_TREE=${VOCAB_TREE:-"https://github.com/colmap/colmap/releases/download/3.13.0/vocab_tree_faiss_flickr100K_words64K_aliked_n16rot.bin;vocab_tree_faiss_flickr100K_words64K_aliked_n16rot.bin;8b2f9bdc44ca7204d8543bb3adab4c03ba9336c84ef41220b5007991036f075e"}
else
  VOCAB_TREE=${VOCAB_TREE:-"https://github.com/colmap/colmap/releases/download/3.11.1/vocab_tree_faiss_flickr100K_words256K.bin;vocab_tree_faiss_flickr100K_words256K.bin;96ca8ec8ea60b1f73465aaf2c401fd3b3ca75cdba2d3c50d6a2f6f760f275ddc"}
fi
MATCH_TYPE="${FEATURES}_${MATCHER}"      # SIFT_BRUTEFORCE, SIFT_LIGHTGLUE, ALIKED_BRUTEFORCE, ALIKED_LIGHTGLUE
EXTRACT_TYPE=$FEATURES; [ "$FEATURES" = "ALIKED" ] && EXTRACT_TYPE=ALIKED_N16ROT   # COLMAP names the ALIKED variants explicitly
MAPPER_EXTRA=""
[ "$RELAXED" = "1" ] && MAPPER_EXTRA="--Mapper.abs_pose_min_num_inliers 15 --Mapper.min_num_matches 10 --Mapper.init_min_num_inliers 50"
UNDISTORT_SIZE=${UNDISTORT_SIZE:-2400}
THREADS=$(sysctl -n hw.ncpu)
DB="$WORK/database.db"
mkdir -p "$WORK"

log() { printf '\n==> %s\n' "$*"; }

if [ ! -f "$DB" ]; then
  log "feature extraction ($(ls "$IMG" | grep -ci jpg) images, $FEATURES, max size $MAX_IMAGE_SIZE)"
  colmap feature_extractor \
    --database_path "$DB" --image_path "$IMG" \
    --ImageReader.camera_model OPENCV --ImageReader.single_camera 1 \
    --FeatureExtraction.type "$EXTRACT_TYPE" \
    --FeatureExtraction.use_gpu 0 --FeatureExtraction.num_threads "$THREADS" \
    --FeatureExtraction.max_image_size "$MAX_IMAGE_SIZE" \
    --SiftExtraction.max_num_features 8192 --AlikedExtraction.max_num_features 4096
else
  log "database exists, skipping feature extraction ($DB)"
fi

if [ "$MATCHING" = "exhaustive" ]; then
  log "exhaustive matching ($MATCH_TYPE, every pair)"
  colmap exhaustive_matcher --database_path "$DB" --FeatureMatching.type "$MATCH_TYPE" \
    --FeatureMatching.use_gpu 0 --FeatureMatching.num_threads "$THREADS"
else
  log "sequential matching ($MATCH_TYPE, overlap $OVERLAP, loop detection $LOOP_DETECTION)"
  colmap sequential_matcher \
    --database_path "$DB" --FeatureMatching.type "$MATCH_TYPE" \
    --SequentialMatching.overlap "$OVERLAP" --SequentialMatching.quadratic_overlap 1 \
    --SequentialMatching.loop_detection "$LOOP_DETECTION" \
    --SequentialMatching.vocab_tree_path "$VOCAB_TREE" \
    --FeatureMatching.use_gpu 0 --FeatureMatching.num_threads "$THREADS"
  if [ "$MATCHING" = "vocab" ]; then
    log "vocab-tree retrieval matching ($VOCAB_NEIGHBOURS look-alike images per image)"
    colmap vocab_tree_matcher --database_path "$DB" --FeatureMatching.type "$MATCH_TYPE" \
      --VocabTreeMatching.vocab_tree_path "$VOCAB_TREE" --VocabTreeMatching.num_images "$VOCAB_NEIGHBOURS" \
      --FeatureMatching.use_gpu 0 --FeatureMatching.num_threads "$THREADS"
  fi
fi

log "mapper (incremental SfM${RELAXED:+, relaxed thresholds})"
mkdir -p "$WORK/sparse"
# shellcheck disable=SC2086
colmap mapper --database_path "$DB" --image_path "$IMG" --output_path "$WORK/sparse" \
  --Mapper.num_threads "$THREADS" $MAPPER_EXTRA

# Pick the sub-model with the most registered images.
BEST=""; BEST_N=0
for d in "$WORK"/sparse/*/; do
  n=$(colmap model_analyzer --path "$d" 2>&1 | sed -n 's/.*Registered images: *\([0-9][0-9]*\).*/\1/p' | head -1)
  n=${n:-0}
  echo "  model $(basename "$d"): $n registered images"
  if [ "${n:-0}" -gt "$BEST_N" ]; then BEST_N=$n; BEST=$d; fi
done
[ -n "$BEST" ] || { echo "no model produced; see README troubleshooting" >&2; exit 1; }
log "best model: $BEST"
colmap model_analyzer --path "$BEST" 2>&1 | sed 's/^/  /'
colmap model_converter --input_path "$BEST" --output_path "$WORK/sparse_points.ply" --output_type PLY

log "undistorting images for OpenMVS -> $WORK/dense"
colmap image_undistorter --image_path "$IMG" --input_path "$BEST" \
  --output_path "$WORK/dense" --output_type COLMAP --max_image_size "$UNDISTORT_SIZE"
colmap model_converter --input_path "$WORK/dense/sparse" --output_path "$WORK/dense/sparse" --output_type TXT

log "done. Open $WORK/sparse_points.ply in CloudCompare/MeshLab to sanity-check the sparse cloud,"
echo "    then run scripts/03_dense.sh $WORK/dense"
