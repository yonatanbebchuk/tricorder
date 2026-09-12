# Backyard Scanner

iPhone video ➜ metric, editable 3D model of the backyard ➜ dimensioned 2D site plan.
All open source, runs on a Mac mini (Apple Silicon, 24 GB), no NVIDIA GPU needed.

```
 iPhone 17 Pro video
        │  01_extract_frames.py   ffmpeg/OpenCV, keeps the sharpest 2 fps
        ▼
 ~300-400 JPEG frames
        │  02_sfm.sh              COLMAP: camera poses + sparse cloud (CPU)
        ▼
 poses + undistorted images
        │  03_dense.sh            OpenMVS: dense cloud → mesh → textured OBJ (CPU)
        ▼
 scene_dense.ply, scene_dense_mesh_texture.obj      (arbitrary scale, arbitrary orientation)
        │  04_scale_model.py      tape-measure pairs → metres, ground plane → Z = 0
        ▼
 transform.json  +  scene_dense_metric.ply
        │  05_site_plan_blender.py  Blender headless: editable .blend + top-down ortho render
        │  06_annotate_plan.py      1 m grid, axis labels, scale bar
        ▼
 plan.blend (edit in Blender) · plan_grid.png (trace in QCAD / Inkscape at true scale)
```

Alternative track, no photogrammetry: `scripts/lidar_fuse.py` fuses a **Stray Scanner** (open-source
iPhone LiDAR app) recording into a metric mesh directly, using ARKit's poses for scale.
Lower detail, but dimensions are right out of the box. Good for the plan; the video track is
better for the pretty textured model. You can do both and overlay them.

## Why these tools

| Need | Choice | Why not the obvious alternative |
|---|---|---|
| Camera poses (SfM) | **COLMAP 4.2** (`brew install colmap`) | Gold standard, brew-bottled for arm64. |
| Dense cloud / mesh / texture | **OpenMVS** (built from source, CPU) | COLMAP's own dense step (`patch_match_stereo`) is CUDA-only, so it cannot run on any Mac. OpenMVS reads COLMAP output and does dense + mesh + texture on CPU. |
| Real-world scale | tape-measured point pairs, or LiDAR poses | Photogrammetry has **no absolute scale**; something in the scene must be measured. |
| Cleanup / measuring | **CloudCompare** | Point picking, distance measuring, cropping, cross-sections. |
| Editing | **Blender** | Import OBJ at metric scale, edit, add proposed features, render. |
| 2D plan | ortho render + **QCAD** (or Inkscape) | Trace fences/walls/beds over the scaled image; QCAD gives proper dimensioned drawings. |

Not chosen: Meshroom (no Mac build, CUDA), Gaussian splatting (beautiful, but not measurable or editable),
OpenDroneMap in Docker (works on arm64 and is a fine fallback — `03_dense.sh` will use its OpenMVS binaries
if `docker pull opendronemap/odm` is present and the native build failed).
Apple's built-in Object Capture *area mode* (Reality Composer on the iPhone → macOS PhotogrammetrySession)
is free, uses the LiDAR for metric scale and gives excellent meshes on this exact hardware, but it is not
open source; it's the pragmatic escape hatch if the open pipeline struggles with your yard.

## Setup

```bash
./setup.sh          # brew: colmap ffmpeg cmake boost eigen opencv cgal libomp; uv venv; builds OpenMVS into tools/openmvs-install
./setup.sh --apps   # same, plus CloudCompare + MeshLab casks
```
Install Blender from blender.org into /Applications (or `brew install --cask blender`), and QCAD (`brew install --cask qcad`) for the 2D drawing.

## Web UI

```bash
make ui        # then open http://127.0.0.1:8765
```
Drop a video on the page (it lands in `data/`), pick frame rate / max frames / dense level, start.
The page shows each run's five stages with status, timing and key numbers (frames kept, sharpness,
images registered, sub-models, points, faces), the live log of whichever stage you click, warnings
when registration or sharpness look bad, and links to every output. "Show in Finder" opens the run
folder. Runs started from the terminal show up too; everything is read from `work/<name>/run_all.log`.

## Capturing the video (this is 80% of the result)

**Scale comes after filming.** You no longer need a scale bar in the shot: once the model is built, the
pipeline tells you which distances to tape-measure (fence corner to house corner, post height, and so on).
Filming a few crisp, permanent corners from more than one angle makes those prompts better.

Camera settings on the iPhone 17 Pro:
- Settings ▸ Camera ▸ Record Video: **4K, 30 fps**. HDR video is tone-mapped automatically by the frame extractor
  (`--hdr hlg`), but turning HDR off gives slightly cleaner colours and is one less thing to go wrong.
- Use the 1× main camera, not ultra-wide. Lock exposure/focus (long-press the subject, AE/AF LOCK) so brightness doesn't pump between frames.
- Overcast or fully shaded is ideal. Avoid harsh sun, moving branches in wind, sprinklers, people, pets.

How to walk:
- Move slowly and smoothly; pause briefly at corners. Blur is the enemy — the extractor keeps the sharpest frames, but it can't fix a whole blurry stretch.
- Walk the perimeter once at chest height with the camera tilted slightly down (~20-30°), keeping the ground *and* the fence/walls in frame. Never point at empty sky.
- Do a second loop from the inside pointing outwards, and a third at a different height (knee level, or arms raised) for any walls or structures.
- Each new frame should overlap the previous by 70-80%: turn slowly, don't whip around.
- 3-6 minutes of video is plenty for a typical yard. Longer isn't better; it just slows COLMAP.

Move the video to `data/backyard.mp4` (AirDrop keeps full quality; iCloud "optimize storage" does not).

## Running

Unattended, all stages in one go (skips stages that already finished; logs to `work/<name>/run_all.log`,
writes a `DONE` or `FAILED` marker; HDR video is tone-mapped automatically):
```bash
caffeinate -i -s ./run_all.sh data/backyard.MOV        # or: make all VIDEO=data/backyard.MOV NAME=backyard
```
The final "preview plan" it renders is levelled but **unscaled** (1 model unit = 1 "metre"); run
`make scale plan` with your measured pairs afterwards for true dimensions.

Stage by stage:
```bash
make frames VIDEO=data/backyard.mp4     # → work/backyard/images (~1 min)
make sfm                                # → work/backyard/sparse, dense/  (10-40 min on M4, CPU SIFT)
make dense                              # → dense/scene_dense.ply, scene_dense_mesh_texture.obj  (30-90 min)
```
COLMAP knobs (env vars for `make sfm` / `run_all.sh`, also in the web UI form):

| Variable | Default | Notes |
|---|---|---|
| `FEATURES` | `SIFT` | `ALIKED` = learned keypoints (ONNX on CPU). Better on blank walls and repetitive texture. |
| `MATCHER` | `BRUTEFORCE` | `LIGHTGLUE` = learned matcher; more matches from weak features. Slow on CPU: see below. |

Measured on the 286-frame basement test (white walls, soft frames):

| Features + matcher | Registered frames | Sub-models | SfM time on the M4 |
|---|---|---|---|
| SIFT + brute force, default mapper | 81 | 6 | 8 min |
| SIFT + brute force, vocab retrieval + relaxed mapper (new default) | 118 | 5 | 13 min |
| ALIKED + LightGlue, vocab retrieval + relaxed mapper | **282** | 1 | ~3 h |

So for a difficult scene, `FEATURES=ALIKED MATCHER=LIGHTGLUE` (the "best" option in the UI) is the one to
run overnight. For a well-textured backyard start with the default and only escalate if registration is poor.
| `MATCHING` | `vocab` | sequential neighbours **plus** vocab-tree retrieval of look-alike frames. `sequential` is faster; `exhaustive` is 4x slower for no gain. |
| `RELAXED` | `1` | mapper accepts images with 15+ inliers instead of 30. On the basement test this registered 118 frames instead of 81 at the same reprojection error. |

Check `work/backyard/sparse_points.ply` in CloudCompare after `make sfm`: it should look like a ghostly
outline of the yard with a ring of camera positions. If it's garbage, fix the capture, not the settings.

**Scale.** Open `work/backyard/dense/scene_dense.ply` in CloudCompare, use *Tools ▸ Point picking* to
click each end of your scale bar and your other measured pairs, and write the coordinates to
`work/backyard/scale_pairs.json`:
```json
{"pairs": [
  {"name": "scale bar",       "a": [1.23, -0.44, 2.10], "b": [1.87, -0.41, 2.12], "meters": 3.00},
  {"name": "fence to house",  "a": [0.10,  0.90, 1.00], "b": [3.12,  0.81, 1.05], "meters": 7.42}
]}
```
```bash
make scale     # prints per-pair error in cm; >3% disagreement means a mis-pick. Writes transform.json + scene_dense_metric.ply
make plan      # Blender headless → work/backyard/plan.blend, plan.png, plan_grid.png
```
`make scale` also finds the ground plane (using the camera orientations to tell lawn from wall) and
rotates the model so the lawn is Z = 0 with the cameras above it. If you want "up" on the plan to be north, rotate the model about Z in Blender (or CloudCompare)
before rendering; the plan's grid is in model metres either way.

## Getting the 2D sketch with dimensions

`plan_grid.png` is an orthographic top-down image at a known scale (`plan.json` holds px/m and the
world coordinates of the image corners). Two ways to turn it into a proper drawing:

1. **QCAD** (recommended for a renovation plan): *File ▸ Bitmap ▸ Insert*, then scale the image so the
   1 m grid lines are 1 unit apart. Trace fence lines, house wall, patio, beds, trees as CAD entities and
   add dimensions with the dimension tools. Export PDF/DXF for whoever builds it.
2. **Blender**: open `plan.blend`, enable the *MeasureIt* add-on (or MeasureIt-ARCH, open source) to
   place dimension lines directly on the 3D model, then render the same top camera.

For heights (fence height, deck steps, slope) use CloudCompare's *Cross section* tool on
`scene_dense_metric.ply`, or measure vertex-to-vertex in Blender with the Measure tool (N panel shows metres).

## LiDAR track (Stray Scanner)

1. Install Stray Scanner from the App Store (free, open source). Record the yard walking slowly within ~3-4 m of everything.
2. Connect the phone, copy the dataset folder out of the app's Documents via Finder into `data/`.
3. `make lidar LIDAR=data/<dataset-folder>` → `work/lidar/backyard_lidar.ply` (already in metres, Z-up) plus a plan render.

Verify the dataset layout matches the docstring in `scripts/lidar_fuse.py`; the app's export format has
changed between versions.

## Troubleshooting

- **COLMAP registers few images / several sub-models**: not enough overlap or blur. Lower `--fps` no
  further than 1.5; raise `OVERLAP=40`; make sure `LOOP_DETECTION=1` (default; the vocab tree is
  downloaded to COLMAP's cache on first use). Re-shoot with slower turns.
- **Reconstruction drifts / bends**: loop closure failed. Walk true loops that end where they started
  and keep the same features in view; keep exposure locked.
- **Floating junk in the mesh / plan**: `03_dense.sh` drops detached fragments under `MIN_FACES`
  (default 2000) before texturing. Raise it for a cleaner but sparser model.
- **OpenMVS out of memory**: `RES_LEVEL=3 make dense` (eighth resolution), or fewer images (`MAXF=250`).
- **Texture looks blurry**: `RES_LEVEL=1 make dense` (slower), or `REFINE=1` for sharper geometry.
- **Ground plane picked a wall**: the script uses the average camera "up" (phones are held roughly
  upright) to choose among the dominant planes and prints each candidate's angle from it. If the
  pick is still wrong, rerun with `--no-ground` and level the model in CloudCompare
  (*Edit ▸ Apply transformation*, or the *Level* tool) before rendering.
- **Wrong scale**: check pair residuals; a single mis-click on a far point can skew it. Use ≥3 pairs.
