# From a 3D model to an architect's site plan: what exists, what fits

Research notes, 2026-09-27. The question: how do we get from the photogrammetric model of a backyard to a clean,
straight-lined, dimensioned site plan, aligned to one of its edges, that an architect would recognise, using
open-source tools and any open AI model that helps.

## What the first attempt got wrong

`09_trace_lines.py` took height steps in a raster DEM, skeletonised them and ran a Hough transform. Three
structural problems, not tuning problems:

1. A raster of *maximum height per cell* mixes fence tops with the vegetation hanging over them; every leaf becomes
   a "step". The 3D point cloud knows which points belong to a vertical surface (their normals are horizontal) and
   how tall that surface is; the raster threw that away.
2. Hough on a skeleton produces many short, slightly-rotated pieces of the same line; merging them afterwards is
   guesswork. Fitting lines to the points directly (RANSAC) gives one line per structure with a measured extent.
3. Nothing ever *closed* anything. An architect's plan is polygons with corners, and every side has a length. Lines
   that don't meet are a sketch, not a plan.

## The field, in four families

### 1. Learned floorplan reconstruction from point-cloud density maps

HEAT (CVPR 2022), RoomFormer (CVPR 2023), FRI-Net and PolyRoom (ECCV 2024), Raster2Seq (2026). Input: a top-down
density image of an *indoor* scan; output: room polygons. They are trained on Structured3D (synthetic apartments)
and evaluated on rooms with four walls. RoomFormer's code is public ([github](https://github.com/ywyue/roomformer)).
Verdict: wrong domain (rooms, not yards; walls that close, not fences with gaps), and they build CUDA deformable-
attention operators, so they don't run on the Mac mini without porting. Not a fit.

### 2. Learned building-polygon extraction from aerial imagery

Frame Field Learning (CVPR 2021, [code](https://github.com/Lydorn/Polygonization-by-Frame-Field-Learning)),
PolyWorld (CVPR 2022), HiSup (ISPRS 2023). Output: regularised building outlines from satellite images. HEAT's
"outdoor" checkpoint is the same task. Verdict: they find *buildings*. The house wall would come out; fences, patios
and beds would not. Their polygon regularisation ideas are useful and are available separately (family 4).

### 3. Deep line and segmentation models as helpers

- **DeepLSD** ([cvg/DeepLSD](https://github.com/cvg/DeepLSD), MIT, CPU inference works): straight line segments
  from an image, robust to texture. Run on the orthomosaic it finds patio rims, path edges, bed borders, fence
  lines: the things that are *visible* edges rather than height steps. A good second source of lines.
- **lang-segment-anything** ([repo](https://github.com/luca-medeiros/lang-segment-anything)): Grounding DINO +
  SAM 2 with a text prompt ("patio", "lawn", "fence", "shed"). Runs without CUDA through HF transformers, slowly.
  Turns the orthomosaic into labelled zones, which is what a landscape plan wants (lawn, paving, planting).
  Grounded-SAM-2 itself needs CUDA to build its operators.
- ScaleLSD / LINEA / DT-LSD (2025) are newer line detectors; DeepLSD is the one with the easiest install.

Verdict: useful as a second and third layer (image edges, surface zones) once the structural lines are right.

### 4. Classical 3D geometry with polygon regularisation

This is how the surveying and LiDAR-mapping world does it, and it fits the data:

- Detect vertical surfaces in the point cloud (normals nearly horizontal; height band above the ground), project
  them to 2D, fit lines with iterative RANSAC, split into runs, regularise to the dominant axes, connect into
  polygons. The 2024 paper "Floor plan reconstruction from indoor 3D point clouds using iterative RANSAC line
  segmentation" (Journal of Building Engineering) is exactly this pipeline; "Using point cloud data to identify,
  trace, and regularize the outlines of buildings" (IJRS 2016) does it for footprints from LiDAR.
- Regularisation is a solved, packaged step: **buildingregulariser** ([DPIRD-DMA/Building-Regulariser](https://github.com/DPIRD-DMA/Building-Regulariser),
  the open equivalent of ArcGIS "Regularize Building Footprint") aligns polygon edges to principal directions
  (orthogonal, optional 45°), snaps near-rectangles to rectangles, simplifies. It works on shapely polygons.
  CGAL's Shape Regularization package does the same for segments in C++ (no Python bindings); its ideas
  (parallelism, orthogonality, collinearity groups) are what the snap/merge steps implement.
- Manhattan-world alignment: the dominant direction from a length-weighted angle histogram of the long segments;
  everything within a tolerance is rotated onto it or its perpendicular. Standard in urban reconstruction.

Verdict: **this is the approach.** It uses the 3D information we have (which no image-only model does), runs in
seconds on the M4, produces closed polygons whose every side has a length, and its knobs mean something physical
(how tall a structure must be, how far segments extend to meet).

## Result on the backyard (same day)

The DEM/Hough tracer produced 106 fragments and no closed shape. The point-cloud pipeline below produces 14 wall
lines and one closed boundary of about 150 m² whose sides carry lengths (top fence 18.5 m, left fence 16.1 m, the
passage 5.9 m and 2.5 m). Two things it got right that the raster never could: the fence lines are single straight
segments at the site axis, and the boundary closes across the gaps (gate, porch) because it comes from the ground's
footprint rather than from the walls alone. What still needs work: where the house meets the yard at an angle to
the fences, the outline steps unless that direction is recognised as its own family (done: long off-axis runs
become extra allowed directions), and porch steps / bay windows leave short jogs that the jog-absorber must not
over-simplify.

## The pipeline (implemented as `scripts/10_trace_walls.py`)

1. **Vertical structure.** Down-sample the metric cloud to 4 cm, estimate normals. Keep points with |n_z| < 0.35 and
   0.25 m < z < 3 m. Lawn, patio surface and tree canopy are gone; fences, walls, the house facade, hedges and the
   sides of raised beds remain.
2. **Structure cells.** Rasterise those points to 5 cm cells and keep cells whose vertical extent is at least 0.5 m.
   A fence line is a row of cells each spanning a metre of points; foliage over the fence spans little and drops.
3. **Lines by RANSAC.** Fit 2-D lines to the cell centres (inliers within 6 cm), split inliers into runs along the
   line (gaps over 0.6 m break a run), keep runs longer than 0.8 m, remove, repeat. One segment per structure, with
   a measured extent.
4. **Regularise.** Dominant axis from the long segments; snap within 12° to it or its perpendicular; merge collinear.
5. **Boundary from the ground.** The yard's usable ground (points within 0.35 m of the levelled ground) is
   rasterised, closed morphologically and traced as a polygon: this is where lawn, paving and paths are, so its
   outline is where the fences and the house stand, and it always closes. It is simplified (0.6 m), regularised to
   the direction families (the site axis, its perpendicular, and any long run that insists on its own direction),
   short jogs are absorbed, and every side that runs parallel and close to a detected wall is snapped onto that
   wall's line. Every side carries its length.
6. **Enclosures.** Walls that close a loop by themselves (a shed, a raised bed) are polygonised with shapely and
   regularised with buildingregulariser.

Outputs `linework.json` with the segments and the polygons; the draw stage puts polygons on a `BOUNDARY` layer with
dimension text on every side, the PDF gets the dimensioned plan, the app draws it and lets you rotate.

## Alignment and rotation

"Aligned along one of its edges": the plan's rotation is a property of the site plan, not of the model. Default: the
longest polygon edge horizontal. In the app you pick any edge ("align to this edge") or drag a rotation; the DXF,
PDF and overlay are re-drawn in that frame, and the north arrow rotates with it. Stored in the asset as
`plan_rotation_deg` so it survives.

## Dimensions and the measurements

Each polygon side gets the length computed from the model at the solved scale. Where a side coincides with one of
the tape measurements (its endpoints within 0.3 m of the constraint's endpoints) the label shows the taped value and
the residual, so the drawing carries the ground truth the user collected.

## What to add after the structural lines are right

- DeepLSD lines from the orthomosaic for patio rims and path edges (visible edges without a height step).
- lang-segment-anything zones (lawn, paving, planting, structures) as hatched areas on a `SURFACES` layer.
- Ground filtering (a proper DTM) so contours describe the ground, not the canopy: cloth-simulation filtering (CSF) is
  available in PDAL and as a Python package.

## Sources

- RoomFormer: https://github.com/ywyue/roomformer · HEAT: https://github.com/woodfrog/heat
- FRI-Net: https://arxiv.org/abs/2407.10687 · PolyRoom: https://arxiv.org/abs/2407.10439
- Frame Field Learning: https://github.com/Lydorn/Polygonization-by-Frame-Field-Learning · HiSup: https://www.sciencedirect.com/science/article/pii/S0924271623000667 · PolyWorld: https://openaccess.thecvf.com/content/CVPR2022/papers/Zorzi_PolyWorld_Polygonal_Building_Extraction_With_Graph_Neural_Networks_in_Satellite_CVPR_2022_paper.pdf
- DeepLSD: https://github.com/cvg/DeepLSD · line-detector survey: https://github.com/Vincentqyw/LineSegmentsDetection
- lang-segment-anything: https://github.com/luca-medeiros/lang-segment-anything · Grounded-SAM-2: https://github.com/IDEA-Research/Grounded-SAM-2
- Iterative RANSAC floor plans: https://www.sciencedirect.com/science/article/abs/pii/S2352710224008064
- Building outlines from LiDAR: https://www.tandfonline.com/doi/full/10.1080/01431161.2015.1131868
- buildingregulariser: https://github.com/DPIRD-DMA/Building-Regulariser · orthogonalize-polygon: https://github.com/Mashin6/orthogonalize-polygon · QGIS plugin: https://github.com/s1m0nS/QGIS-Regularize-Building-Footprints
- pyRANSAC-3D: https://github.com/leomariga/pyRANSAC-3D · CGAL Shape Detection: https://doc.cgal.org/latest/Shape_detection/index.html
- PC2WF / LC2WF (wireframes from point/line clouds): https://arxiv.org/abs/2103.02766 · https://arxiv.org/abs/2208.11948
