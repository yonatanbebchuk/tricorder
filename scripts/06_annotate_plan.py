#!/usr/bin/env python3
"""Draw a 1 m grid, axis labels and a scale bar on the plan rendered by 05.

Usage: python scripts/06_annotate_plan.py work/backyard/plan [--grid 1.0]
Reads <prefix>.png + <prefix>.json, writes <prefix>_grid.png
"""
import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("prefix")
    ap.add_argument("--grid", type=float, default=1.0, help="grid spacing in metres")
    args = ap.parse_args()
    p = Path(args.prefix)
    meta = json.load(open(p.with_suffix(".json")))
    img = cv2.imread(str(p.with_suffix(".png")), cv2.IMREAD_UNCHANGED)
    if img is None:
        sys.exit("plan png not found")
    if img.shape[2] == 4:  # composite over white
        a = img[:, :, 3:4] / 255.0
        img = (img[:, :, :3] * a + 255 * (1 - a)).astype(np.uint8)
    px = meta["px_per_m"]
    H, W = img.shape[:2]
    x_min, y_max = meta["x_min"], meta["y_max"]
    grid, col = args.grid, (60, 60, 60)
    fs = max(0.4, px / 100)

    x = np.ceil(x_min / grid) * grid
    while x <= x_min + W / px:
        i = int(round((x - x_min) * px))
        cv2.line(img, (i, 0), (i, H - 1), col, 1)
        cv2.putText(img, f"{x:.0f}", (i + 3, H - 8), cv2.FONT_HERSHEY_SIMPLEX, fs, col, 1, cv2.LINE_AA)
        x += grid
    y = np.floor(y_max / grid) * grid
    while y >= y_max - H / px:
        j = int(round((y_max - y) * px))
        cv2.line(img, (0, j), (W - 1, j), col, 1)
        cv2.putText(img, f"{y:.0f}", (4, j - 3), cv2.FONT_HERSHEY_SIMPLEX, fs, col, 1, cv2.LINE_AA)
        y -= grid

    # scale bar: 5 m (or smaller if the plan is tiny)
    bar_m = 5 if W / px > 8 else 1
    bx, by = 20, 30
    cv2.rectangle(img, (bx, by), (bx + int(bar_m * px), by + 10), (0, 0, 0), -1)
    cv2.putText(img, f"{bar_m} m   grid {grid:g} m   {px:.1f} px/m", (bx, by - 6),
                cv2.FONT_HERSHEY_SIMPLEX, max(0.5, px / 80), (0, 0, 0), 1, cv2.LINE_AA)
    out = p.with_name(p.stem + "_grid.png")
    cv2.imwrite(str(out), img)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
