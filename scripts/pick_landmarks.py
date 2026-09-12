#!/usr/bin/env python3
"""Choose what to measure: pick well-defined, well-spread landmark pairs from the COLMAP model and
write prompts (with marked-up frame crops) for the user to go and tape-measure.

Reads  <work>/dense/sparse/{cameras,images,points3D}.txt and <work>/dense/images/*.jpg (undistorted),
       <work>/images/frames.csv (sharpness per frame, optional)
Writes <work>/measure/prompts.json and <work>/measure/crops/*.jpg

Prompt types:
  distance  A and B landmarks; user measures the straight-line distance in metres. Ranked: the longest
            span first, then spans in other directions, plus one vertical span (fence/wall height).
  ground    three low, spread-out points; user confirms they are on the ground (levels the model).
  north     one frame; user stands there, faces the same way, reads the compass bearing (orients the plan).

Usage: python scripts/pick_landmarks.py work/backyard --count 4
  --count N   how many distance prompts the UI should ask for (2N+2 are generated so the user can skip)
"""
import argparse
import csv
import json
import sys
from pathlib import Path

import cv2
import numpy as np


def qvec_to_R(q):
    w, x, y, z = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def read_model(sparse: Path):
    cams = {}
    for line in open(sparse / "cameras.txt"):
        if line.startswith("#") or not line.strip():
            continue
        p = line.split()
        cams[int(p[0])] = {"model": p[1], "w": int(p[2]), "h": int(p[3]), "params": list(map(float, p[4:]))}
    images = {}
    lines = [l for l in open(sparse / "images.txt") if l.strip() and not l.startswith("#")]
    for a, b in zip(lines[0::2], lines[1::2]):
        p = a.split()
        R = qvec_to_R(list(map(float, p[1:5])))
        t = np.array(list(map(float, p[5:8])))
        pts = np.array(list(map(float, b.split()))).reshape(-1, 3) if b.strip() else np.zeros((0, 3))
        images[int(p[0])] = {"name": p[9], "cam": int(p[8]), "R": R, "t": t, "C": -R.T @ t,
                             "up": R.T @ np.array([0.0, -1.0, 0.0]), "fwd": R.T @ np.array([0.0, 0.0, 1.0]), "pts": pts}
    points = {}
    for line in open(sparse / "points3D.txt"):
        if line.startswith("#") or not line.strip():
            continue
        p = line.split()
        track = np.array(list(map(int, p[8:]))).reshape(-1, 2)
        points[int(p[0])] = {"xyz": np.array(list(map(float, p[1:4]))), "err": float(p[7]), "track": track}
    return cams, images, points


_lsd = None


def is_vegetation(frame_bgr, x, y, r=40):
    """Green-dominant patch = leaves, ivy, lawn: not something you can hold a tape against."""
    H, W = frame_bgr.shape[:2]
    patch = frame_bgr[max(y - r, 0):min(y + r, H), max(x - r, 0):min(x + r, W)]
    if patch.size == 0:
        return False
    hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
    h, sat, val = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    green = (h > 30) & (h < 90) & (sat > 60) & (val > 40)
    return float(green.mean()) > 0.45


def straight_edges(gray, x, y, half=64, min_len=28, max_dist=7.0):
    """How many long straight edges pass within max_dist px of (x, y), and whether two of them cross at an angle.
    Returns 0 (none: fabric, foliage, plain texture), 1 (on an edge), 2 (a corner of straight edges)."""
    global _lsd
    H, W = gray.shape
    x0, y0 = max(x - half, 0), max(y - half, 0)
    patch = gray[y0:min(y + half, H), x0:min(x + half, W)]
    if _lsd is None:
        _lsd = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD)
    segs = _lsd.detect(patch)[0]
    if segs is None:
        return 0
    px, py = x - x0, y - y0
    angles = []
    for sx0, sy0, sx1, sy1 in segs.reshape(-1, 4):
        dx, dy = sx1 - sx0, sy1 - sy0
        L = np.hypot(dx, dy)
        if L < min_len:
            continue
        t = np.clip(((px - sx0) * dx + (py - sy0) * dy) / (L * L), 0, 1)
        d = np.hypot(sx0 + t * dx - px, sy0 + t * dy - py)
        if d <= max_dist:
            angles.append(np.arctan2(dy, dx) % np.pi)
    if not angles:
        return 0
    for i in range(len(angles)):
        for j in range(i + 1, len(angles)):
            diff = abs(angles[i] - angles[j])
            if np.radians(30) < min(diff, np.pi - diff):
                return 2
    return 1


def project(im, cam, X):
    """Pixel coordinates of world point X in image im (PINHOLE), or None if behind the camera."""
    x = im["R"] @ X + im["t"]
    if x[2] <= 1e-6:
        return None
    fx, fy, cx, cy = cam["params"][:4]
    return (fx * x[0] / x[2] + cx, fy * x[1] / x[2] + cy)


def structural_corners(work, cams, images, sharp, med_sharp, up, diag):
    """Corners where two vertical planes meet the ground (room corners, fence/wall corners), plus the top
    of the wall/fence above each corner. These are what a tape measure is made for.
    Returns (corners, tops, ground_plane) with corners as candidate dicts (xyz, score, img, uv), tops keyed by corner index."""
    import open3d as o3d
    dense_ply = work / "dense" / "scene_dense.ply"
    if not dense_ply.exists():
        return [], {}, None
    o3d.utility.random.seed(0)                       # RANSAC is random; keep prompts reproducible
    cloud = o3d.io.read_point_cloud(str(dense_ply)).voxel_down_sample(diag / 300)
    P = np.asarray(cloud.points)
    n_total = len(P)
    rest = cloud
    planes = []   # (normal, d, inlier xyz)
    for _ in range(24):
        if len(rest.points) < 0.005 * n_total:
            break
        model, inl = rest.segment_plane(distance_threshold=diag / 350, ransac_n=3, num_iterations=3000)
        if len(inl) < 0.005 * n_total:
            break
        pts = np.asarray(rest.points)[inl]
        c = pts.mean(axis=0)
        n = np.linalg.eigh(np.cov((pts - c).T))[1][:, 0]
        n /= np.linalg.norm(n)
        planes.append((n, -float(np.dot(n, c)), pts))
        rest = rest.select_by_index(inl, invert=True)
    if not planes:
        return [], {}, None
    cams_C = np.array([im["C"] for im in images.values()])
    ground = None
    for k, (n, d, pts) in enumerate(planes):
        if abs(float(np.dot(n, up))) > 0.8:
            ground = k
            break
    if ground is None:
        print("  no ground plane among the dominant planes")
        return [], {}, None
    ng, dg, pg = planes[ground]
    if np.mean(cams_C @ ng + dg) < 0:
        ng, dg = -ng, -dg
        planes[ground] = (ng, dg, pg)
    vert = [k for k, (n, d, pts) in enumerate(planes) if abs(float(np.dot(n, up))) < 0.25]
    print(f"  {len(planes)} planes: ground has {len(pg)} pts, {len(vert)} vertical planes")
    trees = {k: o3d.geometry.KDTreeFlann(o3d.geometry.PointCloud(o3d.utility.Vector3dVector(planes[k][2]))) for k in vert + [ground]}

    def support(k, X, r):
        return trees[k].search_radius_vector_3d(X, r)[0]

    corners = []
    R = 0.04 * diag
    for a in range(len(vert)):
        for b in range(a + 1, len(vert)):
            i, j = vert[a], vert[b]
            ni, di, _ = planes[i]
            nj, dj, _ = planes[j]
            cosang = abs(float(np.dot(ni, nj)))
            if cosang > np.cos(np.radians(35)):
                continue
            A = np.array([ng, ni, nj])
            try:
                X = np.linalg.solve(A, -np.array([dg, di, dj]))
            except np.linalg.LinAlgError:
                continue
            si, sj, sg = support(i, X, R), support(j, X, R), support(ground, X, R)
            if min(si, sj) < 8 or sg < 6:
                continue
            dup = next((c for c in corners if np.linalg.norm(X - c["xyz"]) < 0.06 * diag), None)
            if dup is not None:                       # same physical corner from facade sub-planes: keep the better-supported one
                if min(si, sj) > dup["support"]:
                    dup.update({"xyz": X, "planes": (i, j), "support": min(si, sj)})
                continue
            corners.append({"xyz": X, "planes": (i, j), "support": min(si, sj), "score": 0.0})
    if not corners:
        return [], {}, (ng, dg)
    sup = np.array([c["support"] for c in corners], dtype=float)
    for c, sc in zip(corners, sup / sup.max()):
        c["score"] = 0.5 + 0.5 * float(sc)

    # wall/fence top above each corner: highest supported inliers of either plane near the corner
    tops = {}
    for idx, c in enumerate(corners):
        best_h, best_pt = 0.0, None
        for k in c["planes"]:
            pts = planes[k][2]
            horiz = pts - np.outer((pts - c["xyz"]) @ ng, ng) - c["xyz"]
            near = pts[np.linalg.norm(horiz, axis=1) < 0.05 * diag]
            if len(near) < 15:
                continue
            h = (near - c["xyz"]) @ ng
            h95 = float(np.percentile(h, 95))
            if h95 > best_h and (h > h95 - 0.02 * diag).sum() >= 8:
                best_h, best_pt = h95, c["xyz"] + ng * h95
        if best_pt is not None and best_h > 0.04 * diag:
            tops[idx] = {"xyz": best_pt, "height": best_h}

    # visibility: pick a sharp, central, unoccluded, reasonably close frame for each point
    mesh_path = work / "dense" / "scene_dense_mesh.ply"
    scene = None
    if mesh_path.exists():
        mesh = o3d.t.geometry.TriangleMesh.from_legacy(o3d.io.read_triangle_mesh(str(mesh_path)))
        scene = o3d.t.geometry.RaycastingScene()
        scene.add_triangles(mesh)

    def best_view(X):
        opts = []
        for img_id, im in images.items():
            cam = cams[im["cam"]]
            uv = project(im, cam, X)
            if uv is None or not (0.1 * cam["w"] < uv[0] < 0.9 * cam["w"] and 0.1 * cam["h"] < uv[1] < 0.9 * cam["h"]):
                continue
            dist = float(np.linalg.norm(X - im["C"]))
            if dist < 0.03 * diag:
                continue
            opts.append((img_id, uv, dist))
        if not opts:
            return None
        opts.sort(key=lambda o: o[2])
        opts = opts[:max(8, len(opts) // 3)]          # closer third
        if scene is not None:
            rays = np.array([[*images[o[0]]["C"], *((X - images[o[0]]["C"]) / o[2])] for o in opts], dtype=np.float32)
            hit = scene.cast_rays(o3d.core.Tensor(rays))["t_hit"].numpy()
            opts = [o for o, t in zip(opts, hit) if not np.isfinite(t) or t > 0.92 * o[2]] or opts
        return max(opts, key=lambda o: sharp.get(images[o[0]]["name"], med_sharp) / (1 + 3 * o[2] / diag))

    keep = []
    for idx, c in enumerate(corners):
        if float(np.min(np.linalg.norm(cams_C - c["xyz"], axis=1))) > 0.15 * diag:
            continue                                   # across the fence
        v = best_view(c["xyz"])
        if v is None:
            continue
        frame = cv2.imread(str(work / "dense" / "images" / images[v[0]]["name"]))
        if frame is not None and is_vegetation(frame, int(round(v[1][0])), int(round(v[1][1]))):
            continue                                   # hedge "wall"
        c["img"], c["uv"], c["pid"] = v[0], v[1], -1 - idx
        c["h"] = float(np.dot(c["xyz"], up))
        keep.append(c)
        if idx in tops:
            vt = best_view(tops[idx]["xyz"])
            if vt is not None:
                tops[idx].update({"img": vt[0], "uv": vt[1], "pid": -1000 - idx, "score": c["score"], "h": float(np.dot(tops[idx]["xyz"], up))})
            else:
                tops.pop(idx)
    print(f"  {len(keep)} structural corners visible in frames, {len(tops)} with a measurable top")
    return keep, tops, (ng, dg)


def rank(v):
    v = np.asarray(v, dtype=float)
    order = v.argsort().argsort()
    return order / max(len(v) - 1, 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--count", type=int, default=4)
    ap.add_argument("--min-track", type=int, default=6)
    ap.add_argument("--max-error", type=float, default=1.5)
    args = ap.parse_args()
    work = Path(args.work)
    sparse, imgdir = work / "dense" / "sparse", work / "dense" / "images"
    out = work / "measure"
    crops = out / "crops"
    crops.mkdir(parents=True, exist_ok=True)

    cams, images, points = read_model(sparse)
    if not points:
        sys.exit("no 3D points in the model")
    sharp = {}
    fcsv = work / "images" / "frames.csv"
    if fcsv.exists():
        sharp = {r["image"]: float(r["sharpness"]) for r in csv.DictReader(open(fcsv))}
    med_sharp = np.median(list(sharp.values())) if sharp else 1.0

    # ---- candidate points: long tracks, low error, a sharp frame where they sit well inside the image
    cand = []
    for pid, pt in points.items():
        if len(pt["track"]) < args.min_track or pt["err"] > args.max_error:
            continue
        best = None
        for img_id, idx in pt["track"]:
            im = images.get(int(img_id))
            if im is None or idx >= len(im["pts"]):
                continue
            cam = cams[im["cam"]]
            x, y = im["pts"][idx][:2]
            if not (0.08 * cam["w"] < x < 0.92 * cam["w"] and 0.08 * cam["h"] < y < 0.92 * cam["h"]):
                continue
            s = sharp.get(im["name"], med_sharp)
            if best is None or s > best[0]:
                best = (s, int(img_id), float(x), float(y))
        if best is None:
            continue
        cand.append({"pid": pid, "xyz": pt["xyz"], "track": len(pt["track"]), "err": pt["err"],
                     "sharp": best[0], "img": best[1], "uv": (best[2], best[3])})
    if len(cand) < 20:
        sys.exit(f"only {len(cand)} usable points; the reconstruction is too thin to pick landmarks")
    print(f"{len(points)} points -> {len(cand)} candidates with long tracks")

    # ---- cornerness in the chosen frame (Shi-Tomasi min eigenvalue), computed per frame to load each once
    by_img = {}
    for c in cand:
        by_img.setdefault(c["img"], []).append(c)
    cam_centers = np.array([im["C"] for im in images.values()])
    for img_id, cs in by_img.items():
        bgr = cv2.imread(str(imgdir / images[img_id]["name"]))
        if bgr is None:
            for c in cs:
                c["corner"] = 0.0
            continue
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        for c in cs:
            c["veg"] = is_vegetation(bgr, int(round(c["uv"][0])), int(round(c["uv"][1])))
            c["cam_dist"] = float(np.min(np.linalg.norm(cam_centers - c["xyz"], axis=1)))
        H, W = gray.shape
        half = cv2.resize(gray, (W // 2, H // 2), interpolation=cv2.INTER_AREA)
        for c in cs:
            x, y = int(round(c["uv"][0])), int(round(c["uv"][1]))
            x0, y0, x1, y1 = max(x - 32, 0), max(y - 32, 0), min(x + 33, W), min(y + 33, H)
            patch = gray[y0:y1, x0:x1]
            resp = cv2.cornerMinEigenVal(patch, blockSize=7, ksize=3)
            cy, cx = y - y0, x - x0
            local = resp[max(cy - 2, 0):cy + 3, max(cx - 2, 0):cx + 3].max()
            c["corner"] = float(local) * (1.0 if local > 2 * resp.mean() else 0.3)   # distinct from its surroundings?
            c["lines"] = straight_edges(gray, x, y)
            c["blur"] = float(cv2.Laplacian(patch, cv2.CV_64F).var())
            hx, hy = x // 2, y // 2
            hW, hH = half.shape[1], half.shape[0]
            tx0, ty0, tx1, ty1 = max(hx - 24, 0), max(hy - 24, 0), min(hx + 25, hW), min(hy + 25, hH)
            wx0, wy0, wx1, wy1 = max(hx - 200, 0), max(hy - 200, 0), min(hx + 200, hW), min(hy + 200, hH)
            tmpl, win = half[ty0:ty1, tx0:tx1], half[wy0:wy1, wx0:wx1]
            if tmpl.size and win.shape[0] > tmpl.shape[0] + 8 and win.shape[1] > tmpl.shape[1] + 8:
                m = cv2.matchTemplate(win, tmpl, cv2.TM_CCOEFF_NORMED)
                sy, sx = ty0 - wy0, tx0 - wx0
                m[max(sy - 12, 0):sy + 13, max(sx - 12, 0):sx + 13] = 0                   # itself
                c["repeats"] = int((m > 0.6).sum() // 9)          # ~number of other look-alike spots
            else:
                c["repeats"] = 0
    for c in cand:
        c.setdefault("blur", 0.0)
        c.setdefault("repeats", 99)
        c.setdefault("lines", 0)
        c.setdefault("veg", True)
        c.setdefault("cam_dist", 1e9)

    # ---- is it a physical corner? PCA of the 3D neighbourhood in the DENSE cloud (the sparse one is too noisy):
    #      flat surfaces (rug, lawn, wall) ~0 curvature; edges/corners in between; blobs (foliage, cushions) high
    import open3d as o3d
    allP = np.array([pt["xyz"] for pt in points.values()])
    lo0, hi0 = np.percentile(allP, 2, axis=0), np.percentile(allP, 98, axis=0)
    diag0 = float(np.linalg.norm(hi0 - lo0))
    dense_ply = work / "dense" / "scene_dense.ply"
    if dense_ply.exists():
        cloud = o3d.io.read_point_cloud(str(dense_ply)).voxel_down_sample(diag0 / 1500)
        P3 = np.asarray(cloud.points)
        print(f"  dense cloud for structure test: {len(P3)} points after downsampling")
    else:
        P3 = allP
    tree = o3d.geometry.KDTreeFlann(o3d.geometry.PointCloud(o3d.utility.Vector3dVector(P3)))
    for c in cand:
        k, idx, _ = tree.search_radius_vector_3d(c["xyz"], 0.012 * diag0)
        nb = P3[list(idx)]
        if len(nb) < 15:
            c["curv"] = 0.0
            continue
        ev = np.linalg.eigvalsh(np.cov(nb.T))
        c["curv"] = float(max(ev[0], 0) / max(ev.sum(), 1e-12))     # 0 = perfectly planar, ~0.33 = isotropic blob
    # noise floor: curvature of random cloud points (mostly flat surfaces); an edge must clearly exceed it
    rng = np.random.default_rng(0)
    floor = []
    for i in rng.choice(len(P3), size=min(3000, len(P3)), replace=False):
        k, idx, _ = tree.search_radius_vector_3d(P3[i], 0.012 * diag0)
        if k >= 15:
            ev = np.linalg.eigvalsh(np.cov(P3[list(idx)].T))
            floor.append(max(ev[0], 0) / max(ev.sum(), 1e-12))
    floor_med = float(np.median(floor)) if floor else 0.01
    # reachable: near the walked path (things across the fence are 3D-visible but not tape-measurable) and not vegetation
    cand_all = cand
    reach = 0.15 * diag0
    cand = [c for c in cand if c["cam_dist"] <= reach and not c["veg"]]
    print(f"  {len(cand)} of {len(cand_all)} are within reach of the walked path and not vegetation")
    if len(cand) < 20:
        cand = cand_all
    curv = np.array([c["curv"] for c in cand])
    lo_t, hi_t = 0.03, 0.2      # fixed: the noise floor is dominated by textured surfaces (rug pile, gravel), not geometry
    print(f"  curvature noise floor {floor_med:.4f}; candidates p25/p50/p75 = {np.percentile(curv, [25, 50, 75]).round(4)}; edge window [{lo_t:.3f}, {hi_t}]")
    curv_ok = (curv > lo_t) & (curv < hi_t)
    rep_ok = np.array([c["repeats"] for c in cand]) <= 1
    lines = np.array([c["lines"] for c in cand])
    print(f"  {int(curv_ok.sum())} of {len(cand)} sit on 3D edges/corners, {int(rep_ok.sum())} look unique, "
          f"{int((lines >= 1).sum())} lie on a straight edge ({int((lines == 2).sum())} at a corner of edges)")
    strict = [c for c, a, b, l in zip(cand, curv_ok, rep_ok, lines) if a and b and l == 2]
    medium = [c for c, a, b, l in zip(cand, curv_ok, rep_ok, lines) if a and b and l >= 1]
    if len(strict) >= 20:
        cand = strict; print(f"  using {len(cand)} straight-edge corners")
    elif len(medium) >= 20:
        cand = medium; print(f"  using {len(cand)} straight-edge points")
    else:
        print("  too few strict candidates; falling back to soft scoring")
    score = 0.30 * rank([c["lines"] for c in cand]) + 0.25 * rank([c["corner"] for c in cand]) \
        + 0.20 * rank([-abs(c["curv"] - 0.08) for c in cand]) + 0.10 * rank([-c["repeats"] for c in cand]) \
        + 0.10 * rank([c["track"] for c in cand]) + 0.05 * rank([c["sharp"] for c in cand])
    for c, s in zip(cand, score):
        c["score"] = float(s)

    # ---- spatial diversity: best point per voxel, then top 200
    P = np.array([c["xyz"] for c in cand])
    lo, hi = np.percentile(P, 2, axis=0), np.percentile(P, 98, axis=0)
    diag = float(np.linalg.norm(hi - lo))
    vox = {}
    for c in cand:
        key = tuple(np.floor((c["xyz"] - lo) / (diag / 25)).astype(int))
        if key not in vox or c["score"] > vox[key]["score"]:
            vox[key] = c
    cand = sorted(vox.values(), key=lambda c: -c["score"])[:200]
    up = np.mean([im["up"] for im in images.values()], axis=0)
    up /= np.linalg.norm(up)
    for c in cand:
        c["h"] = float(np.dot(c["xyz"], up))
    print(f"{len(cand)} diverse candidates, model diagonal {diag:.2f} units")

    # ---- structural corners take priority over texture points
    corners, tops, gplane = structural_corners(work, cams, images, sharp, med_sharp, up, diag)
    if len(corners) >= 3:
        for c in corners:
            c["score"] += 1.0            # always outrank texture points
        cand = corners + [c for c in cand if c["score"] > 0.6][:60]
    # ---- pairs
    def direction(a, b):
        d = b["xyz"] - a["xyz"]
        return d / (np.linalg.norm(d) + 1e-9)

    pairs = []
    for i in range(len(cand)):
        for j in range(i + 1, len(cand)):
            a, b = cand[i], cand[j]
            dist = float(np.linalg.norm(a["xyz"] - b["xyz"]))
            if dist < 0.08 * diag:
                continue
            d = direction(a, b)
            vert = abs(float(np.dot(d, up)))
            pairs.append({"a": a, "b": b, "dist": dist, "dir": d, "vert": vert,
                          "score": min(a["score"], b["score"]) * (0.4 + 0.6 * dist / diag)})
    pairs.sort(key=lambda p: -p["score"])
    want = max(2 * args.count + 2, 6)
    chosen = []

    def ok_direction(p):
        return all(abs(float(np.dot(p["dir"], q["dir"]))) < np.cos(np.radians(35)) for q in chosen if q["kind"] != "vertical")

    def uses_new_points(p):
        used = {q["a"]["pid"] for q in chosen} | {q["b"]["pid"] for q in chosen}
        return p["a"]["pid"] not in used and p["b"]["pid"] not in used

    # 1. the longest good horizontal span
    for p in pairs:
        if p["dist"] >= 0.5 * diag and p["vert"] < 0.35:
            p["kind"] = "diagonal"; chosen.append(p); break
    # 2. one vertical span: a structural corner to the top of its wall/fence if we have one, else any vertical pair
    if tops:
        idx = max(tops, key=lambda k: tops[k]["height"])
        base = next((c for c in corners if c["pid"] == -1 - idx), None)
        if base is not None:
            t = tops[idx]
            chosen.append({"a": base, "b": t, "dist": float(np.linalg.norm(t["xyz"] - base["xyz"])), "dir": up, "vert": 1.0,
                           "score": 1.0, "kind": "vertical"})
    if not any(p["kind"] == "vertical" for p in chosen):
        for p in pairs:
            if p["vert"] > 0.8 and 0.05 * diag <= p["dist"] <= 0.5 * diag and uses_new_points(p):
                p["kind"] = "vertical"; chosen.append(p); break
    # 3. edges in other directions, then anything long that uses new points
    for p in pairs:
        if len(chosen) >= want:
            break
        if p["vert"] < 0.35 and p["dist"] >= 0.25 * diag and uses_new_points(p) and ok_direction(p):
            p["kind"] = "edge"; chosen.append(p)
    for p in pairs:
        if len(chosen) >= want:
            break
        if p["vert"] < 0.35 and p["dist"] >= 0.2 * diag and uses_new_points(p) and "kind" not in p:
            p["kind"] = "edge"; chosen.append(p)
    print(f"{len(chosen)} distance prompts: " + ", ".join(f"{p['kind']} {p['dist']:.2f}" for p in chosen))

    # ---- ground candidates: lowest, spread out (structural corners are on the ground by construction)
    low = sorted([c for c in cand if c.get("pid", 0) > -1000], key=lambda c: c["h"])
    hmin = low[0]["h"]
    ground = []
    for c in low:
        if c["h"] - hmin > 0.06 * diag:
            break
        if all(np.linalg.norm(c["xyz"] - g["xyz"]) > 0.25 * diag for g in ground):
            ground.append(c)
        if len(ground) == 3:
            break

    # ---- north frame: sharpest frame with a mostly horizontal view direction
    north_img = max(images.values(), key=lambda im: sharp.get(im["name"], med_sharp) * (1 - abs(float(np.dot(im["fwd"], up)))))

    # ---- crops
    def draw(c, tag, color):
        im = images[c["img"]]
        frame = cv2.imread(str(imgdir / im["name"]))
        H, W = frame.shape[:2]
        x, y = int(round(c["uv"][0])), int(round(c["uv"][1]))
        r = 180
        x0, y0 = max(min(x - r, W - 2 * r), 0), max(min(y - r, H - 2 * r), 0)
        zoom = frame[y0:y0 + 2 * r, x0:x0 + 2 * r].copy()
        cv2.circle(zoom, (x - x0, y - y0), 14, color, 3)
        cv2.circle(zoom, (x - x0, y - y0), 2, color, -1)
        cv2.putText(zoom, tag, (10, 34), cv2.FONT_HERSHEY_SIMPLEX, 1.1, color, 3, cv2.LINE_AA)
        s = 720 / max(W, H)
        ctx = cv2.resize(frame, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        cv2.rectangle(ctx, (int(x0 * s), int(y0 * s)), (int((x0 + 2 * r) * s), int((y0 + 2 * r) * s)), color, 2)
        cv2.circle(ctx, (int(x * s), int(y * s)), 8, color, 2)
        zp, cp = crops / f"{tag}.jpg", crops / f"{tag}_ctx.jpg"
        cv2.imwrite(str(zp), zoom, [cv2.IMWRITE_JPEG_QUALITY, 88])
        cv2.imwrite(str(cp), ctx, [cv2.IMWRITE_JPEG_QUALITY, 85])
        return {"pid": int(c.get("pid", 0)), "structural": c.get("pid", 0) < 0, "xyz": [float(v) for v in c["xyz"]], "frame": im["name"], "uv": [x, y],
                "crop": f"measure/crops/{tag}.jpg", "context": f"measure/crops/{tag}_ctx.jpg"}

    RED, BLUE, GREEN = (40, 40, 230), (230, 120, 30), (40, 190, 60)
    prompts = []
    for i, p in enumerate(chosen, 1):
        kind_text = {"diagonal": "Longest span across the site", "vertical": "Vertical span (height)", "edge": "Span"}[p["kind"]]
        if p["a"].get("pid", 0) < 0 and p["b"].get("pid", 0) < 0:
            kind_text += " between two structural corners (where walls/fences meet the ground)"
        elif p["kind"] == "vertical" and p["b"].get("pid", 0) <= -1000:
            kind_text = "Height of the wall/fence at this corner: from the ground corner (A) straight up to its top edge (B)"
        prompts.append({"id": f"d{i}", "type": "distance", "kind": p["kind"], "rank": i, "model_dist": p["dist"],
                        "a": draw(p["a"], f"d{i}A", RED), "b": draw(p["b"], f"d{i}B", BLUE),
                        "text": f"{kind_text}: measure the straight-line distance from A (red) to B (blue), in metres."})
    if len(ground) == 3:
        prompts.append({"id": "g1", "type": "ground", "points": [draw(g, f"g1_{k}", GREEN) for k, g in enumerate(ground)],
                        "text": "Are all three green points on the ground (lawn, patio, path)? This levels the model."})
    frame = cv2.imread(str(imgdir / north_img["name"]))
    s = 720 / max(frame.shape[:2])
    cv2.imwrite(str(crops / "north_ctx.jpg"), cv2.resize(frame, None, fx=s, fy=s, interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 85])
    prompts.append({"id": "n1", "type": "north", "frame": north_img["name"], "context": "measure/crops/north_ctx.jpg",
                    "forward": [float(v) for v in north_img["fwd"]], "position": [float(v) for v in north_img["C"]],
                    "text": "Optional: stand where this frame was shot, face the same way, and enter the compass bearing in degrees (Compass app). This orients the plan with north up."})
    json.dump({"count": args.count, "diag": diag, "up": [float(v) for v in up], "prompts": prompts},
              open(out / "prompts.json", "w"), indent=1)
    print(f"wrote {out / 'prompts.json'} ({len(prompts)} prompts) and {len(list(crops.iterdir()))} crops")
    return 0


if __name__ == "__main__":
    sys.exit(main())
