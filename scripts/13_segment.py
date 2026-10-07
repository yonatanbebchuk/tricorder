#!/usr/bin/env python3
"""Segment: every region of a subset of the registered frames becomes a mask (SAM, automatic mode, no vocabulary).

    python scripts/13_segment.py <run_dir> --model <model3d asset> --frames <recording>/images [--every 10] [--max 60]

Frames are the model's registered images (pycolmap, sparse/0), every n-th one up to a cap, so the lift stage can cast
every mask pixel through a known camera.  Each frame is worked at a long side of 1024 px; masks are stored bit-packed
at that size with the scale back to the original pixels, plus a preview with the outlines of the first frame.

Writes <run>/segments/index.json  {"sam", "work_long_side", "frames": [{"name", "stem", "width", "height", "work": [w, h],
                                   "masks": n, "file"}], "masks": total}
       <run>/segments/<stem>.npz   masks (bit-packed uint8, N x H x W at work size), areas, scores, boxes
       <run>/segments/preview.jpg  the first frame with its mask outlines
Env: TRICORDER_SAM (checkpoint, default facebook/sam-vit-base), PYTORCH_ENABLE_MPS_FALLBACK=1 is set.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("OMP_NUM_THREADS", "6")
import numpy as np  # noqa: E402

WORK_LONG = 1024
MAX_MASKS = 30          # set-of-mark readability: the model names at most this many regions per frame
MIN_AREA_FRAC = 0.002   # masks smaller than 0.2 % of the frame are noise for a site plan


def pick_frames(model: Path, frames: Path, every: int, cap: int) -> list[str]:
    import pycolmap
    rec = pycolmap.Reconstruction(str(model / "sparse" / "0"))
    names = sorted(im.name for im in rec.images.values())
    names = [n for n in names if (frames / n).exists()]
    chosen = names[::every][:cap]
    if len(chosen) < min(cap, len(names)) and len(names) > 0:    # too few: spread the cap evenly instead
        idx = np.linspace(0, len(names) - 1, min(cap, len(names))).round().astype(int)
        chosen = [names[i] for i in sorted(set(idx))]
    return chosen


def outline_preview(img, masks, dst: Path) -> None:
    import cv2
    rgb = np.array(img)[:, :, ::-1].copy()
    rng = np.random.default_rng(1)
    for m in masks:
        color = tuple(int(c) for c in rng.integers(60, 255, 3))
        cnts, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(rgb, cnts, -1, color, 2)
    cv2.imwrite(str(dst), rgb, [cv2.IMWRITE_JPEG_QUALITY, 85])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--every", type=int, default=10)
    ap.add_argument("--max", type=int, default=60)
    ap.add_argument("--points-per-side", type=int, default=24)
    a = ap.parse_args()
    import torch
    from PIL import Image
    from transformers import pipeline

    run, model, frames = Path(a.run), Path(a.model), Path(a.frames)
    out = run / "segments"
    out.mkdir(parents=True, exist_ok=True)
    chosen = pick_frames(model, frames, a.every, a.max)
    if not chosen:
        sys.exit("no registered frames found on disk")
    sam = os.environ.get("TRICORDER_SAM", "facebook/sam-vit-base")
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"{len(chosen)} frames (every {a.every}, cap {a.max}); SAM {sam} on {dev}", flush=True)
    try:
        gen = pipeline("mask-generation", model=sam, device=dev)
    except Exception as e:
        print(f"SAM on {dev} failed ({e}); using CPU", flush=True)
        dev = "cpu"
        gen = pipeline("mask-generation", model=sam, device="cpu")

    index = {"sam": sam, "work_long_side": WORK_LONG, "device": dev, "frames": [], "masks": 0}
    t0 = time.time()
    for k, name in enumerate(chosen):
        img = Image.open(frames / name).convert("RGB")
        W0, H0 = img.size
        s = WORK_LONG / max(W0, H0)
        work = img.resize((max(1, round(W0 * s)), max(1, round(H0 * s))), Image.BILINEAR)
        t1 = time.time()
        try:
            res = gen(work, points_per_batch=64, points_per_side=a.points_per_side, pred_iou_thresh=0.86,
                      stability_score_thresh=0.9, crops_n_layers=0)
        except Exception as e:
            if dev != "cpu":
                print(f"  {name}: SAM on {dev} failed ({e}); switching to CPU", flush=True)
                dev = "cpu"
                gen = pipeline("mask-generation", model=sam, device="cpu")
                index["device"] = dev
                res = gen(work, points_per_batch=64, points_per_side=a.points_per_side, pred_iou_thresh=0.86,
                          stability_score_thresh=0.9, crops_n_layers=0)
            else:
                raise
        masks = [np.asarray(m, dtype=bool) for m in res["masks"]]
        scores = [float(x) for x in np.asarray(res["scores"]).ravel()] if "scores" in res else [1.0] * len(masks)
        area_min = MIN_AREA_FRAC * work.size[0] * work.size[1]
        keep = [(m, sc) for m, sc in zip(masks, scores) if m.sum() >= area_min]
        keep.sort(key=lambda t: -int(t[0].sum()))
        keep = keep[:MAX_MASKS]
        if not keep:
            print(f"  {name}: no masks", flush=True)
            continue
        M = np.stack([m for m, _ in keep])
        boxes = []
        for m in M:
            ys, xs = np.nonzero(m)
            boxes.append([int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())])
        stem = Path(name).stem
        np.savez_compressed(out / f"{stem}.npz", masks=np.packbits(M, axis=-1), shape=np.array(M.shape), areas=M.sum(axis=(1, 2)),
                            scores=np.array([sc for _, sc in keep], dtype=np.float32), boxes=np.array(boxes, dtype=np.int32))
        index["frames"].append({"name": name, "stem": stem, "width": W0, "height": H0, "work": [work.size[0], work.size[1]],
                                "masks": int(len(M)), "file": f"{stem}.npz"})
        index["masks"] += int(len(M))
        if k == 0:
            outline_preview(work, M, out / "preview.jpg")
        print(f"  {k + 1}/{len(chosen)} {name}: {len(masks)} masks, {len(M)} kept, {time.time() - t1:.1f}s "
              f"(total {time.time() - t0:.0f}s)", flush=True)
    index["seconds_per_frame"] = round((time.time() - t0) / max(1, len(index["frames"])), 1)
    json.dump(index, open(out / "index.json", "w"), indent=1)
    print(f"segmented {len(index['frames'])} frames, {index['masks']} masks, {index['seconds_per_frame']} s/frame")
    return 0


if __name__ == "__main__":
    sys.exit(main())
