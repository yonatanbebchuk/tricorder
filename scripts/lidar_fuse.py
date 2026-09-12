#!/usr/bin/env python3
"""Metric mesh straight from an iPhone LiDAR recording (no photogrammetry, no scale bar).

Record the yard with the open-source Stray Scanner app (App Store; source at
github.com/strayrobots/scanner), copy the dataset folder to the Mac via Finder,
and fuse the LiDAR depth frames with ARKit's metric camera poses using a TSDF
volume. ARKit poses are in metres and gravity-aligned (Y up), so the output is
already at true scale.

Expected dataset layout (Stray Scanner format; check yours if it differs):
  <dir>/rgb.mp4                 colour video (e.g. 1920x1440)
  <dir>/depth/000000.png ...    16-bit PNG depth in millimetres (256x192)
  <dir>/confidence/000000.png   0/1/2 confidence per pixel
  <dir>/camera_matrix.csv       3x3 intrinsics for the RGB resolution
  <dir>/odometry.csv            timestamp, frame, x, y, z, qx, qy, qz, qw  (camera-to-world)

Usage:
  python scripts/lidar_fuse.py <dataset_dir> --out work/lidar/backyard_lidar.ply [--voxel 0.03] [--every 2]
Then in Blender:  --mesh work/lidar/backyard_lidar.ply  (no --transform needed; it is metric and Z-up)

Modeled on Stray Robots' StrayVisualizer integration script; LiDAR range is ~5 m,
so walk within a few metres of everything you want captured.
"""
import argparse
import csv
import sys
from pathlib import Path

import cv2
import numpy as np
import open3d as o3d


def quat_to_R(qx, qy, qz, qw):
    return o3d.geometry.get_rotation_matrix_from_quaternion([qw, qx, qy, qz])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dataset")
    ap.add_argument("--out", required=True, help="output mesh .ply")
    ap.add_argument("--voxel", type=float, default=0.03, help="TSDF voxel size in metres (default 3 cm)")
    ap.add_argument("--every", type=int, default=2, help="integrate every Nth frame")
    ap.add_argument("--max-depth", type=float, default=5.0)
    ap.add_argument("--min-confidence", type=int, default=2, help="keep depth with confidence >= this (0-2)")
    ap.add_argument("--no-color", action="store_true", help="skip colour (faster, no rgb.mp4 decode)")
    args = ap.parse_args()
    d = Path(args.dataset)

    K_rgb = np.loadtxt(d / "camera_matrix.csv", delimiter=",")
    poses = []
    with open(d / "odometry.csv") as f:
        rdr = csv.reader(f)
        header = next(rdr)
        for row in rdr:
            v = list(map(float, row))
            poses.append(v)
    poses = np.array(poses)
    depth_files = sorted((d / "depth").glob("*.png"))
    if not depth_files:
        sys.exit("no depth PNGs found; is this a Stray Scanner dataset?")
    sample = cv2.imread(str(depth_files[0]), cv2.IMREAD_UNCHANGED)
    dh, dw = sample.shape[:2]

    cap = None
    rgb_w = rgb_h = None
    if not args.no_color:
        cap = cv2.VideoCapture(str(d / "rgb.mp4"))
        rgb_w, rgb_h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    # intrinsics at depth resolution
    sx, sy = dw / (rgb_w or K_rgb[0, 2] * 2), dh / (rgb_h or K_rgb[1, 2] * 2)
    intr = o3d.camera.PinholeCameraIntrinsic(dw, dh, K_rgb[0, 0] * sx, K_rgb[1, 1] * sy, K_rgb[0, 2] * sx, K_rgb[1, 2] * sy)
    print(f"{len(depth_files)} depth frames {dw}x{dh}, {len(poses)} poses, colour {'off' if args.no_color else f'{rgb_w}x{rgb_h}'}")

    vol = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=args.voxel, sdf_trunc=4 * args.voxel,
        color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8)
    flip = np.diag([1.0, -1.0, -1.0, 1.0])  # ARKit camera looks down -Z (OpenGL); Open3D expects +Z
    used = 0
    for i, df in enumerate(depth_files):
        color = None
        if cap is not None:
            ok, frame = cap.read()
            if not ok:
                break
            if i % args.every:
                continue
            color = cv2.cvtColor(cv2.resize(frame, (dw, dh), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
        elif i % args.every:
            continue
        if i >= len(poses):
            break
        depth = cv2.imread(str(df), cv2.IMREAD_UNCHANGED).astype(np.uint16)
        conf_file = d / "confidence" / df.name
        if conf_file.exists():
            conf = cv2.imread(str(conf_file), cv2.IMREAD_UNCHANGED)
            depth[conf < args.min_confidence] = 0
        x, y, z, qx, qy, qz, qw = poses[i, 2:9]
        T = np.eye(4)
        T[:3, :3] = quat_to_R(qx, qy, qz, qw)
        T[:3, 3] = [x, y, z]
        T = T @ flip
        rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
            o3d.geometry.Image(color if color is not None else np.zeros((dh, dw, 3), np.uint8)),
            o3d.geometry.Image(depth), depth_scale=1000.0, depth_trunc=args.max_depth, convert_rgb_to_intensity=False)
        vol.integrate(rgbd, intr, np.linalg.inv(T))
        used += 1
        if used % 50 == 0:
            print(f"  integrated {used} frames", end="\r", flush=True)

    mesh = vol.extract_triangle_mesh()
    mesh.compute_vertex_normals()
    # ARKit world is Y-up; rotate to Z-up for Blender/CloudCompare and put the lowest 2% of vertices at z=0
    mesh.rotate(o3d.geometry.get_rotation_matrix_from_xyz([np.pi / 2, 0, 0]), center=(0, 0, 0))
    v = np.asarray(mesh.vertices)
    mesh.translate((0, 0, -np.percentile(v[:, 2], 2)))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    o3d.io.write_triangle_mesh(str(out), mesh)
    ext = mesh.get_axis_aligned_bounding_box().get_extent()
    print(f"\nwrote {out}: {len(mesh.vertices)} verts, footprint {ext[0]:.1f} m x {ext[1]:.1f} m, height {ext[2]:.1f} m (from {used} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
