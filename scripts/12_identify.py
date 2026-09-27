#!/usr/bin/env python3
"""Identify what is where: ground materials and site elements, from the video frames, lifted onto the 3D model.

    python scripts/12_identify.py <run_dir> --model <model3d asset> --frames <recording>/images [--every 6] [--max 150]

For a subset of the registered frames, an open-vocabulary detector (Grounding DINO) finds concepts by name and SAM
turns each box into a mask.  Every mask pixel (sub-sampled) becomes a ray through that frame's camera (pycolmap,
the scan's own OPENCV model) that is intersected with the model's mesh.  Hits on the ground vote for a material in a
10 cm grid; hits on objects are clustered into instances.  Many frames see each spot, so votes from different views
agree or cancel out.  Runs on the Mac's GPU (detector) and CPU (SAM) at a few seconds per frame.

Reads  <run>/transform.json (model → metres), <model>/sparse/0 (poses), <model>/dense/scene_dense_mesh_clean.ply
Writes <run>/identify.json  {"surfaces": {label: [polygon ...]}, "objects": [{label, centroid, bbox, height, count, frames}],
                             "cell", "labels"} and <run>/identify_map.png (debug)
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")   # torch and Open3D each ship an OpenMP runtime
os.environ.setdefault("OMP_NUM_THREADS", "4")
import torch  # noqa: E402  (must load before Open3D / pycolmap for the OpenMP runtimes to coexist)
import numpy as np  # noqa: E402

SURFACES = {"brick pavement": "brick", "grass lawn": "grass", "sand": "sand", "garden bed": "garden", "gravel": "gravel",
            "concrete": "concrete", "wooden deck": "deck", "mulch": "garden", "soil": "garden"}
OBJECTS = ["door", "gate", "window", "stairs", "shed", "tree", "wooden fence", "table", "chair", "grill", "pot"]
COLORS = {"brick": (178, 76, 60), "grass": (110, 160, 70), "sand": (222, 190, 120), "garden": (120, 85, 55), "gravel": (150, 150, 150),
          "concrete": (190, 190, 185), "deck": (160, 110, 70)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--every", type=int, default=6)
    ap.add_argument("--max", type=int, default=150)
    ap.add_argument("--cell", type=float, default=0.1)
    ap.add_argument("--threshold", type=float, default=0.3)
    ap.add_argument("--stride", type=int, default=10, help="mask pixel sub-sampling")
    ap.add_argument("--out", default="identify.json")
    a = ap.parse_args()
    import cv2
    import open3d as o3d
    import pycolmap
    from PIL import Image
    from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor, SamModel, SamProcessor

    run, model, frames = Path(a.run), Path(a.model), Path(a.frames)
    T = np.array(json.load(open(run / "transform.json"))["matrix"])
    rec = pycolmap.Reconstruction(str(model / "sparse" / "0"))
    images = sorted(rec.images.values(), key=lambda im: im.name)
    chosen = images[:: a.every][: a.max]
    mesh = o3d.io.read_triangle_mesh(str(model / "dense" / "scene_dense_mesh_clean.ply"))
    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh))

    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    gp = AutoProcessor.from_pretrained("IDEA-Research/grounding-dino-base")
    gm = AutoModelForZeroShotObjectDetection.from_pretrained("IDEA-Research/grounding-dino-base").to(dev).eval()
    sp = SamProcessor.from_pretrained("facebook/sam-vit-base")
    sm = SamModel.from_pretrained("facebook/sam-vit-base").eval()
    labels = list(SURFACES) + OBJECTS
    text = ". ".join(labels) + "."

    def pose(im):
        cfw = im.cam_from_world() if callable(im.cam_from_world) else im.cam_from_world
        return np.asarray(cfw.rotation.matrix()), np.asarray(im.projection_center())

    votes: dict = {}                      # (ix, iy) -> {material: weight}
    hits_obj: dict = {l: [] for l in OBJECTS}
    t0 = time.time()
    for k, im in enumerate(chosen):
        path = frames / im.name
        if not path.exists():
            continue
        img = Image.open(path).convert("RGB")
        W0, H0 = img.size
        img.thumbnail((1200, 1200))
        sx, sy = W0 / img.size[0], H0 / img.size[1]
        inp = gp(images=img, text=text, return_tensors="pt").to(dev)
        with torch.no_grad():
            res = gm(**inp)
        det = gp.post_process_grounded_object_detection(res, inp.input_ids, threshold=a.threshold, text_threshold=0.25,
                                                        target_sizes=[img.size[::-1]])[0]
        boxes = det["boxes"].cpu().numpy()
        scores = det["scores"].cpu().numpy()
        names = [str(n) for n in det.get("text_labels", det.get("labels"))]
        keep = [i for i, n in enumerate(names) if n in labels]
        if not keep:
            continue
        si = sp(img, input_boxes=[[list(map(float, boxes[i])) for i in keep]], return_tensors="pt")
        with torch.no_grad():
            so = sm(**si)
        masks = sp.image_processor.post_process_masks(so.pred_masks, si["original_sizes"], si["reshaped_input_sizes"])[0]
        cam = rec.cameras[im.camera_id]
        R, C = pose(im)
        for mi, i in enumerate(keep):
            m = masks[mi][0].numpy() if masks[mi].ndim == 3 else masks[mi].numpy()
            ys, xs = np.nonzero(m[:: a.stride, :: a.stride])
            if len(xs) == 0:
                continue
            uv = np.column_stack([xs * a.stride * sx, ys * a.stride * sy]).astype(float)
            d_cam = np.array([cam.cam_ray_from_img(p) for p in uv])
            d = d_cam @ R                                    # R.T @ d for each row
            d /= np.linalg.norm(d, axis=1, keepdims=True)
            rays = o3d.core.Tensor(np.hstack([np.tile(C, (len(d), 1)), d]).astype(np.float32))
            t = scene.cast_rays(rays)["t_hit"].numpy()
            ok = np.isfinite(t) & (t < 30)
            if not ok.any():
                continue
            P = C + t[ok, None] * d[ok]
            Pm = (T @ np.hstack([P, np.ones((len(P), 1))]).T).T[:, :3]
            name, score = names[i], float(scores[i])
            if name in SURFACES:
                ground = Pm[np.abs(Pm[:, 2]) < 0.35]
                mat = SURFACES[name]
                for x, y in ground[:, :2]:
                    key = (int(np.floor(x / a.cell)), int(np.floor(y / a.cell)))
                    votes.setdefault(key, {}).setdefault(mat, 0.0)
                    votes[key][mat] += score
            else:
                hits_obj[name].append(np.column_stack([Pm, np.full(len(Pm), score), np.full(len(Pm), k)]))
        if k % 10 == 0:
            print(f"  {k + 1}/{len(chosen)} frames, {time.time() - t0:.0f}s, {len(votes)} ground cells voted", flush=True)

    # surfaces: majority per cell -> label raster -> polygons
    if votes:
        keys = np.array(list(votes.keys()))
        ix0, iy0 = keys[:, 0].min(), keys[:, 1].min()
        W, H = keys[:, 0].max() - ix0 + 1, keys[:, 1].max() - iy0 + 1
        mats = sorted({m for v in votes.values() for m in v})
        raster = np.full((H, W), -1, dtype=np.int32)
        for (ix, iy), v in votes.items():
            best = max(v.items(), key=lambda kv: kv[1])
            if best[1] >= 0.6:                              # at least two confident views, roughly
                raster[iy - iy0, ix - ix0] = mats.index(best[0])
        surfaces = {}
        for mi, mat in enumerate(mats):
            mask = (raster == mi).astype(np.uint8)
            mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
            mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
            cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            polys = []
            for c in cnts:
                if cv2.contourArea(c) * a.cell * a.cell < 0.5:
                    continue
                c = cv2.approxPolyDP(c, 1.5, True).reshape(-1, 2)
                polys.append([[round(float((x + ix0 + 0.5) * a.cell), 3), round(float((y + iy0 + 0.5) * a.cell), 3)] for x, y in c])
            if polys:
                surfaces[mat] = polys
    else:
        surfaces, raster, mats, ix0, iy0 = {}, None, [], 0, 0

    # objects: cluster hit points per label
    from sklearn.cluster import DBSCAN
    objects = []
    for name, chunks in hits_obj.items():
        if not chunks:
            continue
        Pts = np.vstack(chunks)
        lab = DBSCAN(eps=0.5, min_samples=25).fit(Pts[:, :2]).labels_
        for l in set(lab) - {-1}:
            c = Pts[lab == l]
            if len(set(c[:, 4].astype(int))) < 2:            # seen from at least two frames
                continue
            objects.append({"label": name, "centroid": [round(float(v), 3) for v in c[:, :3].mean(axis=0)],
                            "bbox": [[round(float(v), 3) for v in c[:, :2].min(axis=0)], [round(float(v), 3) for v in c[:, :2].max(axis=0)]],
                            "z_range": [round(float(c[:, 2].min()), 2), round(float(c[:, 2].max()), 2)],
                            "count": int(len(c)), "frames": int(len(set(c[:, 4].astype(int)))), "score": round(float(c[:, 3].mean()), 2)})
    objects.sort(key=lambda o: -o["count"])
    json.dump({"cell": a.cell, "labels": labels, "surfaces": surfaces, "objects": objects, "frames_used": len(chosen)},
              open(run / a.out, "w"), indent=1)
    print(f"surfaces: " + ", ".join(f"{m} ({len(p)} polygons)" for m, p in surfaces.items()))
    for o in objects[:20]:
        print(f"  {o['label']:14s} at ({o['centroid'][0]:.1f}, {o['centroid'][1]:.1f}) z {o['z_range'][0]:.1f}..{o['z_range'][1]:.1f} m, "
              f"{o['count']} hits from {o['frames']} frames")

    # debug map
    if raster is not None:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            rgb = np.full((*raster.shape, 3), 255, np.uint8)
            for mi, mat in enumerate(mats):
                rgb[raster == mi] = COLORS.get(mat, (120, 120, 200))
            fig, ax = plt.subplots(figsize=(12, 10))
            ax.imshow(rgb, origin="lower", extent=[ix0 * a.cell, (ix0 + W) * a.cell, iy0 * a.cell, (iy0 + H) * a.cell])
            for o in objects:
                ax.plot(o["centroid"][0], o["centroid"][1], "o", color="black", ms=4)
                ax.text(o["centroid"][0], o["centroid"][1], f" {o['label']}", fontsize=7)
            for mi, mat in enumerate(mats):
                ax.plot([], [], "s", color=np.array(COLORS.get(mat, (120, 120, 200))) / 255, label=mat)
            ax.legend(loc="lower right", fontsize=8); ax.set_aspect("equal"); ax.grid(True, lw=0.3)
            ax.set_title(f"materials and elements from {len(chosen)} frames")
            fig.savefig(run / "identify_map.png", dpi=70, bbox_inches="tight")
        except Exception as e:
            print(f"map not drawn: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
