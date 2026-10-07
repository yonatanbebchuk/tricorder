#!/usr/bin/env python3
"""After the Blender fill: clone the patch textures from the surrounding ground in the atlas, and add points on the fill
planes to the dense cloud so the layout's DEM, contours and orthomosaic see solid ground there.

    python scripts/22_edit_fill_cloud.py <run_dir>

Reads  <run>/edit/selection.json, complete.json; <run>/dense/scene_dense.ply (already cut)
Writes <run>/dense/scene_dense_mesh_texture_patch_<n>_map_Kd.jpg (real crops), <run>/dense/scene_dense.ply (+ fill points),
       <run>/edit/complete.png; updates complete.json with points_added
"""
import argparse
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--spacing", type=float, default=0.02, help="fill point spacing (m)")
    ap.add_argument("--crop", type=int, default=768, help="texture crop size (px)")
    a = ap.parse_args()
    import open3d as o3d
    from PIL import Image, ImageFilter

    run = Path(a.run)
    sel = json.load(open(run / "edit" / "selection.json"))
    comp = json.load(open(run / "edit" / "complete.json"))
    T = np.array(sel["levelled"])
    Ti = np.linalg.inv(T)
    s = sel["est_scale"]
    by_id = {it["id"]: it for it in sel["items"]}
    fill_pts, fill_cols = [], []
    for rep in comp["items"]:
        it = by_id.get(rep["id"])
        if not it or not rep.get("texture"):
            continue
        colour = np.array([0.45, 0.5, 0.3])
        tex_path = run / "dense" / rep["texture"]
        ring = np.array(rep.get("ring_uv") or [], dtype=float)
        bbox = rep.get("uv_bbox")
        if len(ring) >= 10 and bbox:
            # paint the patch from the ground around it: every texel takes the colour of the nearest ring face's texel
            from scipy.spatial import cKDTree
            (x0, y0), (x1, y1) = bbox
            w_m, h_m = (x1 - x0) * s, (y1 - y0) * s
            px_per_m = 160
            W, H = int(np.clip(w_m * px_per_m, 96, 1024)), int(np.clip(h_m * px_per_m, 96, 1024))
            atlases = {}
            for k, path in (rep.get("atlases") or {}).items():
                if path and Path(path).exists():
                    atlases[int(k)] = np.asarray(Image.open(path).convert("RGB"))
            ring_rgb = np.zeros((len(ring), 3))
            for i, (xl, yl, u, v, k) in enumerate(ring):
                A = atlases.get(int(k))
                if A is None:
                    ring_rgb[i] = colour * 255
                    continue
                hh, ww = A.shape[:2]
                ring_rgb[i] = A[int(np.clip((1 - v) * hh, 0, hh - 1)), int(np.clip(u * ww, 0, ww - 1))]
            tree = cKDTree(ring[:, :2])
            gx = x0 + (np.arange(W) + 0.5) / W * (x1 - x0)
            gy = y0 + (np.arange(H) + 0.5) / H * (y1 - y0)
            G = np.c_[np.repeat(gx, H), np.tile(gy, W)]                    # x-major
            d, idx = tree.query(G, k=4)
            wgt = 1.0 / np.maximum(d, 1e-6)
            rgb = (ring_rgb[idx] * wgt[..., None]).sum(axis=1) / wgt.sum(axis=1, keepdims=True)
            img = rgb.reshape(W, H, 3).transpose(1, 0, 2)                  # rows = y
            img = img[::-1]                                                 # v = 1 at the top of the image
            tile = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
            tile.save(tex_path, quality=90)
            colour = ring_rgb.mean(axis=0) / 255.0
            rep["texture_from"] = {"ring_faces": int(len(ring)), "size": [W, H]}
        else:
            Image.new("RGB", (256, 256), tuple(int(c * 255) for c in colour)).save(tex_path, quality=85)
        tris = np.array(rep.get("triangles") or [], dtype=float)
        if len(tris) == 0:
            continue
        # points on the fill triangles, area-weighted, about one per spacing²
        v0, v1, v2 = tris[:, 0], tris[:, 1], tris[:, 2]
        areas = 0.5 * np.linalg.norm(np.cross(v1 - v0, v2 - v0), axis=1) * s * s
        counts = np.maximum(1, np.round(areas / (a.spacing ** 2)).astype(int))
        rng = np.random.default_rng(0)
        idx = np.repeat(np.arange(len(tris)), counts)
        r1, r2 = rng.random(len(idx)), rng.random(len(idx))
        flip = r1 + r2 > 1
        r1[flip], r2[flip] = 1 - r1[flip], 1 - r2[flip]
        P = v0[idx] + (v1[idx] - v0[idx]) * r1[:, None] + (v2[idx] - v0[idx]) * r2[:, None]
        fill_pts.append(P)
        fill_cols.append(np.tile(colour, (len(P), 1)) * rng.uniform(0.9, 1.1, (len(P), 1)))
        rep["points_added"] = int(len(P))
        print(f"  {rep['id']}: {len(P)} fill points on {len(tris)} triangles, texture {tex_path.name}", flush=True)
    added = 0
    if fill_pts:
        cloud_path = run / "dense" / "scene_dense.ply"
        pcd = o3d.io.read_point_cloud(str(cloud_path))
        P = np.vstack(fill_pts)
        Cc = np.clip(np.vstack(fill_cols), 0, 1)
        add = o3d.geometry.PointCloud()
        add.points = o3d.utility.Vector3dVector(P)
        add.colors = o3d.utility.Vector3dVector(Cc)
        if pcd.has_normals():
            n = (Ti[:3, :3] @ np.array([0, 0, 1.0]))
            add.normals = o3d.utility.Vector3dVector(np.tile(n / np.linalg.norm(n), (len(P), 1)))
        pcd += add
        o3d.io.write_point_cloud(str(cloud_path), pcd)
        added = len(P)
        print(f"cloud: +{added} points -> {len(pcd.points)}", flush=True)
    comp["points_added"] = added
    comp["faces_added"] = comp.get("faces_added", 0)
    json.dump(comp, open(run / "edit" / "complete.json", "w"), indent=1)
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig = plt.figure(figsize=(9.6, 7.2))
        ax = fig.add_axes([0, 0, 1, 1])
        for rep in comp["items"]:
            for t in rep.get("triangles") or []:
                P = (T @ np.c_[np.array(t), np.ones(3)].T).T[:, :2] * s
                ax.fill(P[:, 0], P[:, 1], color="#6fa24a", alpha=0.7, lw=0)
            if rep.get("triangles"):
                c = (T @ np.r_[np.mean(np.array(rep["triangles"]).reshape(-1, 3), axis=0), 1.0])[:2] * s
                ax.text(c[0], c[1], f"{rep['id']}: {rep['loops']} hole{'s' if rep['loops'] != 1 else ''} filled", fontsize=7, ha="center", va="center")
        ax.set_aspect("equal"); ax.grid(True, lw=0.3, alpha=0.5)
        ax.set_title(f"{comp.get('faces_added', 0)} faces and {added} points added on the fitted ground", fontsize=9)
        fig.savefig(str(run / "edit" / "complete.png"), dpi=100, facecolor="white", bbox_inches="tight")
        plt.close(fig)
    except Exception as e:
        print(f"preview not drawn: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
