# Computations: scan, extend, layout

Design for the three runs Tricorder performs on an environment, the two assets they produce, and how measurement
works. Decided 2026-09-27: asset names **3D Model** and **Site Plan**; extend scans re-optimise everything (geometry
over frame stability); 0.25 m contours, 1:100 sheets. Step 1 (vocabulary, constraints file, real site-plan outputs)
and step 3 (extend, photo recordings) are implemented; step 2 (measuring in the viewer) is still design.

## Runs are recipes (2026-09-29)

A run kind is a *recipe*: input **slots** (what it consumes, by recording or asset kind, with counts), **stages**, and
one output asset kind. `RUN_KINDS` in `tricorder/models.py` is the single definition; the app mirrors it
(`RunKind.slots`) and builds its "New run" sheet from it: pick a recipe, drag the inputs from the bucket of what the
environment has into the slots, the stage rail turns from grey to colour when every required slot is filled, start.

| recipe | slots | stages | output |
|---|---|---|---|
| Environment scan | video ×1 | frames · sfm · dense · landmarks · preview | 3D Model |
| Extend scan | 3D model ×1 · new footage (video or photos) ×1–8 | frames (per new recording) · register · dense · landmarks · preview | 3D Model (`derived_from` the input) |
| Layout | 3D model ×1 · measurements ×0–8 | solve · ortho · trace · draw · preview | Site Plan |
| Site plan from video | video ×1 · measurements ×0–8 | a *chain*: a scan run, then a layout run | Site Plan (and the 3D Model on the way) |

**Chains.** "Site plan from video" is not a fourth run kind: the ontology stays *one run publishes one asset*. The app
creates two runs; the layout's asset slot holds `@r5` (the output of run r5) and the run is `queued`. When r5
publishes, `pipeline.py` launches every queued run that waits for it (`_launch_dependants`); at start the `@r5` is
resolved to the real asset id. The run page shows the chain ("after scan r5" / "then layout r6").

**Photos are recordings** (kind `photos`): a folder of stills copied into the environment; the frames stage converts
them (HEIC through `sips`), caps the long side, scores sharpness, and writes the same `frames.csv` a video gets. Only an
extend scan takes them (a photo set alone rarely has the overlap a scan needs; that can change).

**Every stage records what it left behind.** `Stage.outputs` lists the files (from `STAGE_OUTPUTS`) with sizes and
labels, and `Stage.preview` names a small picture rendered right after the stage by `tricorder/previews.py`: the
sparse cloud with the camera path (sfm, register), a sub-sample of the dense cloud (dense), the levelled plan
(landmarks), the measurement residuals (solve), the orthomosaic (ortho), the walls and the dimensioned boundary over
it (trace), the PDF sheet (draw). The app's run page is built on these: a progress bar whose segments are sized by
how long each stage usually takes in that environment (median of past runs, else a typical figure), a milestone at
every stage boundary, a card per stage with its preview, numbers and files, and the log only on request (⌘L).
`python -m tricorder.previews <env> <run>` renders them for runs made before this existed.

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
| **Layout** | `layout` | a 3D model + measurement recordings | site plan | solve, ortho, trace, draw, preview |

All three exist. `extend` is `scripts/02b_register.sh` inside the `register` stage (below).

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
2. *register* (`scripts/02b_register.sh`, implemented 2026-09-29): the run's `images/` is the union, the parent's
   frames under the names its database knows (flat) and each new recording's frames under `<rec>/`; the parent
   asset's `database.db` and `sparse/0` are APFS-cloned into the run; `feature_extractor` on the new images only
   (`--image_list_path`, one camera per recording folder, **the parent's feature type**: its database and vocab
   index are SIFT or ALIKED, not both, so the run's features setting is overwritten from the parent's run);
   `sequential_matcher` over the whole set (COLMAP skips pairs already matched) and `vocab_tree_matcher` of the new
   images against everything (`--match_list_path`); `image_registrator` poses the new images in the parent's frame;
   `point_triangulator`; a full `bundle_adjuster`; `image_undistorter` for the union. Result in `sparse/0`.
3. *dense*: OpenMVS on the union, all depth maps recomputed (the poses moved); mesh, clean and texture.
4. *landmarks* and *preview* as in a scan.

Output: `model3d-2`, with `derived_from: model3d-1` and `sources` naming every recording and the name prefix its
frames carry in the database (so a further extend, and snapshot measuring, find the right images). Measurement
items still refer to (recording, frame); `measure_project.py` looks frames up by database name, so items on the
parent's video keep working on the extended model; items on the new footage need the prefix (to do).
Metrics on the register stage: `new_images`, `new_registered`, total `registered`, reprojection error.

Smoke test (2026-09-29, Basement test, ALIKED model, 5 of its own frames re-imported as a photos recording): register
3 min (4 of the 5 registered, 282 → 286 images, 1.21 px), then the usual dense / landmarks / preview.

If the user wants a *cleaner* mesh from the same footage (other features, other dense level), that is simply a
new `scan` run; it produces a new frame and the measurements do not carry over.

Cost on the M4: features + matching for the new frames only (minutes to tens of minutes), then a full densify,
mesh and texture (a few hours for a 600-frame yard), about the same as a scan of the union but without redoing
feature matching for the old frames.

## 3. Layout (3D model + measurements → site plan)

### 3.1 Measurements are recordings

Decided 2026-09-27: a tape measurement is sensed data about the place, so it is a **recording** of kind
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
3. *trace* (the goal, 2026-09-27: "straight clear lines like an architect would draw"): the local height range in
   a 0.4 m window marks steps; steps above 0.5 m are walls/fences, above 0.08 m edges/curbs; the step bands are
   skeletonised, a probabilistic Hough transform gives segments, near-collinear segments are merged, the site's
   dominant axis is found from the long segments and segments within 12° are snapped to it or its perpendicular,
   then merged again and isolated fragments dropped. Output `linework.json` (walls, edges). Heuristic; fence-top
   vegetation still leaves some fragments. Better next: fit lines with RANSAC on the step mask directly, and close
   rectangles where three sides are found.
3b. *contours*: from the DEM, contour lines at 0.25 m (configurable), simplified; footprint from the DEM's valid area.
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
3. **Extend scan**: done (2026-09-29) as designed in B, except that measurement inheritance across the prefix is still to do.
4. **An accurate site plan**: see the next section.

## 4. Towards an accurate site plan (2026-09-29)

The current boundary comes from the *ground footprint* (where the dense cloud has points within 0.35 m of the ground),
regularised and snapped to the detected walls. That is why it looks wrong where the cloud is incomplete: under the
canopy along the house, in the side passages, wherever the walk did not look. The walls themselves (vertical
surfaces → RANSAC lines) are right where they exist: the three fence sides of the backyard come out as single
straight segments at the site axis with lengths that agree with the tape.

Tried today: a **wall-first boundary** (`wall_first_boundary` in `10_trace_walls.py`): keep the walls that run
along the footprint's outline (within 1.2 m, within 30° of its tangent, at least 1.5 m long), order them around the
yard, join consecutive walls at the intersection of their lines when they meet at an angle, with a perpendicular jog
when they are parallel and offset, and follow the ground's outline only across long gaps that the outline does not
detour around. On the backyard it gives 13 sides instead of 17 and gets the three fence sides exactly (19.09 m,
11.07 m, 6.17 m) but draws diagonals across the house side and the passage, where the walls are short pieces
(porch, bay window, gate posts) and the footprint fills in. It is written to `linework.json` as `wall_boundary` next
to the footprint boundary (`polygons[0]`, still the one drawn), so the two can be compared on other sites.

What a human does when tracing is two things: geometry (where is the line: solved) and *semantics* (which lines are
the perimeter, which jog is a bay window and which is a hole in the data). The plan to close the gap:

1. **Label the walls** with the identify prototype (`12_identify.py`: Grounding DINO + SAM lifted through the poses):
   each wall segment gets a label (fence, house, hedge, shed, gate) from the masks that hit it. The perimeter is then
   the chain of *fence* and *house* segments; a *gate* segment bridges a gap in a fence; nothing inside counts.
2. **Close the house side from the facade**, not the ground: the house facade is a tall vertical surface (3 m) with
   short jogs (porch, bay); a dedicated pass with `--min-height 2.0` finds it as one polyline with jogs.
3. **Edit in the app**: a plan editor over the orthomosaic with the candidate walls faint underneath and snapping
   to them; drag a vertex, delete a side, add a line. Edits are saved with the site plan asset
   (`linework_edits.json`) and the draw stage re-runs from them. The geometry underneath is metric, so a hand-traced
   plan is exact; the automatic tracer is a first draft that gets closer each time.

Direct "video → 2D map" without the 3D model is not a shortcut worth taking: the plan's accuracy comes from the
poses and the dense geometry, and no image-only model is metric or knows the yard's fences. The "Site plan from
video" recipe gives the one-step experience on top of the same computation.

