"""Pipeline orchestrator: runs the stage scripts for a run and keeps run.json / scan.json current.

    python -m scanner.pipeline new data/backyard.MOV --name "Backyard noon" [--fps 2 --max-frames 600 ...] [--start]
    python -m scanner.pipeline run   <scan_id> <run_id>      # frames (if needed) -> sfm -> dense -> landmarks
    python -m scanner.pipeline plan  <scan_id> <run_id>      # scale/level/north from answers, plan render
    python -m scanner.pipeline new-run <scan_id> [--features ALIKED ...] [--start]

Stage scripts are unchanged (scripts/01..06, 02_sfm.sh, 03_dense.sh, pick_landmarks.py, solve_scale.py);
this module only decides what to run, where to log, and records status + metrics.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import metrics
from .models import (DATA, ROOT, SCANS, FrameSettings, Run, RunSettings, Scan, now, slugify, unique_id)

PY = sys.executable
SCRIPTS = ROOT / "scripts"
BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------- creation

def create_scan(video: Path, name: str | None = None, fs: FrameSettings | None = None) -> Scan:
    video = video if video.is_absolute() else ROOT / video
    if not video.exists():
        raise FileNotFoundError(video)
    name = name or video.stem
    sid = unique_id(slugify(name), SCANS)
    info = metrics.video_info(video)
    info["path"] = os.path.relpath(video, ROOT)
    scan = Scan(id=sid, name=name, created_at=now(), video=info, frame_settings=fs or FrameSettings())
    scan.save()
    return scan


def create_run(scan: Scan, settings: RunSettings | None = None, label: str = "") -> Run:
    rd = scan.dir / "runs"
    rd.mkdir(parents=True, exist_ok=True)
    n = 1
    while (rd / f"r{n}").exists():
        n += 1
    run = Run(id=f"r{n}", scan_id=scan.id, created_at=now(), settings=settings or RunSettings(), label=label)
    run.save()
    link = run.dir / "images"
    if not link.exists():
        link.symlink_to("../../images")
    (run.dir / "logs").mkdir(exist_ok=True)
    return run


# ---------------------------------------------------------------- execution

def _exec(cmd: list[str], log: Path, env: dict | None = None, cwd: Path | None = None) -> int:
    """Run a stage command, appending stdout+stderr to its log. Returns the exit code."""
    with open(log, "a") as f:
        f.write(f"\n$ {' '.join(cmd)}\n")
        f.flush()
        p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=cwd or ROOT,
                             env={**os.environ, "PYTHONUNBUFFERED": "1", **(env or {})})
        _exec.current = p
        try:
            return p.wait()
        finally:
            _exec.current = None


_exec.current = None


def _stage(owner, name: str, fn) -> None:
    """Mark a stage running, run fn(log_path) -> metrics dict, mark done/failed. Raises on failure."""
    st = owner.frames if name == "frames" else owner.stages[name]
    st.status, st.started_at, st.finished_at, st.error = "running", now(), None, None
    st.log = f"logs/{name}.log"
    owner.save()
    log = owner.dir / st.log
    log.parent.mkdir(exist_ok=True)
    try:
        st.metrics = fn(log) or {}
        st.status = "done"
    except Cancelled:
        st.status = "cancelled"
        st.error = "cancelled"
        raise
    except Exception as e:
        st.status = "failed"
        st.error = str(e)[:500]
        raise
    finally:
        st.finished_at = now()
        owner.save()


def _check(rc: int, what: str) -> None:
    if rc == -signal.SIGTERM or rc == 143:
        raise Cancelled()
    if rc != 0:
        raise RuntimeError(f"{what} exited with code {rc}")


def stage_frames(scan: Scan) -> dict:
    def fn(log: Path) -> dict:
        fs = scan.frame_settings
        hdr = scan.video.get("hdr", "none") if fs.hdr == "auto" else fs.hdr
        cmd = [PY, str(SCRIPTS / "01_extract_frames.py"), str(ROOT / scan.video["path"]), str(scan.dir / "images"),
               "--fps", str(fs.fps), "--max-frames", str(fs.max_frames)]
        if hdr != "none":
            cmd += ["--hdr", hdr]
        _check(_exec(cmd, log), "frame extraction")
        scan.thumbnail = metrics.scan_thumbnail(scan.dir)
        return metrics.frames_metrics(scan.dir)
    _stage(scan, "frames", fn)
    return scan.frames.metrics


def stage_sfm(run: Run) -> None:
    def fn(log: Path) -> dict:
        _check(_exec(["bash", str(SCRIPTS / "02_sfm.sh"), str(run.dir / "images"), str(run.dir)], log, env=run.settings.env()), "COLMAP")
        return metrics.sfm_metrics(run.dir)
    _stage(run, "sfm", fn)


def stage_dense(run: Run) -> None:
    def fn(log: Path) -> dict:
        _check(_exec(["bash", str(SCRIPTS / "03_dense.sh"), str(run.dir / "dense")], log, env=run.settings.env()), "OpenMVS")
        return metrics.dense_metrics(run.dir)
    _stage(run, "dense", fn)


def render_plan(run: Run, transform: Path, out_prefix: str, log: Path, px_per_m: int = 100) -> None:
    if not os.path.exists(BLENDER):
        with open(log, "a") as f:
            f.write(f"Blender not found at {BLENDER}; skipping render\n")
        return
    _check(_exec([BLENDER, "--background", "--python", str(SCRIPTS / "05_site_plan_blender.py"), "--",
                  "--mesh", str(run.dir / "dense" / "scene_dense_mesh_texture.obj"), "--transform", str(transform),
                  "--out", str(run.dir / out_prefix), "--px-per-m", str(px_per_m)], log), "Blender render")
    _check(_exec([PY, str(SCRIPTS / "06_annotate_plan.py"), str(run.dir / out_prefix)], log), "grid overlay")


def stage_landmarks(run: Run) -> None:
    def fn(log: Path) -> dict:
        _check(_exec([PY, str(SCRIPTS / "04_scale_model.py"), "--cloud", str(run.dir / "dense" / "scene_dense.ply"),
                      "--factor", "1.0", "--colmap-sparse", str(run.dir / "dense" / "sparse"),
                      "--out", str(run.dir / "transform_preview.json")], log), "preview levelling")
        render_plan(run, run.dir / "transform_preview.json", "preview_plan", log)
        _check(_exec([PY, str(SCRIPTS / "pick_landmarks.py"), str(run.dir), "--count", str(run.settings.measures)], log), "landmark picking")
        if (run.dir / "preview_plan_grid.png").exists():
            metrics.make_thumbnail(run.dir / "preview_plan_grid.png", run.dir / "thumb.jpg")
        return metrics.landmarks_metrics(run.dir)
    _stage(run, "landmarks", fn)


def stage_plan(run: Run, px_per_m: int = 50) -> None:
    def fn(log: Path) -> dict:
        _check(_exec([PY, str(SCRIPTS / "solve_scale.py"), str(run.dir)], log), "scale solve")
        render_plan(run, run.dir / "transform.json", "plan", log, px_per_m)
        rc = _exec([PY, "-c", (
            "import json,sys,numpy as np,open3d as o3d;from pathlib import Path;w=Path(sys.argv[1]);"
            "T=np.array(json.load(open(w/'transform.json'))['matrix']);p=o3d.io.read_point_cloud(str(w/'dense/scene_dense.ply'));"
            "p.transform(T);o3d.io.write_point_cloud(str(w/'dense/scene_dense_metric.ply'),p);e=p.get_axis_aligned_bounding_box().get_extent();"
            "print(f'metric cloud: {e[0]:.1f} m x {e[1]:.1f} m, height {e[2]:.1f} m')"), str(run.dir)], log)
        _check(rc, "metric cloud")
        if (run.dir / "plan_grid.png").exists():
            metrics.make_thumbnail(run.dir / "plan_grid.png", run.dir / "thumb.jpg")
        m = metrics.plan_metrics(run.dir)
        run.plan_versions.append({"at": now(), **m})
        return m
    _stage(run, "plan", fn)


def _install_cancel_handler(run: Run):
    def handler(signum, frame):
        p = _exec.current
        if p is not None and p.poll() is None:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except ProcessLookupError:
                p.terminate()
        raise Cancelled()
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def run_pipeline(scan_id: str, run_id: str) -> int:
    scan, run = Scan.load(scan_id), Run.load(scan_id, run_id)
    run.status, run.pid, run.started_at, run.finished_at = "running", os.getpid(), now(), None
    run.save()
    _install_cancel_handler(run)
    try:
        need_frames = scan.frames.status != "done" or not (scan.dir / "images" / "frames.csv").exists()
        if need_frames:
            stage_frames(scan)
        for name, fn in (("sfm", stage_sfm), ("dense", stage_dense), ("landmarks", stage_landmarks)):
            if run.stages[name].status == "done":
                continue
            fn(run)
        run.status = "done"
    except Cancelled:
        run.status = "cancelled"
        if scan.frames.status == "running":
            scan.frames.status, scan.frames.finished_at = "cancelled", now()
            scan.save()
    except Exception as e:
        run.status = "failed"
        print(f"run failed: {e}", file=sys.stderr)
    finally:
        run.finished_at, run.pid = now(), None
        run.save()
    return 0 if run.status == "done" else 1


def run_plan(scan_id: str, run_id: str, px_per_m: int = 50) -> int:
    run = Run.load(scan_id, run_id)
    if run.stages["plan"].status == "running":
        return 1
    run.status, run.pid = "running", os.getpid()
    run.save()
    _install_cancel_handler(run)
    ok = False
    try:
        stage_plan(run, px_per_m)
        ok = True
    except Cancelled:
        pass
    except Exception as e:
        print(f"plan failed: {e}", file=sys.stderr)
    finally:
        run.status, run.pid = ("done" if ok else "failed"), None
        run.save()
    return 0 if ok else 1


def launch(args: list[str]) -> subprocess.Popen:
    """Start a pipeline command detached (own session, survives the caller), under caffeinate when available."""
    cmd = [PY, "-m", "scanner.pipeline", *args]
    if shutil.which("caffeinate"):
        cmd = ["caffeinate", "-i", "-s", *cmd]
    return subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ---------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_run_settings(p):
        p.add_argument("--res-level", type=int, default=2)
        p.add_argument("--features", default="SIFT", choices=["SIFT", "ALIKED"])
        p.add_argument("--matcher", default="BRUTEFORCE", choices=["BRUTEFORCE", "LIGHTGLUE"])
        p.add_argument("--matching", default="vocab", choices=["vocab", "sequential", "exhaustive"])
        p.add_argument("--measures", type=int, default=4)
        p.add_argument("--max-faces", type=int, default=4_000_000)
        p.add_argument("--label", default="")
        p.add_argument("--start", action="store_true", help="run the pipeline now (in this process)")

    p = sub.add_parser("new", help="create a scan from a video (and a first run)")
    p.add_argument("video")
    p.add_argument("--name")
    p.add_argument("--fps", type=float, default=2.0)
    p.add_argument("--max-frames", type=int, default=400)
    p.add_argument("--hdr", default="auto", choices=["auto", "none", "hlg", "pq"])
    add_run_settings(p)

    p = sub.add_parser("new-run", help="add a run to an existing scan")
    p.add_argument("scan_id")
    add_run_settings(p)

    p = sub.add_parser("run"); p.add_argument("scan_id"); p.add_argument("run_id")
    p = sub.add_parser("plan"); p.add_argument("scan_id"); p.add_argument("run_id"); p.add_argument("--px-per-m", type=int, default=50)
    p = sub.add_parser("list")
    a = ap.parse_args(argv)

    if a.cmd in ("new", "new-run"):
        if a.cmd == "new":
            scan = create_scan(Path(a.video), a.name, FrameSettings(fps=a.fps, max_frames=a.max_frames, hdr=a.hdr))
        else:
            scan = Scan.load(a.scan_id)
        run = create_run(scan, RunSettings(res_level=a.res_level, features=a.features, matcher=a.matcher, matching=a.matching,
                                           measures=a.measures, max_faces=a.max_faces), a.label)
        print(f"scan {scan.id}  run {run.id}  -> {run.dir}")
        return run_pipeline(scan.id, run.id) if a.start else 0
    if a.cmd == "run":
        return run_pipeline(a.scan_id, a.run_id)
    if a.cmd == "plan":
        return run_plan(a.scan_id, a.run_id, a.px_per_m)
    if a.cmd == "list":
        from .models import list_scans
        for s in list_scans():
            print(f"{s.id:24s} {s.name:28s} frames={s.frames.status:9s} runs={','.join(f'{r}:{Run.load(s.id, r).status}' for r in s.run_ids())}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
