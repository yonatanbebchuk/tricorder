#!/usr/bin/env python3
"""Cut: remove the selected voxels' faces from the run's copy of the clean mesh and their points from the dense cloud.

    python scripts/20_edit_cut.py <run_dir> --model <model3d asset>

Reads  <run>/edit/selection.json + voxels_*.npy; <run>/dense/scene_dense_mesh_clean.ply, scene_dense.ply (the run's copies)
Writes the same two files, cut; <run>/edit/cut.json {faces_before, faces_after, faces_removed, points_before, points_after,
       points_removed, faces, dense_points}; <run>/edit/cut.png
"""
import argparse
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np  # noqa: E402

OFF = 1 << 20


def keys_of(cells: np.ndarray) -> np.ndarray:
    c = cells.astype(np.int64) + OFF
    return (c[:, 0] << 42) | (c[:, 1] << 21) | c[:, 2]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--chunk", type=int, default=4_000_000)
    a = ap.parse_args()
    import open3d as o3d

    run = Path(a.run)
    sel = json.load(open(run / "edit" / "selection.json"))
    T = np.array(sel["levelled"])
    vox = sel["voxel_units"]
    cells = np.vstack([np.load(run / "edit" / it["voxels"]) for it in sel["items"]]) if sel["items"] else np.zeros((0, 3), np.int32)
    occupied = np.unique(keys_of(cells))
    print(f"{len(occupied)} occupied voxels from {len(sel['items'])} items", flush=True)

    def hit(P: np.ndarray) -> np.ndarray:
        L = (T @ np.c_[P, np.ones(len(P))].T).T[:, :3]
        return np.isin(keys_of(np.floor(L / vox)), occupied)

    mesh_path = run / "dense" / "scene_dense_mesh_clean.ply"
    mesh = o3d.io.read_triangle_mesh(str(mesh_path))
    V, Tri = np.asarray(mesh.vertices), np.asarray(mesh.triangles)
    C = V[Tri].mean(axis=1)
    gone = hit(C)
    faces_before = len(Tri)
    mesh.remove_triangles_by_mask(gone)
    mesh.remove_unreferenced_vertices()
    o3d.io.write_triangle_mesh(str(mesh_path), mesh)
    faces_after = len(mesh.triangles)
    print(f"mesh: {faces_before} -> {faces_after} faces ({int(gone.sum())} removed)", flush=True)
    removed_xy = (T @ np.c_[C[gone], np.ones(int(gone.sum()))].T).T[:, :2] if gone.any() else np.zeros((0, 2))

    # the cloud is denser than the mesh and holds points off it: cut by region (inside the footprint, from a little under
    # the fill plane to the top of what was removed), and by the voxels as well
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import identify_common as ic
    regions = []
    for it in sel["items"]:
        if it.get("fill_polygon") and it.get("z_range") and it["cls"] == "remove":
            a_, b_, c_ = it["plane"]
            regions.append((np.array(it["fill_polygon"]), (a_, b_, c_), it["z_range"][1]))

    def in_region(L: np.ndarray) -> np.ndarray:
        m = np.zeros(len(L), dtype=bool)
        for poly, (a_, b_, c_), ztop in regions:
            zp = a_ * L[:, 0] + b_ * L[:, 1] + c_
            m |= ic.point_in_polygon(L[:, :2], poly) & (L[:, 2] > zp - 0.08 / sel["est_scale"]) & (L[:, 2] < ztop + 0.08 / sel["est_scale"])
        return m

    cloud_path = run / "dense" / "scene_dense.ply"
    points_before = points_after = 0
    if cloud_path.exists():
        pcd = o3d.io.read_point_cloud(str(cloud_path))
        P = np.asarray(pcd.points)
        points_before = len(P)
        keep = np.ones(len(P), dtype=bool)
        for i in range(0, len(P), a.chunk):
            Q = P[i:i + a.chunk]
            L = (T @ np.c_[Q, np.ones(len(Q))].T).T[:, :3]
            gone = hit(Q)
            if regions:
                gone |= in_region(L)
            keep[i:i + a.chunk] = ~gone
        pcd = pcd.select_by_index(np.nonzero(keep)[0])
        o3d.io.write_point_cloud(str(cloud_path), pcd)
        points_after = len(pcd.points)
        print(f"cloud: {points_before} -> {points_after} points ({points_before - points_after} removed)", flush=True)
    json.dump({"faces_before": faces_before, "faces_after": faces_after, "faces_removed": faces_before - faces_after,
               "points_before": points_before, "points_after": points_after, "points_removed": points_before - points_after,
               "faces": faces_after, "dense_points": points_after}, open(run / "edit" / "cut.json", "w"), indent=1)
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        s = sel["est_scale"]
        rng = np.random.default_rng(0)
        idx = rng.choice(len(C), min(300_000, len(C)), replace=False)
        L = (T @ np.c_[C[idx], np.ones(len(idx))].T).T[:, :2] * s
        fig = plt.figure(figsize=(9.6, 7.2))
        ax = fig.add_axes([0, 0, 1, 1])
        ax.scatter(L[:, 0], L[:, 1], s=0.3, c="#bbb", marker=".", linewidths=0, rasterized=True)
        if len(removed_xy):
            ax.scatter(removed_xy[:, 0] * s, removed_xy[:, 1] * s, s=0.5, c="#b9452c", marker=".", linewidths=0, rasterized=True)
        ax.set_aspect("equal"); ax.axis("off")
        ax.text(0.01, 0.01, f"cut: {faces_before - faces_after} faces, {points_before - points_after} points", transform=ax.transAxes, fontsize=9, color="#444")
        fig.savefig(str(run / "edit" / "cut.png"), dpi=100, facecolor="white", bbox_inches="tight")
        plt.close(fig)
    except Exception as e:
        print(f"preview not drawn: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
