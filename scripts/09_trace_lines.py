#!/usr/bin/env python3
"""Trace the site as an architect would draw it: straight, merged, orthogonally snapped line segments.

Reads  <work>/scene_dense_metric.ply (metres, Z up, north +Y)
Writes <work>/linework.json  {"axis_deg": θ, "walls": [[[x,y],[x,y]], ...], "edges": [...]}
        walls: height jumps above --wall (fences, walls, the house); edges: smaller steps (patio rims, curbs, beds)

How: a 5 cm digital elevation model; the local height range in a small window marks steps; the step bands are
skeletonised; a probabilistic Hough transform turns the skeleton into segments; near-collinear segments are merged;
the site's dominant axis is found from the long segments and every segment within --snap degrees of it or its
perpendicular is rotated onto it. The result is a clean line drawing, not survey-grade geometry.

Usage: python scripts/09_trace_lines.py <work> [--cell 0.05] [--wall 0.5] [--edge 0.08] [--min-len 0.6] [--snap 8]
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("siteplan08", HERE / "08_site_plan.py")
siteplan08 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(siteplan08)


def step_mask(dem: np.ndarray, cell: float, jump: float, window_m: float = 0.3) -> np.ndarray:
    """Cells where the height changes by more than `jump` within a small window: the foot of a wall, a fence line."""
    k = max(3, int(round(window_m / cell)) | 1)
    valid = np.isfinite(dem)
    z = np.where(valid, dem, np.nan).astype(np.float32)
    lo = z.copy(); lo[~valid] = np.inf
    hi = z.copy(); hi[~valid] = -np.inf
    kernel = np.ones((k, k), np.uint8)
    local_min = cv2.erode(lo, kernel)
    local_max = cv2.dilate(hi, kernel)
    rng = local_max - local_min
    return ((rng > jump) & valid).astype(np.uint8)


def segments_from_mask(mask: np.ndarray, cell: float, min_len: float, gap: float):
    from skimage.morphology import skeletonize
    if mask.sum() < 20:
        return []
    m = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    skel = skeletonize(m.astype(bool)).astype(np.uint8) * 255
    lines = cv2.HoughLinesP(skel, rho=1, theta=np.pi / 360, threshold=int(0.4 / cell),
                            minLineLength=int(min_len / cell), maxLineGap=int(gap / cell))
    if lines is None:
        return []
    return [tuple(map(float, l)) for l in np.asarray(lines).reshape(-1, 4)]      # (x1, y1, x2, y2) in pixels


def merge_segments(segs, ang_tol_deg=6.0, offset_tol=0.12, gap_tol=0.5):
    """Greedy merge of near-collinear, nearby segments (metres)."""
    segs = [np.array(s, dtype=float).reshape(2, 2) for s in segs]
    merged = True
    while merged:
        merged = False
        out = []
        used = [False] * len(segs)
        for i, a in enumerate(segs):
            if used[i]:
                continue
            da = a[1] - a[0]
            la = np.linalg.norm(da)
            if la < 1e-6:
                used[i] = True
                continue
            ua = da / la
            na = np.array([-ua[1], ua[0]])
            group = [a]
            used[i] = True
            for j in range(i + 1, len(segs)):
                if used[j]:
                    continue
                b = segs[j]
                db = b[1] - b[0]
                lb = np.linalg.norm(db)
                if lb < 1e-6:
                    used[j] = True
                    continue
                ub = db / lb
                ang = np.degrees(np.arccos(min(1.0, abs(np.dot(ua, ub)))))
                if ang > ang_tol_deg:
                    continue
                off = max(abs(np.dot(b[0] - a[0], na)), abs(np.dot(b[1] - a[0], na)))
                if off > offset_tol:
                    continue
                ta = sorted([0.0, la])
                tb = sorted([np.dot(b[0] - a[0], ua), np.dot(b[1] - a[0], ua)])
                if tb[0] > ta[1] + gap_tol or tb[1] < ta[0] - gap_tol:
                    continue
                group.append(b)
                used[j] = True
            if len(group) > 1:
                merged = True
                pts = np.vstack(group)
                w = np.concatenate([[np.linalg.norm(g[1] - g[0])] * 2 for g in group])
                c = np.average(pts, axis=0, weights=w)
                # principal direction of the group
                u, _, vt = np.linalg.svd((pts - c) * np.sqrt(w)[:, None], full_matrices=False)
                d = vt[0]
                t = (pts - c) @ d
                out.append(np.array([c + t.min() * d, c + t.max() * d]))
            else:
                out.append(a)
        segs = out
    return segs


def dominant_axis(segs):
    if not segs:
        return 0.0
    ang = np.array([np.degrees(np.arctan2(*(s[1] - s[0])[::-1])) % 90 for s in segs])
    w = np.array([np.linalg.norm(s[1] - s[0]) for s in segs])
    hist, edges = np.histogram(ang, bins=90, range=(0, 90), weights=w)
    hist = np.convolve(np.concatenate([hist[-2:], hist, hist[:2]]), np.ones(5) / 5, mode="valid")
    return float(edges[int(np.argmax(hist))] + 0.5)


def prune_isolated(segs, keep_len=1.5, near=0.6):
    """Drop short segments that have no longer neighbour: fence-top vegetation, not structure."""
    long_ = [s for s in segs if np.linalg.norm(s[1] - s[0]) >= keep_len]
    out = list(long_)
    for s in segs:
        if np.linalg.norm(s[1] - s[0]) >= keep_len:
            continue
        c = (s[0] + s[1]) / 2
        for l in long_:
            d = l[1] - l[0]
            t = np.clip(np.dot(c - l[0], d) / max(np.dot(d, d), 1e-9), 0, 1)
            if np.linalg.norm(c - (l[0] + t * d)) <= near:
                out.append(s)
                break
    return out


def snap(segs, axis_deg, tol_deg):
    out = []
    for s in segs:
        d = s[1] - s[0]
        l = np.linalg.norm(d)
        ang = np.degrees(np.arctan2(d[1], d[0]))
        best = None
        for target in (axis_deg, axis_deg + 90, axis_deg + 180, axis_deg + 270, axis_deg - 90, axis_deg - 180):
            diff = (ang - target + 180) % 360 - 180
            if abs(diff) <= tol_deg and (best is None or abs(diff) < abs(best[0])):
                best = (diff, target)
        if best is None:
            out.append(s)
            continue
        t = np.radians(best[1])
        u = np.array([np.cos(t), np.sin(t)])
        c = (s[0] + s[1]) / 2
        out.append(np.array([c - u * l / 2, c + u * l / 2]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--cell", type=float, default=0.05)
    ap.add_argument("--wall", type=float, default=0.5, help="height jump that counts as a wall or fence (m)")
    ap.add_argument("--edge", type=float, default=0.08, help="height jump that counts as an edge or curb (m)")
    ap.add_argument("--min-len", type=float, default=0.8, help="shortest segment kept (m)")
    ap.add_argument("--snap", type=float, default=12.0, help="snap segments within this many degrees of the site axis")
    a = ap.parse_args()
    work = Path(a.work)
    dem, meta = siteplan08.build_dem(work / "scene_dense_metric.ply", a.cell)
    cell = meta["cell"]

    def to_world(segs_px):
        out = []
        for (x1, y1, x2, y2) in segs_px:
            (X1, Y1), (X2, Y2) = siteplan08.grid_to_world([[x1, y1], [x2, y2]], meta)
            out.append(np.array([[X1, Y1], [X2, Y2]]))
        return out

    wall_px = segments_from_mask(step_mask(dem, cell, a.wall, window_m=0.4), cell, a.min_len, 0.6)
    walls = merge_segments(to_world(wall_px), ang_tol_deg=8.0, offset_tol=0.2, gap_tol=0.8)
    edge_mask = step_mask(dem, cell, a.edge) & (1 - step_mask(dem, cell, a.wall, window_m=0.6))
    edge_px = segments_from_mask(edge_mask, cell, a.min_len, 0.3)
    edges = merge_segments(to_world(edge_px), ang_tol_deg=6.0, offset_tol=0.12, gap_tol=0.4)
    axis = dominant_axis(walls if walls else edges)
    # snap to the site's axes, then merge again: snapped pieces of one fence become one run
    walls = merge_segments(snap(walls, axis, a.snap), ang_tol_deg=2.0, offset_tol=0.25, gap_tol=1.0)
    walls = prune_isolated([s for s in walls if np.linalg.norm(s[1] - s[0]) >= a.min_len])
    edges = merge_segments(snap(edges, axis, a.snap), ang_tol_deg=2.0, offset_tol=0.15, gap_tol=0.5)
    edges = prune_isolated([s for s in edges if np.linalg.norm(s[1] - s[0]) >= a.min_len], keep_len=1.2, near=0.5)
    rounded = lambda segs: [[[round(float(p[0]), 3), round(float(p[1]), 3)] for p in s] for s in segs]
    json.dump({"axis_deg": round(axis, 2), "wall_jump_m": a.wall, "edge_jump_m": a.edge,
               "walls": rounded(walls), "edges": rounded(edges)}, open(work / "linework.json", "w"))
    total = sum(np.linalg.norm(s[1] - s[0]) for s in walls)
    print(f"linework: {len(walls)} wall/fence segments ({total:.0f} m), {len(edges)} edge segments, site axis {axis:.1f}°")
    return 0


if __name__ == "__main__":
    sys.exit(main())
