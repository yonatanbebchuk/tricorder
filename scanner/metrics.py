"""Stage metrics computed from the files a stage leaves behind, plus thumbnails."""
from __future__ import annotations

import csv
import json
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np


def video_info(path: Path) -> dict:
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "stream=width,height,r_frame_rate,nb_frames,color_transfer",
                              "-show_entries", "format=duration", "-of", "json", str(path)],
                             capture_output=True, text=True, timeout=60).stdout
        j = json.loads(out)
        st = (j.get("streams") or [{}])[0]
        num, den = (st.get("r_frame_rate") or "30/1").split("/")
        trc = st.get("color_transfer") or ""
        return {"path": str(path), "size": path.stat().st_size, "duration_s": float(j.get("format", {}).get("duration", 0) or 0),
                "width": st.get("width"), "height": st.get("height"), "fps": float(num) / float(den or 1),
                "frames": int(st.get("nb_frames") or 0), "color_transfer": trc,
                "hdr": "hlg" if trc == "arib-std-b67" else "pq" if trc == "smpte2084" else "none"}
    except Exception as e:  # ffprobe missing or odd file
        return {"path": str(path), "size": path.stat().st_size if path.exists() else 0, "error": str(e), "hdr": "none"}


def frames_metrics(scan_dir: Path) -> dict:
    f = scan_dir / "images" / "frames.csv"
    if not f.exists():
        n = len(list((scan_dir / "images").glob("*.jpg"))) if (scan_dir / "images").exists() else 0
        return {"images": n}
    rows = list(csv.DictReader(open(f)))
    s = np.array([float(r["sharpness"]) for r in rows]) if rows else np.zeros(1)
    return {"images": len(rows), "sharpness_median": float(np.median(s)), "sharpness_min": float(s.min()),
            "sharpness_p10": float(np.percentile(s, 10))}


def sfm_metrics(run_dir: Path) -> dict:
    m: dict = {}
    sparse = run_dir / "dense" / "sparse"
    if not sparse.exists():
        sparse = run_dir / "sparse" / "0"
    if sparse.exists() and shutil.which("colmap"):
        out = subprocess.run(["colmap", "model_analyzer", "--path", str(sparse)], capture_output=True, text=True).stderr
        for key, pat in (("registered", r"Registered images: (\d+)"), ("points", r"Points: (\d+)"),
                         ("reproj_px", r"Mean reprojection error: ([\d.]+)px"), ("track_len", r"Mean track length: ([\d.]+)")):
            mm = re.search(pat, out)
            if mm:
                m[key] = float(mm[1]) if "." in mm[1] else int(mm[1])
    sd = run_dir / "sparse"
    if sd.exists():
        m["submodels"] = len([p for p in sd.iterdir() if p.is_dir()])
    imgs = run_dir / "images"
    if imgs.exists():
        m["images"] = len(list(imgs.glob("*.jpg")))
    return m


def ply_counts(path: Path) -> dict:
    """vertex / face counts from a PLY header without reading the body."""
    out = {}
    try:
        with open(path, "rb") as f:
            for _ in range(60):
                line = f.readline().decode("ascii", "replace").strip()
                if line.startswith("element vertex"):
                    out["vertices"] = int(line.split()[-1])
                elif line.startswith("element face"):
                    out["faces"] = int(line.split()[-1])
                elif line == "end_header":
                    break
    except OSError:
        pass
    return out


def dense_metrics(run_dir: Path) -> dict:
    d = run_dir / "dense"
    m: dict = {}
    if (d / "scene_dense.ply").exists():
        m["dense_points"] = ply_counts(d / "scene_dense.ply").get("vertices")
    if (d / "scene_dense_mesh.ply").exists():
        m["faces_raw"] = ply_counts(d / "scene_dense_mesh.ply").get("faces")
    if (d / "scene_dense_mesh_clean.ply").exists():
        m["faces"] = ply_counts(d / "scene_dense_mesh_clean.ply").get("faces")
    if (d / "scene_dense_mesh_texture.obj").exists():
        m["textured"] = True
    return m


def landmarks_metrics(run_dir: Path) -> dict:
    p = run_dir / "measure" / "prompts.json"
    if not p.exists():
        return {}
    j = json.load(open(p))
    dist = [x for x in j["prompts"] if x["type"] == "distance"]
    return {"prompts": len(dist), "structural": sum(1 for x in dist if x["a"].get("structural") and x["b"].get("structural")),
            "ground_prompt": any(x["type"] == "ground" for x in j["prompts"]),
            "north_prompt": any(x["type"] == "north" for x in j["prompts"]), "asked": j.get("count")}


def plan_metrics(run_dir: Path) -> dict:
    t = run_dir / "transform.json"
    if not t.exists():
        return {}
    j = json.load(open(t))
    return {"scale": j.get("scale"), "measurements": len(j.get("residuals", [])), "spread_pct": j.get("spread_pct"),
            "ground": j.get("ground"), "north": j.get("north"), "warning": j.get("warning", False),
            "max_residual_cm": max((abs(r["residual_cm"]) for r in j.get("residuals", [])), default=0.0)}


def make_thumbnail(src: Path, dst: Path, width: int = 640) -> bool:
    try:
        import cv2
        im = cv2.imread(str(src), cv2.IMREAD_UNCHANGED)
        if im is None:
            return False
        if im.ndim == 3 and im.shape[2] == 4:
            a = im[:, :, 3:4] / 255.0
            im = (im[:, :, :3] * a + 255 * (1 - a)).astype("uint8")
        s = width / im.shape[1]
        if s < 1:
            im = cv2.resize(im, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        dst.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(dst), im, [cv2.IMWRITE_JPEG_QUALITY, 82])
        return True
    except Exception:
        return False


def scan_thumbnail(scan_dir: Path) -> str | None:
    f = scan_dir / "images" / "frames.csv"
    if not f.exists():
        return None
    rows = list(csv.DictReader(open(f)))
    if not rows:
        return None
    # a sharp frame from the middle third of the walk usually shows the site, not the start point
    mid = rows[len(rows) // 3: 2 * len(rows) // 3] or rows
    best = max(mid, key=lambda r: float(r["sharpness"]))
    return "thumb.jpg" if make_thumbnail(scan_dir / "images" / best["image"], scan_dir / "thumb.jpg") else None
