#!/usr/bin/env python3
"""Entities: connected runs of same-label faces become named things with a centroid, height, outline and footprint.

    python scripts/16_entities.py <run_dir> --model <model3d asset>

Reads  <run>/faces.npy (label index per face, from lift), labels.json, lift/mask_faces.npz; <model>/dense/scene_dense_mesh_clean.ply,
       transform_preview.json (levelled: Z up, ground ≈ 0, unscaled), sparse/0 (camera heights → an approximate scale, so the
       size thresholds can be in metres before any tape measurement exists)
Writes <run>/entities.json       {"model", "frame", "levelled": 4x4, "est_scale", "entities": [{id, cls, label, name, description,
                                  material, confidence, frames, faces, area_m2, height_m, centroid, outline: [[x,y,z] model frame],
                                  shape: polygon|line, z_range}]}
       <run>/faces.npy           int32 per face: entity index (-1 none); the label-per-face array moves to lift/label_faces.npy
       <run>/segments/entity_masks.json   {eid: [[stem, mask index], ...]}: which 2D masks saw each entity (review, carry-over)
       <run>/inventory_map.png   top-down map of the entities, named
"""
import argparse
import json
import os
import shutil
import sys
from collections import defaultdict
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402

# per element class: how far apart (m) two fragments may be and still be one entity; the smallest footprint kept (m²)
GAP = {"wall": 0.5, "fence": 0.5, "window": 0.15, "door": 0.2, "stairs": 0.4, "area": 0.35, "tree": 0.4, "bush": 0.3, "object": 0.15}
MIN_AREA = {"wall": 0.4, "fence": 0.3, "window": 0.05, "door": 0.3, "stairs": 0.2, "area": 0.4, "tree": 0.1, "bush": 0.1, "object": 0.02}
MIN_FACES = 25
PALETTE = {"grass": "#6fa24a", "brick": "#b24c3c", "sand": "#dec07a", "gravel": "#9a9a96", "concrete": "#bdbdb8", "deck": "#a06e46",
           "garden": "#7a5637", "soil": "#7a5637", "tiles": "#c9b7a0", "stone": "#8f8a80", "asphalt": "#555555", "other": "#aaaaaa",
           "wall": "#3c3c3c", "fence": "#8c6a3c", "window": "#4a90c8", "door": "#c98a2a", "stairs": "#6d5aa8", "tree": "#2f6b3a",
           "bush": "#4f8f4a", "object": "#d97757"}


def color_of(cls: str, material: str | None) -> str:
    return PALETTE.get(material or "", PALETTE.get(cls, "#d97757")) if cls == "area" else PALETTE.get(cls, "#d97757")


def components(Tri: np.ndarray, label: np.ndarray):
    """Connected components over faces that share an edge and a label. Returns comp id per face (-1 unlabelled)."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    F = len(Tri)
    e = np.concatenate([Tri[:, [0, 1]], Tri[:, [1, 2]], Tri[:, [2, 0]]])
    e.sort(axis=1)
    fid = np.tile(np.arange(F), 3)
    order = np.lexsort((e[:, 1], e[:, 0]))
    e, fid = e[order], fid[order]
    same = np.all(e[1:] == e[:-1], axis=1)
    a, b = fid[:-1][same], fid[1:][same]
    ok = (label[a] >= 0) & (label[a] == label[b])
    a, b = a[ok], b[ok]
    g = coo_matrix((np.ones(len(a), dtype=np.int8), (a, b)), shape=(F, F))
    n, comp = connected_components(g, directed=False)
    comp = comp.astype(np.int64)
    comp[label < 0] = -1
    return comp


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-entities", type=int, default=120)
    a = ap.parse_args()
    import open3d as o3d
    from scipy.spatial import cKDTree
    import shapely
    from shapely.geometry import MultiPoint, Polygon

    run, model = Path(a.run), Path(a.model)
    info = json.load(open(model / "asset.json")) if (model / "asset.json").exists() else {}
    lab = json.load(open(run / "labels.json"))
    labels = lab["labels"]
    face_label = np.load(run / "faces.npy")
    (run / "lift").mkdir(exist_ok=True)
    np.save(run / "lift" / "label_faces.npy", face_label)
    mesh = o3d.io.read_triangle_mesh(str(model / "dense" / "scene_dense_mesh_clean.ply"))
    V, Tri = np.asarray(mesh.vertices), np.asarray(mesh.triangles)
    T = np.array(json.load(open(model / "transform_preview.json"))["matrix"]) if (model / "transform_preview.json").exists() else np.eye(4)
    Ti = np.linalg.inv(T)
    s = ic.est_scale(model, T)
    VL = (T @ np.c_[V, np.ones(len(V))].T).T[:, :3]
    CL = VL[Tri].mean(axis=1)
    area_f = 0.5 * np.linalg.norm(np.cross(VL[Tri[:, 1]] - VL[Tri[:, 0]], VL[Tri[:, 2]] - VL[Tri[:, 0]]), axis=1) * s * s
    print(f"{len(Tri)} faces, {int((face_label >= 0).sum())} labelled, est. scale {s:.3f} m/unit", flush=True)

    comp = components(Tri, face_label)
    ids, inv, counts = np.unique(comp[comp >= 0], return_inverse=True, return_counts=True)
    labelled_faces = np.nonzero(comp >= 0)[0]
    groups: dict[int, np.ndarray] = {}
    for gi, cid in enumerate(ids):
        groups[int(cid)] = labelled_faces[inv == gi]
    print(f"{len(groups)} raw components", flush=True)

    # merge fragments of the same label that nearly touch (bbox gap in est. metres)
    frag = []
    for cid, faces in groups.items():
        if len(faces) < 8:
            continue
        lbl = labels[face_label[faces[0]]]
        cls = lbl.split(":")[0]
        xy = CL[faces, :2] * s
        frag.append({"faces": faces, "label": lbl, "cls": cls, "lo": xy.min(axis=0), "hi": xy.max(axis=0), "area": float(area_f[faces].sum())})
    parent = list(range(len(frag)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    by_label = defaultdict(list)
    for i, f in enumerate(frag):
        by_label[f["label"]].append(i)
    for lbl, idx in by_label.items():
        gap = GAP.get(frag[idx[0]]["cls"], 0.2)
        for ii in range(len(idx)):
            for jj in range(ii + 1, len(idx)):
                A, B = frag[idx[ii]], frag[idx[jj]]
                if np.all(A["lo"] - gap <= B["hi"]) and np.all(B["lo"] - gap <= A["hi"]):
                    parent[find(idx[ii])] = find(idx[jj])
    merged = defaultdict(list)
    for i in range(len(frag)):
        merged[find(i)].append(i)

    ents = []
    for root, members in merged.items():
        faces = np.concatenate([frag[i]["faces"] for i in members])
        lbl = frag[members[0]]["label"]
        cls = lbl.split(":")[0]
        area = float(area_f[faces].sum())
        if len(faces) < MIN_FACES or area < MIN_AREA.get(cls, 0.1):
            continue
        ents.append({"faces": faces, "label": lbl, "cls": cls, "area": area})
    ents.sort(key=lambda e: -e["area"])
    ents = ents[: a.max_entities]
    print(f"{len(ents)} entities after merging and size filter", flush=True)

    # which masks saw which entity (for names per entity, frames, review and carry-over)
    ent_of_face = np.full(len(Tri), -1, dtype=np.int32)
    for i, e in enumerate(ents):
        ent_of_face[e["faces"]] = i
    mf = np.load(run / "lift" / "mask_faces.npz")
    entity_masks = defaultdict(list)
    for key in mf.files:
        faces = mf[key]
        hit = ent_of_face[faces]
        hit = hit[hit >= 0]
        if len(hit) == 0:
            continue
        u, c = np.unique(hit, return_counts=True)
        for ei, n in zip(u, c):
            if n >= 0.2 * len(faces) or n >= 200:
                stem, mi = key.rsplit("/", 1)
                entity_masks[int(ei)].append([stem, int(mi)])

    tree = cKDTree(CL[:, :2])
    out = []
    name_count = defaultdict(int)
    for i, e in enumerate(ents):
        faces, cls, lbl = e["faces"], e["cls"], e["label"]
        P = CL[faces]
        xy = P[:, :2]
        z0, z1 = float(np.percentile(P[:, 2], 2)), float(np.percentile(P[:, 2], 98))
        material = lbl.split(":")[1] if cls == "area" else None
        names = lab.get("names", {}).get(lbl, {})
        name = lbl.split(":")[1] if cls == "object" else (max(names, key=names.get) if names else cls)
        if cls == "area":
            name = {"grass": "lawn", "brick": "brick paving", "sand": "sand pit", "deck": "decking", "garden": "garden bed"}.get(material, f"{material} ground")
        descs = lab.get("descriptions", {}).get(lbl, {})
        desc = max(descs, key=descs.get) if descs else ""
        # outline in the levelled frame
        shape = "polygon"
        if cls in ("wall", "fence", "window", "door") and len(xy) >= 3:
            c = xy.mean(axis=0)
            _, _, vt = np.linalg.svd(xy - c, full_matrices=False)
            d = vt[0]
            t = (xy - c) @ d
            p0, p1 = c + d * np.percentile(t, 1), c + d * np.percentile(t, 99)
            if cls in ("window", "door"):
                pts = [[*p0, z0], [*p1, z0], [*p1, z1], [*p0, z1]]
            else:
                pts = [[*p0, z0], [*p1, z0]]
                shape = "line"
        else:
            mp = MultiPoint(xy if len(xy) <= 20000 else xy[np.random.default_rng(0).choice(len(xy), 20000, replace=False)])
            try:
                poly = shapely.concave_hull(mp, ratio=0.35 if cls in ("area", "stairs") else 0.6)
            except Exception:
                poly = mp.convex_hull
            if poly.geom_type != "Polygon" or poly.is_empty:
                poly = mp.convex_hull
            if poly.geom_type != "Polygon":
                continue
            poly = poly.simplify(0.08 / s)
            ring = np.array(poly.exterior.coords)[:-1]
            if len(ring) > 80:
                ring = ring[:: int(np.ceil(len(ring) / 80))]
            zs = CL[tree.query(ring)[1], 2]
            pts = [[float(x), float(y), float(z)] for (x, y), z in zip(ring, zs)]
        pts_model = (Ti @ np.c_[np.array(pts), np.ones(len(pts))].T).T[:, :3]
        name_count[name] += 1
        shown = name if name_count[name] == 1 else f"{name} {name_count[name]}"
        ent_masks = entity_masks.get(i, [])
        frames = sorted({m[0] for m in ent_masks})
        conf = float(min(1.0, 0.35 + 0.15 * len(frames)))
        cen = (Ti @ np.array([*P.mean(axis=0), 1.0]))[:3]
        out.append({"id": f"e{len(out) + 1}", "cls": cls, "label": lbl, "name": shown, "description": desc, "material": material,
                    "confidence": round(conf, 2), "frames": len(frames), "faces": int(len(faces)), "area_m2": round(e["area"], 2),
                    "height_m": round((z1 - z0) * s, 2), "z_range": [round(z0, 3), round(z1, 3)],
                    "centroid": [round(float(v), 4) for v in cen], "shape": shape,
                    "outline": [[round(float(v), 4) for v in p] for p in pts_model], "color": color_of(cls, material),
                    "_faces": faces, "_masks": ent_masks})
    ent_idx = np.full(len(Tri), -1, dtype=np.int32)
    emasks = {}
    for k, e in enumerate(out):
        ent_idx[e.pop("_faces")] = k
        emasks[e["id"]] = e.pop("_masks")
    np.save(run / "faces.npy", ent_idx)
    json.dump(emasks, open(run / "segments" / "entity_masks.json", "w"))
    json.dump({"model": info.get("id", model.name), "frame": info.get("frame") or info.get("id", model.name), "levelled": T.tolist(),
               "est_scale": s, "entities": out}, open(run / "entities.json", "w"), indent=1)
    for e in out[:40]:
        print(f"  {e['id']:5s} {e['cls']:7s} {e['name']:22s} {e['area_m2']:7.2f} m²  h {e['height_m']:.2f}  {e['frames']} frames  {e['faces']} faces")

    # map
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig = plt.figure(figsize=(10, 8))
        ax = fig.add_axes([0.02, 0.02, 0.96, 0.96])
        for e in out:
            pts = (T @ np.c_[np.array(e["outline"]), np.ones(len(e["outline"]))].T).T[:, :2] * s
            if e["shape"] == "polygon" and len(pts) >= 3:
                ax.fill(pts[:, 0], pts[:, 1], color=e["color"], alpha=0.35, lw=0)
                ax.plot(np.r_[pts[:, 0], pts[0, 0]], np.r_[pts[:, 1], pts[0, 1]], color=e["color"], lw=1.2)
            else:
                ax.plot(pts[:, 0], pts[:, 1], color=e["color"], lw=2.5)
            c = pts.mean(axis=0)
            ax.text(c[0], c[1], e["name"], fontsize=6.5, ha="center", va="center", color="#222",
                    bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))
        ax.set_aspect("equal"); ax.grid(True, lw=0.3, alpha=0.5)
        ax.set_title(f"{len(out)} entities · approx. metres (scale estimated from camera height)", fontsize=9)
        fig.savefig(str(run / "inventory_map.png"), dpi=100, facecolor="white", bbox_inches="tight")
        plt.close(fig)
    except Exception as ex:
        print(f"map not drawn: {ex}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
