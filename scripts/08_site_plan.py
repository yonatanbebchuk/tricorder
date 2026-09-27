#!/usr/bin/env python3
"""The site plan proper: DEM, contour lines, footprint, DXF, PDF sheet, world file, app overlay.

Inputs in <work>:  transform.json (scale/level/north), scene_dense_metric.ply (metres, Z up, north +Y),
                   orthomosaic.png + orthomosaic.json (05_site_plan_blender.py), measure/constraints.json
Outputs in <work>: dem.tif + dem.json          32-bit heights on a regular grid (metres), NaN where nothing was seen
                   contours.json               polylines per level, metres
                   footprint.json              outline(s) of the surveyed area, metres
                   orthomosaic.pgw             ESRI world file so CAD / GIS place the image at true scale
                   site_plan.dxf               layers ORTHO, GRID, CONTOURS, FOOTPRINT, MEASURE, NORTH, SCALEBAR, TITLE
                   site_plan.pdf               a sheet at 1:100 (or the largest of 1:50/100/200/500 that fits A2)
                   overlay.json                what the app draws over the orthomosaic

Usage: python scripts/08_site_plan.py <work> [--contour 0.25] [--cell 0.05] [--scale 100] [--title "Backyard"]
"""
import argparse
import json
import sys
from datetime import date
from pathlib import Path

import cv2
import numpy as np

A2 = (594.0, 420.0)           # mm; the sheet turns portrait for sites taller than wide
MARGIN = 15.0                 # mm
TITLE_H = 32.0                # mm


# ---------------------------------------------------------------- DEM

def build_dem(cloud: Path, cell: float):
    import open3d as o3d
    pcd = o3d.io.read_point_cloud(str(cloud))
    P = np.asarray(pcd.points, dtype=np.float32)
    del pcd
    if len(P) == 0:
        sys.exit("empty metric cloud")
    z_hi = np.percentile(P[:, 2], 99.7)                       # drop flying outliers
    P = P[P[:, 2] <= z_hi]
    x0, y0 = np.floor(P[:, 0].min() / cell) * cell, np.floor(P[:, 1].min() / cell) * cell
    x1, y1 = np.ceil(P[:, 0].max() / cell) * cell, np.ceil(P[:, 1].max() / cell) * cell
    W, H = int(round((x1 - x0) / cell)), int(round((y1 - y0) / cell))
    ix = np.clip(((P[:, 0] - x0) / cell).astype(np.int64), 0, W - 1)
    iy = np.clip(((y1 - P[:, 1]) / cell).astype(np.int64), 0, H - 1)      # row 0 = north edge (y1)
    dem = np.full((H, W), -np.inf, dtype=np.float32)
    np.maximum.at(dem, (iy, ix), P[:, 2])
    count = np.zeros((H, W), dtype=np.int32)
    np.add.at(count, (iy, ix), 1)
    dem[count < 2] = np.nan
    # smooth the surface a little (tape-measure plans, not survey grade): median then gaussian, ignoring holes
    valid = np.isfinite(dem)
    filled = np.where(valid, dem, 0).astype(np.float32)
    weight = valid.astype(np.float32)
    k = max(3, int(round(0.3 / cell)) | 1)
    num = cv2.GaussianBlur(filled, (k, k), 0)
    den = cv2.GaussianBlur(weight, (k, k), 0)
    smooth = np.where(den > 0.2, num / np.maximum(den, 1e-6), np.nan).astype(np.float32)
    smooth[~valid] = np.nan
    meta = {"x_min": float(x0), "y_max": float(y1), "cell": cell, "width": W, "height": H,
            "z_min": float(np.nanmin(smooth)), "z_max": float(np.nanmax(smooth))}
    return smooth, meta


def grid_to_world(pts, meta):
    """(col, row) pixel centres -> (x, y) metres."""
    c = meta["cell"]
    return [[meta["x_min"] + (p[0] + 0.5) * c, meta["y_max"] - (p[1] + 0.5) * c] for p in pts]


def contours(dem, meta, interval: float):
    import contourpy
    z = np.ma.masked_invalid(dem)
    gen = contourpy.contour_generator(z=z, name="serial", corner_mask=True, line_type=contourpy.LineType.Separate)
    lo, hi = np.floor(meta["z_min"] / interval) * interval, np.ceil(meta["z_max"] / interval) * interval
    out = []
    for level in np.arange(lo, hi + interval / 2, interval):
        for line in gen.lines(float(level)):
            if len(line) < 8:
                continue
            pts = grid_to_world(line, meta)
            out.append({"level": round(float(level), 3), "index": bool(abs(level / (interval * 4) - round(level / (interval * 4))) < 1e-6),
                        "points": [[round(x, 3), round(y, 3)] for x, y in pts]})
    return out


def footprint(dem, meta):
    valid = np.isfinite(dem).astype(np.uint8)
    k = max(3, int(round(0.6 / meta["cell"])) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    m = cv2.morphologyEx(valid, cv2.MORPH_CLOSE, kernel)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, kernel)
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    polys = []
    min_area = 1.0 / meta["cell"] ** 2                      # 1 m²
    for cnt in cnts:
        if cv2.contourArea(cnt) < min_area:
            continue
        cnt = cv2.approxPolyDP(cnt, 0.05 / meta["cell"], True)
        pts = grid_to_world(cnt.reshape(-1, 2), meta)
        polys.append([[round(x, 3), round(y, 3)] for x, y in pts])
    return sorted(polys, key=len, reverse=True)


# ---------------------------------------------------------------- measurements in plan coordinates

def plan_measurements(work: Path, T: np.ndarray):
    cpath = work / "measure" / "constraints.json"
    if not cpath.exists():
        return []
    c = json.load(open(cpath))
    out = []
    for d in c.get("distances", []):
        try:
            a = T @ np.array([*d["a"], 1.0]); b = T @ np.array([*d["b"], 1.0])
        except (KeyError, TypeError):
            continue
        out.append({"id": d.get("id", ""), "source": d.get("source", "prompt"), "meters": float(d["meters"]),
                    "a": [round(float(a[0]), 3), round(float(a[1]), 3)], "b": [round(float(b[0]), 3), round(float(b[1]), 3)],
                    "za": round(float(a[2]), 3), "zb": round(float(b[2]), 3)})
    return out


# ---------------------------------------------------------------- DXF

def write_dxf(path: Path, ortho: dict, cont, foot, meas, title: str, sub: str):
    import ezdxf
    doc = ezdxf.new("R2010", setup=True)
    doc.header["$INSUNITS"] = 6                             # metres
    for name, color in (("ORTHO", 8), ("GRID", 253), ("GRID_MAJOR", 251), ("CONTOURS", 32), ("CONTOURS_INDEX", 30),
                        ("FOOTPRINT", 4), ("MEASURE", 1), ("NORTH", 7), ("SCALEBAR", 7), ("TITLE", 7)):
        doc.layers.add(name, color=color)
    msp = doc.modelspace()
    x0, y1, w, h = ortho["x_min"], ortho["y_max"], ortho["width_m"], ortho["height_m"]
    y0, x1 = y1 - h, x0 + w
    img = doc.add_image_def(filename="orthomosaic.png", size_in_pixel=(ortho["width_px"], ortho["height_px"]))
    msp.add_image(image_def=img, insert=(x0, y0), size_in_units=(w, h), rotation=0, dxfattribs={"layer": "ORTHO"})
    for gx in np.arange(np.ceil(x0), x1, 1.0):
        major = abs(gx % 5) < 1e-6
        msp.add_line((gx, y0), (gx, y1), dxfattribs={"layer": "GRID_MAJOR" if major else "GRID"})
        if major:
            msp.add_text(f"{gx:.0f}", height=0.25, dxfattribs={"layer": "GRID_MAJOR"}).set_placement((gx + 0.05, y1 + 0.1))
    for gy in np.arange(np.ceil(y0), y1, 1.0):
        major = abs(gy % 5) < 1e-6
        msp.add_line((x0, gy), (x1, gy), dxfattribs={"layer": "GRID_MAJOR" if major else "GRID"})
        if major:
            msp.add_text(f"{gy:.0f}", height=0.25, dxfattribs={"layer": "GRID_MAJOR"}).set_placement((x1 + 0.1, gy + 0.05))
    for c in cont:
        layer = "CONTOURS_INDEX" if c["index"] else "CONTOURS"
        msp.add_lwpolyline(c["points"], dxfattribs={"layer": layer, "elevation": c["level"]})
        if c["index"] and len(c["points"]) > 80:
            mx, my = c["points"][len(c["points"]) // 2]
            msp.add_text(f"{c['level']:.2f}", height=0.18, dxfattribs={"layer": layer}).set_placement((mx, my))
    for poly in foot:
        msp.add_lwpolyline(poly, close=True, dxfattribs={"layer": "FOOTPRINT", "linetype": "DASHED"})
    for m in meas:
        dim = msp.add_aligned_dim(p1=tuple(m["a"]), p2=tuple(m["b"]), distance=0.4, text=f"{m['meters']:.2f} m",
                                  dxfattribs={"layer": "MEASURE"})
        dim.render()
    # north arrow (top right, outside the image)
    nx, ny = x1 + 1.0, y1 - 0.5
    msp.add_lwpolyline([(nx, ny - 2.0), (nx, ny)], dxfattribs={"layer": "NORTH"})
    msp.add_lwpolyline([(nx - 0.35, ny - 0.7), (nx, ny), (nx + 0.35, ny - 0.7)], close=True, dxfattribs={"layer": "NORTH"})
    msp.add_text("N", height=0.5, dxfattribs={"layer": "NORTH"}).set_placement((nx - 0.18, ny + 0.2))
    # scale bar (bottom left, outside the image): 0 .. 5 m
    sx, sy = x0, y0 - 1.2
    for i in range(5):
        msp.add_lwpolyline([(sx + i, sy), (sx + i + 1, sy), (sx + i + 1, sy + 0.25), (sx + i, sy + 0.25)], close=True,
                           dxfattribs={"layer": "SCALEBAR", "color": 7 if i % 2 == 0 else 250})
        msp.add_text(f"{i}", height=0.25, dxfattribs={"layer": "SCALEBAR"}).set_placement((sx + i - 0.07, sy - 0.4))
    msp.add_text("5 m", height=0.25, dxfattribs={"layer": "SCALEBAR"}).set_placement((sx + 4.85, sy - 0.4))
    msp.add_text(title, height=0.6, dxfattribs={"layer": "TITLE"}).set_placement((sx + 7, sy - 0.15))
    msp.add_text(sub, height=0.25, dxfattribs={"layer": "TITLE"}).set_placement((sx + 7, sy - 0.65))
    doc.saveas(path)


# ---------------------------------------------------------------- PDF

def write_pdf(path: Path, ortho_png: Path, ortho: dict, cont, foot, meas, title: str, sub: str, wanted_scale: int):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon

    x0, y1, w, h = ortho["x_min"], ortho["y_max"], ortho["width_m"], ortho["height_m"]
    y0, x1 = y1 - h, x0 + w
    A2 = (594.0, 420.0) if w >= h else (420.0, 594.0)     # landscape or portrait, whichever suits the site
    avail_w, avail_h = A2[0] - 2 * MARGIN - 20, A2[1] - 2 * MARGIN - TITLE_H
    scale = next((s for s in sorted({wanted_scale, 50, 100, 200, 500, 1000}) if s >= wanted_scale
                  and (w + 3) * 1000 / s <= avail_w and (h + 3) * 1000 / s <= avail_h), 1000)
    mm = 1000.0 / scale                                     # mm on paper per metre
    fig = plt.figure(figsize=(A2[0] / 25.4, A2[1] / 25.4))
    aw, ah = (w + 3) * mm / A2[0], (h + 3) * mm / A2[1]
    # centre the drawing in the area above the title block
    left = (MARGIN + (avail_w - (w + 3) * mm) / 2) / A2[0]
    bottom = (MARGIN + TITLE_H + (avail_h - (h + 3) * mm) / 2) / A2[1]
    ax = fig.add_axes([left, bottom, aw, ah])
    ax.set_xlim(x0 - 1.5, x1 + 1.5); ax.set_ylim(y0 - 1.5, y1 + 1.5); ax.set_aspect("equal"); ax.axis("off")
    im = plt.imread(str(ortho_png))
    ax.imshow(im, extent=[x0, x1, y0, y1], interpolation="bilinear", zorder=0)
    for gx in np.arange(np.ceil(x0), x1, 1.0):
        major = abs(gx % 5) < 1e-6
        ax.plot([gx, gx], [y0, y1], color="#66655c" if major else "#b0aea5", lw=0.5 if major else 0.25, alpha=0.7, zorder=1)
        if major:
            ax.text(gx, y1 + 0.15, f"{gx:.0f}", fontsize=5, ha="center", color="#66655c")
    for gy in np.arange(np.ceil(y0), y1, 1.0):
        major = abs(gy % 5) < 1e-6
        ax.plot([x0, x1], [gy, gy], color="#66655c" if major else "#b0aea5", lw=0.5 if major else 0.25, alpha=0.7, zorder=1)
        if major:
            ax.text(x1 + 0.15, gy, f"{gy:.0f}", fontsize=5, va="center", color="#66655c")
    for c in cont:
        P = np.array(c["points"])
        ax.plot(P[:, 0], P[:, 1], color="#8a5a2b", lw=0.6 if c["index"] else 0.3, zorder=2)
        if c["index"] and len(P) > 80:
            mx, my = P[len(P) // 2]
            ax.text(mx, my, f"{c['level']:.2f}", fontsize=4, color="#8a5a2b", ha="center", va="center",
                    bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.7), zorder=3)
    for poly in foot:
        ax.add_patch(Polygon(poly, closed=True, fill=False, ls="--", lw=0.6, ec="#2a6f97", zorder=2))
    for m in meas:
        (ax_, ay_), (bx_, by_) = m["a"], m["b"]
        ax.plot([ax_, bx_], [ay_, by_], color="#d97757", lw=1.0, zorder=4)
        ax.plot([ax_, bx_], [ay_, by_], "o", color="#d97757", ms=2, zorder=4)
        ax.text((ax_ + bx_) / 2, (ay_ + by_) / 2, f"{m['meters']:.2f} m", fontsize=6, color="#d97757", ha="center", va="bottom",
                bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.8), zorder=5)
    # north arrow and scale bar in figure coordinates (mm)
    fx = lambda x_mm: x_mm / A2[0]
    fy = lambda y_mm: y_mm / A2[1]
    fig.text(fx(A2[0] - MARGIN - 6), fy(A2[1] - MARGIN - 4), "N", ha="center", va="top", fontsize=11, fontweight="bold")
    fig.patches.append(plt.Polygon([[fx(A2[0] - MARGIN - 6), fy(A2[1] - MARGIN - 9)], [fx(A2[0] - MARGIN - 8.5), fy(A2[1] - MARGIN - 19)],
                                    [fx(A2[0] - MARGIN - 3.5), fy(A2[1] - MARGIN - 19)]], closed=True, transform=fig.transFigure, fc="black"))
    bx, by = MARGIN, MARGIN + TITLE_H - 8
    for i in range(5):
        fig.patches.append(plt.Rectangle((fx(bx + i * mm), fy(by)), fx(mm), fy(2), transform=fig.transFigure,
                                         fc="black" if i % 2 == 0 else "white", ec="black", lw=0.5))
        fig.text(fx(bx + i * mm), fy(by - 1), f"{i}", ha="center", va="top", fontsize=6)
    fig.text(fx(bx + 5 * mm), fy(by - 1), "5 m", ha="center", va="top", fontsize=6)
    fig.text(fx(MARGIN), fy(MARGIN + 12), title, fontsize=16, fontweight="bold", va="bottom", family="serif")
    fig.text(fx(MARGIN), fy(MARGIN + 4), f"{sub}  ·  scale 1:{scale} on A2 {'landscape' if A2[0] > A2[1] else 'portrait'}  ·  contours every {CONTOUR_INTERVAL} m  ·  grid 1 m  ·  north up",
             fontsize=7, va="bottom", color="#66655c")
    fig.savefig(str(path), format="pdf")
    plt.close(fig)
    return scale


CONTOUR_INTERVAL = 0.25


def main() -> int:
    global CONTOUR_INTERVAL
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work")
    ap.add_argument("--contour", type=float, default=0.25, help="contour interval in metres")
    ap.add_argument("--cell", type=float, default=0.05, help="DEM cell size in metres")
    ap.add_argument("--scale", type=int, default=100, help="wanted sheet scale 1:N (auto-reduced if it does not fit A2)")
    ap.add_argument("--title", default="Site plan")
    ap.add_argument("--subtitle", default="")
    a = ap.parse_args()
    CONTOUR_INTERVAL = a.contour
    work = Path(a.work)
    T = np.array(json.load(open(work / "transform.json"))["matrix"])
    ortho = json.load(open(work / "orthomosaic.json"))

    dem, meta = build_dem(work / "scene_dense_metric.ply", a.cell)
    cv2.imwrite(str(work / "dem.tif"), np.where(np.isfinite(dem), dem, -9999).astype(np.float32))
    json.dump({**meta, "nodata": -9999}, open(work / "dem.json", "w"), indent=2)
    cont = contours(dem, meta, a.contour)
    foot = footprint(dem, meta)
    meas = plan_measurements(work, T)
    json.dump({"interval": a.contour, "lines": cont}, open(work / "contours.json", "w"))
    json.dump({"polygons": foot}, open(work / "footprint.json", "w"))
    ppm = ortho["px_per_m"]
    (work / "orthomosaic.pgw").write_text(f"{1 / ppm:.8f}\n0\n0\n{-1 / ppm:.8f}\n{ortho['x_min'] + 0.5 / ppm:.6f}\n{ortho['y_max'] - 0.5 / ppm:.6f}\n")
    sub = a.subtitle or f"existing conditions · {date.today().isoformat()}"
    write_dxf(work / "site_plan.dxf", ortho, cont, foot, meas, a.title, sub)
    scale = write_pdf(work / "site_plan.pdf", work / "orthomosaic.png", ortho, cont, foot, meas, a.title, sub, a.scale)
    json.dump({"px_per_m": ppm, "x_min": ortho["x_min"], "y_max": ortho["y_max"], "width_px": ortho["width_px"], "height_px": ortho["height_px"],
               "width_m": ortho["width_m"], "height_m": ortho["height_m"], "contour_interval": a.contour, "sheet_scale": scale,
               "contours": cont, "footprint": foot, "measurements": meas}, open(work / "overlay.json", "w"))
    print(f"site plan: {len(cont)} contour lines every {a.contour} m, {len(foot)} footprint polygon(s), {len(meas)} measurements, "
          f"DEM {meta['width']}x{meta['height']} @ {a.cell} m, sheet 1:{scale}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
