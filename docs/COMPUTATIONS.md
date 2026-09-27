# Computations: scan, extend, layout

Design for the three runs Tricorder performs on an environment, the two assets they produce, and how measurement
works. Decided 2026-09-27: asset names **3D Model** and **Site Plan**; extend scans re-optimise everything (geometry
over frame stability); 0.25 m contours, 1:100 sheets. Step 1 (vocabulary, constraints file, real site-plan outputs)
is implemented; steps 2 and 3 are still design.

## Vocabulary

Using the terms surveyors, photogrammetrists and architects actually use:

| Tricorder | term of art | what it is | id |
|---|---|---|---|
| 3D asset | **3D Model** (the trade calls it a 3D model or reality-capture model) | a textured photogrammetric mesh of the site: dense point cloud, mesh, texture atlas, camera poses. | `model3d` |
| 2D asset | **Site Plan** (existing-conditions plan) | the architect's drawing: a top-down, north-up, true-scale plan of what is there today. Built from an **orthomosaic** (the top-down render), **contour lines**, the site **footprint**, a **1 m grid**, north arrow and scale bar, plus the measurements it was scaled with. | `site_plan` |

A site plan is not a PNG. The deliverable set is:

| file | format | who uses it |
|---|---|---|
| `site_plan.dxf` | DXF (AutoCAD interchange, open, written with `ezdxf`) with layers `ORTHO`, `GRID`, `CONTOURS`, `FOOTPRINT`, `MEASURE`, `NORTH`, `SCALEBAR`, `TITLE` | architects, landscape designers, QCAD/AutoCAD/Vectorworks/Revit import |
| `site_plan.pdf` | PDF sheet at a stated scale (1:100 or 1:200 on A2/A3) with title block | printing, sharing with contractors |
| `orthomosaic.png` + `orthomosaic.pgw` | image plus ESRI world file (pixel → metres); `orthomosaic.tif` GeoTIFF later | QGIS, any CAD raster underlay |
| `contours.dxf` / inside the main DXF | 0.25 m contours from the digital elevation model | drainage, terracing, levels |
| `dem.tif` | digital elevation model (heights in metres on the 1 m grid, later) | slope analysis |
| `site_plan.blend` | the Blender scene at true scale, the ortho camera set up | editing, proposed changes |
| `transform.json` | scale / level / north and residuals | provenance |

Runs (a run consumes recordings and/or assets and publishes one asset):

| run | id | input | output | stages |
|---|---|---|---|---|
| **Environment scan** | `scan` | one recording (video) | 3D model | frames, sfm, dense, landmarks, preview |
| **Extend scan** | `extend` | a 3D model + one or more new recordings (video or photos) | a new 3D model | frames, register, dense, landmarks, preview |
| **Layout** | `layout` | a 3D model + its measurements | site plan | solve, ortho, draw, preview |

`scan` and `layout` exist; `extend` is design.

## 1. Environment scan (video → 3D model)

Today's pipeline, unchanged in substance: sharpest frames at 2 fps → COLMAP (SIFT or ALIKED features, vocab-tree
plus sequential matching, relaxed mapper) → undistort → OpenMVS densify, mesh, clean, texture → levelled preview
plan and measurement prompts → USDZ preview. The 3D model asset carries the **camera poses** (`sparse/` in
COLMAP text format) and the COLMAP **database** alongside the mesh, because the next two runs need them.

Coordinate frame: COLMAP's, arbitrary scale and orientation. Everything measured is expressed in this frame;
`transform_preview.json` (level only) and `transform.json` (scale, level, north) map it to metres.

## 2. Extend scan (3D model + new footage → improved 3D model)

The point is to add coverage (a corner you missed, the far side of the shed, close-ups of a wall) or to fill
holes, without throwing away what worked.

Two ways to do it; the second is the recommendation.

**A. Reconstruct the new footage on its own, then align.** Independent COLMAP runs have independent scale and
orientation, so the two meshes must be registered with a similarity transform (scale + rotation + translation),
either from matched features or ICP with scale, then the point clouds merged and re-meshed. Fragile: ICP with
unknown scale on partially overlapping outdoor scenes fails quietly, and texture atlases can't be merged, only
re-baked.

**B. Incremental structure-from-motion into the existing model** (recommended). COLMAP supports registering new
images into an existing reconstruction; that is how photogrammetry suites do "add photos to project". Decision
(2026-09-27): the old poses are **not** held fixed; the final bundle adjustment re-optimises everything for the best
geometry, the frame drifts a little, old depth maps are recomputed, and the measurements are re-prompted (the
constraint *points* can be re-projected into the new frame via their frames' new poses, so most tape values survive
as suggestions). Time is acceptable; geometry is what matters.

1. *frames*: extract frames from each new recording (photos: convert HEIC → JPEG, cap the long side).
2. *register*: copy the mesh asset's `database.db` and `sparse/` into the run; `feature_extractor` on the new
   images only (same feature type as the original, it is recorded in the asset); `vocab_tree_matcher` of the new
   images against **all** images plus `sequential_matcher` within each new video; `image_registrator` to pose the
   new images into the existing model; `point_triangulator` for the new tracks; a full `bundle_adjuster` over old
   and new images; `image_undistorter` for the union.
3. *dense*: OpenMVS on the union, all depth maps recomputed (the poses moved); mesh, clean and texture.
4. *landmarks* and *preview* as in a scan.

Output: `model3d-2`, with `derived_from: model3d-1`. Measurements from the parent are re-projected into the new
frame through their frames' new poses and offered as suggestions to confirm. Quality metrics on the run: registered new frames, new dense points, mesh faces before /
after, and a coverage number (fraction of the previous footprint that got a second look).

If the user wants a *cleaner* mesh from the same footage (other features, other dense level), that is simply a
new `scan` run; it produces a new frame and the measurements do not carry over.

Cost on the M4: features + matching for the new frames only (minutes to tens of minutes), then a full densify,
mesh and texture (a few hours for a 600-frame yard), about the same as a scan of the union but without redoing
feature matching for the old frames.

## 3. Layout (3D model + measurements → site plan)

### 3.1 Measurements are recordings

Decided 2026-09-27 (user): a tape measurement is sensed data about the place, so it is a **recording** of kind
`measurements`, not a property of one model. Each item is *two pixels on a frame of a video recording + the metres
taped between them* (+ note); a recording may also hold a compass bearing read at a frame. Any layout can take any
measurement recordings, on any model built from that footage; sets can be compared across layouts. Implemented:
`MeasurementsEditor` in the app (frame strip, point picker), `scripts/measure_project.py` at solve time (pycolmap
undistortion with the scan's OPENCV camera, ray cast onto the model mesh with Open3D), `constraints.json` in the run.
Items whose frame the model did not register are reported and skipped. With no measurement recording the scale is
estimated from the camera height above the ground plane (1.5 m, about ±10 %) and `transform.json` says `estimated`.

The older ideas, kept for reference: all produce the same **distance constraint** `{a: xyz, b: xyz, meters, source}`.

1. **Prompted** (*today*). After a scan, `pick_landmarks.py` chooses long, well-triangulated spans between
   structural corners and shows the two points as crops of the frames. You tape-measure them on site and type the
   metres. Good default because it picks spans that are long and unambiguous.
2. **Drawn in the 3D viewer.** Click two points on the mesh in the SceneKit view (`SCNView.hitTest` on the
   decimated preview), a line appears with its model length; type the real length. The preview is exported with
   the levelling transform and USD's Y-up convention applied, both known matrices, so the picked points are
   mapped back into the mesh frame exactly. Decimation moves surfaces by millimetres, irrelevant against a
   tape-measured metre. This is the most natural way to add a measurement for something you already measured
   ("the patio is 4.20 m wide").
3. **Drawn on a snapshot.** Pick two points on any frame of the recording (the app already shows them). Each
   pixel becomes a ray from that frame's camera (pose and intrinsics are in the asset's `sparse/`), and the ray is
   intersected with the mesh (Open3D `RaycastingScene`). That gives the 3D point; the rest is as above. Best for
   things easier to identify in a photo than in the mesh (a fence post base, a manhole cover).

Two other constraint kinds, both *today*: **level** (three ground points you confirm, else the dominant plane
that faces the cameras' "up") and **north** (compass bearing of one frame, or later: a direction drawn on the plan).

The measurement file becomes `measure/constraints.json` on the 3D model asset (replacing `answers.json`; the
prompts stay in `prompts.json` as suggestions). Each constraint records its source so residuals can be judged:
a 2 % disagreement between two tape measures is a mistake, between a tape and a photo pick it is expected.

Solve (*today*, generalised): scale is the ratio metres / model-units averaged over constraints, with each
constraint's residual reported in cm; a spread above 3 % is flagged. With positions rather than lengths (a later
LiDAR track, or two GPS-tagged photos) the same code becomes a similarity fit.

### 3.2 From a scaled mesh to a plan

1. *solve*: `transform.json` (scale, level, north) from the constraints; metric mesh and cloud.
2. *ortho*: Blender orthographic top-down render at a chosen resolution (px/m) → `orthomosaic.png` + world file.
   Also a height render → `dem.tif` (32-bit, metres).
3. *contours*: from the DEM, contour lines at 0.25 m (configurable), simplified; footprint = alpha shape of the
   projected point cloud; both as polylines.
4. *draw*: `ezdxf` writes `site_plan.dxf`: the orthomosaic as an IMAGE entity in metres on `ORTHO`, grid,
   contours with elevation labels, footprint, the measurement lines with dimension text on `MEASURE`, north arrow,
   scale bar, title block (environment name, date, scale, source asset ids). `site_plan.pdf` from the same
   entities via matplotlib at 1:100 on A2 (or the largest standard sheet that fits).
5. *preview*: the metric, levelled, north-up USDZ for the app's viewer, and a plan thumbnail.

The app shows the site plan as the orthomosaic with contours and measurement lines overlaid (SwiftUI Canvas over
the image, both in metres), and offers Open in QCAD / Blender / Preview.

## Data model changes

- `Run.inputs` becomes `{"asset": id?, "recordings": [ids]}` so `extend` can take several recordings.
- Recording kinds: `video` (*today*) and `photos` (a folder of stills; frames stage converts and caps size).
- `Asset.derived_from: id?` for extended meshes; `Asset.frame: id` naming the coordinate frame (the id of the
  first scan asset in the chain) so the app knows which measurements apply to which mesh.
- 3D model deliverables gain `database.db` and `sparse/` (poses) so extend and snapshot-picking work from the
  asset alone, not from the run's working folder.
- Site plan deliverables as listed above.
- Migration: rename kinds in place (`scan3d → reality_mesh`, `plan2d → site_plan`, `reconstruct → scan`,
  `plan → layout`), `answers.json → constraints.json` with `source: "prompt"`.

## Order of work

1. **Vocabulary + layout outputs** (small, high value): rename kinds, add DXF / PDF / world file / contours to
   the layout run, constraints file with sources, app overlay of contours and measurement lines.
2. **Measure in the viewer and on snapshots**: hit-test picking in SceneKit, pixel-to-mesh raycasting helper
   (`python -m tricorder.measure project <asset> <frame> <u> <v>`), the measurement list UI with residuals.
3. **Extend scan**: incremental registration with fixed old poses, depth-map reuse, photo recordings,
   `derived_from` chains and measurement inheritance.

Open questions for the user are in the chat summary; the answers go here once decided.
