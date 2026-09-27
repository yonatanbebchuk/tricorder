#!/usr/bin/env python3
"""Find stairs in the metric point cloud and describe them the way a plan does: treads, rise, run, direction.

Reads  <work>/scene_dense_metric.ply (metres, Z up, ground ≈ 0)
Writes <work>/stairs.json  [{"treads": [[[x,y],...] per tread polygon], "rise_m", "run_m", "steps", "direction_deg",
                             "top": [x,y], "bottom": [x,y], "width_m"}]

How: points with vertical normals (horizontal surfaces) between 0.08 m and 1.5 m above the ground are binned by
height; a bin with enough points is a candidate tread level.  Candidate levels are clustered in 2D (DBSCAN) so
that separate flat things at the same height (a table, a wall top) don't join.  A staircase is a chain of
clusters whose heights step by a consistent rise (0.10–0.22 m) and that touch each other in plan; the run is the
distance between successive tread centroids, the direction the vector from the lowest to the highest tread.
Treads are drawn as rectangles from each cluster's oriented bounding box.

Usage: python scripts/11_detect_stairs.py <work> [--voxel 0.03] [--bin 0.03]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--voxel", type=float, default=0.03)
    ap.add_argument("--bin", type=float, default=0.03, help="height bin (m)")
    ap.add_argument("--zmin", type=float, default=0.08)
    ap.add_argument("--zmax", type=float, default=1.6)
    ap.add_argument("--min-rise", type=float, default=0.10)
    ap.add_argument("--max-rise", type=float, default=0.24)
    ap.add_argument("--min-area", type=float, default=0.15, help="smallest tread (m²)")
    ap.add_argument("--out", default="stairs.json")
    a = ap.parse_args()
    import open3d as o3d
    from sklearn.cluster import DBSCAN

    work = Path(a.work)
    pcd = o3d.io.read_point_cloud(str(work / "scene_dense_metric.ply")).voxel_down_sample(a.voxel)
    pcd.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=a.voxel * 4, max_nn=30))
    P, N = np.asarray(pcd.points), np.asarray(pcd.normals)
    flat = P[(np.abs(N[:, 2]) > 0.9) & (P[:, 2] > a.zmin) & (P[:, 2] < a.zmax)]
    print(f"horizontal surface points above ground: {len(flat)}")

    # candidate tread levels: 2-D clusters of flat points within one height bin
    cands = []
    for z0 in np.arange(a.zmin, a.zmax, a.bin):
        sel = flat[(flat[:, 2] >= z0) & (flat[:, 2] < z0 + a.bin)]
        if len(sel) < 40:
            continue
        labels = DBSCAN(eps=0.12, min_samples=15).fit(sel[:, :2]).labels_
        for l in set(labels) - {-1}:
            c = sel[labels == l]
            area = len(c) * a.voxel * a.voxel * 1.5
            if area < a.min_area:
                continue
            cands.append({"z": float(c[:, 2].mean()), "xy": c[:, :2], "centroid": c[:, :2].mean(axis=0), "area": area})
    cands.sort(key=lambda c: c["z"])
    print(f"tread candidates: {len(cands)}")

    # chains: from each candidate, climb to a candidate one rise higher whose footprint is adjacent (< 0.6 m)
    def adjacent(c1, c2):
        return np.linalg.norm(c1["centroid"] - c2["centroid"]) < 1.6 and \
            np.min(np.linalg.norm(c1["xy"][::5, None, :] - c2["xy"][None, ::5, :], axis=2)) < 0.5

    used = set()
    stairs = []
    for i, c in enumerate(cands):
        if i in used:
            continue
        chain = [i]
        while True:
            last = cands[chain[-1]]
            nxt = [j for j, d in enumerate(cands) if j not in used and j not in chain
                   and a.min_rise <= d["z"] - last["z"] <= a.max_rise and adjacent(last, d)]
            if not nxt:
                break
            j = min(nxt, key=lambda j: abs(cands[j]["z"] - last["z"] - 0.17))
            chain.append(j)
        if len(chain) >= 2:
            used.update(chain)
            steps = [cands[k] for k in chain]
            rises = np.diff([s["z"] for s in steps])
            cents = np.array([s["centroid"] for s in steps])
            runs = np.linalg.norm(np.diff(cents, axis=0), axis=1)
            d = cents[-1] - cents[0]
            direction = float(np.degrees(np.arctan2(d[1], d[0])))
            u = d / max(np.linalg.norm(d), 1e-9)
            n = np.array([-u[1], u[0]])
            treads = []
            widths = []
            for s in steps:                       # tread rectangle aligned with the stair direction
                rel = s["xy"] - s["centroid"]
                t, w = rel @ u, rel @ n
                t0, t1 = np.percentile(t, 3), np.percentile(t, 97)
                w0, w1 = np.percentile(w, 3), np.percentile(w, 97)
                corners = [s["centroid"] + t0 * u + w0 * n, s["centroid"] + t1 * u + w0 * n,
                           s["centroid"] + t1 * u + w1 * n, s["centroid"] + t0 * u + w1 * n]
                treads.append([[round(float(p[0]), 3), round(float(p[1]), 3)] for p in corners])
                widths.append(w1 - w0)
            stairs.append({"steps": len(steps), "rise_m": round(float(rises.mean()), 3), "run_m": round(float(runs.mean()), 3),
                           "width_m": round(float(np.median(widths)), 2), "direction_deg": round(direction, 1),
                           "bottom": [round(float(cents[0][0]), 3), round(float(cents[0][1]), 3)],
                           "top": [round(float(cents[-1][0]), 3), round(float(cents[-1][1]), 3)],
                           "z_bottom": round(steps[0]["z"], 3), "z_top": round(steps[-1]["z"], 3), "treads": treads})
    # join flights whose top meets another flight's bottom (a landing splits nothing in the drawing)
    joined = True
    while joined:
        joined = False
        for i, s1 in enumerate(stairs):
            for j, s2 in enumerate(stairs):
                if i == j:
                    continue
                if a.min_rise * 0.5 <= s2["z_bottom"] - s1["z_top"] <= a.max_rise * 1.5 and \
                        np.linalg.norm(np.array(s2["bottom"]) - np.array(s1["top"])) < 1.6:
                    n1, n2 = s1["steps"], s2["steps"]
                    merged = {"steps": n1 + n2, "rise_m": round((s1["rise_m"] * n1 + s2["rise_m"] * n2) / (n1 + n2), 3),
                              "run_m": round((s1["run_m"] * n1 + s2["run_m"] * n2) / (n1 + n2), 3),
                              "width_m": round(max(s1["width_m"], s2["width_m"]), 2), "direction_deg": s2["direction_deg"],
                              "bottom": s1["bottom"], "top": s2["top"], "z_bottom": s1["z_bottom"], "z_top": s2["z_top"],
                              "treads": s1["treads"] + s2["treads"]}
                    stairs = [s for k, s in enumerate(stairs) if k not in (i, j)] + [merged]
                    joined = True
                    break
            if joined:
                break
    stairs = [s for s in stairs if s["steps"] >= 2]
    stairs.sort(key=lambda s: -s["steps"])
    json.dump(stairs, open(work / a.out, "w"), indent=1)
    for s in stairs:
        print(f"  stairs: {s['steps']} steps, rise {s['rise_m']:.2f} m, run {s['run_m']:.2f} m, width {s['width_m']:.2f} m, "
              f"from z={s['z_bottom']:.2f} to {s['z_top']:.2f}, direction {s['direction_deg']:.0f}°")
    print(f"{len(stairs)} staircase(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
