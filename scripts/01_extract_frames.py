#!/usr/bin/env python3
"""Extract sharp, evenly spaced frames from a phone video for photogrammetry.

The video is split into windows of (source_fps / --fps) frames. Inside each
window --candidates frames are decoded and scored for sharpness (variance of
the Laplacian); the sharpest one is written out. This throws away motion-blurred
frames, which are the #1 cause of bad COLMAP reconstructions from video.

Usage:
  python scripts/01_extract_frames.py data/backyard.mp4 work/backyard/images --fps 2 --max-frames 400
"""
import argparse
import csv
import sys
from pathlib import Path

import cv2
import numpy as np


BT2020_TO_BT709 = np.array([[1.6605, -0.5876, -0.0728],
                            [-0.1246, 1.1329, -0.0083],
                            [-0.0182, -0.1006, 1.1187]], dtype=np.float32)


def hdr_to_sdr(bgr: np.ndarray, mode: str) -> np.ndarray:
    """Tone-map an 8-bit decode of HLG ('hlg', iPhone default) or PQ ('pq') video to SDR sRGB.

    OpenCV hands back the HDR signal values scaled to 8 bits, which look washed out. This
    linearises them (HLG inverse OETF + OOTF, or PQ EOTF), maps BT.2020 primaries to BT.709,
    scales so HDR reference white (203 nits) becomes SDR white, rolls off highlights, and
    applies the sRGB curve. Approximate, but plenty for feature matching and texturing.
    """
    x = bgr[..., ::-1].astype(np.float32) / 255.0
    if mode == "hlg":
        a, b, c = 0.17883277, 0.28466892, 0.55991073
        lin = np.where(x <= 0.5, x * x / 3.0, (np.exp((x - c) / a) + b) / 12.0)
        y = 0.2627 * lin[..., 0] + 0.6780 * lin[..., 1] + 0.0593 * lin[..., 2]
        lin *= (np.maximum(y, 1e-6) ** 0.2)[..., None]          # OOTF, gamma 1.2
        lin /= 0.203                                             # HLG 75% signal -> SDR white
    elif mode == "pq":
        m1, m2, c1, c2, c3 = 0.1593017578125, 78.84375, 0.8359375, 18.8515625, 18.6875
        xp = np.power(x, 1.0 / m2)
        lin = np.power(np.maximum(xp - c1, 0) / (c2 - c3 * xp), 1.0 / m1)   # 1.0 = 10000 nits
        lin /= 203.0 / 10000.0
    else:
        return bgr
    lin = np.clip(lin @ BT2020_TO_BT709.T, 0, None)
    w = 4.0                                                      # extended Reinhard, white point 4x SDR
    lin = lin * (1 + lin / (w * w)) / (1 + lin)
    srgb = np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * np.power(np.maximum(lin, 1e-7), 1 / 2.4) - 0.055)
    return (np.clip(srgb, 0, 1)[..., ::-1] * 255 + 0.5).astype(np.uint8)


def sharpness(bgr: np.ndarray) -> float:
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    if w > 960:
        gray = cv2.resize(gray, (960, int(h * 960 / w)), interpolation=cv2.INTER_AREA)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("out_dir")
    ap.add_argument("--fps", type=float, default=2.0, help="frames to keep per second of video (default 2)")
    ap.add_argument("--candidates", type=int, default=4, help="frames scored per kept frame (default 4)")
    ap.add_argument("--max-frames", type=int, default=400, help="hard cap on kept frames (default 400)")
    ap.add_argument("--max-dim", type=int, default=0, help="downscale so the longest side <= this px (0 = keep original)")
    ap.add_argument("--quality", type=int, default=95, help="JPEG quality")
    ap.add_argument("--hdr", choices=["none", "hlg", "pq"], default="none",
                    help="tone-map HDR video to SDR: 'hlg' for iPhone HDR video (ffprobe color_transfer=arib-std-b67), 'pq' for smpte2084")
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        print(f"error: cannot open {args.video}", file=sys.stderr)
        return 1
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    n_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    window = src_fps / args.fps
    if n_frames / window > args.max_frames:
        window = n_frames / args.max_frames
    cand_step = max(1, int(round(window / args.candidates)))

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    print(f"{args.video}: {width}x{height} @ {src_fps:.2f} fps, {n_frames} frames")
    print(f"keeping ~1 frame per {window:.1f} source frames, scoring every {cand_step} -> ~{int(n_frames / window)} images")

    rows = []
    best = None  # (score, idx, frame)
    cur_window = -1
    kept = 0

    def flush():
        nonlocal best, kept
        if best is None:
            return
        score, idx, frame = best
        if args.hdr != "none":
            frame = hdr_to_sdr(frame, args.hdr)
        if args.max_dim and max(frame.shape[:2]) > args.max_dim:
            s = args.max_dim / max(frame.shape[:2])
            frame = cv2.resize(frame, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        name = f"f{idx:06d}.jpg"
        cv2.imwrite(str(out / name), frame, [cv2.IMWRITE_JPEG_QUALITY, args.quality])
        rows.append((name, idx, idx / src_fps, score))
        kept += 1
        best = None

    idx = 0
    while True:
        if not cap.grab():
            break
        w = int(idx // window)
        if w != cur_window:
            flush()
            cur_window = w
        if idx % cand_step == 0:
            ok, frame = cap.retrieve()
            if ok:
                s = sharpness(frame)
                if best is None or s > best[0]:
                    best = (s, idx, frame)
        idx += 1
        if idx % 500 == 0:
            print(f"  scanned {idx}/{n_frames} frames, kept {kept}", end="\r", flush=True)
    flush()
    cap.release()

    with open(out / "frames.csv", "w", newline="") as f:
        wtr = csv.writer(f)
        wtr.writerow(["image", "source_frame", "time_s", "sharpness"])
        wtr.writerows(rows)

    scores = np.array([r[3] for r in rows]) if rows else np.zeros(1)
    print(f"\nwrote {kept} images to {out}  (sharpness median {np.median(scores):.0f}, min {scores.min():.0f})")
    if kept and scores.min() < 0.25 * np.median(scores):
        print("note: some windows had only blurry candidates; consider walking slower or re-shooting those parts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
