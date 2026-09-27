#!/usr/bin/env python3
"""Architect's line drawing from the 3D model: vertical surfaces → 2D lines → regularized, dimensioned polygons.

Reads  <work>/scene_dense_metric.ply   (metres, Z up = levelled ground at z ≈ 0, north +Y)
Writes <work>/linework.json  {"axis_deg", "walls": [[[x,y],[x,y]], ...], "polygons": [{"points": [...], "lengths": [...], "area"}]}

Steps (all classical, seconds on an M4):
  1. Down-sample to 4 cm, estimate normals.  Points whose normal is nearly horizontal and that sit between 0.25 m and
     3 m above the ground are "vertical structure": fences, walls, the house, hedges.  Trees and lawn are excluded.
  2. Rasterise those points to 5 cm cells; keep cells where the structure spans at least --min-height vertically
     (a fence has 1+ m of points on one line; a bush top does not).
  3. Iterative 2-D RANSAC on the cell centres: fit a line, take inliers within --inlier m, split them into runs along
     the line (gaps over --gap m break a run), keep runs longer than --min-len, remove, repeat.
  4. Regularise: the site's dominant axis from the long segments; snap everything within --snap° to the axis or its
     perpendicular; merge collinear pieces.
  5. Polygonise: extend segments a little, node them, and take the faces they enclose; orthogonalise each face with
     buildingregulariser; every edge gets its length.  The largest face is the yard boundary.

Usage: python scripts/10_trace_walls.py <work> [--voxel 0.04] [--min-height 0.5] [--inlier 0.06] [--min-len 0.8] [--snap 12]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def load_points(cloud: Path, voxel: float):
    import open3d as o3d
    pcd = o3d.io.read_point_cloud(str(cloud))
    pcd = pcd.voxel_down_sample(voxel)
    pcd.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=voxel * 4, max_nn=30))
    return np.asarray(pcd.points), np.asarray(pcd.normals)


def vertical_structure(P, N, zmin: float, zmax: float, nz_max: float):
    sel = (np.abs(N[:, 2]) < nz_max) & (P[:, 2] > zmin) & (P[:, 2] < zmax)
    return P[sel]


def ground_footprint(P, cell: float = 0.1, ground_z: float = 0.35, close_m: float = 0.6, min_area_m2: float = 4.0):
    """The walkable ground (lawn, paving, paths) as a polygon: where the low points are.  Its outline is where the
    fences and the house stand, so it is the yard boundary, and it always closes."""
    import cv2
    from shapely.geometry import Polygon
    G = P[np.abs(P[:, 2]) < ground_z]
    x0, y0 = G[:, 0].min() - cell, G[:, 1].min() - cell
    W = int((G[:, 0].max() - x0) / cell) + 3
    H = int((G[:, 1].max() - y0) / cell) + 3
    m = np.zeros((H, W), np.uint8)
    m[((G[:, 1] - y0) / cell).astype(int), ((G[:, 0] - x0) / cell).astype(int)] = 1
    k = max(3, int(round(close_m / cell)) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, kernel)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (max(3, k // 2) | 1,) * 2))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(m)
    if n < 2:
        return []
    polys = []
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] * cell * cell < min_area_m2:
            continue
        comp = (lab == i).astype(np.uint8)
        cnts, _ = cv2.findContours(comp, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in cnts:
            pts = c.reshape(-1, 2).astype(float)
            xy = np.column_stack([x0 + (pts[:, 0] + 0.5) * cell, y0 + (pts[:, 1] + 0.5) * cell])
            if len(xy) >= 4:
                polys.append(Polygon(xy).buffer(0))
    return sorted([p for p in polys if not p.is_empty], key=lambda p: -p.area)


def snap_polygon_to_walls(poly, walls, max_offset: float = 0.5, ang_tol: float = 3.0):
    """Move polygon edges that run parallel and close to a detected wall onto that wall's line."""
    from shapely.geometry import Polygon
    xy = np.array(poly.exterior.coords)[:-1]
    n = len(xy)
    edges = []
    for i in range(n):
        a, b = xy[i], xy[(i + 1) % n]
        d = b - a
        L = np.linalg.norm(d)
        if L < 1e-6:
            edges.append((a, b)); continue
        u = d / L
        best = None
        for w in walls:
            wd = w[1] - w[0]
            wl = np.linalg.norm(wd)
            wu = wd / max(wl, 1e-9)
            if np.degrees(np.arccos(min(1.0, abs(u @ wu)))) > ang_tol:
                continue
            wn = np.array([-wu[1], wu[0]])
            off = (abs((a - w[0]) @ wn) + abs((b - w[0]) @ wn)) / 2
            # the edge must overlap the wall's extent
            ta, tb = (a - w[0]) @ wu, (b - w[0]) @ wu
            overlap = min(max(ta, tb), wl) - max(min(ta, tb), 0)
            if off <= max_offset and overlap > 0.5 * min(L, wl) and (best is None or off < best[0]):
                best = (off, w, wu, wn)
        if best is None:
            edges.append((a, b))
        else:
            _, w, wu, wn = best
            shift = ((a - w[0]) @ wn + (b - w[0]) @ wn) / 2
            edges.append((a - shift * wn, b - shift * wn))
    # rebuild vertices as intersections of consecutive edge lines (keeps corners sharp)
    out = []
    for i in range(n):
        (a1, b1), (a2, b2) = edges[i - 1], edges[i]
        u1, u2 = b1 - a1, b2 - a2
        A = np.array([u1, -u2]).T
        if abs(np.linalg.det(A)) < 1e-6:
            out.append(b1)
        else:
            t, _ = np.linalg.solve(A, a2 - a1)
            x = a1 + t * u1
            out.append(x if np.linalg.norm(x - b1) < 2.0 else b1)
    p = Polygon(out).buffer(0)
    return p if not p.is_empty and p.geom_type == "Polygon" else poly


def structure_cells(P: np.ndarray, cell: float, min_height: float, min_count: int = 3):
    """2-D cell centres where vertical structure spans at least min_height."""
    x0, y0 = P[:, 0].min(), P[:, 1].min()
    ix = ((P[:, 0] - x0) / cell).astype(np.int64)
    iy = ((P[:, 1] - y0) / cell).astype(np.int64)
    W, H = ix.max() + 1, iy.max() + 1
    key = iy * W + ix
    order = np.argsort(key)
    key_s, z_s = key[order], P[order, 2]
    uniq, start, counts = np.unique(key_s, return_index=True, return_counts=True)
    zmin = np.minimum.reduceat(z_s, start)
    zmax = np.maximum.reduceat(z_s, start)
    keep = (counts >= min_count) & ((zmax - zmin) >= min_height)
    cx = (uniq[keep] % W + 0.5) * cell + x0
    cy = (uniq[keep] // W + 0.5) * cell + y0
    return np.column_stack([cx, cy]), (zmax - zmin)[keep]


def ransac_lines(Q: np.ndarray, inlier: float, min_len: float, gap: float, min_inliers: int = 20, iters: int = 400, seed: int = 0):
    rng = np.random.default_rng(seed)
    pts = Q.copy()
    segs = []
    while len(pts) >= min_inliers:
        best = None
        for _ in range(iters):
            i, j = rng.choice(len(pts), 2, replace=False)
            d = pts[j] - pts[i]
            L = np.linalg.norm(d)
            if L < 0.3:
                continue
            u = d / L
            n = np.array([-u[1], u[0]])
            dist = np.abs((pts - pts[i]) @ n)
            inl = dist < inlier
            c = int(inl.sum())
            if best is None or c > best[0]:
                best = (c, i, u, inl)
        if best is None or best[0] < min_inliers:
            break
        _, i, u, inl = best
        # refine direction on the inliers, then split into runs along the line
        sub = pts[inl]
        c0 = sub.mean(axis=0)
        _, _, vt = np.linalg.svd(sub - c0, full_matrices=False)
        u = vt[0]
        t = (sub - c0) @ u
        order = np.argsort(t)
        t, sub = t[order], sub[order]
        breaks = np.where(np.diff(t) > gap)[0]
        runs = np.split(np.arange(len(t)), breaks + 1)
        used = np.zeros(len(sub), dtype=bool)
        for r in runs:
            if len(r) < min_inliers // 2:
                continue
            length = t[r[-1]] - t[r[0]]
            if length >= min_len:
                segs.append(np.array([c0 + t[r[0]] * u, c0 + t[r[-1]] * u]))
                used[r] = True
        # remove the used inliers (and, if nothing was kept, the whole inlier set to avoid looping)
        idx = np.where(inl)[0][order]
        remove = idx[used] if used.any() else idx
        mask = np.ones(len(pts), dtype=bool)
        mask[remove] = False
        pts = pts[mask]
    return segs


def dominant_axis(segs):
    if not segs:
        return 0.0
    ang = np.array([np.degrees(np.arctan2(*(s[1] - s[0])[::-1])) % 90 for s in segs])
    w = np.array([np.linalg.norm(s[1] - s[0]) for s in segs])
    hist, edges = np.histogram(ang, bins=90, range=(0, 90), weights=w)
    hist = np.convolve(np.concatenate([hist[-2:], hist, hist[:2]]), np.ones(5) / 5, mode="valid")
    return float(edges[int(np.argmax(hist))] + 0.5)


def snap(segs, axis_deg, tol_deg):
    out = []
    for s in segs:
        d = s[1] - s[0]
        L = np.linalg.norm(d)
        ang = np.degrees(np.arctan2(d[1], d[0]))
        best = None
        for target in (axis_deg + k * 90 for k in range(-2, 3)):
            diff = (ang - target + 180) % 360 - 180
            if abs(diff) <= tol_deg and (best is None or abs(diff) < abs(best[0])):
                best = (diff, target)
        if best is None:
            out.append(s)
            continue
        t = np.radians(best[1])
        u = np.array([np.cos(t), np.sin(t)])
        c = (s[0] + s[1]) / 2
        out.append(np.array([c - u * L / 2, c + u * L / 2]))
    return out


def merge_collinear(segs, ang_tol=2.0, offset_tol=0.2, gap_tol=1.0):
    changed = True
    while changed:
        changed = False
        out, used = [], [False] * len(segs)
        for i, a in enumerate(segs):
            if used[i]:
                continue
            used[i] = True
            ua = (a[1] - a[0]) / max(np.linalg.norm(a[1] - a[0]), 1e-9)
            na = np.array([-ua[1], ua[0]])
            group = [a]
            for j in range(i + 1, len(segs)):
                if used[j]:
                    continue
                b = segs[j]
                ub = (b[1] - b[0]) / max(np.linalg.norm(b[1] - b[0]), 1e-9)
                if np.degrees(np.arccos(min(1.0, abs(ua @ ub)))) > ang_tol:
                    continue
                if max(abs((b[0] - a[0]) @ na), abs((b[1] - a[0]) @ na)) > offset_tol:
                    continue
                ta = sorted([0.0, (a[1] - a[0]) @ ua])
                tb = sorted([(b[0] - a[0]) @ ua, (b[1] - a[0]) @ ua])
                if tb[0] > ta[1] + gap_tol or tb[1] < ta[0] - gap_tol:
                    continue
                group.append(b)
                used[j] = True
            if len(group) > 1:
                changed = True
                pts = np.vstack(group)
                t = (pts - a[0]) @ ua
                out.append(np.array([a[0] + t.min() * ua, a[0] + t.max() * ua]))
            else:
                out.append(a)
        segs = out
    return segs


def prune_isolated(segs, keep_len=1.5, near=1.0):
    """Short segments with no long neighbour are noise (a bush, a chair), not structure."""
    long_ = [s for s in segs if np.linalg.norm(s[1] - s[0]) >= keep_len]
    out = list(long_)
    for s in segs:
        if np.linalg.norm(s[1] - s[0]) >= keep_len:
            continue
        c = (s[0] + s[1]) / 2
        for l in long_:
            d = l[1] - l[0]
            t = np.clip((c - l[0]) @ d / max(d @ d, 1e-9), 0, 1)
            if np.linalg.norm(c - (l[0] + t * d)) <= near:
                out.append(s)
                break
    return out


def close_corners(segs, join: float, min_angle: float = 30.0):
    """Where an endpoint is within `join` of another segment's line, extend it to the intersection (an L-corner) or,
    for near-parallel lines, to the foot of the perpendicular.  Both segments meet exactly; polygons can close."""
    segs = [s.copy() for s in segs]
    for i, a in enumerate(segs):
        ua = (a[1] - a[0]) / max(np.linalg.norm(a[1] - a[0]), 1e-9)
        for end in (0, 1):
            p = a[end]
            best = None
            for j, b in enumerate(segs):
                if j == i:
                    continue
                ub = (b[1] - b[0]) / max(np.linalg.norm(b[1] - b[0]), 1e-9)
                ang = np.degrees(np.arccos(min(1.0, abs(ua @ ub))))
                if ang < min_angle:
                    continue
                # intersection of the two infinite lines
                A = np.array([ua, -ub]).T
                if abs(np.linalg.det(A)) < 1e-6:
                    continue
                t, u = np.linalg.solve(A, b[0] - a[0])
                x = a[0] + t * ua
                # x must be near this endpoint, and near (or within) the other segment's extent
                Lb = np.linalg.norm(b[1] - b[0])
                if np.linalg.norm(x - p) <= join and -join <= u <= Lb + join:
                    d = np.linalg.norm(x - p)
                    if best is None or d < best[0]:
                        best = (d, j, x, u, Lb)
            if best is None:
                continue
            _, j, x, u, Lb = best
            a[end] = x
            b = segs[j]
            if u < 0:
                b[0] = x                       # the other segment's start reaches the corner
            elif u > Lb:
                b[1] = x
    return segs


def polygonize(segs, extend: float, min_area: float):
    from shapely.geometry import LineString
    from shapely.ops import polygonize as sh_polygonize, unary_union
    lines = []
    for s in segs:
        u = (s[1] - s[0]) / max(np.linalg.norm(s[1] - s[0]), 1e-9)
        lines.append(LineString([tuple(s[0] - u * extend), tuple(s[1] + u * extend)]))
    noded = unary_union(lines)
    polys = [p for p in sh_polygonize(noded) if p.area >= min_area]
    return polys


def regularize(polys, axis_deg):
    import geopandas as gpd
    from buildingregulariser import regularize_geodataframe
    if not polys:
        return []
    gdf = gpd.GeoDataFrame(geometry=polys)
    try:
        reg = regularize_geodataframe(gdf, parallel_threshold=1.5, simplify_tolerance=0.5, allow_45_degree=False,
                                      allow_circles=False, num_cores=1)
        out = list(reg.geometry)
    except Exception as e:                      # keep going with the raw faces
        print(f"regularizer failed ({e}); using simplified faces", file=sys.stderr)
        out = [p.simplify(0.15) for p in polys]
    return [p for p in out if p is not None and not p.is_empty]


def direction_families(walls, axis_deg: float, extra_min_len: float = 4.0, tol: float = 8.0):
    """The site's axis and its perpendicular, plus any direction a long *detected wall* insists on (a house that is
    not parallel to the fence).  Footprint edges are not trusted for this: coverage gaps make false diagonals."""
    fams = [axis_deg % 180, (axis_deg + 90) % 180]
    for w in walls:
        d = w[1] - w[0]
        L = np.linalg.norm(d)
        ang = np.degrees(np.arctan2(d[1], d[0])) % 180
        if L < extra_min_len:
            continue
        if all(min(abs(ang - f), 180 - abs(ang - f)) > tol for f in fams):
            fams.append(ang)
    return fams


def regularize_polygon(poly, fams, tol: float = 20.0):
    """Snap every edge to the nearest allowed direction (if within tol), keep its midpoint, and rebuild the corners
    as the intersections of consecutive edge lines.  Our own version of 'regularize building footprint' that
    allows more than one axis family."""
    from shapely.geometry import Polygon
    xy = np.array(poly.exterior.coords)[:-1]
    n = len(xy)
    edges = []
    for i in range(n):
        a, b = xy[i], xy[(i + 1) % n]
        d = b - a
        L = np.linalg.norm(d)
        ang = np.degrees(np.arctan2(d[1], d[0]))
        best = None
        for f in fams:
            for t in (f, f + 180, f - 180):
                diff = (ang - t + 180) % 360 - 180
                if abs(diff) <= tol and (best is None or abs(diff) < abs(best[0])):
                    best = (diff, t)
        if best is None:
            edges.append((a, d / max(L, 1e-9)))
        else:
            r = np.radians(best[1])
            u = np.array([np.cos(r), np.sin(r)])
            edges.append(((a + b) / 2 - u * L / 2, u))
    out = []
    for i in range(n):
        (p1, u1), (p2, u2) = edges[i - 1], edges[i]
        A = np.array([u1, -u2]).T
        if abs(np.linalg.det(A)) < 1e-3:               # parallel neighbours: keep the vertex
            out.append(xy[i])
        else:
            t, _ = np.linalg.solve(A, p2 - p1)
            out.append(p1 + t * u1)
    p = Polygon(out).buffer(0)
    return p if not p.is_empty and p.geom_type == "Polygon" else poly


def remove_spikes(poly, min_turn_deg: float = 20.0):
    """Drop vertices where the outline doubles back on itself (a zero-width spur) or continues straight."""
    from shapely.geometry import Polygon
    xy = np.array(poly.exterior.coords)[:-1]
    changed = True
    while changed and len(xy) > 4:
        changed = False
        n = len(xy)
        for i in range(n):
            a, b, c = xy[i - 1], xy[i], xy[(i + 1) % n]
            u, v = a - b, c - b
            nu, nv = np.linalg.norm(u), np.linalg.norm(v)
            if nu < 1e-6 or nv < 1e-6:
                xy = np.delete(xy, i, axis=0); changed = True; break
            ang = np.degrees(np.arccos(np.clip(u @ v / (nu * nv), -1, 1)))
            if ang < min_turn_deg or ang > 180 - 3:      # spur, or collinear
                xy = np.delete(xy, i, axis=0); changed = True; break
    p = Polygon(xy).buffer(0)
    return p if not p.is_empty and p.geom_type == "Polygon" else poly


def supported_by_wall(a, b, walls, max_offset=0.35, ang_tol=6.0):
    """True when a detected wall runs along this edge: then the jog is real (a bay window, a step in the fence)."""
    d = b - a
    L = np.linalg.norm(d)
    if L < 1e-6:
        return False
    u = d / L
    n = np.array([-u[1], u[0]])
    for w in walls:
        wd = w[1] - w[0]
        wl = np.linalg.norm(wd)
        wu = wd / max(wl, 1e-9)
        if np.degrees(np.arccos(min(1.0, abs(u @ wu)))) > ang_tol:
            continue
        mid = (a + b) / 2
        off = abs((mid - w[0]) @ np.array([-wu[1], wu[0]]))
        t = (mid - w[0]) @ wu
        if off <= max_offset and -0.3 <= t <= wl + 0.3:
            return True
    return False


def collapse_short_edges(poly, min_edge: float = 0.9, passes: int = 4, walls=()):
    """An architect draws a jog only when it is real: edges shorter than min_edge are absorbed into their neighbours
    (the vertex pair is replaced by the intersection of the surrounding edges' lines), unless a detected wall
    supports the edge."""
    from shapely.geometry import Polygon
    xy = np.array(poly.exterior.coords)[:-1]
    for _ in range(passes):
        n = len(xy)
        if n <= 4:
            break
        L = np.array([np.linalg.norm(xy[(i + 1) % n] - xy[i]) for i in range(n)])
        for k in range(n):
            if supported_by_wall(xy[k], xy[(k + 1) % n], walls):
                L[k] = np.inf
        i = int(np.argmin(L))
        if L[i] >= min_edge:
            break
        a1, b1 = xy[i - 1], xy[i]                    # edge before the short one
        a2, b2 = xy[(i + 1) % n], xy[(i + 2) % n]    # edge after
        u1, u2 = b1 - a1, b2 - a2
        A = np.array([u1, -u2]).T
        if abs(np.linalg.det(A)) < 1e-6:            # parallel neighbours: drop the jog, keep the longer line
            keep = xy[[k for k in range(n) if k not in (i, (i + 1) % n)]]
        else:
            t, _ = np.linalg.solve(A, a2 - a1)
            x = a1 + t * u1
            if np.linalg.norm(x - b1) > 3.0:         # would fly off: leave it
                break
            keep = np.array([x if k == i else xy[k] for k in range(n) if k != (i + 1) % n])
        p = Polygon(keep).buffer(0)
        if p.is_empty or p.geom_type != "Polygon":
            break
        xy = np.array(p.exterior.coords)[:-1]
    return Polygon(xy).buffer(0)


def describe(poly):
    xy = np.array(poly.exterior.coords)
    if len(xy) > 1 and np.allclose(xy[0], xy[-1]):
        xy = xy[:-1]
    lengths = [float(np.linalg.norm(xy[(i + 1) % len(xy)] - xy[i])) for i in range(len(xy))]
    return {"points": [[round(float(x), 3), round(float(y), 3)] for x, y in xy], "lengths": [round(l, 2) for l in lengths],
            "area": round(float(poly.area), 2)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--voxel", type=float, default=0.04)
    ap.add_argument("--cell", type=float, default=0.05)
    ap.add_argument("--zmin", type=float, default=0.25)
    ap.add_argument("--zmax", type=float, default=3.0)
    ap.add_argument("--min-height", type=float, default=0.5, help="vertical extent a cell must span to count as structure (m)")
    ap.add_argument("--inlier", type=float, default=0.06)
    ap.add_argument("--min-len", type=float, default=0.8)
    ap.add_argument("--gap", type=float, default=0.6)
    ap.add_argument("--snap", type=float, default=12.0)
    ap.add_argument("--join", type=float, default=2.5, help="endpoints this close to another line are extended to meet it (m)")
    ap.add_argument("--extend", type=float, default=0.15, help="small extension so met corners overlap when noding (m)")
    ap.add_argument("--min-edge", type=float, default=1.2, help="boundary jogs shorter than this are absorbed (m)")
    ap.add_argument("--out", default="linework.json")
    a = ap.parse_args()
    work = Path(a.work)

    PA, NA = load_points(work / "scene_dense_metric.ply", a.voxel)
    P = vertical_structure(PA, NA, a.zmin, a.zmax, nz_max=0.35)
    print(f"points: {len(PA)}; vertical structure: {len(P)}")
    Q, extent = structure_cells(P, a.cell, a.min_height)
    print(f"structure cells: {len(Q)} (>= {a.min_height} m tall)")
    segs = ransac_lines(Q, a.inlier, a.min_len, a.gap)
    print(f"ransac: {len(segs)} segments")
    axis = dominant_axis(segs)
    segs = merge_collinear(snap(segs, axis, a.snap))
    segs = prune_isolated([s for s in segs if np.linalg.norm(s[1] - s[0]) >= a.min_len])
    segs = merge_collinear(close_corners(segs, a.join), ang_tol=1.0, offset_tol=0.1, gap_tol=0.3)
    print(f"regularized: {len(segs)} segments, axis {axis:.1f}°")
    # the yard boundary: the ground's footprint, simplified, orthogonalised, then snapped onto the detected walls
    foot = ground_footprint(PA)
    boundary = []
    if foot:
        boundary = []
        fams = direction_families(segs, axis)
        aligned_walls = [w for w in segs if any(min(abs((np.degrees(np.arctan2(*(w[1] - w[0])[::-1])) % 180) - f) % 180,
                                                        180 - abs((np.degrees(np.arctan2(*(w[1] - w[0])[::-1])) % 180) - f) % 180) < 3 for f in fams)]
        for p in foot[:3]:
            p = p.simplify(0.6)
            for _ in range(2):                            # regularise, absorb jogs, regularise again
                p = regularize_polygon(p, fams)
                p = remove_spikes(collapse_short_edges(p, a.min_edge, passes=10, walls=aligned_walls))
            p = snap_polygon_to_walls(p, aligned_walls, max_offset=0.8)
            p = regularize_polygon(p, fams)
            p = remove_spikes(collapse_short_edges(p, a.min_edge, passes=6, walls=aligned_walls))
            p = regularize_polygon(p, fams)
            if p.geom_type == "Polygon" and not p.is_empty:
                boundary.append(p)
        print(f"boundary directions: {[round(float(f), 1) for f in fams]}")
    # enclosures the walls close by themselves (a shed, a raised bed)
    faces = polygonize(segs, a.extend, min_area=3.0)
    faces.sort(key=lambda p: -p.area)
    enclosures = regularize(faces, axis)
    polys = boundary + [p for p in enclosures if not any(p.equals(b) for b in boundary)]
    rounded = [[[round(float(p[0]), 3), round(float(p[1]), 3)] for p in s] for s in segs]
    json.dump({"axis_deg": round(axis, 2), "walls": rounded, "edges": [],
               "polygons": [describe(p) for p in polys]}, open(work / a.out, "w"))
    print(f"boundary: {len(boundary)} polygon(s)" + (f", largest {boundary[0].area:.1f} m² with {len(boundary[0].exterior.coords) - 1} sides" if boundary else "")
          + f"; enclosures from walls: {len(enclosures)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
