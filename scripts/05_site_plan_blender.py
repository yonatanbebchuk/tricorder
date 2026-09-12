"""Blender (headless) — import the textured mesh at real scale, save a .blend you
can edit, and render a top-down orthographic site plan at a known px/metre.

Run with Blender's Python, arguments after "--":
  /Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/05_site_plan_blender.py -- \
      --mesh work/backyard/dense/scene_dense_mesh_texture.obj \
      --transform work/backyard/transform.json --out work/backyard/plan --px-per-m 50

Outputs: <out>.png (orthographic plan, texture, flat lighting), <out>.blend (editable scene),
         <out>.json (px_per_m + world coordinates of the image corners, for 06_annotate_plan.py)
"""
import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--mesh", required=True, help=".obj (textured) or .ply")
ap.add_argument("--transform", help="transform.json from 04_scale_model.py (omit if the mesh is already metric/Z-up)")
ap.add_argument("--out", required=True, help="output path prefix (no extension)")
ap.add_argument("--px-per-m", type=float, default=50.0)
ap.add_argument("--margin", type=float, default=1.0, help="metres of margin around the model")
ap.add_argument("--max-px", type=int, default=8000, help="cap on the longest image side")
args = ap.parse_args(argv)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.length_unit = "METERS"

mesh_path = Path(args.mesh).resolve()
if mesh_path.suffix.lower() == ".obj":
    bpy.ops.wm.obj_import(filepath=str(mesh_path), forward_axis="Y", up_axis="Z")  # keep coordinates as-is
elif mesh_path.suffix.lower() == ".ply":
    bpy.ops.wm.ply_import(filepath=str(mesh_path), forward_axis="Y", up_axis="Z")
else:
    sys.exit(f"unsupported mesh type: {mesh_path}")
objs = [o for o in bpy.context.selected_objects if o.type == "MESH"]
if not objs:
    sys.exit("nothing imported")

if args.transform:
    T = Matrix(json.load(open(args.transform))["matrix"])
    for o in objs:
        o.matrix_world = T @ o.matrix_world
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# world-space bounds
xs, ys, zs = [], [], []
for o in objs:
    for c in o.bound_box:
        v = o.matrix_world @ Matrix.Translation(c).to_translation()
        xs.append(v.x); ys.append(v.y); zs.append(v.z)
x0, x1, y0, y1, z1 = min(xs) - args.margin, max(xs) + args.margin, min(ys) - args.margin, max(ys) + args.margin, max(zs)
w, h = x1 - x0, y1 - y0
px = args.px_per_m
if max(w, h) * px > args.max_px:
    px = args.max_px / max(w, h)
    print(f"px/m reduced to {px:.1f} to stay under --max-px")
res_x, res_y = int(round(w * px)), int(round(h * px))
# Blender's ortho_scale spans the larger of res_x/res_y
ortho = max(w, h)
px = max(res_x, res_y) / ortho  # exact px/m after rounding

cam_data = bpy.data.cameras.new("PlanCam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = ortho
cam_data.clip_end = 1000
cam = bpy.data.objects.new("PlanCam", cam_data)
scene.collection.objects.link(cam)
cam.location = ((x0 + x1) / 2, (y0 + y1) / 2, z1 + 10)
cam.rotation_euler = (0, 0, 0)  # looks straight down -Z, image up = +Y (north if you aligned it)
scene.camera = cam

scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "FLAT"
scene.display.shading.color_type = "TEXTURE"
scene.display.shading.show_shadows = False
scene.render.film_transparent = True
scene.render.resolution_x, scene.render.resolution_y = res_x, res_y
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"

out = Path(args.out).resolve()
out.parent.mkdir(parents=True, exist_ok=True)
scene.render.filepath = str(out.with_suffix(".png"))
bpy.ops.render.render(write_still=True)

# image corner (0,0) is top-left = (x_min, y_max); pixel (i, j) -> world (x0 + i/px, y1 - j/px)
json.dump({"px_per_m": px, "x_min": x0, "y_max": y1, "width_px": res_x, "height_px": res_y,
           "width_m": w, "height_m": h}, open(out.with_suffix(".json"), "w"), indent=2)
bpy.ops.wm.save_as_mainfile(filepath=str(out.with_suffix(".blend")))
print(f"wrote {out.with_suffix('.png')} ({res_x}x{res_y}, {px:.2f} px/m), {out.with_suffix('.blend')}")
