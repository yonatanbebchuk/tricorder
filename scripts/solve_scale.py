#!/usr/bin/env python3
"""Turn the measurement constraints into a similarity transform (metres, Z up, north = +Y).

Reads  <work>/measure/constraints.json   (written by the app; see tricorder/models.py for the schema)
       <work>/measure/prompts.json       (optional: the camera "up" hint and the kind of prompted spans)
Writes <work>/transform.json  (what 05_site_plan_blender.py and 08_site_plan.py consume) with per-constraint residuals.

constraints.json:
  {"distances": [{"id": "m1", "source": "prompt|viewer|snapshot", "prompt_id": "d1", "a": [x,y,z], "b": [x,y,z], "meters": 7.42}],
   "skipped_prompts": ["d3"],
   "level": {"source": "prompt", "confirmed": true, "points": [[x,y,z], [x,y,z], [x,y,z]]},
   "north": {"source": "prompt", "frame": "f001.jpg", "forward": [x,y,z], "bearing": 212}}
Scale   = mean over distance constraints of metres / model distance (residuals reported per constraint).
Level   = plane through the three confirmed ground points; otherwise the camera-up + dominant-plane heuristic.
North   = the given frame's viewing direction has the given compass bearing; rotate so +Y is north.

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
    cpath = work / "measure" / "constraints.json"
    if not cpath.exists():
        sys.exit("no measure/constraints.json yet; enter at least one measurement")
    c = json.load(open(cpath))
    ppath = work / "measure" / "prompts.json"
    prompts = json.load(open(ppath)) if ppath.exists() else {}
    by_id = {p["id"]: p for p in prompts.get("prompts", [])}
    up_hint = np.array(c.get("up") or prompts.get("up", [0, 0, 1]), dtype=float)

    # 1. scale from the distance constraints
    factors, residuals = [], []
    for d in c.get("distances", []):
        try:
            a, b, m = np.array(d["a"], dtype=float), np.array(d["b"], dtype=float), float(d["meters"])
        except (KeyError, TypeError, ValueError):
            continue
        model = float(np.linalg.norm(a - b))
        if m <= 0 or model <= 0:
            continue
        f = m / model
        factors.append(f)
        kind = by_id.get(d.get("prompt_id", ""), {}).get("kind", d.get("source", "distance"))
        residuals.append({"id": d.get("id", f"m{len(residuals) + 1}"), "source": d.get("source", "prompt"), "kind": kind,
                          "meters": m, "model_dist": model, "factor": f})
    estimated = False
    if factors:
        scale = float(np.mean(factors))
        for r in residuals:
            r["residual_cm"] = (r["factor"] / scale - 1) * r["meters"] * 100
        spread = (max(factors) / min(factors) - 1) * 100 if len(factors) > 1 else 0.0
        print(f"scale = {scale:.5f} m/unit from {len(factors)} constraint(s); spread {spread:.1f}%")
        for r in residuals:
            print(f"  {r['id']} {r['kind']:9s} {r['source']:8s} {r['meters']:6.2f} m  -> {r['residual_cm']:+.1f} cm vs mean")
        warn = spread > 3.0
    elif c.get("cameras"):
        estimated, warn, spread, scale = True, True, 0.0, None      # decided after the ground plane is known
        print("no distance constraints: scale will be ESTIMATED from the camera height above the ground (phone at chest height)")
    else:
        sys.exit("no distance constraints yet; add a measurement recording to the layout")

    # 2. level
    ground_src = "auto"
    lvl = c.get("level") or {}
    pts = lvl.get("points") or []
    if lvl.get("confirmed") and len(pts) >= 3:
        P = np.array(pts[:3], dtype=float)
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
    if estimated:
        CAMERA_HEIGHT_M = 1.5
        heights = np.array([np.dot(np.array(C) - centroid, n) for C in c["cameras"]])
        h = float(np.median(heights[heights > 0])) if np.any(heights > 0) else float(np.median(np.abs(heights)))
        scale = CAMERA_HEIGHT_M / h
        print(f"estimated scale = {scale:.5f} m/unit (median camera height {h:.3f} model units taken as {CAMERA_HEIGHT_M} m; expect ±10%)")

    # 3. north
    north_src = "none"
    nc = c.get("north") or {}
    Rz = np.eye(3)
    if nc.get("bearing") is not None and nc.get("forward"):
        f = R @ np.array(nc["forward"], dtype=float)
        phi = np.arctan2(f[1], f[0])                         # current angle of the view direction from +X
        theta = np.radians(90.0 - float(nc["bearing"]))      # wanted angle: bearing measured clockwise from north (+Y)
        d = theta - phi
        Rz = np.array([[np.cos(d), -np.sin(d), 0], [np.sin(d), np.cos(d), 0], [0, 0, 1]])
        north_src = f"bearing {float(nc['bearing']):.0f} deg from frame {nc.get('frame', '?')}"
        print(f"north: rotated {np.degrees(d):+.1f} deg about Z so +Y is north")

    T = np.eye(4)
    T[:3, :3] = scale * (Rz @ R)
    T[:3, 3] = -(T[:3, :3] @ centroid)
    json.dump({"scale": scale, "matrix": T.tolist(), "residuals": residuals, "spread_pct": spread, "warning": warn,
               "estimated": estimated, "ground": ground_src, "north": north_src, "constraints": len(factors)},
              open(work / args.out, "w"), indent=2)
    print(f"wrote {work / args.out}" + ("   WARNING: measurements disagree by >3%; re-check them" if warn and not estimated else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
