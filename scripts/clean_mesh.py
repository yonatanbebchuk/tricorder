#!/usr/bin/env python3
"""Drop small floating fragments from the textured mesh before rendering or editing.

OpenMVS meshes from a partial reconstruction carry lots of little detached shells (mis-triangulated
depth at silhouettes, bits of ceiling, blur artefacts). They clutter the plan and Blender scene.
This keeps only connected components with at least --min-faces triangles (or --min-frac of the total).

Run it on the UNTEXTURED mesh (scene_dense_mesh.ply), before TextureMesh: the textured OBJ has its
vertices split along every texture patch seam, so connectivity there means "same texture patch", not
"same object", and cleaning it punches holes. 03_dense.sh does this automatically.

Usage:
  python scripts/clean_mesh.py work/backyard/dense/scene_dense_mesh.ply [--min-faces 2000] [--min-frac 0.002]
Writes <name>_clean.ply next to the input plus a one-line report.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import open3d as o3d


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mesh")
    ap.add_argument("--min-faces", type=int, default=2000)
    ap.add_argument("--min-frac", type=float, default=0.002, help="also drop components smaller than this fraction of all faces")
    ap.add_argument("--out")
    ap.add_argument("--max-faces", type=int, default=4_000_000,
                    help="decimate to at most this many faces (texturing time grows superlinearly; 0 = never)")
    args = ap.parse_args()
    src = Path(args.mesh)
    mesh = o3d.io.read_triangle_mesh(str(src), enable_post_processing=False)
    n = len(mesh.triangles)
    if n == 0:
        sys.exit(f"could not read triangles from {src}")
    cluster_ids, cluster_n, _ = mesh.cluster_connected_triangles()
    cluster_ids, cluster_n = np.asarray(cluster_ids), np.asarray(cluster_n)
    thresh = max(args.min_faces, int(args.min_frac * n))
    drop = cluster_n[cluster_ids] < thresh
    mesh.remove_triangles_by_mask(drop)
    mesh.remove_unreferenced_vertices()
    if args.max_faces and len(mesh.triangles) > args.max_faces:
        before = len(mesh.triangles)
        mesh = mesh.simplify_quadric_decimation(target_number_of_triangles=args.max_faces)
        mesh.remove_degenerate_triangles()
        mesh.remove_unreferenced_vertices()
        print(f"  decimated {before} -> {len(mesh.triangles)} faces (--max-faces {args.max_faces})")
    out = Path(args.out) if args.out else src.with_name(src.stem + "_clean" + src.suffix)
    o3d.io.write_triangle_mesh(str(out), mesh, write_triangle_uvs=True)
    # Open3D's OBJ writer drops the texture map reference; put the original map_Kd lines back
    src_mtl, out_mtl = src.with_suffix(".mtl"), out.with_suffix(".mtl")
    if src_mtl.exists() and out_mtl.exists():
        maps = [l for l in src_mtl.read_text().splitlines() if l.startswith("map_")]
        if maps:
            out_mtl.write_text(out_mtl.read_text().rstrip("\n") + "\n" + "\n".join(maps) + "\n")
    print(f"{src.name}: {len(cluster_n)} components, kept {int((cluster_n >= thresh).sum())} with >= {thresh} faces; "
          f"{n} -> {len(mesh.triangles)} faces ({100 * (1 - len(mesh.triangles) / n):.1f}% removed) -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
