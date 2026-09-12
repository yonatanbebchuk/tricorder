# Backyard scanner pipeline.  Usage:
#   make frames VIDEO=data/backyard.mp4     # 1. sharp frames from the video
#   make sfm                                # 2. COLMAP poses + sparse cloud (10-40 min)
#   make dense                              # 3. OpenMVS dense cloud, mesh, texture (30-90 min)
#   make landmarks                          # 4. pick landmark pairs to tape-measure (run_all does this too)
#   -- answer the prompts in the web UI (make ui) --
#   make plan                               # 5. scale + level + north from the answers, Blender .blend + 2D plan
#   make lidar LIDAR=data/stray_dataset     # alt: metric mesh from a Stray Scanner LiDAR recording
NAME    ?= backyard
VIDEO   ?= data/$(NAME).mp4
WORK     = work/$(NAME)
PY       = .venv/bin/python
BLENDER ?= /Applications/Blender.app/Contents/MacOS/Blender
FPS     ?= 2
MAXF    ?= 400
PXM     ?= 50
MEASURES ?= 4

.PHONY: setup frames sfm dense landmarks plan scale-manual lidar clean ui all

setup:
	./setup.sh

frames:
	$(PY) scripts/01_extract_frames.py $(VIDEO) $(WORK)/images --fps $(FPS) --max-frames $(MAXF)

sfm:
	scripts/02_sfm.sh $(WORK)/images $(WORK)

dense:
	scripts/03_dense.sh $(WORK)/dense

landmarks:
	$(PY) scripts/pick_landmarks.py $(WORK) --count $(MEASURES)

plan:    # after answering the prompts (web UI or work/$(NAME)/measure/answers.json)
	PXM=$(PXM) scripts/make_plan.sh $(WORK)

scale-manual:   # old path: 3D point pairs picked in CloudCompare, see README
	$(PY) scripts/04_scale_model.py --cloud $(WORK)/dense/scene_dense.ply --pairs $(WORK)/scale_pairs.json \
	    --colmap-sparse $(WORK)/dense/sparse --out $(WORK)/transform.json --apply $(WORK)/dense/scene_dense.ply
	$(BLENDER) --background --python scripts/05_site_plan_blender.py -- \
	    --mesh $(WORK)/dense/scene_dense_mesh_texture.obj --transform $(WORK)/transform.json \
	    --out $(WORK)/plan --px-per-m $(PXM)
	$(PY) scripts/06_annotate_plan.py $(WORK)/plan

lidar:
	$(PY) scripts/lidar_fuse.py $(LIDAR) --out work/lidar/$(NAME)_lidar.ply
	$(BLENDER) --background --python scripts/05_site_plan_blender.py -- \
	    --mesh work/lidar/$(NAME)_lidar.ply --out work/lidar/$(NAME)_plan --px-per-m $(PXM)
	$(PY) scripts/06_annotate_plan.py work/lidar/$(NAME)_plan

clean:
	rm -rf $(WORK)

all:
	caffeinate -i -s ./run_all.sh $(VIDEO) $(NAME)

ui:
	.venv/bin/uvicorn ui.server:app --host 127.0.0.1 --port 8765 --reload
