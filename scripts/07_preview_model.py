"""Blender headless: import the textured mesh, decimate it to a viewer-friendly size, export a USDZ preview.

    Blender --background --python scripts/07_preview_model.py -- --mesh dense/scene_dense_mesh_texture.obj \
        [--transform transform.json] [--faces 300000] --out preview.usdz

The Mac app shows the USDZ with the system 3D viewer; the full-resolution OBJ stays the asset's deliverable.
"""
import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("--mesh", required=True, help=".obj (textured) or .ply")
ap.add_argument("--transform", help="transform.json (metric, Z-up); omit to keep model coordinates")
ap.add_argument("--faces", type=int, default=300_000, help="target face count for the preview")
ap.add_argument("--texture", type=int, default=4096, help="longest texture side in the USDZ (OpenMVS atlases are 8192², too heavy for a viewer)")
ap.add_argument("--out", required=True, help="output .usdz path")
args = ap.parse_args(argv)

bpy.ops.wm.read_factory_settings(use_empty=True)
mesh_path = Path(args.mesh).resolve()
if mesh_path.suffix.lower() == ".obj":
    bpy.ops.wm.obj_import(filepath=str(mesh_path), forward_axis="Y", up_axis="Z")
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

total = sum(len(o.data.polygons) for o in objs)
if total > args.faces:
    ratio = args.faces / total
    for o in objs:
        mod = o.modifiers.new("preview", "DECIMATE")
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_apply(modifier="preview")
    print(f"decimated {total} -> {sum(len(o.data.polygons) for o in objs)} faces")

out = Path(args.out).resolve()
out.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.usd_export(filepath=str(out), export_materials=True, generate_preview_surface=True, export_normals=True,
                      triangulate_meshes=True, convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
                      export_global_up_selection="Y", selected_objects_only=False,
                      usdz_downscale_size="CUSTOM", usdz_downscale_custom_size=args.texture)
print(f"wrote {out} ({out.stat().st_size / 1e6:.1f} MB)")
