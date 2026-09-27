# Tricorder: environments (sites) hold recordings (raw video), runs (processing) and assets (3D scans, site plans).
# Everything lives in work/environments/<env>/ (local, git-ignored).
#
#   make setup                                     # brew deps, Python env, OpenMVS build
#   make app                                       # build + open the native Mac app (app/, needs Xcode 26+, xcodegen)
#   make xcode                                     # generate app/Tricorder.xcodeproj and open it in Xcode
#   make new VIDEO=data/backyard.MOV NAME="Backyard"   # environment + recording + scan run, executed now (foreground)
#   make run ENV=backyard RUN=r1                   # (re)execute a run: finished stages are kept, then the asset is published
#   make layout ENV=backyard ASSET=model3d-1       # site plan (DXF, PDF, orthomosaic, contours) from a measured 3D model
#   make list                                      # environments, recordings, runs, assets
#   make migrate                                   # old work/scans layout -> work/environments
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

.PHONY: setup app xcode new run layout list lidar migrate

setup:
	./setup.sh

app:        # native Mac app -> app/build/Build/Products/Release/Tricorder.app
	cd app && xcodegen generate --quiet && xcodebuild -project Tricorder.xcodeproj -scheme Tricorder \
	    -configuration Release -derivedDataPath build -quiet build && open "build/Build/Products/Release/Tricorder.app"

xcode:
	cd app && xcodegen generate --quiet && open Tricorder.xcodeproj

new:
	caffeinate -i -s $(PY) -m tricorder.pipeline new $(VIDEO) --name "$(NAME)" --fps $(FPS) --max-frames $(MAXF) \
	    --res-level $(RES_LEVEL) --features $(FEATURES) --matcher $(MATCHER) --matching $(MATCHING) --measures $(MEASURES) --start

run:
	caffeinate -i -s $(PY) -m tricorder.pipeline run $(ENV) $(RUN)

layout:
	caffeinate -i -s $(PY) -m tricorder.pipeline new-run $(ENV) layout --asset $(ASSET) --px-per-m $(PXM) --start

list:
	$(PY) -m tricorder.pipeline list

migrate:
	$(PY) -m tricorder.migrate

lidar:
	$(PY) scripts/lidar_fuse.py $(LIDAR) --out work/lidar/$(NAME)_lidar.ply
	$(BLENDER) --background --python scripts/05_site_plan_blender.py -- \
	    --mesh work/lidar/$(NAME)_lidar.ply --out work/lidar/$(NAME)_plan --px-per-m $(PXM)
	$(PY) scripts/06_annotate_plan.py work/lidar/$(NAME)_plan
