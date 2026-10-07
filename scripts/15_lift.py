#!/usr/bin/env python3
"""Lift: every named mask onto the mesh. Mask pixels → rays through the frame's camera → faces (Open3D cast_rays gives the
face index); each hit votes for the mask's label with the model's confidence; faces take the label with the most weight.

    python scripts/15_lift.py <run_dir> --model <model3d asset> --frames <recording>/images [--per-mask 2500] [--min-weight 0.6]

Reads  <run>/segments/index.json, names.json, <stem>.npz; <model>/sparse/0; <model>/dense/scene_dense_mesh_clean.ply
       <run>/segments/carried_from.json (optional: a prior inventory's masks; its removed entities' masks are skipped)
Writes <run>/faces.npy        int32 per face: index into labels.json["labels"], -1 unlabelled
       <run>/labels.json      {"labels": [...], "faces", "labelled_faces", "names": {label: {name: weight}},
                               "descriptions": {label: {description: weight}}, "frames_per_label": {label: n}}
       <run>/lift/mask_faces.npz   per (frame, mask): the faces it hit (for the review stage's best-frame choice)
       <run>/lift_map.png     top-down map of the labelled faces
"""
import argparse
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402

PALETTE = {"area:grass": "#6fa24a", "area:brick": "#b24c3c", "area:sand": "#dec07a", "area:gravel": "#9a9a96", "area:concrete": "#bdbdb8",
           "area:deck": "#a06e46", "area:garden": "#7a5637", "area:soil": "#7a5637", "area:tiles": "#c9b7a0", "area:stone": "#8f8a80",
           "wall": "#3c3c3c", "fence": "#8c6a3c", "window": "#4a90c8", "door": "#c98a2a", "stairs": "#6d5aa8", "tree": "#2f6b3a",
           "bush": "#4f8f4a"}


def pose(im):
    cfw = im.cam_from_world() if callable(im.cam_from_world) else im.cam_from_world
    return np.asarray(cfw.rotation.matrix()), np.asarray(im.projection_center())


def face_neighbours(Tri: np.ndarray) -> np.ndarray:
    """(F, 3) neighbour face per edge, -1 where the edge is a boundary."""
    F = len(Tri)
    e = np.concatenate([Tri[:, [0, 1]], Tri[:, [1, 2]], Tri[:, [2, 0]]])
    e.sort(axis=1)
    fid = np.tile(np.arange(F), 3)
    order = np.lexsort((e[:, 1], e[:, 0]))
    e, fid = e[order], fid[order]
    same = np.all(e[1:] == e[:-1], axis=1)
    a, b = fid[:-1][same], fid[1:][same]
    N = np.full((F, 3), -1, dtype=np.int64)
    slot = np.zeros(F, dtype=np.int64)
    for x, y in ((a, b), (b, a)):
        # place y into the next free slot of x (duplicates past 3 are dropped)
        for k in range(3):
            free = slot[x] == k
            N[x[free], k] = y[free]
            slot[x[free]] += 1
            x, y = x[~free], y[~free]
            if len(x) == 0:
                break
    return N


def smooth_labels(Tri: np.ndarray, best: np.ndarray, passes: int) -> np.ndarray:
    """Mode filter over face adjacency: an unlabelled face takes a label two neighbours agree on; a labelled face flips
    when two neighbours agree on another one.  Fills the gaps left by sparse votes and removes speckle."""
    N = face_neighbours(Tri)
    valid = N >= 0
    cur = best.copy()
    for _ in range(passes):
        L = np.where(valid, cur[np.where(valid, N, 0)], -2)       # -2: no neighbour there
        c0, c1, c2 = L[:, 0], L[:, 1], L[:, 2]
        agree01 = (c0 == c1) & (c0 >= 0)
        agree02 = (c0 == c2) & (c0 >= 0)
        agree12 = (c1 == c2) & (c1 >= 0)
        mode = np.where(agree01 | agree02, c0, np.where(agree12, c1, -1))
        change = (mode >= 0) & (mode != cur)
        cur = np.where(change, mode, cur)
    return cur


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--per-mask", type=int, default=40000, help="pixels sampled per mask (big surfaces need many to cover their faces)")
    ap.add_argument("--smooth", type=int, default=8, help="label smoothing / gap filling passes over face adjacency")
    ap.add_argument("--min-weight", type=float, default=0.6, help="a face needs this much agreeing weight (≈ two confident views)")
    ap.add_argument("--max-depth", type=float, default=60.0)
    a = ap.parse_args()
    import open3d as o3d
    import pycolmap

    run, model, frames = Path(a.run), Path(a.model), Path(a.frames)
    seg = run / "segments"
    index = json.load(open(seg / "index.json"))
    names = json.load(open(seg / "names.json"))
    carried = json.load(open(seg / "carried_from.json")) if (seg / "carried_from.json").exists() else None
    removed_masks: set[tuple[str, str]] = set()
    if carried:
        prior_faces = json.load(open(seg / "entity_masks.json")) if (seg / "entity_masks.json").exists() else {}
        for eid in carried.get("removed_entities", []):
            for stem, mi in prior_faces.get(eid, []):
                removed_masks.add((stem, str(mi)))
        print(f"carried masks from {carried['prior']}; skipping {len(removed_masks)} masks of removed entities")

    rec = pycolmap.Reconstruction(str(model / "sparse" / "0"))
    by_name = {im.name: im for im in rec.images.values()}
    mesh = o3d.io.read_triangle_mesh(str(model / "dense" / "scene_dense_mesh_clean.ply"))
    F = len(mesh.triangles)
    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh))
    print(f"mesh: {F} faces; {len(index['frames'])} frames", flush=True)

    labels: list[str] = []
    lab_idx: dict[str, int] = {}
    # votes as a sparse (face, label) → weight accumulation: dict of label → (faces array, weights) lists, merged at the end
    votes: dict[int, list] = defaultdict(list)
    name_w: dict[str, dict] = defaultdict(lambda: defaultdict(float))
    desc_w: dict[str, dict] = defaultdict(lambda: defaultdict(float))
    frames_per_label: dict[str, set] = defaultdict(set)
    mask_faces: dict[str, np.ndarray] = {}
    rng = np.random.default_rng(0)
    t0 = time.time()
    for k, fr in enumerate(index["frames"]):
        ans = names["frames"].get(fr["stem"], {})
        if not ans:
            continue
        im = by_name.get(fr["name"])
        if im is None:
            print(f"  {fr['name']}: not registered, skipped", flush=True)
            continue
        cam = rec.cameras[im.camera_id]
        R, C = pose(im)
        M, _ = ic.load_masks(seg / fr["file"])
        sx, sy = fr["width"] / fr["work"][0], fr["height"] / fr["work"][1]
        hits = 0
        for mi in range(len(M)):
            an = ans.get(str(mi + 1))
            if not an or not an.get("label"):
                continue
            if (fr["stem"], str(mi)) in removed_masks:
                continue
            ys, xs = np.nonzero(M[mi])
            if len(xs) > a.per_mask:
                sel = rng.choice(len(xs), a.per_mask, replace=False)
                xs, ys = xs[sel], ys[sel]
            uv = np.column_stack([(xs + 0.5) * sx, (ys + 0.5) * sy]).astype(float)
            d_cam = np.asarray([cam.cam_ray_from_img(p) for p in uv])
            d = d_cam @ R
            d /= np.linalg.norm(d, axis=1, keepdims=True)
            rays = o3d.core.Tensor(np.hstack([np.tile(C, (len(d), 1)), d]).astype(np.float32))
            res = scene.cast_rays(rays)
            t = res["t_hit"].numpy()
            fid = res["primitive_ids"].numpy()
            ok = np.isfinite(t) & (t < a.max_depth) & (fid != o3d.t.geometry.RaycastingScene.INVALID_ID)
            if not ok.any():
                continue
            faces, counts = np.unique(fid[ok], return_counts=True)
            label = an["label"]
            if label not in lab_idx:
                lab_idx[label] = len(labels)
                labels.append(label)
            li = lab_idx[label]
            w = float(an.get("confidence", 0.5))
            # a mask's weight is spread over the faces it covers so that big and small masks count alike per view
            votes[li].append((faces.astype(np.int64), np.full(len(faces), w, dtype=np.float32)))
            mask_faces[f"{fr['stem']}/{mi}"] = faces.astype(np.int32)
            name_w[label][an.get("name") or label] += w
            if an.get("description"):
                desc_w[label][an["description"]] += w
            frames_per_label[label].add(fr["stem"])
            hits += int(ok.sum())
        print(f"  {k + 1}/{len(index['frames'])} {fr['name']}: {hits} hits, {time.time() - t0:.0f}s", flush=True)

    # merge votes: per label a dense weight vector over faces (labels are few, faces are many)
    best = np.full(F, -1, dtype=np.int32)
    best_w = np.zeros(F, dtype=np.float32)
    total_w = np.zeros(F, dtype=np.float32)
    for li, lst in votes.items():
        wv = np.zeros(F, dtype=np.float32)
        for faces, w in lst:
            np.add.at(wv, faces, w)
        total_w += wv
        better = wv > best_w
        best[better] = li
        best_w[better] = wv[better]
    weak = best_w < a.min_weight
    best[weak] = -1
    raw_labelled = int((best >= 0).sum())
    if a.smooth > 0:
        best = smooth_labels(Tri_arr := np.asarray(mesh.triangles), best, a.smooth)
        print(f"smoothing: {raw_labelled} -> {int((best >= 0).sum())} labelled faces after {a.smooth} passes", flush=True)
    np.save(run / "faces.npy", best)
    (run / "lift").mkdir(exist_ok=True)
    np.savez_compressed(run / "lift" / "mask_faces.npz", **mask_faces)
    out = {"labels": labels, "faces": int(F), "labelled_faces": int((best >= 0).sum()),
           "names": {l: dict(sorted(v.items(), key=lambda kv: -kv[1])[:8]) for l, v in name_w.items()},
           "descriptions": {l: dict(sorted(v.items(), key=lambda kv: -kv[1])[:5]) for l, v in desc_w.items()},
           "frames_per_label": {l: len(s) for l, s in frames_per_label.items()}, "min_weight": a.min_weight}
    json.dump(out, open(run / "labels.json", "w"), indent=1)
    counts = {l: int((best == i).sum()) for i, l in enumerate(labels)}
    print(f"labelled {out['labelled_faces']} / {F} faces: " + ", ".join(f"{l} {n}" for l, n in sorted(counts.items(), key=lambda kv: -kv[1])[:15]))

    # map
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        T = np.array(json.load(open(model / "transform_preview.json"))["matrix"]) if (model / "transform_preview.json").exists() else np.eye(4)
        V = np.asarray(mesh.vertices)
        Tri = np.asarray(mesh.triangles)
        sel = np.nonzero(best >= 0)[0]
        if len(sel) > 400_000:
            sel = rng.choice(sel, 400_000, replace=False)
        cen = V[Tri[sel]].mean(axis=1)
        cen = (T @ np.c_[cen, np.ones(len(cen))].T).T[:, :3]
        fig = plt.figure(figsize=(9.6, 7.2))
        ax = fig.add_axes([0, 0, 1, 1])
        for i, l in enumerate(labels):
            m = best[sel] == i
            if not m.any():
                continue
            col = PALETTE.get(l, "#d97757" if l.startswith("object") else "#777")
            ax.scatter(cen[m, 0], cen[m, 1], s=0.4, c=col, marker=".", linewidths=0, label=f"{l} ({int((best == i).sum())})", rasterized=True)
        ax.set_aspect("equal"); ax.axis("off")
        ax.legend(loc="lower right", fontsize=6, markerscale=14, ncol=2, framealpha=0.85)
        fig.savefig(str(run / "lift_map.png"), dpi=100, facecolor="white", bbox_inches="tight")
        plt.close(fig)
    except Exception as e:
        print(f"map not drawn: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
