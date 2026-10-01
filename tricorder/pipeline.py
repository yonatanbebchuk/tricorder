"""Pipeline orchestrator: runs the stage scripts for a run and keeps the manifests current.

    python -m tricorder.pipeline new data/backyard.MOV --name "Backyard" [--fps 2 --max-frames 600 ...] [--start]
                                       # environment + recording + scan run in one go
    python -m tricorder.pipeline new-env "Backyard"
    python -m tricorder.pipeline new-recording <env> data/walk.MOV [--name ... --fps 2 --max-frames 400 --hdr auto]
    python -m tricorder.pipeline new-recording <env> IMG_0001.HEIC IMG_0002.HEIC … | photos/   # a photos recording
    python -m tricorder.pipeline new-measurements <env> --name "Tape, Saturday"   # then add items in the app
    python -m tricorder.pipeline new-run <env> scan   --recording rec1 [--features ALIKED ...] [--start]
    python -m tricorder.pipeline new-run <env> extend --asset model3d-1 --recordings rec4 rec5 [--start]
    python -m tricorder.pipeline new-run <env> layout --asset model3d-1 --recordings rec2 [--px-per-m 50 --contour 0.25] [--start]
    python -m tricorder.pipeline new-run <env> layout --asset @r5 --recordings rec2     # chained: waits for run r5's model
    python -m tricorder.pipeline run    <env> <run> [--redo preview]   # execute (finished stages kept unless redone), publish
    python -m tricorder.pipeline launch run <env> <run>      # same, detached (own session, caffeinate); used by the Mac app
    python -m tricorder.pipeline list

Stage scripts (scripts/01..10, 02_sfm.sh, 02b_register.sh, 03_dense.sh, pick_landmarks.py, solve_scale.py) do the work;
this module only decides what to run, where to log, records status + metrics + outputs, renders a stage preview, and
publishes the run's deliverables as an asset.  A run whose asset input is "@<run>" is a chained run: it stays queued
until that run publishes, and that run launches it.
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
from typing import Any

from . import metrics, previews
from .models import (ASSET_KINDS, DATA, ENVS, IMAGE_EXT, RECORDING_KINDS, ROOT, RUN_KINDS, VIDEO_EXT, Asset, Environment,
                     FrameSettings, Recording, Run, RunSettings, Stage, next_id, now, slugify, unique_id)

PY = sys.executable
SCRIPTS = ROOT / "scripts"
BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")

# What a run hands over to its asset (paths relative to the run dir; globs allowed; directories are copied whole).
DELIVERABLES = {
    "model3d": ["dense/scene_dense.ply", "dense/scene_dense_mesh_clean.ply", "dense/scene_dense_mesh_texture.obj",
                "dense/scene_dense_mesh_texture.mtl", "dense/scene_dense_mesh_texture_*_map_Kd.jpg", "dense/sparse", "sparse/0",
                "database.db", "sparse_points.ply", "preview_plan.png", "preview_plan_grid.png", "preview_plan.json",
                "preview_plan.blend", "transform_preview.json", "measure", "preview.usdz", "thumb.jpg"],
    "site_plan": ["transform.json", "measure", "orthomosaic.png", "orthomosaic.json", "orthomosaic.pgw", "dem.tif", "dem.json",
                  "contours.json", "footprint.json", "linework.json", "overlay.json", "site_plan.dxf", "site_plan.pdf", "site_plan.blend",
                  "site_plan_page*.png", "scene_dense_metric.ply", "preview.usdz", "thumb.jpg"],
}
# What each stage leaves behind (paths relative to the run dir; globs allowed): shown per stage in the app.
STAGE_OUTPUTS = {
    "sfm": ["sparse_points.ply", "sparse/0", "database.db", "dense/sparse/images.txt"],
    "register": ["sparse_points.ply", "sparse/0", "database.db", "dense/sparse/images.txt"],
    "dense": ["dense/scene_dense.ply", "dense/scene_dense_mesh_clean.ply", "dense/scene_dense_mesh_texture.obj"],
    "landmarks": ["preview_plan_grid.png", "preview_plan.blend", "measure/prompts.json", "transform_preview.json"],
    "preview": ["preview.usdz"],
    "solve": ["transform.json", "measure/constraints.json", "scene_dense_metric.ply"],
    "ortho": ["orthomosaic.png", "orthomosaic.pgw", "site_plan.blend"],
    "trace": ["linework.json"],
    "draw": ["site_plan.pdf", "site_plan.dxf", "dem.tif", "contours.json", "overlay.json"],
}
FILE_LABELS = {
    "sparse_points.ply": "Sparse point cloud (COLMAP)",
    "dense/scene_dense.ply": "Dense point cloud",
    "dense/scene_dense_mesh_clean.ply": "Mesh, cleaned + decimated",
    "dense/scene_dense_mesh_texture.obj": "Textured mesh (OBJ + MTL + JPG)",
    "dense/sparse/images.txt": "Camera poses, undistorted (COLMAP)",
    "sparse/0/images.bin": "Camera poses, original (COLMAP)",
    "sparse/0": "Camera poses, original (COLMAP)",
    "database.db": "COLMAP database (features, matches)",
    "preview_plan_grid.png": "Preview plan, unscaled, 1 m grid",
    "preview_plan.blend": "Preview Blender scene",
    "transform_preview.json": "Levelling transform (preview)",
    "measure/prompts.json": "Measurement prompts",
    "measure/constraints.json": "Measurements",
    "preview.usdz": "3D preview (USDZ)",
    "site_plan.dxf": "Site plan, CAD drawing (DXF)",
    "site_plan.pdf": "Site plan, sheet (PDF)",
    "orthomosaic.png": "Orthomosaic (top-down, true scale)",
    "orthomosaic.pgw": "World file for the orthomosaic",
    "dem.tif": "Digital elevation model (32-bit, metres)",
    "contours.json": "Contour lines",
    "linework.json": "Traced linework (walls, boundary)",
    "overlay.json": "Plan overlay for the app",
    "site_plan.blend": "Blender scene at true scale",
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


def create_photos_recording(env: Environment, photos: list[Path], name: str | None = None) -> Recording:
    """A set of still photos (a folder or a list of files) copied into the environment as one recording."""
    files: list[Path] = []
    for p in photos:
        p = p if p.is_absolute() else ROOT / p
        if p.is_dir():
            files += sorted(q for q in p.iterdir() if q.suffix.lower() in IMAGE_EXT and not q.name.startswith("."))
        elif p.suffix.lower() in IMAGE_EXT:
            files.append(p)
    if not files:
        raise FileNotFoundError("no photos given")
    rid = next_id(env.dir / "recordings", "rec")
    rec = Recording(id=rid, env_id=env.id, name=name or f"{len(files)} photos", created_at=now(), kind="photos")
    folder = rec.dir / "photos"
    folder.mkdir(parents=True, exist_ok=True)
    for f in files:
        clone(f, folder / f.name)
    rec.source = {"path": os.path.relpath(folder, ROOT), "count": len(files), "size": sum(f.stat().st_size for f in files),
                  "originals": [str(f) for f in files[:200]]}
    rec.save()
    return rec


def create_measurements(env: Environment, name: str) -> Recording:
    """An empty measurement recording; the app fills its items."""
    rec = Recording(id=next_id(env.dir / "recordings", "rec"), env_id=env.id, name=name, created_at=now(), kind="measurements")
    rec.dir.mkdir(parents=True, exist_ok=True)
    rec.save()
    return rec


def _check_slots(env: Environment, kind: str, inputs: dict[str, Any]) -> None:
    """Every slot of the kind is filled with things of the kinds it accepts, within its counts."""
    for slot in RUN_KINDS[kind]["slots"]:
        v = inputs.get(slot["key"])
        ids = [v] if isinstance(v, str) else list(v or [])
        if not slot["min"] <= len(ids) <= slot["max"]:
            raise ValueError(f"{kind}: slot '{slot['label']}' takes {slot['min']}–{slot['max']} inputs, got {len(ids)}")
        for i in ids:
            if i.startswith("@"):                    # another run's output; checked when that run has published
                if slot["accepts"][0] not in ASSET_KINDS:
                    raise ValueError(f"{kind}: '{slot['label']}' cannot take a run's output")
                continue
            if slot["accepts"][0] in ASSET_KINDS:
                a = Asset.load(env.id, i)
                if a.kind not in slot["accepts"]:
                    raise ValueError(f"{kind}: '{slot['label']}' needs a {ASSET_KINDS[slot['accepts'][0]]}, {i} is a {ASSET_KINDS[a.kind]}")
            else:
                r = Recording.load(env.id, i)
                if r.kind not in slot["accepts"]:
                    raise ValueError(f"{kind}: '{slot['label']}' takes {' / '.join(RECORDING_KINDS[k].lower() for k in slot['accepts'])}, "
                                     f"{i} is {RECORDING_KINDS.get(r.kind, r.kind).lower()}")


def create_run(env: Environment, kind: str, inputs: dict[str, Any], settings: RunSettings | None = None, label: str = "",
               after: str | None = None) -> Run:
    spec = RUN_KINDS.get(kind)
    if not spec:
        raise ValueError(f"unknown run kind {kind!r}")
    inputs = {k: v for k, v in inputs.items() if v not in (None, [], "")}
    _check_slots(env, kind, inputs)
    run = Run(id=next_id(env.dir / "runs", "r"), env_id=env.id, kind=kind, inputs=dict(inputs), created_at=now(),
              settings=settings or RunSettings(), label=label, after=after)
    run.save()
    (run.dir / "logs").mkdir(exist_ok=True)
    _prepare(run)
    return run


def _prepare(run: Run) -> None:
    """Working links a run needs before its first stage; a no-op while an asset input is still "@run"."""
    if run.kind == "scan":
        _link(run.dir / "images", f"../../recordings/{run.inputs['recording']}/images")
    elif run.kind == "layout" and not run.asset_id.startswith("@"):
        # the layout scripts expect dense/ next to their work dir; measure/ is built by solve
        _link(run.dir / "dense", f"../../assets/{run.asset_id}/dense")
        (run.dir / "measure").mkdir(exist_ok=True)


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


def _outputs(base: Path, patterns: list[str]) -> list[dict]:
    out = []
    for pattern in patterns:
        for src in sorted(glob.glob(str(base / pattern))):
            p = Path(src)
            rel = str(p.relative_to(base))
            size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) if p.is_dir() else p.stat().st_size
            out.append({"path": rel, "label": FILE_LABELS.get(rel, ""), "size": size})
    return out


def _stage(owner, name: str, fn) -> None:
    """Mark a stage running, run fn(log_path) -> metrics dict, mark done/failed; then record what it left behind and
    render its preview. Raises on failure."""
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
    if isinstance(owner, Run):
        st.outputs = _outputs(owner.dir, STAGE_OUTPUTS.get(name, []))
        st.preview = previews.render_stage(owner, name)
    else:
        st.outputs = _outputs(owner.dir, ["images/frames.csv"])
        st.preview = previews.render_frames(owner)
    owner.save()


def _check(rc: int, what: str) -> None:
    if rc == -signal.SIGTERM or rc == 143:
        raise Cancelled()
    if rc != 0:
        raise RuntimeError(f"{what} exited with code {rc}")


def stage_frames(rec: Recording) -> dict:
    def fn(log: Path) -> dict:
        if rec.kind == "photos":
            cmd = [PY, str(SCRIPTS / "01b_import_photos.py"), str(ROOT / rec.source["path"]), str(rec.dir / "images")]
            _check(_exec(cmd, log), "photo import")
        else:
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


def model_sources(env_id: str, asset: Asset) -> list[dict]:
    """The recordings a 3D model's frames came from, with the name prefix each one has inside the COLMAP database."""
    if asset.sources:
        return asset.sources
    try:                                        # models from before extend: the scan's single video, flat names
        return [{"recording": Run.load(env_id, asset.run_id).inputs["recording"], "prefix": ""}]
    except Exception:
        return []


def stage_register(run: Run) -> None:
    """Extend: the parent model's database and poses, plus the new recordings' frames, through COLMAP's incremental
    registration and a full bundle adjustment; then undistorted for OpenMVS."""
    def fn(log: Path) -> dict:
        parent = Asset.load(run.env_id, run.inputs["asset"])
        if not (parent.dir / "database.db").exists() or not (parent.dir / "sparse" / "0").exists():
            raise RuntimeError(f"{parent.id} has no COLMAP database / original poses; re-run its scan to publish them")
        sources = model_sources(run.env_id, parent)
        new_ids = [r for r in run.inputs.get("recordings", []) if r not in {s["recording"] for s in sources}]
        if not new_ids:
            raise RuntimeError("every recording given is already part of the model")
        # the union image folder: old frames under their database names, new frames under <recording>/
        images = run.dir / "images"
        if images.is_symlink():
            images.unlink()
        shutil.rmtree(images, ignore_errors=True)
        images.mkdir()
        n_old = 0
        for s in sources:
            src = ENVS / run.env_id / "recordings" / s["recording"] / "images"
            dst = images / s["prefix"] if s["prefix"] else images
            dst.mkdir(parents=True, exist_ok=True)
            for f in sorted(src.glob("*.jpg")):
                (dst / f.name).symlink_to(os.path.relpath(f, dst))
                n_old += 1
        new_names = []
        for rid in new_ids:
            src = ENVS / run.env_id / "recordings" / rid / "images"
            dst = images / rid
            dst.mkdir(parents=True, exist_ok=True)
            for f in sorted(src.glob("*.jpg")):
                (dst / f.name).symlink_to(os.path.relpath(f, dst))
                new_names.append(f"{rid}/{f.name}")
        (run.dir / "register_new.txt").write_text("\n".join(new_names) + "\n")
        clone(parent.dir / "database.db", run.dir / "database.db")
        clone(parent.dir / "sparse" / "0", run.dir / "sparse" / "parent")
        # the new features must be of the parent's kind (its database and vocab index are SIFT or ALIKED, not both)
        env = run.settings.env()
        try:
            parent_settings = Run.load(run.env_id, parent.run_id).settings
            env.update({"FEATURES": parent_settings.features, "MATCHER": parent_settings.matcher})
            run.settings.features, run.settings.matcher = parent_settings.features, parent_settings.matcher
            run.save()
        except KeyError:
            pass
        with open(log, "a") as f:
            f.write(f"parent {parent.id}: {n_old} frames ({env['FEATURES']} features); new: {len(new_names)} frames from {', '.join(new_ids)}\n")
        _check(_exec(["bash", str(SCRIPTS / "02b_register.sh"), str(images), str(run.dir), str(run.dir / "register_new.txt")], log,
                     env=env), "COLMAP registration")
        m = metrics.sfm_metrics(run.dir)
        m["images"] = n_old + len(new_names)
        m["new_images"] = len(new_names)
        m["parent_registered"] = parent.metrics.get("registered")
        m["new_registered"] = max(0, int(m.get("registered", 0)) - int(parent.metrics.get("registered") or 0))
        m["submodels"] = 1
        return m
    _stage(run, "register", fn)


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


def stage_solve(run: Run) -> None:
    """Measurement recordings -> 3D constraints on this model; scale, level and north; the dense cloud in metres."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        recs = [str(Recording.load(run.env_id, r).dir) for r in run.inputs.get("recordings", []) or []]
        _check(_exec([PY, str(SCRIPTS / "measure_project.py"), str(run.dir), "--model", str(asset.dir), "--recordings", *recs], log),
               "measurement projection")
        _check(_exec([PY, str(SCRIPTS / "solve_scale.py"), str(run.dir)], log), "scale solve")
        rc = _exec([PY, "-c", (
            "import json,sys,numpy as np,open3d as o3d;from pathlib import Path;w=Path(sys.argv[1]);"
            "T=np.array(json.load(open(w/'transform.json'))['matrix']);p=o3d.io.read_point_cloud(str(w/'dense/scene_dense.ply'));"
            "p.transform(T);o3d.io.write_point_cloud(str(w/'scene_dense_metric.ply'),p);e=p.get_axis_aligned_bounding_box().get_extent();"
            "print(f'metric cloud: {e[0]:.1f} m x {e[1]:.1f} m, height {e[2]:.1f} m')"), str(run.dir)], log)
        _check(rc, "metric cloud")
        m = metrics.plan_metrics(run.dir)
        t = json.load(open(run.dir / "transform.json"))
        m["estimated"] = bool(t.get("estimated", False))
        c = json.load(open(run.dir / "measure" / "constraints.json"))
        m["skipped"] = len(c.get("skipped", []))
        return m
    _stage(run, "solve", fn)


def stage_ortho(run: Run) -> None:
    """Blender: orthographic top-down render at true scale (the orthomosaic) and the Blender scene."""
    def fn(log: Path) -> dict:
        if not os.path.exists(BLENDER):
            raise RuntimeError(f"Blender not found at {BLENDER}")
        _check(_exec([BLENDER, "--background", "--python", str(SCRIPTS / "05_site_plan_blender.py"), "--",
                      "--mesh", str(run.dir / "dense" / "scene_dense_mesh_texture.obj"), "--transform", str(run.dir / "transform.json"),
                      "--out", str(run.dir / "orthomosaic"), "--px-per-m", str(run.settings.px_per_m)], log), "Blender render")
        os.replace(run.dir / "orthomosaic.blend", run.dir / "site_plan.blend")
        metrics.make_thumbnail(run.dir / "orthomosaic.png", run.dir / "thumb.jpg")
        o = json.load(open(run.dir / "orthomosaic.json"))
        return {"px_per_m": o.get("px_per_m"), "width_m": o.get("width_m"), "height_m": o.get("height_m")}
    _stage(run, "ortho", fn)


def stage_trace(run: Run) -> None:
    """The architect's line drawing: vertical structure in the cloud → wall lines; the ground's footprint →
    the regularised, dimensioned boundary polygon snapped onto those walls."""
    def fn(log: Path) -> dict:
        _check(_exec([PY, str(SCRIPTS / "10_trace_walls.py"), str(run.dir), "--min-height", str(run.settings.wall_jump_m),
                      "--min-edge", str(run.settings.min_edge_m)], log), "line tracing")
        lw = json.load(open(run.dir / "linework.json"))
        polys = lw.get("polygons", [])
        return {"walls": len(lw.get("walls", [])), "polygons": len(polys), "axis_deg": lw.get("axis_deg"),
                "boundary_sides": len(polys[0]["points"]) if polys else 0, "boundary_area_m2": polys[0]["area"] if polys else None}
    _stage(run, "trace", fn)


def stage_draw(run: Run) -> None:
    """DEM, contours, footprint, DXF, PDF sheet, world file, app overlay."""
    def fn(log: Path) -> dict:
        env = Environment.load(run.env_id)
        _check(_exec([PY, str(SCRIPTS / "08_site_plan.py"), str(run.dir), "--contour", str(run.settings.contour_m),
                      "--scale", str(run.settings.sheet_scale), "--title", env.name,
                      "--subtitle", f"existing conditions · {run.env_id} · {run.inputs.get('asset', '')} · {now()[:10]}"], log), "site plan drawing")
        o = json.load(open(run.dir / "overlay.json"))
        return {"contours": len(o.get("contours", [])), "measurements": len(o.get("measurements", [])),
                "sheet_scale": o.get("sheet_scale"), "contour_interval": o.get("contour_interval")}
    _stage(run, "draw", fn)


def stage_preview(run: Run) -> None:
    """Decimated USDZ of the textured mesh for the app's 3D viewer. Metric + levelled for plans, levelled only for scans."""
    def fn(log: Path) -> dict:
        if not os.path.exists(BLENDER):
            raise RuntimeError(f"Blender not found at {BLENDER}")
        transform = run.dir / ("transform.json" if run.kind == "layout" else "transform_preview.json")
        cmd = [BLENDER, "--background", "--python", str(SCRIPTS / "07_preview_model.py"), "--",
               "--mesh", str(run.dir / "dense" / "scene_dense_mesh_texture.obj"), "--faces", str(run.settings.preview_faces),
               "--out", str(run.dir / "preview.usdz")]
        if transform.exists():
            cmd += ["--transform", str(transform)]
        _check(_exec(cmd, log), "preview export")
        return {"faces": run.settings.preview_faces, "size": (run.dir / "preview.usdz").stat().st_size}
    _stage(run, "preview", fn)


STAGE_FN = {"sfm": stage_sfm, "register": stage_register, "dense": stage_dense, "landmarks": stage_landmarks, "solve": stage_solve,
            "ortho": stage_ortho, "trace": stage_trace, "draw": stage_draw, "preview": stage_preview}


# ---------------------------------------------------------------- publishing

def asset_metrics(run: Run) -> dict:
    m: dict = {}
    if run.kind in ("scan", "extend"):
        s = run.stages["sfm" if run.kind == "scan" else "register"].metrics
        d, l = run.stages["dense"].metrics, run.stages["landmarks"].metrics
        for k in ("registered", "images", "submodels", "reproj_px", "new_images", "new_registered"):
            if k in s:
                m[k] = s[k]
        for k in ("dense_points", "faces"):
            if k in d:
                m[k] = d[k]
        if "prompts" in l:
            m["prompts"] = l["prompts"]
    else:
        m.update(run.stages["solve"].metrics)
        m.update(run.stages["trace"].metrics)
        m.update(run.stages["draw"].metrics)
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
            if src.is_symlink():                            # a layout run's dense/ and measure/ links point at its input asset
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
    if kind == "model3d":
        asset.metrics["features"] = run.settings.features
    if run.kind == "scan":
        asset.sources = [{"recording": run.inputs["recording"], "prefix": ""}]
    elif run.kind == "extend":
        parent = Asset.load(run.env_id, run.inputs["asset"])
        asset.derived_from = parent.id
        old = model_sources(run.env_id, parent)
        asset.sources = old + [{"recording": r, "prefix": f"{r}/"} for r in run.inputs.get("recordings", [])
                               if r not in {s["recording"] for s in old}]
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


def _resolve_chain(run: Run) -> str | None:
    """A chained run's "@r5" asset becomes r5's published asset. Returns a reason to wait, or None to go ahead."""
    parent_id = run.waits_for
    if not parent_id:
        return None
    try:
        parent = Run.load(run.env_id, parent_id)
    except KeyError:
        return f"run {parent_id} (this run's input) no longer exists"
    if parent.status != "done" or not parent.output_asset:
        return f"waiting for run {parent_id} ({parent.status})"
    if isinstance(run.asset_id, str) and run.asset_id.startswith("@"):
        run.inputs["asset"] = parent.output_asset
        run.save()
        _prepare(run)
    return None


def _launch_dependants(run: Run) -> None:
    """Queued runs whose input is this run's output start now."""
    env = Environment.load(run.env_id)
    for rid in env.run_ids():
        try:
            r = Run.load(run.env_id, rid)
        except Exception:
            continue
        if r.status == "queued" and r.waits_for == run.id:
            print(f"launching chained run {rid}")
            launch(["run", run.env_id, rid])


def run_pipeline(env_id: str, run_id: str, redo: list[str] | None = None) -> int:
    """Execute a run. Finished stages are skipped unless named in `redo`; the asset is (re)published at the end."""
    run = Run.load(env_id, run_id)
    for name in redo or []:
        if name not in run.stages:
            print(f"no stage {name!r} in a {run.kind} run", file=sys.stderr)
            return 2
        run.stages[name] = Stage()
    if reason := _resolve_chain(run):
        print(reason, file=sys.stderr)
        return 3
    run.status, run.pid, run.started_at, run.finished_at = "running", os.getpid(), now(), None
    run.save()
    _install_cancel_handler()
    recs: list[Recording] = []
    try:
        for rid in run.recording_ids():
            rec = Recording.load(env_id, rid)
            if rec.kind in ("video", "photos") and (rec.frames.status != "done" or not (rec.dir / "images" / "frames.csv").exists()):
                recs.append(rec)
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
        for rec in recs:
            if rec.frames.status == "running":
                rec.frames.status, rec.frames.finished_at = "cancelled", now()
                rec.save()
    except Exception as e:
        run.status = "failed"
        print(f"run failed: {e}", file=sys.stderr)
    finally:
        run.finished_at, run.pid = now(), None
        run.save()
    if run.status == "done":
        _launch_dependants(run)
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
                       measures=a.measures, max_faces=a.max_faces, px_per_m=a.px_per_m, contour_m=a.contour, sheet_scale=a.sheet_scale,
                       wall_jump_m=a.wall, edge_jump_m=a.edge, min_edge_m=a.min_edge, preview_faces=a.preview_faces)


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
        p.add_argument("--contour", type=float, default=0.25)
        p.add_argument("--sheet-scale", type=int, default=100)
        p.add_argument("--wall", type=float, default=0.5, help="linework: height step of a wall/fence (m)")
        p.add_argument("--edge", type=float, default=0.08, help="(reserved) height step of an edge/curb (m)")
        p.add_argument("--min-edge", type=float, default=1.2, help="linework: boundary jogs shorter than this are absorbed (m)")
        p.add_argument("--preview-faces", type=int, default=300_000)
        p.add_argument("--label", default="")
        p.add_argument("--start", action="store_true", help="run the pipeline now (in this process)")

    p = sub.add_parser("new", help="environment + recording + scan run from a video")
    p.add_argument("video"); p.add_argument("--name"); add_frame_args(p); add_run_settings(p)
    p = sub.add_parser("new-env", help="create an empty environment"); p.add_argument("name")
    p = sub.add_parser("new-recording", help="add a video, or photos (files or a folder), to an environment")
    p.add_argument("env_id"); p.add_argument("paths", nargs="+"); p.add_argument("--name"); add_frame_args(p)
    p = sub.add_parser("new-measurements", help="add an empty measurement recording (the app fills it)")
    p.add_argument("env_id"); p.add_argument("--name", default="Measurements")
    p = sub.add_parser("new-run", help="add a run to an environment")
    p.add_argument("env_id"); p.add_argument("kind", choices=list(RUN_KINDS))
    p.add_argument("--recording", help="input video recording id (scan)")
    p.add_argument("--asset", help="input 3D-model asset id (extend, layout), or @<run> for a chained run")
    p.add_argument("--recordings", nargs="*", default=[], help="extend: new video/photo recordings; layout: measurement recordings")
    p.add_argument("--after", help="wait for this run to finish first (usually implied by --asset @<run>)")
    add_run_settings(p)
    p = sub.add_parser("run", help="execute a run; finished stages are kept unless --redo names them")
    p.add_argument("env_id"); p.add_argument("run_id")
    p.add_argument("--redo", action="append", default=[], metavar="STAGE", help="reset this stage first (repeatable), e.g. --redo preview")
    p = sub.add_parser("list")
    p = sub.add_parser("launch", help="start a pipeline command detached (own session, under caffeinate) and return at once")
    p.add_argument("args", nargs=argparse.REMAINDER, help="e.g. run <env_id> <run_id>")
    a = ap.parse_args(argv)

    if a.cmd == "new":
        env = create_environment(a.name or Path(a.video).stem)
        rec = create_recording(env, Path(a.video), a.name, FrameSettings(fps=a.fps, max_frames=a.max_frames, hdr=a.hdr))
        run = create_run(env, "scan", {"recording": rec.id}, _settings_from(a), a.label)
        print(f"env {env.id}  recording {rec.id}  run {run.id}  -> {run.dir}")
        return run_pipeline(env.id, run.id) if a.start else 0
    if a.cmd == "new-env":
        env = create_environment(a.name)
        print(f"env {env.id}  -> {env.dir}")
        return 0
    if a.cmd == "new-recording":
        env = Environment.load(a.env_id)
        paths = [Path(p) for p in a.paths]
        if len(paths) == 1 and paths[0].suffix.lower() in VIDEO_EXT:
            rec = create_recording(env, paths[0], a.name, FrameSettings(fps=a.fps, max_frames=a.max_frames, hdr=a.hdr))
        else:
            rec = create_photos_recording(env, paths, a.name)
        print(f"env {env.id}  recording {rec.id}  -> {rec.dir}")
        return 0
    if a.cmd == "new-measurements":
        env = Environment.load(a.env_id)
        rec = create_measurements(env, a.name)
        print(f"env {env.id}  recording {rec.id}  -> {rec.dir}")
        return 0
    if a.cmd == "new-run":
        env = Environment.load(a.env_id)
        inputs: dict = {"recording": a.recording} if a.kind == "scan" else {"asset": a.asset, "recordings": a.recordings}
        if not next(iter(inputs.values())):
            ap.error("scan needs --recording; extend and layout need --asset")
        run = create_run(env, a.kind, inputs, _settings_from(a), a.label, after=a.after)
        print(f"env {env.id}  run {run.id}  -> {run.dir}")
        if a.start:
            return run_pipeline(env.id, run.id)
        return 0
    if a.cmd == "run":
        return run_pipeline(a.env_id, a.run_id, a.redo)
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
                detail = (f"{len(rec.items)} measurements" if rec.kind == "measurements"
                          else f"{rec.source.get('count', '?')} photos, frames={rec.frames.status}" if rec.kind == "photos"
                          else f"frames={rec.frames.status}")
                print(f"    recording {r:8s} {rec.name:28s} {detail}")
            for r in e.run_ids():
                run = Run.load(e.id, r)
                chain = f" after {run.waits_for}" if run.waits_for else ""
                print(f"    run       {r:8s} {run.kind:12s} {run.status:10s} inputs={run.inputs}{chain} -> {run.output_asset}")
            for aid in e.asset_ids():
                asset = Asset.load(e.id, aid)
                print(f"    asset     {aid:10s} {asset.name:28s} from {asset.run_id}" + (f" (extends {asset.derived_from})" if asset.derived_from else ""))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
