"""Pipeline orchestrator: runs the stage scripts for a run and keeps the manifests current.

    python -m tricorder.pipeline new data/backyard.MOV --name "Backyard" [--fps 2 --max-frames 600 ...] [--start]
                                       # environment + recording + reconstruct run in one go
    python -m tricorder.pipeline new-env "Backyard"
    python -m tricorder.pipeline new-recording <env> data/walk.MOV [--name ... --fps 2 --max-frames 400 --hdr auto]
    python -m tricorder.pipeline new-run <env> reconstruct --recording rec1 [--features ALIKED ...] [--start]
    python -m tricorder.pipeline new-run <env> plan --asset scan3d-1 [--px-per-m 50] [--start]
    python -m tricorder.pipeline run    <env> <run>          # execute (finished stages are kept), then publish the asset
    python -m tricorder.pipeline launch run <env> <run>      # same, detached (own session, caffeinate); used by the Mac app
    python -m tricorder.pipeline list

Stage scripts are unchanged (scripts/01..07, 02_sfm.sh, 03_dense.sh, pick_landmarks.py, solve_scale.py); this module
only decides what to run, where to log, records status + metrics, and publishes the run's deliverables as an asset.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

from . import metrics
from .models import (ASSET_KINDS, DATA, ENVS, ROOT, RUN_KINDS, VIDEO_EXT, Asset, Environment, FrameSettings, Recording,
                     Run, RunSettings, next_id, now, slugify, unique_id)

PY = sys.executable
SCRIPTS = ROOT / "scripts"
BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")

# What a run hands over to its asset (paths relative to the run dir; globs allowed; directories are copied whole).
DELIVERABLES = {
    "scan3d": ["dense/scene_dense.ply", "dense/scene_dense_mesh_clean.ply", "dense/scene_dense_mesh_texture.obj",
               "dense/scene_dense_mesh_texture.mtl", "dense/scene_dense_mesh_texture_*_map_Kd.jpg", "sparse_points.ply",
               "preview_plan.png", "preview_plan_grid.png", "preview_plan.json", "preview_plan.blend",
               "transform_preview.json", "measure", "preview.usdz", "thumb.jpg"],
    "plan2d": ["transform.json", "plan.png", "plan_grid.png", "plan.json", "plan.blend", "scene_dense_metric.ply",
               "preview.usdz", "thumb.jpg"],
}
FILE_LABELS = {
    "sparse_points.ply": "Sparse point cloud (COLMAP)",
    "dense/scene_dense.ply": "Dense point cloud",
    "dense/scene_dense_mesh_clean.ply": "Mesh, cleaned + decimated",
    "dense/scene_dense_mesh_texture.obj": "Textured mesh (OBJ + MTL + JPG)",
    "preview_plan_grid.png": "Preview plan, unscaled, 1 m grid",
    "preview_plan.blend": "Preview Blender scene",
    "measure/prompts.json": "Measurement prompts",
    "preview.usdz": "3D preview (USDZ)",
    "plan_grid.png": "Site plan, true scale, 1 m grid",
    "plan.png": "Site plan, true scale, plain",
    "plan.blend": "Blender scene at true scale",
    "scene_dense_metric.ply": "Dense cloud in metres",
    "transform.json": "Scale / level / north + residuals",
}


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------- creation

def clone(src: Path, dst: Path) -> None:
    """Copy a file or directory; on APFS this is an instant clone, so assets cost no extra disk."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        shutil.rmtree(dst) if dst.is_dir() else dst.unlink()
    if subprocess.run(["cp", "-Rc", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copytree(src, dst, symlinks=True) if src.is_dir() else shutil.copy2(src, dst)


def create_environment(name: str) -> Environment:
    env = Environment(id=unique_id(slugify(name), ENVS), name=name, created_at=now())
    env.save()
    return env


def create_recording(env: Environment, video: Path, name: str | None = None, fs: FrameSettings | None = None) -> Recording:
    video = video if video.is_absolute() else ROOT / video
    if not video.exists():
        raise FileNotFoundError(video)
    rid = next_id(env.dir / "recordings", "rec")
    rec = Recording(id=rid, env_id=env.id, name=name or video.stem, created_at=now(), frame_settings=fs or FrameSettings())
    rec.dir.mkdir(parents=True, exist_ok=True)
    local = rec.dir / f"video{video.suffix.lower()}"
    clone(video, local)                       # the raw data belongs to the environment
    info = metrics.video_info(local)
    info["path"] = os.path.relpath(local, ROOT)
    info["original"] = str(video)
    rec.source = info
    rec.save()
    return rec


def create_run(env: Environment, kind: str, inputs: dict[str, str], settings: RunSettings | None = None, label: str = "") -> Run:
    spec = RUN_KINDS.get(kind)
    if not spec:
        raise ValueError(f"unknown run kind {kind!r}")
    if spec["input"] == "recording":
        rec = Recording.load(env.id, inputs.get("recording", ""))
    else:
        asset = Asset.load(env.id, inputs.get("asset", ""))
        if asset.kind != spec["input"]:
            raise ValueError(f"{kind} needs a {ASSET_KINDS[spec['input']]} asset, {asset.id} is a {ASSET_KINDS[asset.kind]}")
    run = Run(id=next_id(env.dir / "runs", "r"), env_id=env.id, kind=kind, inputs=dict(inputs), created_at=now(),
              settings=settings or RunSettings(), label=label)
    run.save()
    (run.dir / "logs").mkdir(exist_ok=True)
    if kind == "reconstruct":
        _link(run.dir / "images", f"../../recordings/{rec.id}/images")
    else:                                    # the plan stage scripts expect dense/ and measure/ next to their work dir
        _link(run.dir / "dense", f"../../assets/{asset.id}/dense")
        _link(run.dir / "measure", f"../../assets/{asset.id}/measure")
    return run


def _link(link: Path, target: str) -> None:
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target)


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


def stage_frames(rec: Recording) -> dict:
    def fn(log: Path) -> dict:
        fs = rec.frame_settings
        hdr = rec.source.get("hdr", "none") if fs.hdr == "auto" else fs.hdr
        cmd = [PY, str(SCRIPTS / "01_extract_frames.py"), str(rec.video_path), str(rec.dir / "images"),
               "--fps", str(fs.fps), "--max-frames", str(fs.max_frames)]
        if hdr != "none":
            cmd += ["--hdr", hdr]
        _check(_exec(cmd, log), "frame extraction")
        rec.thumbnail = metrics.recording_thumbnail(rec.dir)
        return metrics.frames_metrics(rec.dir)
    _stage(rec, "frames", fn)
    return rec.frames.metrics


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


def stage_plan(run: Run) -> None:
    def fn(log: Path) -> dict:
        _check(_exec([PY, str(SCRIPTS / "solve_scale.py"), str(run.dir)], log), "scale solve")
        render_plan(run, run.dir / "transform.json", "plan", log, run.settings.px_per_m)
        rc = _exec([PY, "-c", (
            "import json,sys,numpy as np,open3d as o3d;from pathlib import Path;w=Path(sys.argv[1]);"
            "T=np.array(json.load(open(w/'transform.json'))['matrix']);p=o3d.io.read_point_cloud(str(w/'dense/scene_dense.ply'));"
            "p.transform(T);o3d.io.write_point_cloud(str(w/'scene_dense_metric.ply'),p);e=p.get_axis_aligned_bounding_box().get_extent();"
            "print(f'metric cloud: {e[0]:.1f} m x {e[1]:.1f} m, height {e[2]:.1f} m')"), str(run.dir)], log)
        _check(rc, "metric cloud")
        if (run.dir / "plan_grid.png").exists():
            metrics.make_thumbnail(run.dir / "plan_grid.png", run.dir / "thumb.jpg")
        return metrics.plan_metrics(run.dir)
    _stage(run, "plan", fn)


def stage_preview(run: Run) -> None:
    """Decimated USDZ of the textured mesh for the app's 3D viewer. Metric + levelled for plans, levelled only for scans."""
    def fn(log: Path) -> dict:
        if not os.path.exists(BLENDER):
            raise RuntimeError(f"Blender not found at {BLENDER}")
        transform = run.dir / ("transform.json" if run.kind == "plan" else "transform_preview.json")
        cmd = [BLENDER, "--background", "--python", str(SCRIPTS / "07_preview_model.py"), "--",
               "--mesh", str(run.dir / "dense" / "scene_dense_mesh_texture.obj"), "--faces", str(run.settings.preview_faces),
               "--out", str(run.dir / "preview.usdz")]
        if transform.exists():
            cmd += ["--transform", str(transform)]
        _check(_exec(cmd, log), "preview export")
        return {"faces": run.settings.preview_faces, "size": (run.dir / "preview.usdz").stat().st_size}
    _stage(run, "preview", fn)


STAGE_FN = {"sfm": stage_sfm, "dense": stage_dense, "landmarks": stage_landmarks, "plan": stage_plan, "preview": stage_preview}


# ---------------------------------------------------------------- publishing

def asset_metrics(run: Run) -> dict:
    m: dict = {}
    if run.kind == "reconstruct":
        s, d, l = run.stages["sfm"].metrics, run.stages["dense"].metrics, run.stages["landmarks"].metrics
        for k in ("registered", "images", "submodels", "reproj_px"):
            if k in s:
                m[k] = s[k]
        for k in ("dense_points", "faces"):
            if k in d:
                m[k] = d[k]
        if "prompts" in l:
            m["prompts"] = l["prompts"]
    else:
        m.update(run.stages["plan"].metrics)
        m["px_per_m"] = run.settings.px_per_m
    return m


def publish(run: Run) -> Asset:
    """Clone the run's deliverables into an asset folder and write asset.json. A run re-publishes into its own asset."""
    kind = RUN_KINDS[run.kind]["output"]
    aid = run.output_asset or next_id(run.dir.parent.parent / "assets", f"{kind}-")
    asset = Asset(id=aid, env_id=run.env_id, kind=kind, name=f"{ASSET_KINDS[kind]} · {run.id}", run_id=run.id, created_at=now())
    asset.dir.mkdir(parents=True, exist_ok=True)
    files = []
    for pattern in DELIVERABLES[kind]:
        for src in sorted(glob.glob(str(run.dir / pattern))):
            src = Path(src)
            if src.is_symlink() and src.is_dir():          # a plan run's measure/ link points at its input asset
                continue
            rel = src.relative_to(run.dir)
            clone(src, asset.dir / rel)
            if src.is_dir():
                for f in sorted(p for p in src.rglob("*") if p.is_file()):
                    r = str(f.relative_to(run.dir))
                    files.append({"path": r, "label": FILE_LABELS.get(r, ""), "size": f.stat().st_size})
            else:
                files.append({"path": str(rel), "label": FILE_LABELS.get(str(rel), ""), "size": src.stat().st_size})
    asset.files = files
    asset.metrics = asset_metrics(run)
    asset.save()
    run.output_asset = asset.id
    run.save()
    return asset


# ---------------------------------------------------------------- running

def _install_cancel_handler():
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


def run_pipeline(env_id: str, run_id: str) -> int:
    run = Run.load(env_id, run_id)
    run.status, run.pid, run.started_at, run.finished_at = "running", os.getpid(), now(), None
    run.save()
    _install_cancel_handler()
    rec = None
    try:
        if run.kind == "reconstruct":
            rec = Recording.load(env_id, run.inputs["recording"])
            if rec.frames.status != "done" or not (rec.dir / "images" / "frames.csv").exists():
                stage_frames(rec)
        for name in run.stage_names:
            if run.stages[name].status == "done":
                continue
            if name == "preview":
                try:
                    stage_preview(run)
                except Cancelled:
                    raise
                except Exception as e:                   # the preview is a nicety; the asset is still published
                    print(f"preview skipped: {e}", file=sys.stderr)
                continue
            STAGE_FN[name](run)
        publish(run)
        run.status = "done"
    except Cancelled:
        run.status = "cancelled"
        if rec is not None and rec.frames.status == "running":
            rec.frames.status, rec.frames.finished_at = "cancelled", now()
            rec.save()
    except Exception as e:
        run.status = "failed"
        print(f"run failed: {e}", file=sys.stderr)
    finally:
        run.finished_at, run.pid = now(), None
        run.save()
    return 0 if run.status == "done" else 1


def launch(args: list[str]) -> subprocess.Popen:
    """Start a pipeline command detached (own session, survives the caller), under caffeinate when available."""
    cmd = [PY, "-m", "tricorder.pipeline", *args]
    if shutil.which("caffeinate"):
        cmd = ["caffeinate", "-i", "-s", *cmd]
    return subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ---------------------------------------------------------------- CLI

def _settings_from(a) -> RunSettings:
    return RunSettings(res_level=a.res_level, features=a.features, matcher=a.matcher, matching=a.matching,
                       measures=a.measures, max_faces=a.max_faces, px_per_m=a.px_per_m, preview_faces=a.preview_faces)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_frame_args(p):
        p.add_argument("--fps", type=float, default=2.0)
        p.add_argument("--max-frames", type=int, default=400)
        p.add_argument("--hdr", default="auto", choices=["auto", "none", "hlg", "pq"])

    def add_run_settings(p):
        p.add_argument("--res-level", type=int, default=2)
        p.add_argument("--features", default="SIFT", choices=["SIFT", "ALIKED"])
        p.add_argument("--matcher", default="BRUTEFORCE", choices=["BRUTEFORCE", "LIGHTGLUE"])
        p.add_argument("--matching", default="vocab", choices=["vocab", "sequential", "exhaustive"])
        p.add_argument("--measures", type=int, default=4)
        p.add_argument("--max-faces", type=int, default=4_000_000)
        p.add_argument("--px-per-m", type=int, default=50)
        p.add_argument("--preview-faces", type=int, default=300_000)
        p.add_argument("--label", default="")
        p.add_argument("--start", action="store_true", help="run the pipeline now (in this process)")

    p = sub.add_parser("new", help="environment + recording + reconstruct run from a video")
    p.add_argument("video"); p.add_argument("--name"); add_frame_args(p); add_run_settings(p)
    p = sub.add_parser("new-env", help="create an empty environment"); p.add_argument("name")
    p = sub.add_parser("new-recording", help="add a video to an environment")
    p.add_argument("env_id"); p.add_argument("video"); p.add_argument("--name"); add_frame_args(p)
    p = sub.add_parser("new-run", help="add a run to an environment")
    p.add_argument("env_id"); p.add_argument("kind", choices=list(RUN_KINDS))
    p.add_argument("--recording", help="input recording id (reconstruct)")
    p.add_argument("--asset", help="input asset id (plan)")
    add_run_settings(p)
    p = sub.add_parser("run"); p.add_argument("env_id"); p.add_argument("run_id")
    p = sub.add_parser("list")
    p = sub.add_parser("launch", help="start a pipeline command detached (own session, under caffeinate) and return at once")
    p.add_argument("args", nargs=argparse.REMAINDER, help="e.g. run <env_id> <run_id>")
    a = ap.parse_args(argv)

    if a.cmd == "new":
        env = create_environment(a.name or Path(a.video).stem)
        rec = create_recording(env, Path(a.video), a.name, FrameSettings(fps=a.fps, max_frames=a.max_frames, hdr=a.hdr))
        run = create_run(env, "reconstruct", {"recording": rec.id}, _settings_from(a), a.label)
        print(f"env {env.id}  recording {rec.id}  run {run.id}  -> {run.dir}")
        return run_pipeline(env.id, run.id) if a.start else 0
    if a.cmd == "new-env":
        env = create_environment(a.name)
        print(f"env {env.id}  -> {env.dir}")
        return 0
    if a.cmd == "new-recording":
        env = Environment.load(a.env_id)
        rec = create_recording(env, Path(a.video), a.name, FrameSettings(fps=a.fps, max_frames=a.max_frames, hdr=a.hdr))
        print(f"env {env.id}  recording {rec.id}  -> {rec.dir}")
        return 0
    if a.cmd == "new-run":
        env = Environment.load(a.env_id)
        inputs = {"recording": a.recording} if a.kind == "reconstruct" else {"asset": a.asset}
        if not next(iter(inputs.values())):
            ap.error("reconstruct needs --recording, plan needs --asset")
        run = create_run(env, a.kind, inputs, _settings_from(a), a.label)
        print(f"env {env.id}  run {run.id}  -> {run.dir}")
        return run_pipeline(env.id, run.id) if a.start else 0
    if a.cmd == "run":
        return run_pipeline(a.env_id, a.run_id)
    if a.cmd == "launch":
        if not a.args:
            ap.error("launch needs a pipeline command")
        launch(a.args)
        return 0
    if a.cmd == "list":
        from .models import list_environments
        for e in list_environments():
            print(f"{e.id:24s} {e.name}")
            for r in e.recording_ids():
                rec = Recording.load(e.id, r)
                print(f"    recording {r:8s} {rec.name:28s} frames={rec.frames.status}")
            for r in e.run_ids():
                run = Run.load(e.id, r)
                print(f"    run       {r:8s} {run.kind:12s} {run.status:10s} inputs={run.inputs} -> {run.output_asset}")
            for aid in e.asset_ids():
                asset = Asset.load(e.id, aid)
                print(f"    asset     {aid:10s} {asset.name:28s} from {asset.run_id}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
