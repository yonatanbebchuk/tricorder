#!/usr/bin/env python3
"""Bring the reconstruction to real-world metres and put the ground on Z=0.

Photogrammetry has no absolute scale. You give this script pairs of 3D points
whose true distance you measured with a tape (e.g. the two ends of a 3.00 m
scale bar, or two fence posts). Pick the points in CloudCompare
(Tools > Point picking, or just hover and read the coordinates) on the dense
cloud, put them in a JSON file:

  {"pairs": [
     {"a": [x, y, z], "b": [x, y, z], "meters": 3.00, "name": "scale bar"},
     {"a": [x, y, z], "b": [x, y, z], "meters": 7.42, "name": "fence to wall"}
  ]}

The script computes one scale factor (mean of all pairs, reporting the error of
each so you can spot a bad pick), fits the dominant plane (the ground) and
rotates it to Z-up with the cameras above it, and writes transform.json holding
the 4x4 similarity transform. It can also apply it to PLY files directly; the
textured OBJ gets the same transform when imported by 05_site_plan_blender.py.

Usage:
  python scripts/04_scale_model.py --cloud work/backyard/dense/scene_dense.ply \
      --pairs work/backyard/scale_pairs.json --colmap-sparse work/backyard/dense/sparse \
      --out work/backyard/transform.json --apply work/backyard/dense/scene_dense.ply
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import open3d as o3d


def read_cameras(sparse_dir: Path):
    """Camera centres (C = -R^T t) and camera 'up' vectors in world space from a COLMAP images.txt.

    COLMAP cameras look down +Z with +Y pointing down in the image, so world-space up for a
    camera is R^T * (0, -1, 0). People hold phones roughly upright, so the mean of these is a
    solid gravity estimate even when the phone is tilted down 30 degrees.
    """
    path = sparse_dir / "images.txt"
    if not path.exists():
        return np.zeros((0, 3)), np.zeros((0, 3))
    centers, ups = [], []
    with open(path) as f:
        lines = [l for l in f if l.strip() and not l.startswith("#")]
    for line in lines[0::2]:
        p = line.split()
        if len(p) < 8:
            continue
        qw, qx, qy, qz = map(float, p[1:5])
        t = np.array(list(map(float, p[5:8])))
        R = o3d.geometry.get_rotation_matrix_from_quaternion([qw, qx, qy, qz])
        centers.append(-R.T @ t)
        ups.append(R.T @ np.array([0.0, -1.0, 0.0]))
    return np.array(centers), np.array(ups)


def find_ground(pcd_ds, diag, up_hint, max_planes=6, min_frac=0.03):
    """RANSAC planes one after another; return (plane, inliers) for the ground.

    With an up hint (from cameras) pick the plane whose normal is most parallel to it,
    otherwise the largest plane. Walls are the classic false positive without the hint.
    """
    rest = pcd_ds
    rest_idx = np.arange(len(pcd_ds.points))
    candidates = []
    for _ in range(max_planes):
        if len(rest.points) < 100:
            break
        plane, inl = rest.segment_plane(distance_threshold=diag / 300, ransac_n=3, num_iterations=2000)
        if len(inl) < min_frac * len(pcd_ds.points):
            break
        candidates.append((plane, rest_idx[inl]))
        keep = np.setdiff1d(np.arange(len(rest.points)), inl)
        rest = rest.select_by_index(keep)
        rest_idx = rest_idx[keep]
    if not candidates:
        sys.exit("no dominant plane found; use --no-ground and level the model in CloudCompare")
    if up_hint is None:
        return candidates[0]
    scored = [(abs(float(np.dot(np.array(pl[:3]) / np.linalg.norm(pl[:3]), up_hint))), pl, inl) for pl, inl in candidates]
    for cosang, pl, inl in scored:
        print(f"  plane candidate: {len(inl):7d} pts, {np.degrees(np.arccos(min(cosang, 1))):5.1f} deg from camera-up")
    best = max(scored, key=lambda c: c[0])
    return best[1], best[2]


def rotation_to_z(normal: np.ndarray) -> np.ndarray:
    n = normal / np.linalg.norm(normal)
    z = np.array([0.0, 0.0, 1.0])
    v = np.cross(n, z)
    c = float(np.dot(n, z))
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1.0 / (1.0 + c))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cloud", required=True, help="dense point cloud PLY (used for ground-plane fit)")
    ap.add_argument("--pairs", help="JSON with measured point pairs (see docstring)")
    ap.add_argument("--factor", type=float, help="use this scale factor instead of --pairs")
    ap.add_argument("--colmap-sparse", help="COLMAP sparse dir with images.txt, to know which way is up")
    ap.add_argument("--no-ground", action="store_true", help="skip ground-plane alignment (scale only)")
    ap.add_argument("--out", default="transform.json")
    ap.add_argument("--apply", nargs="*", default=[], help="PLY files to transform; writes <name>_metric.ply")
    args = ap.parse_args()

    # 1. scale factor
    if args.factor:
        scale = args.factor
    elif args.pairs:
        spec = json.load(open(args.pairs))
        factors = []
        for p in spec["pairs"]:
            d = float(np.linalg.norm(np.array(p["a"]) - np.array(p["b"])))
            factors.append(p["meters"] / d)
        scale = float(np.mean(factors))
        print("scale factor per pair (metres per model unit):")
        for p, f in zip(spec["pairs"], factors):
            err_cm = (f / scale - 1) * p["meters"] * 100
            print(f"  {p.get('name', '?'):20s} {f:.5f}   -> {err_cm:+.1f} cm vs mean")
        if len(factors) > 1 and (max(factors) / min(factors) - 1) > 0.03:
            print("warning: pairs disagree by >3%; re-check the picked points", file=sys.stderr)
    else:
        ap.error("give --pairs or --factor")
    print(f"scale = {scale:.6f}")

    # 2. ground plane -> Z up, cameras above ground
    R = np.eye(3)
    if not args.no_ground:
        pcd = o3d.io.read_point_cloud(args.cloud)
        if len(pcd.points) == 0:
            sys.exit(f"empty or unreadable cloud: {args.cloud}")
        diag = np.linalg.norm(pcd.get_max_bound() - pcd.get_min_bound())
        pcd_ds = pcd.voxel_down_sample(diag / 400)
        centers, ups = read_cameras(Path(args.colmap_sparse)) if args.colmap_sparse else (np.zeros((0, 3)), np.zeros((0, 3)))
        up_hint = None
        if len(ups):
            up_hint = ups.mean(axis=0)
            up_hint /= np.linalg.norm(up_hint)
        else:
            print("no camera poses given; taking the largest plane as ground (pass --colmap-sparse to be safe)")
        plane, inliers = find_ground(pcd_ds, diag, up_hint)
        normal = np.array(plane[:3]) / np.linalg.norm(plane[:3])
        print(f"ground plane: {len(inliers)}/{len(pcd_ds.points)} points ({100 * len(inliers) / len(pcd_ds.points):.0f}%)")
        if len(centers):
            height = np.mean(centers @ normal + plane[3] / np.linalg.norm(plane[:3]))
            if height < 0:
                normal = -normal
            print(f"cameras are {abs(height) * scale:.2f} m above the ground plane")
        elif up_hint is not None and np.dot(normal, up_hint) < 0:
            normal = -normal
        R = rotation_to_z(normal)

    # 3. build similarity transform: X' = s * R * X + t, with ground at z = 0 and origin at cloud centre
    T = np.eye(4)
    T[:3, :3] = scale * R
    if not args.no_ground:
        pts = np.asarray(pcd_ds.points)[np.asarray(inliers)]
        moved = pts @ (scale * R).T
        T[:3, 3] = -np.array([moved[:, 0].mean(), moved[:, 1].mean(), np.median(moved[:, 2])])
    json.dump({"scale": scale, "matrix": T.tolist(), "cloud": args.cloud}, open(args.out, "w"), indent=2)
    print(f"wrote {args.out}")

    # 4. apply to PLYs
    for f in args.apply:
        src = Path(f)
        try:
            mesh = o3d.io.read_triangle_mesh(str(src))
            if len(mesh.triangles) == 0:
                raise ValueError
            geom = mesh
        except Exception:
            geom = o3d.io.read_point_cloud(str(src))
        geom.transform(T)
        dst = src.with_name(src.stem + "_metric.ply")
        if isinstance(geom, o3d.geometry.TriangleMesh):
            o3d.io.write_triangle_mesh(str(dst), geom)
        else:
            o3d.io.write_point_cloud(str(dst), geom)
        bb = geom.get_axis_aligned_bounding_box()
        ext = bb.get_extent()
        print(f"wrote {dst}: footprint {ext[0]:.1f} m x {ext[1]:.1f} m, height {ext[2]:.1f} m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
