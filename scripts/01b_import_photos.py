#!/usr/bin/env python3
"""Import still photos as frames for photogrammetry: HEIC/PNG/DNG → JPEG, capped size, sharpness scored.

Photos taken with the iPhone camera (HEIC, 48 MP) are converted with sips (macOS) so nothing extra is installed; other
formats go through OpenCV. Every photo is kept (unlike video frames there is nothing to choose between); frames.csv has
the same columns as a video recording's so the rest of the pipeline treats both alike.

Usage: python scripts/01b_import_photos.py <photos_dir> <out_dir> [--max-dim 4032] [--quality 95]
"""
import argparse
import csv
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2

EXT = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".dng", ".tif", ".tiff"}


def sharpness(bgr) -> float:
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    if w > 960:
        gray = cv2.resize(gray, (960, int(h * 960 / w)), interpolation=cv2.INTER_AREA)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def load(path: Path, tmp: Path):
    im = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if im is not None:
        return im
    if shutil.which("sips"):                      # HEIC / DNG: let macOS decode (applies the EXIF rotation too)
        out = tmp / (path.stem + ".jpg")
        r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "98", str(path), "--out", str(out)],
                           capture_output=True, text=True)
        if r.returncode == 0 and out.exists():
            return cv2.imread(str(out), cv2.IMREAD_COLOR)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("photos_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--max-dim", type=int, default=4032, help="downscale so the longest side <= this (0 = keep)")
    ap.add_argument("--quality", type=int, default=95)
    a = ap.parse_args()
    src, out = Path(a.photos_dir), Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in src.iterdir() if p.suffix.lower() in EXT and not p.name.startswith("."))
    if not files:
        print(f"no photos in {src}", file=sys.stderr)
        return 1
    rows = []
    with tempfile.TemporaryDirectory() as td:
        for i, p in enumerate(files):
            im = load(p, Path(td))
            if im is None:
                print(f"  skip {p.name}: cannot decode")
                continue
            if a.max_dim and max(im.shape[:2]) > a.max_dim:
                s = a.max_dim / max(im.shape[:2])
                im = cv2.resize(im, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
            name = f"p{i:04d}.jpg"
            cv2.imwrite(str(out / name), im, [cv2.IMWRITE_JPEG_QUALITY, a.quality])
            sh = sharpness(im)
            rows.append((name, i, 0.0, sh, p.name))
            print(f"  {name}  {im.shape[1]}x{im.shape[0]}  sharpness {sh:.0f}  ({p.name})")
    with open(out / "frames.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["image", "source_frame", "time_s", "sharpness", "original"])
        w.writerows(rows)
    print(f"{len(rows)} photos -> {out}")
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
