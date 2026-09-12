# Backyard scanner.  Scans live in work/scans/<scan>/ with runs in runs/<r>/ (all local, git-ignored).
#
#   make setup                                     # brew deps, Python env, OpenMVS build
#   make ui                                        # web UI at http://127.0.0.1:8765  (upload, run, measure, plan)
#   make new VIDEO=data/backyard.MOV NAME="Backyard"   # create scan + run and execute it now (foreground)
#   make run SCAN=backyard RUN=r1                  # (re)execute a run: frames if needed -> sfm -> dense -> landmarks
#   make plan SCAN=backyard RUN=r1                 # after answering the measurement prompts
#   make list                                      # scans and their runs
#   make lidar LIDAR=data/stray_dataset            # alt: metric mesh from a Stray Scanner LiDAR recording
PY       = .venv/bin/python
BLENDER ?= /Applications/Blender.app/Contents/MacOS/Blender
FPS     ?= 2
MAXF    ?= 400
PXM     ?= 50
MEASURES ?= 4
FEATURES ?= SIFT
MATCHER  ?= BRUTEFORCE
MATCHING ?= vocab
RES_LEVEL ?= 2

.PHONY: setup ui new run plan list lidar migrate

setup:
	./setup.sh

ui:
	.venv/bin/uvicorn ui.server:app --host 127.0.0.1 --port 8765 --reload

new:
	caffeinate -i -s $(PY) -m scanner.pipeline new $(VIDEO) --name "$(NAME)" --fps $(FPS) --max-frames $(MAXF) \
	    --res-level $(RES_LEVEL) --features $(FEATURES) --matcher $(MATCHER) --matching $(MATCHING) --measures $(MEASURES) --start

run:
	caffeinate -i -s $(PY) -m scanner.pipeline run $(SCAN) $(RUN)

plan:
	$(PY) -m scanner.pipeline plan $(SCAN) $(RUN) --px-per-m $(PXM)

list:
	$(PY) -m scanner.pipeline list

migrate:    # import old flat work/<name> folders
	$(PY) -m scanner.migrate

lidar:
	$(PY) scripts/lidar_fuse.py $(LIDAR) --out work/lidar/$(NAME)_lidar.ply
	$(BLENDER) --background --python scripts/05_site_plan_blender.py -- \
	    --mesh work/lidar/$(NAME)_lidar.ply --out work/lidar/$(NAME)_plan --px-per-m $(PXM)
	$(PY) scripts/06_annotate_plan.py work/lidar/$(NAME)_plan
