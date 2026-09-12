#!/usr/bin/env python3
"""Turn the user's measurement answers into a similarity transform (metres, Z up, north = +Y).

Reads  <work>/measure/prompts.json + <work>/measure/answers.json
Writes <work>/transform.json  (same format 05_site_plan_blender.py consumes) with per-pair residuals.

answers.json: {"d1": {"value": 7.42}, "d2": {"skipped": true}, "g1": {"confirmed": true}, "n1": {"bearing": 212}}
Scale   = mean over answered distance pairs of metres / model distance (residuals reported per pair).
Level   = plane through the three confirmed ground points; otherwise the camera-up + dominant-plane heuristic.
North   = the north-prompt frame's viewing direction has the given compass bearing; rotate so +Y is north.

Usage: python scripts/solve_scale.py work/backyard [--cloud dense/scene_dense.ply]
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scale04", HERE / "04_scale_model.py")
scale04 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scale04)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--cloud", default="dense/scene_dense.ply")
    ap.add_argument("--out", default="transform.json")
    args = ap.parse_args()
    work = Path(args.work)
    prompts = json.load(open(work / "measure" / "prompts.json"))
    apath = work / "measure" / "answers.json"
    answers = json.load(open(apath)) if apath.exists() else {}
    by_id = {p["id"]: p for p in prompts["prompts"]}
    up_hint = np.array(prompts["up"])

    # 1. scale
    factors, residuals = [], []
    for pid, a in answers.items():
        p = by_id.get(pid)
        if not p or p["type"] != "distance" or a.get("skipped") or not a.get("value"):
            continue
        f = float(a["value"]) / p["model_dist"]
        factors.append(f)
        residuals.append({"id": pid, "kind": p["kind"], "meters": float(a["value"]), "model_dist": p["model_dist"], "factor": f})
    if not factors:
        sys.exit("no distance answers yet; enter at least one measurement")
    scale = float(np.mean(factors))
    for r in residuals:
        r["residual_cm"] = (r["factor"] / scale - 1) * r["meters"] * 100
    spread = (max(factors) / min(factors) - 1) * 100 if len(factors) > 1 else 0.0
    print(f"scale = {scale:.5f} m/unit from {len(factors)} measurement(s); spread {spread:.1f}%")
    for r in residuals:
        print(f"  {r['id']} {r['kind']:9s} {r['meters']:6.2f} m  -> {r['residual_cm']:+.1f} cm vs mean")
    warn = spread > 3.0

    # 2. level
    ground_src = "auto"
    g = by_id.get("g1")
    if g and answers.get("g1", {}).get("confirmed"):
        P = np.array([pt["xyz"] for pt in g["points"]])
        n = np.cross(P[1] - P[0], P[2] - P[0])
        n /= np.linalg.norm(n)
        if np.dot(n, up_hint) < 0:
            n = -n
        centroid = P.mean(axis=0)
        ground_src = "3 confirmed points"
    else:
        import open3d as o3d
        pcd = o3d.io.read_point_cloud(str(work / args.cloud))
        diag = np.linalg.norm(pcd.get_max_bound() - pcd.get_min_bound())
        pcd_ds = pcd.voxel_down_sample(diag / 400)
        plane, inl = scale04.find_ground(pcd_ds, diag, up_hint)
        n = np.array(plane[:3]) / np.linalg.norm(plane[:3])
        if np.dot(n, up_hint) < 0:
            n = -n
        centroid = np.asarray(pcd_ds.points)[np.asarray(inl)].mean(axis=0)
    R = scale04.rotation_to_z(n)
    print(f"level: ground from {ground_src}, tilt vs camera-up {np.degrees(np.arccos(min(abs(np.dot(n, up_hint)), 1))):.1f} deg")

    # 3. north
    north_src = "none"
    nprompt = by_id.get("n1")
    bearing = answers.get("n1", {}).get("bearing")
    Rz = np.eye(3)
    if nprompt and bearing is not None:
        f = R @ np.array(nprompt["forward"])
        phi = np.arctan2(f[1], f[0])                         # current angle of the view direction from +X
        theta = np.radians(90.0 - float(bearing))            # wanted angle: bearing measured clockwise from north (+Y)
        d = theta - phi
        Rz = np.array([[np.cos(d), -np.sin(d), 0], [np.sin(d), np.cos(d), 0], [0, 0, 1]])
        north_src = f"bearing {float(bearing):.0f} deg from frame {nprompt['frame']}"
        print(f"north: rotated {np.degrees(d):+.1f} deg about Z so +Y is north")

    T = np.eye(4)
    T[:3, :3] = scale * (Rz @ R)
    T[:3, 3] = -(T[:3, :3] @ centroid)
    json.dump({"scale": scale, "matrix": T.tolist(), "residuals": residuals, "spread_pct": spread, "warning": warn,
               "ground": ground_src, "north": north_src}, open(work / args.out, "w"), indent=2)
    print(f"wrote {work / args.out}" + ("   WARNING: measurements disagree by >3%; re-check them" if warn else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
