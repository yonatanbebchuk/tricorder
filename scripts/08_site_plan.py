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

ELEMENT_LAYERS = {"wall": ("WALLS_MARKED", 7), "fence": ("FENCES", 34), "window": ("WINDOWS", 5), "door": ("DOORS", 30), "stairs": ("STAIRS", 6),
                  "tree": ("TREES", 3), "bush": ("PLANTING", 3), "object": ("OBJECTS", 1), "area": ("AREAS", 8)}


def element_layer(el: dict) -> str:
    if el.get("cls") == "area":
        return f"AREA_{(el.get('material') or 'other').upper()}"
    return ELEMENT_LAYERS.get(el.get("cls", "object"), ("OBJECTS", 1))[0]


def write_dxf(path: Path, ortho: dict, cont, foot, meas, title: str, sub: str, linework: dict | None = None, elements: dict | None = None):
    import ezdxf
    doc = ezdxf.new("R2010", setup=True)
    doc.header["$INSUNITS"] = 6                             # metres
    for name, color in (("ORTHO", 8), ("GRID", 253), ("GRID_MAJOR", 251), ("CONTOURS", 32), ("CONTOURS_INDEX", 30),
                        ("FOOTPRINT", 4), ("WALLS", 7), ("EDGES", 8), ("BOUNDARY", 7), ("BOUNDARY_WALL", 7), ("BOUNDARY_FENCE", 34),
                        ("BOUNDARY_ALT", 8), ("ENCLOSURES", 7), ("DIMENSIONS", 3), ("OPENINGS", 5), ("LANDUSE", 8),
                        ("MEASURE", 1), ("NORTH", 7), ("SCALEBAR", 7), ("TITLE", 7), ("LABELS", 7), ("LEGEND", 7)):
        doc.layers.add(name, color=color)
    doc.layers.get("BOUNDARY_ALT").off()
    for _, (name, color) in ELEMENT_LAYERS.items():
        if name not in doc.layers:
            doc.layers.add(name, color=color)
    msp = doc.modelspace()
    x0, y1, w, h = ortho["x_min"], ortho["y_max"], ortho["width_m"], ortho["height_m"]
    for el in (elements or {}).get("elements", []):
        if el.get("minor"):                                   # small or unsure generated entities: not on the drawing
            continue
        layer = element_layer(el)
        if layer not in doc.layers:
            doc.layers.add(layer, color=8)
        pts = el.get("points") or []
        if el.get("shape") == "polygon" and len(pts) >= 3:
            msp.add_lwpolyline(pts, close=True, dxfattribs={"layer": layer, "const_width": 0.03 if el["cls"] == "area" else 0.04})
            if el["cls"] == "area":
                try:
                    hatch = msp.add_hatch(color=254, dxfattribs={"layer": layer})
                    hatch.set_pattern_fill("ANSI31" if el.get("material") in ("brick", "tiles", "stone") else "DOTS" if el.get("material") in ("sand", "gravel", "soil", "garden") else "GRASS", scale=0.5)
                    hatch.paths.add_polyline_path(pts, is_closed=True)
                except Exception:
                    pass
        elif len(pts) >= 2:
            msp.add_lwpolyline(pts, dxfattribs={"layer": layer, "const_width": 0.06 if el["cls"] in ("wall", "fence") else 0.03})
        elif len(pts) == 1:
            msp.add_circle(tuple(pts[0]), 0.25, dxfattribs={"layer": layer})
        if pts:
            c = np.mean(np.array(pts), axis=0)
            label = el.get("name") or el.get("cls", "")
            if el.get("area_m2"):
                label += f" {el['area_m2']:.1f} m²"
            elif el.get("length_m") and el["cls"] in ("wall", "fence"):
                label += f" {el['length_m']:.2f} m"
            msp.add_text(label, height=0.22, dxfattribs={"layer": "LABELS"}).set_placement((c[0], c[1]), align=ezdxf.enums.TextEntityAlignment.MIDDLE_CENTER)
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
    for seg in (linework or {}).get("walls", []):
        msp.add_lwpolyline(seg, dxfattribs={"layer": "WALLS", "const_width": 0.05})
    for seg in (linework or {}).get("edges", []):
        msp.add_lwpolyline(seg, dxfattribs={"layer": "EDGES"})
    structure = (elements or {})
    chosen = structure.get("boundaries", {}).get(structure.get("boundary_source", ""))
    for k, poly in enumerate((linework or {}).get("polygons", [])):
        pts = poly["points"]
        if k == 0 and chosen:
            # the boundary edge by edge, each in its class (wall / fence / unknown); the other traced boundary on a layer that is off
            for e in chosen["edges"]:
                layer = {"wall": "BOUNDARY_WALL", "fence": "BOUNDARY_FENCE"}.get(e["cls"], "BOUNDARY")
                msp.add_lwpolyline([e["a"], e["b"]], dxfattribs={"layer": layer, "const_width": 0.1 if e["cls"] == "wall" else 0.05})
            for src, b in structure.get("boundaries", {}).items():
                if src != structure.get("boundary_source"):
                    msp.add_lwpolyline(b["points"], close=True, dxfattribs={"layer": "BOUNDARY_ALT", "linetype": "DASHED"})
            for op in chosen.get("openings", []):
                a_, b_ = np.array(op["a"]), np.array(op["b"])
                d = b_ - a_
                L_ = max(np.linalg.norm(d), 1e-9)
                nrm = np.array([-d[1], d[0]]) / L_ * op.get("swing", 1)
                if op["cls"] == "window":
                    for off in (-0.08, 0.08):
                        msp.add_lwpolyline([tuple(a_ + nrm * off), tuple(b_ + nrm * off)], dxfattribs={"layer": "OPENINGS"})
                    msp.add_lwpolyline([tuple(a_ - nrm * 0.08), tuple(a_ + nrm * 0.08)], dxfattribs={"layer": "OPENINGS"})
                    msp.add_lwpolyline([tuple(b_ - nrm * 0.08), tuple(b_ + nrm * 0.08)], dxfattribs={"layer": "OPENINGS"})
                else:
                    leaf = a_ + nrm * L_
                    msp.add_lwpolyline([tuple(a_), tuple(leaf)], dxfattribs={"layer": "OPENINGS"})
                    import math
                    ang0 = math.degrees(math.atan2(nrm[1], nrm[0])); ang1 = math.degrees(math.atan2(d[1], d[0]))
                    msp.add_arc(center=tuple(a_), radius=L_, start_angle=min(ang0, ang1), end_angle=max(ang0, ang1), dxfattribs={"layer": "OPENINGS"})
        else:
            msp.add_lwpolyline(pts, close=True, dxfattribs={"layer": "BOUNDARY" if k == 0 else "ENCLOSURES", "const_width": 0.08 if k == 0 else 0.04})
        for i, L in enumerate(poly["lengths"]):
            if L < 0.5:
                continue
            p1, p2 = pts[i], pts[(i + 1) % len(pts)]
            dim = msp.add_aligned_dim(p1=tuple(p1), p2=tuple(p2), distance=-0.6 if k == 0 else 0.35, text=f"{L:.2f} m",
                                      dxfattribs={"layer": "DIMENSIONS"})
            dim.render()
    if "PARTITION" not in doc.layers:
        doc.layers.add("PARTITION", color=7)
    for lu in structure.get("landuse", []):
        if lu["material"] == "unassigned":
            continue
        for part in lu["polygons"]:
            pts_ = part["exterior"]
            msp.add_lwpolyline(pts_, close=True, dxfattribs={"layer": "PARTITION", "const_width": 0.04})
            for i in range(len(pts_)):
                p1, p2 = pts_[i], pts_[(i + 1) % len(pts_)]
                L_ = float(np.hypot(p2[0] - p1[0], p2[1] - p1[1]))
                if L_ < 0.5:
                    continue
                dim = msp.add_aligned_dim(p1=tuple(p1), p2=tuple(p2), distance=0.3, text=f"{L_:.2f} m", dxfattribs={"layer": "DIMENSIONS"})
                dim.render()
            c_ = np.mean(np.array(pts_), axis=0)
            msp.add_text(f"{lu['name'].upper()} {lu['area_m2']:.1f} m²", height=0.25, dxfattribs={"layer": "LABELS"}).set_placement((c_[0], c_[1]), align=ezdxf.enums.TextEntityAlignment.MIDDLE_CENTER)
    for lu in structure.get("landuse", []):
        for part in lu["polygons"]:
            try:
                hatch = msp.add_hatch(color=254, dxfattribs={"layer": "LANDUSE"})
                mat = lu["material"]
                pattern = "ANSI31" if mat in ("brick", "tiles", "stone", "concrete", "asphalt") else "DOTS" if mat in ("sand", "gravel", "soil", "garden") else "GRASS" if mat == "grass" else "ANSI37"
                if mat == "unassigned":
                    continue
                hatch.set_pattern_fill(pattern, scale=0.6)
                hatch.paths.add_polyline_path(part["exterior"], is_closed=True, flags=1)
                for h in part["holes"]:
                    hatch.paths.add_polyline_path(h, is_closed=True, flags=16)
            except Exception:
                pass
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
    # legend and quantities, to the right of the drawing
    q = (elements or {}).get("quantities") or {}
    if q:
        lx, ly = x0 + w + 1.5, y1
        msp.add_text("QUANTITIES", height=0.35, dxfattribs={"layer": "LEGEND"}).set_placement((lx, ly))
        row = 0
        for mat, area in sorted(q.get("areas", {}).items(), key=lambda kv: -kv[1]):
            row += 1
            msp.add_text(f"{mat}: {area:.1f} m²", height=0.25, dxfattribs={"layer": "LEGEND"}).set_placement((lx, ly - 0.5 * row))
        for cls, length in q.get("lengths", {}).items():
            row += 1
            msp.add_text(f"{cls}: {length:.1f} m", height=0.25, dxfattribs={"layer": "LEGEND"}).set_placement((lx, ly - 0.5 * row))
        for cls, n in sorted(q.get("counts", {}).items()):
            if cls in ("area", "wall", "fence"):
                continue
            row += 1
            msp.add_text(f"{cls}: {n}", height=0.25, dxfattribs={"layer": "LEGEND"}).set_placement((lx, ly - 0.5 * row))
    doc.saveas(path)


# ---------------------------------------------------------------- PDF

def write_pdf(path: Path, ortho_png: Path, ortho: dict, cont, foot, meas, title: str, sub: str, wanted_scale: int, linework: dict | None = None,
              elements: dict | None = None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.backends.backend_pdf import PdfPages
    from matplotlib.patches import Polygon

    x0, y1, w, h = ortho["x_min"], ortho["y_max"], ortho["width_m"], ortho["height_m"]
    y0, x1 = y1 - h, x0 + w
    A2 = (594.0, 420.0) if w >= h else (420.0, 594.0)     # landscape or portrait, whichever suits the site
    avail_w, avail_h = A2[0] - 2 * MARGIN - 20, A2[1] - 2 * MARGIN - TITLE_H
    scale = next((s for s in sorted({wanted_scale, 50, 100, 200, 500, 1000}) if s >= wanted_scale
                  and (w + 3) * 1000 / s <= avail_w and (h + 3) * 1000 / s <= avail_h), 1000)
    mm = 1000.0 / scale                                     # mm on paper per metre
    pdf = PdfPages(str(path))
    for n, page in enumerate(("ortho", "lines", "inner")):
        if page == "lines" and not linework:
            continue
        if page == "inner" and not (elements or {}).get("landuse"):
            continue
        fig = plt.figure(figsize=(A2[0] / 25.4, A2[1] / 25.4))
        aw, ah = (w + 3) * mm / A2[0], (h + 3) * mm / A2[1]
        # centre the drawing in the area above the title block
        left = (MARGIN + (avail_w - (w + 3) * mm) / 2) / A2[0]
        bottom = (MARGIN + TITLE_H + (avail_h - (h + 3) * mm) / 2) / A2[1]
        ax = fig.add_axes([left, bottom, aw, ah])
        ax.set_xlim(x0 - 1.5, x1 + 1.5); ax.set_ylim(y0 - 1.5, y1 + 1.5); ax.set_aspect("equal"); ax.axis("off")
        draw_page(fig, ax, page, ortho_png, ortho, cont, foot, meas, linework, title, sub, scale, mm, A2, elements)
        pdf.savefig(fig)
        fig.savefig(str(path.with_name(f"site_plan_page{n + 1}.png")), dpi=60)   # the sheet as a picture (app previews)
        plt.close(fig)
    pdf.close()
    return scale


def draw_elements(ax, elements: dict | None, page: str) -> None:
    """Named elements. The ortho page shows everything that is not minor; the line drawing shows your marks (as outlines)
    and the planting the inventory found, so the drawing stays a drawing."""
    from matplotlib.patches import Polygon
    for el in (elements or {}).get("elements", []):
        if el.get("minor"):
            continue
        if page == "lines" and el.get("source") != "mark" and el.get("cls") not in ("tree", "bush", "stairs"):
            continue
        pts = np.array(el.get("points") or [])
        if len(pts) == 0:
            continue
        col = el.get("color", "#d97757")
        if el.get("shape") == "polygon" and len(pts) >= 3:
            ax.add_patch(Polygon(pts, closed=True, fill=page == "ortho" and el.get("cls") != "area", fc=col, alpha=0.35, ec=col, lw=1.1 if page == "lines" else 0.9, zorder=3))
        elif len(pts) >= 2:
            ax.plot(pts[:, 0], pts[:, 1], color=col, lw=1.8 if el["cls"] in ("wall", "fence") else 1.0, solid_capstyle="round", zorder=3)
        else:
            ax.plot(pts[0, 0], pts[0, 1], "o", color=col, ms=4, zorder=3)
        c = pts.mean(axis=0)
        label = el.get("name") or el.get("cls", "")
        if el.get("area_m2") and el["cls"] == "area":
            label += f"\n{el['area_m2']:.1f} m²"
        ax.text(c[0], c[1], label, fontsize=5.5, ha="center", va="center", color="#222", zorder=6,
                bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))


def draw_boundary_structure(ax, elements, page):
    """The chosen boundary edge by edge (wall thick, fence thin with ticks, unknown plain) and its windows and doors."""
    structure = elements or {}
    chosen = structure.get("boundaries", {}).get(structure.get("boundary_source", ""))
    if not chosen:
        return
    for e in chosen["edges"]:
        a, b = np.array(e["a"]), np.array(e["b"])
        if e["cls"] == "wall":
            ax.plot([a[0], b[0]], [a[1], b[1]], color="black", lw=2.6, solid_capstyle="butt", zorder=4)
        elif e["cls"] == "fence":
            ax.plot([a[0], b[0]], [a[1], b[1]], color="black", lw=1.0, zorder=4)
            d = b - a; L = max(np.linalg.norm(d), 1e-9); u = d / L; nrm = np.array([-u[1], u[0]])
            for t in np.arange(0.25, L, 0.5):
                p = a + u * t
                ax.plot([p[0] - nrm[0] * 0.12, p[0] + nrm[0] * 0.12], [p[1] - nrm[1] * 0.12, p[1] + nrm[1] * 0.12], color="black", lw=0.7, zorder=4)
        else:
            ax.plot([a[0], b[0]], [a[1], b[1]], color="black", lw=1.6, ls=(0, (6, 2)), zorder=4)
    for op in chosen.get("openings", []):
        a, b = np.array(op["a"]), np.array(op["b"])
        d = b - a; L = max(np.linalg.norm(d), 1e-9); nrm = np.array([-d[1], d[0]]) / L * op.get("swing", 1)
        if op["cls"] == "window":
            ax.plot([a[0], b[0]], [a[1], b[1]], color="white", lw=2.6, zorder=5)
            for off in (-0.08, 0.08):
                ax.plot([a[0] + nrm[0] * off, b[0] + nrm[0] * off], [a[1] + nrm[1] * off, b[1] + nrm[1] * off], color="black", lw=0.8, zorder=6)
        else:
            ax.plot([a[0], b[0]], [a[1], b[1]], color="white", lw=3.2, zorder=5)
            leaf = a + nrm * L
            ax.plot([a[0], leaf[0]], [a[1], leaf[1]], color="black", lw=0.8, zorder=6)
            ang = np.linspace(np.arctan2(nrm[1], nrm[0]), np.arctan2(d[1], d[0]), 24)
            if abs(ang[-1] - ang[0]) > np.pi:
                ang = np.linspace(np.arctan2(nrm[1], nrm[0]), np.arctan2(d[1], d[0]) + (2 * np.pi if ang[-1] < ang[0] else -2 * np.pi), 24)
            ax.plot(a[0] + L * np.cos(ang), a[1] + L * np.sin(ang), color="black", lw=0.5, zorder=6)
        if page != "ortho":
            ax.text((a[0] + b[0]) / 2 + nrm[0] * 0.3, (a[1] + b[1]) / 2 + nrm[1] * 0.3, op["name"], fontsize=4.5, ha="center", va="center", color="#333", zorder=6)


def draw_inner(ax, elements):
    """The partition of the ground (your areas, clipped into the boundary) as the same black line, each side that is not
    the boundary dimensioned, each area named with its square metres. No colour: a line drawing."""
    from shapely.geometry import LineString, Point
    structure = elements or {}
    chosen = structure.get("boundaries", {}).get(structure.get("boundary_source", ""))
    ring = LineString(chosen["points"] + chosen["points"][:1]) if chosen else None

    def on_boundary(a, b):
        if ring is None:
            return False
        mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
        return all(ring.distance(Point(q)) < 0.12 for q in (a, b, mid))

    for lu in structure.get("landuse", []):
        if lu["material"] == "unassigned":
            continue
        for part in lu["polygons"]:
            ext = part["exterior"]
            n = len(ext)
            c = np.mean(np.array(ext), axis=0)
            for i in range(n):
                a, b = np.array(ext[i]), np.array(ext[(i + 1) % n])
                if on_boundary(a, b):
                    continue
                ax.plot([a[0], b[0]], [a[1], b[1]], color="black", lw=1.1, solid_capstyle="round", zorder=4)
                L = float(np.linalg.norm(b - a))
                if L < 0.5:
                    continue
                d = (b - a) / L
                nrm = np.array([-d[1], d[0]])
                if np.dot(c - a, nrm) < 0:
                    nrm = -nrm
                mid = (a + b) / 2 + nrm * 0.35
                ang = np.degrees(np.arctan2(d[1], d[0]))
                if ang > 90 or ang < -90:
                    ang += 180
                ax.text(mid[0], mid[1], f"{L:.2f}", fontsize=5.5, rotation=ang, ha="center", va="center", color="black",
                        bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.9), zorder=5)
            for h in part["holes"]:
                H = np.array(h + h[:1])
                ax.plot(H[:, 0], H[:, 1], color="black", lw=1.1, zorder=4)
            if lu["area_m2"] >= 1:
                ax.text(c[0], c[1], f"{lu['name'].upper()}\n{lu['area_m2']:.1f} m²", fontsize=6.5, ha="center", va="center", color="black", zorder=6,
                        bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))


def draw_page(fig, ax, page, ortho_png, ortho, cont, foot, meas, linework, title, sub, scale, mm, A2, elements=None):
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon
    x0, y1, w, h = ortho["x_min"], ortho["y_max"], ortho["width_m"], ortho["height_m"]
    y0, x1 = y1 - h, x0 + w
    chosen = (elements or {}).get("boundaries", {}).get((elements or {}).get("boundary_source", ""))
    if page == "inner":
        draw_inner(ax, elements)
        draw_elements(ax, elements, "lines")
    elif page == "ortho":
        draw_elements(ax, elements, page)
    draw_boundary_structure(ax, elements, page)
    q = (elements or {}).get("quantities") or {}
    if q:
        lines = ["QUANTITIES"] + [f"{m}: {a_:.1f} m²" for m, a_ in sorted(q.get("areas", {}).items(), key=lambda kv: -kv[1])]
        lines += [f"{c}: {l:.1f} m" for c, l in q.get("lengths", {}).items()]
        lines += [f"{c}: {n}" for c, n in sorted(q.get("counts", {}).items()) if c not in ("area", "wall", "fence")]
        fig.text((A2[0] - MARGIN - 6) / A2[0], (MARGIN + TITLE_H + 6) / A2[1], "\n".join(lines), fontsize=6, ha="right", va="bottom",
                 family="monospace", bbox=dict(boxstyle="round,pad=0.4", fc="white", ec="#66655c", lw=0.5))
    if page == "ortho":
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
    if page == "ortho":
        for c in cont:
            P = np.array(c["points"])
            ax.plot(P[:, 0], P[:, 1], color="#8a5a2b", lw=0.6 if c["index"] else 0.3, zorder=2)
            if c["index"] and len(P) > 80:
                mx, my = P[len(P) // 2]
                ax.text(mx, my, f"{c['level']:.2f}", fontsize=4, color="#8a5a2b", ha="center", va="center",
                        bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.7), zorder=3)
    for poly in foot:
        ax.add_patch(Polygon(poly, closed=True, fill=False, ls="--", lw=0.6, ec="#2a6f97" if page == "ortho" else "#9a9a9a", zorder=2))
    for seg in (linework or {}).get("walls", []):
        if page != "ortho" and chosen:
            continue                                            # the drawing pages carry one line: the boundary itself
        ax.plot([seg[0][0], seg[1][0]], [seg[0][1], seg[1][1]], color="#d97757" if page == "ortho" else "black", lw=1.1, solid_capstyle="round", zorder=3)
    for seg in (linework or {}).get("edges", []):
        ax.plot([seg[0][0], seg[1][0]], [seg[0][1], seg[1][1]], color="#333333" if page == "lines" else "#555555", lw=0.6, zorder=3)
    for k, poly in enumerate((linework or {}).get("polygons", [])):
        P = np.array(poly["points"] + [poly["points"][0]])
        if not (k == 0 and chosen):
            ax.plot(P[:, 0], P[:, 1], color="black", lw=2.0 if k == 0 else 0.9, solid_joinstyle="miter", zorder=4)
        if page in ("lines", "inner"):
            for i, L in enumerate(poly["lengths"]):
                if L < 0.5:
                    continue
                a, b = P[i], P[i + 1]
                d = b - a; n = np.array([d[1], -d[0]]) / max(np.linalg.norm(d), 1e-9)
                mid = (a + b) / 2 + n * (0.45 if k == 0 else -0.3)       # outside the boundary, inside enclosures
                ang = np.degrees(np.arctan2(d[1], d[0]))
                if ang > 90 or ang < -90: ang += 180
                ax.text(mid[0], mid[1], f"{L:.2f}", fontsize=6.5, rotation=ang, ha="center", va="center", color="black",
                        bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none", alpha=0.9), zorder=5)
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
    fig.text(fx(MARGIN), fy(MARGIN + 12), title + ("  ·  outer" if page == "lines" else "  ·  inner" if page == "inner" else ""), fontsize=16, fontweight="bold", va="bottom", family="serif")
    detail = (f"contours every {CONTOUR_INTERVAL} m" if page == "ortho" else "the boundary and the partition of the ground, every side dimensioned" if page == "inner"
              else "the boundary from the perimeter walls; thick = wall, ticked = fence, dashed = no wall found")
    fig.text(fx(MARGIN), fy(MARGIN + 4), f"{sub}  ·  scale 1:{scale} on A2 {'landscape' if A2[0] > A2[1] else 'portrait'}  ·  {detail}  ·  grid 1 m  ·  north up",
             fontsize=7, va="bottom", color="#66655c")


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
    ap.add_argument("--boundary", default="walls", choices=["walls", "footprint"], help="which traced boundary the plan is built on")
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
    lw_path = work / "linework.json"
    linework = json.load(open(lw_path)) if lw_path.exists() else None
    el_path = work / "elements.json"
    elements = json.load(open(el_path)) if el_path.exists() else None
    if elements and linework is not None and elements.get("boundaries"):
        chosen = elements["boundaries"].get(a.boundary) or elements["boundaries"].get(elements.get("boundary_source", ""))
        if chosen:
            elements["boundary_source"] = a.boundary if a.boundary in elements["boundaries"] else elements.get("boundary_source")
            polys0 = {"points": chosen["points"], "lengths": chosen["lengths"], "area": chosen["area"]}
            linework = {**linework, "polygons": [polys0] + list(linework.get("polygons", [])[1:]),
                        "walls_all": linework.get("walls", []), "walls": elements.get("walls_interior", linework.get("walls", []))}
    if elements and elements.get("override_walls") and linework is not None:
        # marked walls and fences replace the traced wall lines on the drawing
        marked = [el for el in elements["elements"] if el.get("cls") in ("wall", "fence") and el.get("source") == "mark" and len(el.get("points") or []) >= 2]
        if marked:
            segs = []
            for el in marked:
                p = el["points"]
                segs += [[p[i], p[i + 1]] for i in range(len(p) - 1)]
            linework = {**linework, "walls": segs, "traced_walls": linework.get("walls", [])}
    write_dxf(work / "site_plan.dxf", ortho, cont, foot, meas, a.title, sub, linework, elements)
    scale = write_pdf(work / "site_plan.pdf", work / "orthomosaic.png", ortho, cont, foot, meas, a.title, sub, a.scale, linework, elements)
    polys = (linework or {}).get("polygons", [])
    align = 0.0
    if polys:                                             # the longest boundary side becomes horizontal in the app's default view
        pts, lengths = polys[0]["points"], polys[0]["lengths"]
        i = int(np.argmax(lengths)); p1, p2 = np.array(pts[i]), np.array(pts[(i + 1) % len(pts)])
        align = float(np.degrees(np.arctan2(p2[1] - p1[1], p2[0] - p1[0])))
    json.dump({"px_per_m": ppm, "x_min": ortho["x_min"], "y_max": ortho["y_max"], "width_px": ortho["width_px"], "height_px": ortho["height_px"],
               "width_m": ortho["width_m"], "height_m": ortho["height_m"], "contour_interval": a.contour, "sheet_scale": scale,
               "contours": cont, "footprint": foot, "measurements": meas,
               "walls": (linework or {}).get("walls", []), "edges": (linework or {}).get("edges", []),
               "polygons": polys, "axis_deg": (linework or {}).get("axis_deg"), "align_deg": align,
               "elements": (elements or {}).get("elements", []), "quantities": (elements or {}).get("quantities", {}),
               "boundary_source": (elements or {}).get("boundary_source"), "boundaries": (elements or {}).get("boundaries", {}),
               "landuse": (elements or {}).get("landuse", []), "walls_all": (linework or {}).get("walls_all", (linework or {}).get("walls", []))},
              open(work / "overlay.json", "w"))
    print(f"site plan: {len(cont)} contour lines every {a.contour} m, {len(foot)} footprint polygon(s), {len(meas)} measurements, "
          f"DEM {meta['width']}x{meta['height']} @ {a.cell} m, sheet 1:{scale}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
