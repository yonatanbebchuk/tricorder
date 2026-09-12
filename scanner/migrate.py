"""Import legacy flat runs (work/<name>/ with run_all.log) into the scan/run layout.

    python -m scanner.migrate            # migrates every legacy folder it finds
    python -m scanner.migrate backyard   # just one

Moves (not copies): work/<name>/images -> work/scans/<name>/images, everything else -> runs/r1/.
The old run_all.log is split into per-stage logs by its '########' markers.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
from pathlib import Path

from . import metrics
from .models import ROOT, SCANS, FrameSettings, Run, RunSettings, Scan, Stage, now, slugify

WORK = ROOT / "work"
MARK = re.compile(r"^######## (?:(\d)\. (\w[\w-]*)|(done) in (\d+) min).*?\[(\d\d:\d\d:\d\d), \+(\d+)m\].*$", re.M)
LEGACY_STAGE = {1: "frames", 2: "sfm", 3: "dense", 4: "landmarks", 5: "plan"}


def split_log(text: str) -> dict[str, str]:
    marks = list(MARK.finditer(text))
    out: dict[str, str] = {}
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        if m.group(1):
            name = LEGACY_STAGE.get(int(m.group(1)))
            if name:
                out[name] = out.get(name, "") + text[m.start():end]
    return out


def migrate(name: str) -> str | None:
    src = WORK / name
    log = src / "run_all.log"
    if not src.is_dir() or not log.exists():
        return None
    text = log.read_text(errors="replace")
    video = re.search(r"^video: (.*)$", text, re.M)
    settings = dict(re.findall(r"(\w+)=([\w.]+)", (re.search(r"^settings: (.*)$", text, re.M) or [None, ""])[1]))
    # a legacy folder whose images/ is a symlink into another legacy folder is a second run of that scan
    link = src / "images"
    parent_scan = None
    if link.is_symlink():
        target = Path(os.readlink(link))
        parts = [q for q in target.parts if q not in ("..", ".")]
        if len(parts) >= 2 and parts[-1] == "images":
            parent_scan = slugify(parts[-2])
    if parent_scan and (SCANS / parent_scan / "scan.json").exists():
        scan = Scan.load(parent_scan)
        sid = scan.id
        link.unlink()
        rid = f"r{len(scan.run_ids()) + 1}"
    else:
        sid = slugify(name)
        if (SCANS / sid).exists():
            print(f"{name}: scans/{sid} already exists, skipping")
            return None
        vpath = Path(video[1]) if video else None
        vinfo = metrics.video_info(ROOT / vpath) if vpath and (ROOT / vpath).exists() else {"path": video[1] if video else "", "hdr": "none"}
        scan = Scan(id=sid, name=name, created_at=now(), video=vinfo,
                    frame_settings=FrameSettings(fps=float(settings.get("fps", 2)), max_frames=int(settings.get("max_frames", 400))))
        scan.dir.mkdir(parents=True)
        if link.is_dir() and not link.is_symlink():
            shutil.move(str(link), str(scan.dir / "images"))
        elif link.is_symlink():
            link.unlink()
        scan.frames = Stage(status="done" if (scan.dir / "images" / "frames.csv").exists() else "pending",
                            metrics=metrics.frames_metrics(scan.dir), log="logs/frames.log")
        scan.thumbnail = metrics.scan_thumbnail(scan.dir)
        rid = "r1"
    run = Run(id=rid, scan_id=sid, created_at=now(),
              settings=RunSettings(res_level=int(settings.get("res_level", 2)), features=settings.get("features", "SIFT"),
                                   matcher=settings.get("matcher", "BRUTEFORCE"), matching=settings.get("matching", "vocab"),
                                   relaxed=int(settings.get("relaxed", 1))),
              label=f"migrated from work/{name}")
    run.dir.mkdir(parents=True)
    for p in list(src.iterdir()):
        if p.name in ("run_all.log", "run.pid", "plan.pid"):
            continue
        shutil.move(str(p), str(run.dir / p.name))
    (run.dir / "images").symlink_to("../../images")
    (run.dir / "logs").mkdir(exist_ok=True)
    (scan.dir / "logs").mkdir(exist_ok=True)
    parts = split_log(text)
    for st, body in parts.items():
        dest = (scan.dir if st == "frames" else run.dir) / "logs" / f"{st}.log"
        dest.write_text(body)
    (run.dir / "logs" / "legacy_run_all.log").write_text(text)
    done, failed = (src / "DONE").exists() or (run.dir / "DONE").exists(), (run.dir / "FAILED").exists()
    for st, fn in (("sfm", metrics.sfm_metrics), ("dense", metrics.dense_metrics),
                   ("landmarks", metrics.landmarks_metrics), ("plan", metrics.plan_metrics)):
        m = fn(run.dir)
        has = {"sfm": (run.dir / "dense" / "sparse").exists(), "dense": (run.dir / "dense" / "scene_dense_mesh_texture.obj").exists(),
               "landmarks": (run.dir / "measure" / "prompts.json").exists(), "plan": (run.dir / "transform.json").exists()}[st]
        run.stages[st] = Stage(status="done" if has else "pending", metrics=m, log=f"logs/{st}.log" if st in parts else None)
    if run.stages["plan"].status == "done":
        run.plan_versions.append({"at": now(), **metrics.plan_metrics(run.dir)})
    run.status = "done" if done or run.stages["landmarks"].status == "done" else "failed" if failed else "interrupted"
    for f in ("DONE", "FAILED", "PLAN_DONE", "PLAN_FAILED"):
        (run.dir / f).unlink(missing_ok=True)
    if (run.dir / "preview_plan_grid.png").exists():
        metrics.make_thumbnail(run.dir / "plan_grid.png" if (run.dir / "plan_grid.png").exists() else run.dir / "preview_plan_grid.png", run.dir / "thumb.jpg")
    run.save()
    scan.save()
    src.rmdir() if not any(src.iterdir()) else None
    print(f"{name}: -> scans/{sid}/runs/{rid}  ({run.status}; stages " + ", ".join(f"{k}={v.status}" for k, v in run.stages.items()) + ")")
    return sid


def main(argv=None) -> int:
    names = (argv if argv is not None else sys.argv[1:]) or [p.name for p in WORK.iterdir() if p.is_dir() and p.name != "scans" and (p / "run_all.log").exists()]
    for n in names:
        migrate(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
