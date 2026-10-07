#!/usr/bin/env python3
"""Select: edit marks → what to cut and where to fill, as geometry every later stage can apply to its own copy of the model.

    python scripts/19_edit_select.py <run_dir> --model <model3d asset> --marks <rec dir> ...

The marks recordings are a person's marks (edit items: remove / patch) and generated inventories (entities.json, faces.npy).
A `remove` mark naming an entity takes that entity's faces plus the ring of ground directly under its footprint, so the hole
has a clean ground rim; a `remove` polygon takes the faces inside it (whole entities when it covers most of one); a `patch`
polygon takes only the junk inside it (faces far from the fitted ground); a `patch` point means "fill the hole around here"
and takes nothing. For each item a ground plane is fitted to the ring of ground around the footprint. The selection is
written as occupied 3 cm voxels of the clean mesh (the textured mesh shares its faces) and as a region for the cloud.

Writes <run>/edit/selection.json  {"voxel", "voxel_units", "levelled", "est_scale", "items": [{id, cls, name, entity, entities, text, faces,
                                   voxels (file), footprint: [[x,y]] levelled, fill_polygon, plane: [a,b,c], z_range, seed, radius,
                                   ring_material, ring_samples}], "removed_entities": [...], "skipped": [...]}
       <run>/edit/voxels_<n>.npy, <run>/edit/selection.png
"""
import argparse
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402

STRUCTURAL = {"wall", "fence", "window", "door", "stairs"}


def fit_plane(P: np.ndarray):
    A = np.c_[P[:, 0], P[:, 1], np.ones(len(P))]
    coef, *_ = np.linalg.lstsq(A, P[:, 2], rcond=None)
    return [float(v) for v in coef]


def load_inventory(marks_dirs: list[Path], frame: str, model_id: str):
    """The newest generated inventory on this frame among the marks recordings: entities, entity index per face, labels per face."""
    best = None
    for d in marks_dirs:
        r = json.load(open(d / "recording.json"))
        src = r.get("source") or {}
        if not src.get("generated") or not (d / "faces.npy").exists() or not (d / "entities.json").exists():
            continue
        if (src.get("frame") or src.get("model")) not in (frame, model_id):
            continue
        if best is None or r.get("created_at", "") > best[0]:
            best = (r.get("created_at", ""), d, r)
    if best is None:
        return None, None, None, [], None
    d = best[1]
    E = json.load(open(d / "entities.json"))
    ent_idx = np.load(d / "faces.npy")
    labels_of_face = np.load(d / "lift" / "label_faces.npy") if (d / "lift" / "label_faces.npy").exists() else None
    label_names = json.load(open(d / "labels.json"))["labels"] if (d / "labels.json").exists() else []
    return E, ent_idx, labels_of_face, label_names, d.name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--marks", nargs="*", default=[])
    ap.add_argument("--voxel", type=float, default=0.03, help="voxel size in (estimated) metres")
    ap.add_argument("--ring", type=float, default=0.5, help="width of the ground ring the fill plane is fitted to (m)")
    ap.add_argument("--rim", type=float, default=0.10, help="ground rim under a removed thing that is cut too, for a clean hole (m)")
    ap.add_argument("--seed-radius", type=float, default=4.0, help="how far a point patch looks for its hole (m)")
    a = ap.parse_args()
    import open3d as o3d
    from shapely.geometry import MultiPoint, Point, Polygon

    run, model = Path(a.run), Path(a.model)
    out = run / "edit"
    out.mkdir(exist_ok=True)
    info = json.load(open(model / "asset.json")) if (model / "asset.json").exists() else {}
    frame = info.get("frame") or info.get("id") or model.name
    T = ic.levelled_transform(model)
    s = ic.est_scale(model, T)
    vox = a.voxel / s
    mesh = o3d.io.read_triangle_mesh(str(model / "dense" / "scene_dense_mesh_clean.ply"))
    V, Tri = np.asarray(mesh.vertices), np.asarray(mesh.triangles)
    VL = (T @ np.c_[V, np.ones(len(V))].T).T[:, :3]
    CL = VL[Tri].mean(axis=1)
    N = np.cross(VL[Tri[:, 1]] - VL[Tri[:, 0]], VL[Tri[:, 2]] - VL[Tri[:, 0]])
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)
    horizontal = np.abs(N[:, 2]) > 0.75
    print(f"{len(Tri)} faces; est. scale {s:.3f} m/unit; voxel {vox:.4f} units", flush=True)

    marks_dirs = [Path(d) for d in a.marks]
    E, ent_idx, labels_of_face, label_names, inv_id = load_inventory(marks_dirs, frame, info.get("id", model.name))
    if E is not None and (ent_idx is None or len(ent_idx) != len(Tri)):
        print("inventory faces do not match this mesh; entities by footprint only", file=sys.stderr)
        ent_idx = None
    if labels_of_face is not None and len(labels_of_face) == len(Tri):
        area_ids = [i for i, l in enumerate(label_names) if l.startswith("area:")]
        structural_ids = [i for i, l in enumerate(label_names) if l.split(":")[0] in STRUCTURAL]
        ground = np.isin(labels_of_face, area_ids) | (horizontal & (labels_of_face < 0))
        structural = np.isin(labels_of_face, structural_ids)
    else:
        ground = horizontal
        structural = np.zeros(len(Tri), dtype=bool)
    ent_by_id = {e["id"]: k for k, e in enumerate(E["entities"])} if E else {}
    print(f"inventory: {inv_id or 'none'} ({len(ent_by_id)} entities)", flush=True)

    def inside(poly: np.ndarray) -> np.ndarray:
        return ic.point_in_polygon(CL[:, :2], poly)

    def ring_of(foot, exclude: np.ndarray):
        outer = foot.buffer(a.ring / s)
        inner = foot.buffer(0.02 / s)
        cand = np.nonzero(inside(np.array(outer.exterior.coords)[:-1]) & ~inside(np.array(inner.exterior.coords)[:-1]))[0]
        cand = np.setdiff1d(cand, exclude)
        ring = cand[ground[cand]]
        if len(ring) >= 30:
            z_med = np.median(CL[ring, 2])
            ring = ring[np.abs(CL[ring, 2] - z_med) < 0.35 / s]
        return ring

    items, removed, skipped = [], [], []
    for d in marks_dirs:
        r = json.load(open(d / "recording.json"))
        rid = r.get("id", d.name)
        src = r.get("source") or {}
        if src.get("generated"):
            continue
        rframe = src.get("frame") or src.get("model")
        if rframe not in (frame, info.get("id")):
            skipped.append({"recording": rid, "reason": f"marked on frame {rframe}, the model is {frame}"})
            continue
        for it in r.get("items", []):
            if it.get("role") != "edit":
                continue
            cls = it.get("cls")
            faces = np.zeros(0, dtype=np.int64)
            poly_xy, seed = None, None
            ents_here: list[str] = []
            P = None
            if it.get("points"):
                P = (T @ np.c_[np.array(it["points"], dtype=float), np.ones(len(it["points"]))].T).T[:, :3]
                if len(P) >= 3:
                    poly_xy = P[:, :2]
                elif cls == "patch" and len(P) >= 1:
                    seed = P[0, :2]
            foot = None
            if cls == "remove" and it.get("entity") and it["entity"] in ent_by_id and ent_idx is not None:
                k = ent_by_id[it["entity"]]
                faces = np.nonzero(ent_idx == k)[0]
                ents_here = [it["entity"]]
                e = E["entities"][k]
                ol = np.array(e.get("outline") or [])
                if len(ol) >= 3:
                    OL = (T @ np.c_[ol, np.ones(len(ol))].T).T[:, :2]
                    foot = Polygon(OL)
                    if not foot.is_valid:
                        foot = foot.buffer(0)
            elif cls == "remove" and poly_xy is not None:
                ins = inside(poly_xy)
                faces = np.nonzero(ins & ~structural)[0]
                if ent_idx is not None:
                    u, c = np.unique(ent_idx[ins][ent_idx[ins] >= 0], return_counts=True)
                    for k, n in zip(u, c):
                        tot = int((ent_idx == k).sum())
                        if tot and n / tot >= 0.5 and E["entities"][k]["cls"] not in ("area", *STRUCTURAL):
                            faces = np.union1d(faces, np.nonzero(ent_idx == k)[0])
                            ents_here.append(E["entities"][k]["id"])
                foot = Polygon(poly_xy)
            elif cls == "patch" and poly_xy is not None:
                foot = Polygon(poly_xy)
            elif cls == "patch" and seed is not None:
                foot = None
            else:
                skipped.append({"recording": rid, "item": it.get("id"), "reason": "no entity, polygon or point"})
                continue
            if cls == "remove" and len(faces) == 0:
                skipped.append({"recording": rid, "item": it.get("id"), "reason": "selects no faces"})
                continue
            if foot is None and cls == "remove":
                pts = CL[faces, :2]
                foot = MultiPoint(pts if len(pts) <= 20000 else pts[np.random.default_rng(0).choice(len(pts), 20000, replace=False)]).convex_hull
            if foot is not None and (foot.geom_type != "Polygon" or foot.is_empty):
                foot = foot.convex_hull if not foot.is_empty else None
            # the ground plane: from the ring around the footprint, or around the seed
            if foot is not None:
                ring = ring_of(foot, faces)
            else:
                disc = Point(*seed).buffer(1.5 / s)
                cand = np.nonzero(inside(np.array(disc.exterior.coords)[:-1]))[0]
                ring = cand[ground[cand]]
            if len(ring) >= 30:
                plane = fit_plane(CL[ring])
            else:
                zf = float(np.percentile(CL[faces, 2], 5)) if len(faces) else (float(np.median(CL[ring, 2])) if len(ring) else 0.0)
                plane = [0.0, 0.0, zf]
                print(f"  {rid}/{it.get('id')}: thin ground ring ({len(ring)} faces); flat fill at z={zf:.3f}", flush=True)
            if cls == "patch" and foot is not None:              # junk inside the polygon, far from the plane
                ins = np.nonzero(inside(np.array(foot.exterior.coords)[:-1]))[0]
                dz = CL[ins, 2] - (plane[0] * CL[ins, 0] + plane[1] * CL[ins, 1] + plane[2])
                faces = ins[np.abs(dz) > 0.12 / s]
            if cls == "remove" and foot is not None:              # the ground rim under the thing, for a clean hole
                rim = foot.buffer(a.rim / s)
                ins = inside(np.array(rim.exterior.coords)[:-1])
                dz = CL[:, 2] - (plane[0] * CL[:, 0] + plane[1] * CL[:, 1] + plane[2])
                under = ins & ground & ~structural & (np.abs(dz) < 0.15 / s)
                faces = np.union1d(faces, np.nonzero(under)[0])
                foot = rim
            ring_mat = "ground"
            if labels_of_face is not None and len(ring):
                u, c = np.unique(labels_of_face[ring][labels_of_face[ring] >= 0], return_counts=True)
                if len(u):
                    ring_mat = label_names[u[c.argmax()]].replace("area:", "")
            samples = CL[ring[np.linspace(0, len(ring) - 1, min(24, len(ring))).astype(int)]] if len(ring) else np.zeros((0, 3))
            cells = np.unique(np.floor(CL[faces] / vox).astype(np.int64), axis=0) if len(faces) else np.zeros((0, 3), np.int64)
            n = len(items)
            np.save(out / f"voxels_{n}.npy", cells.astype(np.int32))
            fill = foot.buffer(0.02 / s).simplify(vox / 2) if foot is not None else None
            items.append({"id": f"{rid}/{it.get('id', n + 1)}", "cls": cls, "name": it.get("name") or (", ".join(ents_here) if ents_here else cls),
                          "entity": it.get("entity"), "entities": ents_here, "text": it.get("text", ""), "faces": int(len(faces)),
                          "voxels": f"voxels_{n}.npy", "n_voxels": int(len(cells)),
                          "footprint": [[round(float(x), 4), round(float(y), 4)] for x, y in np.array(foot.exterior.coords)[:-1]] if foot is not None else None,
                          "fill_polygon": [[round(float(x), 4), round(float(y), 4)] for x, y in np.array(fill.exterior.coords)[:-1]] if fill is not None else None,
                          "seed": [round(float(v), 4) for v in seed] if seed is not None else None, "radius": a.seed_radius / s,
                          "plane": plane, "z_range": [round(float(CL[faces, 2].min()), 4), round(float(CL[faces, 2].max()), 4)] if len(faces) else None,
                          "ring_faces": int(len(ring)), "ring_material": ring_mat,
                          "ring_samples": [[round(float(v), 4) for v in p] for p in samples]})
            removed += ents_here
            print(f"  {items[-1]['id']}: {cls} {items[-1]['name']}: {len(faces)} faces, {len(cells)} voxels, ring {len(ring)} faces ({ring_mat})"
                  + (f", fill {fill.area * s * s:.2f} m²" if fill is not None else f", hole around {seed}"), flush=True)
    json.dump({"voxel": a.voxel, "voxel_units": vox, "levelled": T.tolist(), "est_scale": s, "frame": frame, "inventory": inv_id, "items": items,
               "removed_entities": sorted(set(removed)), "skipped": skipped}, open(out / "selection.json", "w"), indent=1)
    for sk in skipped:
        print(f"  skipped: {sk}")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        rng = np.random.default_rng(0)
        sel = rng.choice(len(Tri), min(300_000, len(Tri)), replace=False)
        fig = plt.figure(figsize=(9.6, 7.2))
        ax = fig.add_axes([0, 0, 1, 1])
        ax.scatter(CL[sel, 0] * s, CL[sel, 1] * s, s=0.3, c="#bbb", marker=".", linewidths=0, rasterized=True)
        for it in items:
            if it["fill_polygon"]:
                f = np.array(it["fill_polygon"]) * s
                ax.fill(f[:, 0], f[:, 1], color="#d97757" if it["cls"] == "remove" else "#4a90c8", alpha=0.5)
                ax.text(f[:, 0].mean(), f[:, 1].mean(), f"{it['cls']}: {it['name']}", fontsize=7, ha="center", va="center")
            elif it["seed"]:
                ax.plot(it["seed"][0] * s, it["seed"][1] * s, "o", color="#4a90c8", ms=6)
                ax.text(it["seed"][0] * s, it["seed"][1] * s, " patch here", fontsize=7, va="center")
        ax.set_aspect("equal"); ax.axis("off")
        fig.savefig(str(out / "selection.png"), dpi=100, facecolor="white", bbox_inches="tight")
        plt.close(fig)
    except Exception as e:
        print(f"preview not drawn: {e}", file=sys.stderr)
    print(f"{len(items)} edit items, {len(set(removed))} entities to remove")
    return 0 if items else 1


if __name__ == "__main__":
    sys.exit(main())
