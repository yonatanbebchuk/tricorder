#!/usr/bin/env python3
"""Annotate: the inventory's entities merged with the element marks → named elements in plan metres.

    python scripts/18_annotate.py <run_dir> --model <model3d asset> [--marks <rec dir> ...]

Reads  <run>/transform.json (model → metres, Z up, north +Y); each marks recording.json (generated inventories and yours)
Writes <run>/elements.json  {"frame", "elements": [{id, cls, name, material, shape, points: [[x,y], ...] (metres), z: [z0, z1],
                             length_m, area_m2, height_m, source: inventory|mark, entity, confidence, color, description, note}],
                             "override_walls": bool, "quantities": {"areas": {material: m²}, "lengths": {cls: m}, "counts": {cls: n}},
                             "skipped": [...]}
Marks win: an element mark linked to an entity replaces it; a mark with "reject": true drops the entity; unlinked marks are
added. When marks include walls or fences, the traced walls are overridden on the drawing.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from identify_common import MATERIALS  # noqa: E402

PALETTE = {"grass": "#6fa24a", "brick": "#b24c3c", "sand": "#dec07a", "gravel": "#9a9a96", "concrete": "#bdbdb8", "deck": "#a06e46",
           "garden": "#7a5637", "soil": "#7a5637", "tiles": "#c9b7a0", "stone": "#8f8a80", "asphalt": "#555555", "other": "#aaaaaa",
           "wall": "#3c3c3c", "fence": "#8c6a3c", "window": "#4a90c8", "door": "#c98a2a", "stairs": "#6d5aa8", "tree": "#2f6b3a",
           "bush": "#4f8f4a", "object": "#d97757"}


def color_of(cls, material):
    return PALETTE.get(material or "other", "#aaaaaa") if cls == "area" else PALETTE.get(cls, "#d97757")


def to_plan(T: np.ndarray, pts) -> np.ndarray:
    P = np.array(pts, dtype=float).reshape(-1, 3)
    return (T @ np.c_[P, np.ones(len(P))].T).T[:, :3]


def measure(shape: str, P: np.ndarray) -> tuple[float | None, float | None]:
    from shapely.geometry import Polygon
    xy = P[:, :2]
    if shape == "polygon" and len(xy) >= 3:
        poly = Polygon(xy)
        if not poly.is_valid:
            poly = poly.buffer(0)
        return float(poly.length), float(poly.area)
    if len(xy) >= 2:
        return float(np.sum(np.linalg.norm(np.diff(xy, axis=0), axis=1))), None
    return None, None


# ---------------------------------------------------------------- the plan's structure: boundary, its edges, openings, land use

def _seg_geom(a, b):
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = float(np.linalg.norm(d))
    return a, b, d / max(L, 1e-9), L


def _classify_edges(points, elements):
    """Each boundary edge as wall / fence / unknown from the wall and fence elements running along it (a person's marks
    weigh three times a generated entity). Returns [{a, b, cls, length}] and the class totals."""
    n = len(points)
    cands = []
    for el in elements:
        if el.get("minor") or el.get("cls") not in ("wall", "fence") or len(el.get("points") or []) < 2:
            continue
        w = 3.0 if el.get("source") == "mark" else 1.0
        pts = el["points"]
        for i in range(len(pts) - 1):
            cands.append((el["cls"], w, np.asarray(pts[i], float), np.asarray(pts[i + 1], float)))
    edges = []
    totals = {}
    for i in range(n):
        a, b, u, L = _seg_geom(points[i], points[(i + 1) % n])
        nrm = np.array([-u[1], u[0]])
        score = {"wall": 0.0, "fence": 0.0}
        for cls, w, p, q in cands:
            v = q - p
            Lc = np.linalg.norm(v)
            if Lc < 0.2:
                continue
            ang = np.degrees(np.arccos(min(1.0, abs(float(u @ v)) / Lc)))
            if ang > 15:
                continue
            if abs(float((p - a) @ nrm)) > 0.5 or abs(float((q - a) @ nrm)) > 0.5:
                continue
            t0, t1 = sorted([float((p - a) @ u), float((q - a) @ u)])
            overlap = max(0.0, min(t1, L) - max(t0, 0.0))
            score[cls] += w * overlap
        best = max(score, key=score.get)
        cls = best if score[best] >= 0.25 * L and L > 0 else "unknown"
        edges.append({"a": [round(float(a[0]), 3), round(float(a[1]), 3)], "b": [round(float(b[0]), 3), round(float(b[1]), 3)],
                      "cls": cls, "length": round(L, 2)})
        totals[cls] = round(totals.get(cls, 0.0) + L, 2)
    return edges, totals


def _openings(points, elements, inside_sign):
    """Windows and doors snapped onto the boundary edge they sit on: [{cls, name, edge, a, b, width, swing}]."""
    n = len(points)
    out = []
    for el in elements:
        if el.get("minor") or el.get("cls") not in ("window", "door") or not el.get("points"):
            continue
        P = np.asarray(el["points"], float)
        c = P.mean(axis=0)
        best = None
        for i in range(n):
            a, b, u, L = _seg_geom(points[i], points[(i + 1) % n])
            t = float((c - a) @ u)
            if t < -0.3 or t > L + 0.3:
                continue
            nrm = np.array([-u[1], u[0]])
            d = abs(float((c - a) @ nrm))
            if d < 0.8 and (best is None or d < best[0]):
                best = (d, i, a, u, L)
        if best is None:
            continue
        d, i, a, u, L = best
        ts = sorted(float((p - a) @ u) for p in P)
        t0, t1 = max(0.0, ts[0]), min(L, ts[-1])
        width = t1 - t0
        if width < 0.5:
            mid = (t0 + t1) / 2
            width = 0.9
            t0, t1 = max(0.0, mid - width / 2), min(L, mid + width / 2)
        pa, pb = a + u * t0, a + u * t1
        out.append({"cls": el["cls"], "name": el.get("name") or el["cls"], "edge": i, "a": [round(float(pa[0]), 3), round(float(pa[1]), 3)],
                    "b": [round(float(pb[0]), 3), round(float(pb[1]), 3)], "width": round(t1 - t0, 2), "swing": inside_sign,
                    "source": el.get("source"), "entity": el.get("entity")})
    return out


def _poly_parts(geom):
    """A shapely (Multi)Polygon as [{exterior, holes}] with rounded coordinates."""
    from shapely.geometry import MultiPolygon, Polygon
    parts = []
    geoms = list(geom.geoms) if geom.geom_type == "MultiPolygon" else [geom] if geom.geom_type == "Polygon" else []
    for g in geoms:
        if g.is_empty or g.area < 0.05:
            continue
        parts.append({"exterior": [[round(x, 3), round(y, 3)] for x, y in g.exterior.coords[:-1]],
                      "holes": [[[round(x, 3), round(y, 3)] for x, y in r.coords[:-1]] for r in g.interiors]})
    return parts


def _landuse(boundary, elements):
    """The yard partitioned: a person's areas first (later marks win), then generated ground entities that are not minor,
    each clipped to the boundary and to what came before; the rest is unassigned ground."""
    from shapely.geometry import Polygon
    from shapely.ops import unary_union
    layers = []
    human = [e for e in elements if e["cls"] == "area" and e["source"] == "mark" and e["shape"] == "polygon" and len(e["points"]) >= 3]
    # the most specific area wins: smaller polygons are carved out of larger ones (a sand pit drawn inside the lawn)
    human.sort(key=lambda e: -(e.get("area_m2") or 0))
    generated = [e for e in elements if e["cls"] == "area" and e["source"] == "inventory" and not e.get("minor") and e["shape"] == "polygon"
                 and len(e["points"]) >= 3 and (e.get("confidence") or 0) >= 0.5]
    taken = None
    out = []
    for e in list(reversed(human)) + generated:               # the newest human mark has the final say where marks overlap
        poly = Polygon(e["points"])
        poly = poly if poly.is_valid else poly.buffer(0)
        piece = poly.intersection(boundary)
        if taken is not None:
            piece = piece.difference(taken)
        if piece.is_empty or piece.area < 0.2:
            continue
        taken = piece if taken is None else unary_union([taken, piece])
        out.append({"material": e.get("material") or "other", "name": e.get("name") or e.get("material") or "area", "source": e["source"],
                    "element": e["id"], "color": e.get("color"), "area_m2": round(piece.area, 2), "polygons": _poly_parts(piece)})
    rest = boundary.difference(taken) if taken is not None else boundary
    if not rest.is_empty and rest.area > 0.2:
        out.append({"material": "unassigned", "name": "unassigned ground", "source": "boundary", "element": None, "color": "#e8e4dc",
                    "area_m2": round(rest.area, 2), "polygons": _poly_parts(rest)})
    return out


def plan_structure(run: Path, elements: list[dict], boundary_source: str) -> dict:
    """Boundary (both traced versions, with edge classes and openings), the chosen one, land use inside it, and the wall
    segments that are not part of the boundary (so the drawing shows one line where the boundary follows a wall)."""
    from shapely.geometry import LineString, Polygon
    lw_path = run / "linework.json"
    if not lw_path.exists():
        return {}
    L = json.load(open(lw_path))
    sources = {}
    if L.get("polygons"):
        sources["footprint"] = L["polygons"][0]
    if L.get("wall_boundary"):
        sources["walls"] = L["wall_boundary"][0]
    if not sources:
        return {}
    chosen = boundary_source if boundary_source in sources else next(iter(sources))
    boundaries = {}
    for src, poly in sources.items():
        pts = poly["points"]
        P = Polygon(pts)
        P = P if P.is_valid else P.buffer(0)
        if P.geom_type == "MultiPolygon":
            P = max(P.geoms, key=lambda g: g.area)
        ring_pts = [[round(float(x), 3), round(float(y), 3)] for x, y in P.exterior.coords[:-1]]
        # orientation: inside is to the left of a counter-clockwise ring
        signed = 0.5 * sum(ring_pts[i][0] * ring_pts[(i + 1) % len(ring_pts)][1] - ring_pts[(i + 1) % len(ring_pts)][0] * ring_pts[i][1] for i in range(len(ring_pts)))
        inside_sign = 1 if signed > 0 else -1
        edges, totals = _classify_edges(ring_pts, elements)
        lengths = [round(float(np.linalg.norm(np.subtract(ring_pts[(i + 1) % len(ring_pts)], ring_pts[i]))), 2) for i in range(len(ring_pts))]
        boundaries[src] = {"points": ring_pts, "lengths": lengths, "area": round(P.area, 2), "edges": edges, "edge_classes": totals,
                           "openings": _openings(ring_pts, elements, inside_sign)}
    B = Polygon(boundaries[chosen]["points"])
    B = B if B.is_valid else B.buffer(0)
    ring = LineString(list(B.exterior.coords))
    interior = []
    for seg in L.get("walls", []):
        a, b = np.asarray(seg[0], float), np.asarray(seg[1], float)
        if np.linalg.norm(b - a) < 0.3:
            continue
        mid = (a + b) / 2
        on = ring.distance(LineString([a, b])) < 0.01 and max(ring.distance(__import__("shapely").geometry.Point(a)), ring.distance(__import__("shapely").geometry.Point(b)),
                                                             ring.distance(__import__("shapely").geometry.Point(mid))) < 0.35
        if not on:
            interior.append(seg)
    return {"boundary_source": chosen, "boundaries": boundaries, "landuse": _landuse(B, elements), "walls_interior": interior}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--marks", nargs="*", default=[], help="marks recordings: generated inventories and a person's marks")
    ap.add_argument("--boundary", default="walls", choices=["walls", "footprint"], help="which traced boundary the plan is built on")
    a = ap.parse_args()
    run, model = Path(a.run), Path(a.model)
    T = np.array(json.load(open(run / "transform.json"))["matrix"])
    scale = float(json.load(open(run / "transform.json")).get("scale") or np.cbrt(abs(np.linalg.det(T[:3, :3]))))
    info = json.load(open(model / "asset.json")) if (model / "asset.json").exists() else {}
    frame = info.get("frame") or info.get("id") or model.name
    elements, skipped = [], []

    recs = []
    for rdir in a.marks:
        r = json.load(open(Path(rdir) / "recording.json"))
        rid = r.get("id", Path(rdir).name)
        src = r.get("source") or {}
        rframe = src.get("frame") or src.get("model")
        if rframe not in (frame, info.get("id")):
            skipped.append({"recording": rid, "reason": f"marked on frame {rframe}, the model is {frame}"})
            continue
        recs.append((bool(src.get("generated")), rid, r))
    recs.sort(key=lambda t: not t[0])                      # generated inventories first, a person's marks override them

    def element_of(it: dict, rid: str, generated: bool) -> dict | None:
        pts = it.get("points") or []
        if not pts:
            return None
        P = to_plan(T, pts)
        shape = it.get("shape") or ("polygon" if len(pts) >= 3 else "line" if len(pts) == 2 else "point")
        cls = it.get("cls", "object")
        length, area = measure(shape, P)
        material = it.get("material") if cls == "area" else None
        if material and material not in MATERIALS:
            material = "other"
        return {"id": it["id"] if generated else f"{rid}/{it.get('id', '')}", "cls": cls, "name": it.get("name") or (material or cls), "material": material,
                "shape": shape, "points": [[round(float(x), 3), round(float(y), 3)] for x, y in P[:, :2]],
                "z": [round(float(P[:, 2].min()), 3), round(float(P[:, 2].max()), 3)],
                "length_m": round(length, 2) if length is not None else None, "area_m2": round(area, 2) if area is not None else None,
                "height_m": round(float(it["height_m"]), 2) if it.get("height_m") else None,
                "source": "inventory" if generated else "mark", "entity": it.get("entity"), "confidence": it.get("confidence", 1.0 if not generated else None),
                "color": it.get("color") or color_of(cls, material), "description": it.get("text") or it.get("note") or "", "note": it.get("note", "")}

    override_walls = False
    for generated, rid, r in recs:
        for it in r.get("items", []):
            if it.get("role", "element") != "element":
                continue
            ent = it.get("entity")
            if not generated and ent:                       # a person's word on an entity replaces the generated one
                elements = [x for x in elements if x.get("entity") != ent]
            if it.get("reject"):
                continue
            el = element_of(it, rid, generated)
            if el is None:
                continue
            if not generated and el["cls"] in ("wall", "fence"):
                override_walls = True
            elements.append(el)

    # a person's area covers generated ground entities inside it; small, unsure generated things are kept but minor
    from shapely.geometry import Polygon as _P
    human_areas = []
    for el in elements:
        if el["source"] == "mark" and el["cls"] == "area" and el["shape"] == "polygon" and len(el["points"]) >= 3:
            poly = _P(el["points"])
            human_areas.append(poly if poly.is_valid else poly.buffer(0))
    kept = []
    for el in elements:
        if el["source"] == "inventory" and el["shape"] == "polygon" and len(el["points"]) >= 3 and human_areas:
            poly = _P(el["points"])
            poly = poly if poly.is_valid else poly.buffer(0)
            if poly.area > 0 and any(poly.intersection(h).area / poly.area >= 0.5 for h in human_areas) and el["cls"] == "area":
                continue                                          # the person's word on that ground
        if el["source"] == "inventory":
            if el["cls"] in ("wall", "fence"):
                small = (el.get("length_m") or 0) < 0.8
            else:
                small = (el.get("area_m2") or 0) < 0.3 and el["cls"] not in ("window", "door")
            unsure = (el.get("confidence") or 0) < 0.5
            el["minor"] = bool(small or unsure)
        kept.append(el)
    elements = kept

    q_area, q_len, q_cnt = {}, {}, {}
    for el in elements:
        if el.get("minor"):
            continue
        q_cnt[el["cls"]] = q_cnt.get(el["cls"], 0) + 1
        if el["cls"] == "area" and el.get("area_m2"):
            q_area[el["material"] or "other"] = round(q_area.get(el["material"] or "other", 0) + el["area_m2"], 2)
        elif el["cls"] in ("wall", "fence") and el.get("length_m"):
            q_len[el["cls"]] = round(q_len.get(el["cls"], 0) + el["length_m"], 2)
    structure = plan_structure(run, elements, a.boundary)
    json.dump({"frame": frame, "elements": elements, "override_walls": override_walls,
               "quantities": {"areas": q_area, "lengths": q_len, "counts": q_cnt}, "skipped": skipped, **structure},
              open(run / "elements.json", "w"), indent=1)
    if structure.get("landuse"):
        print("land use: " + ", ".join(f"{l['name']} {l['area_m2']:.1f} m²" for l in structure["landuse"]))
    for src, b in structure.get("boundaries", {}).items():
        print(f"boundary ({src}): {b['area']:.1f} m², {len(b['points'])} sides, edges " +
              ", ".join(f"{k} {v}" for k, v in b["edge_classes"].items()) + f", {len(b['openings'])} openings")
    print(f"{len(elements)} elements ({sum(1 for e in elements if e['source'] == 'mark')} from marks, "
          f"{sum(1 for e in elements if e['source'] == 'inventory')} generated); areas {q_area}; lengths {q_len}")
    for sk in skipped:
        print(f"  skipped: {sk}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
