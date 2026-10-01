#!/usr/bin/env bash
# Register new images into an existing COLMAP reconstruction (the "extend scan" run), then re-optimise everything.
#
# Usage: scripts/02b_register.sh <images_dir> <work_dir> <new_images_list>
#   <work_dir>/database.db and <work_dir>/sparse/parent must be clones of the parent 3D model's database and poses;
#   <images_dir> holds the parent's frames (as the database names them) plus the new ones (names in the list file,
#   relative to <images_dir>, one per line, e.g. rec4/p0003.jpg).
#
# Steps: features for the new images only (same feature type as the parent; one camera per new recording folder) →
# sequential matching (new videos) and vocab-tree retrieval of the new images against everything → image_registrator
# poses the new images in the parent's frame → point_triangulator adds their tracks → a full bundle adjustment over
# old and new (the frame drifts a little; geometry wins) → undistort the union for OpenMVS.  Output: sparse/0.
#
# Env: FEATURES, MATCHER, MAX_IMAGE_SIZE, VOCAB_NEIGHBOURS, VOCAB_TREE, OVERLAP, UNDISTORT_SIZE as in 02_sfm.sh.
set -euo pipefail
IMG=${1:?usage: 02b_register.sh <images_dir> <work_dir> <new_images_list>}
WORK=${2:?usage: 02b_register.sh <images_dir> <work_dir> <new_images_list>}
NEW=${3:?usage: 02b_register.sh <images_dir> <work_dir> <new_images_list>}
FEATURES=${FEATURES:-SIFT}
MATCHER=${MATCHER:-BRUTEFORCE}
if [ "$MATCHER" = "LIGHTGLUE" ]; then VOCAB_NEIGHBOURS=${VOCAB_NEIGHBOURS:-20}; else VOCAB_NEIGHBOURS=${VOCAB_NEIGHBOURS:-50}; fi
if [ "$FEATURES" = "ALIKED" ]; then MAX_IMAGE_SIZE=${MAX_IMAGE_SIZE:-1600}; else MAX_IMAGE_SIZE=${MAX_IMAGE_SIZE:-3200}; fi
OVERLAP=${OVERLAP:-25}
if [ "$FEATURES" = "ALIKED" ]; then
  VOCAB_TREE=${VOCAB_TREE:-"https://github.com/colmap/colmap/releases/download/3.13.0/vocab_tree_faiss_flickr100K_words64K_aliked_n16rot.bin;vocab_tree_faiss_flickr100K_words64K_aliked_n16rot.bin;8b2f9bdc44ca7204d8543bb3adab4c03ba9336c84ef41220b5007991036f075e"}
else
  VOCAB_TREE=${VOCAB_TREE:-"https://github.com/colmap/colmap/releases/download/3.11.1/vocab_tree_faiss_flickr100K_words256K.bin;vocab_tree_faiss_flickr100K_words256K.bin;96ca8ec8ea60b1f73465aaf2c401fd3b3ca75cdba2d3c50d6a2f6f760f275ddc"}
fi
MATCH_TYPE="${FEATURES}_${MATCHER}"
EXTRACT_TYPE=$FEATURES; [ "$FEATURES" = "ALIKED" ] && EXTRACT_TYPE=ALIKED_N16ROT
UNDISTORT_SIZE=${UNDISTORT_SIZE:-2400}
THREADS=$(sysctl -n hw.ncpu)
DB="$WORK/database.db"
PARENT="$WORK/sparse/parent"
[ -f "$DB" ] || { echo "missing $DB (clone of the parent model's database)" >&2; exit 1; }
[ -d "$PARENT" ] || { echo "missing $PARENT (clone of the parent model's sparse/0)" >&2; exit 1; }
N_NEW=$(grep -c . "$NEW")

log() { printf '\n==> %s\n' "$*"; }

log "parent model"
colmap model_analyzer --path "$PARENT" 2>&1 | sed 's/^/  /'

log "feature extraction for $N_NEW new images ($FEATURES, max size $MAX_IMAGE_SIZE, one camera per recording)"
colmap feature_extractor \
  --database_path "$DB" --image_path "$IMG" --image_list_path "$NEW" \
  --ImageReader.camera_model OPENCV --ImageReader.single_camera_per_folder 1 \
  --FeatureExtraction.type "$EXTRACT_TYPE" \
  --FeatureExtraction.use_gpu 0 --FeatureExtraction.num_threads "$THREADS" \
  --FeatureExtraction.max_image_size "$MAX_IMAGE_SIZE" \
  --SiftExtraction.max_num_features 8192 --AlikedExtraction.max_num_features 4096

log "sequential matching across the whole set ($MATCH_TYPE; pairs already matched are skipped)"
colmap sequential_matcher \
  --database_path "$DB" --FeatureMatching.type "$MATCH_TYPE" \
  --SequentialMatching.overlap "$OVERLAP" --SequentialMatching.quadratic_overlap 1 \
  --SequentialMatching.loop_detection 1 --SequentialMatching.vocab_tree_path "$VOCAB_TREE" \
  --FeatureMatching.use_gpu 0 --FeatureMatching.num_threads "$THREADS"

log "vocab-tree retrieval: each new image against $VOCAB_NEIGHBOURS look-alikes in the whole set"
colmap vocab_tree_matcher --database_path "$DB" --FeatureMatching.type "$MATCH_TYPE" \
  --VocabTreeMatching.vocab_tree_path "$VOCAB_TREE" --VocabTreeMatching.num_images "$VOCAB_NEIGHBOURS" \
  --VocabTreeMatching.match_list_path "$NEW" \
  --FeatureMatching.use_gpu 0 --FeatureMatching.num_threads "$THREADS"

log "registering the new images into the parent's frame"
rm -rf "$WORK/sparse/reg" "$WORK/sparse/tri" "$WORK/sparse/0"; mkdir -p "$WORK/sparse/reg" "$WORK/sparse/tri" "$WORK/sparse/0"
colmap image_registrator --database_path "$DB" --input_path "$PARENT" --output_path "$WORK/sparse/reg" \
  --Mapper.abs_pose_min_num_inliers 15 --Mapper.num_threads "$THREADS"
colmap model_analyzer --path "$WORK/sparse/reg" 2>&1 | sed 's/^/  /'

log "triangulating the new tracks"
colmap point_triangulator --database_path "$DB" --image_path "$IMG" --input_path "$WORK/sparse/reg" --output_path "$WORK/sparse/tri" \
  --Mapper.num_threads "$THREADS"

log "bundle adjustment over everything (old poses move too: geometry over frame stability)"
colmap bundle_adjuster --input_path "$WORK/sparse/tri" --output_path "$WORK/sparse/0" \
  --BundleAdjustment.refine_principal_point 0 --BundleAdjustmentCeres.max_num_iterations 50
colmap model_analyzer --path "$WORK/sparse/0" 2>&1 | sed 's/^/  /'
colmap model_converter --input_path "$WORK/sparse/0" --output_path "$WORK/sparse_points.ply" --output_type PLY

log "undistorting the union for OpenMVS -> $WORK/dense"
rm -rf "$WORK/dense"
colmap image_undistorter --image_path "$IMG" --input_path "$WORK/sparse/0" \
  --output_path "$WORK/dense" --output_type COLMAP --max_image_size "$UNDISTORT_SIZE"
colmap model_converter --input_path "$WORK/dense/sparse" --output_path "$WORK/dense/sparse" --output_type TXT
log "done: sparse/0 holds the extended model"
