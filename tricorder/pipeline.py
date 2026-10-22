"""Pipeline orchestrator: runs the stage scripts for a run and keeps the manifests current.

    python -m tricorder.pipeline new data/backyard.MOV --name "Backyard" [--fps 2 --max-frames 600 ...] [--start]
                                       # environment + recording + scan run in one go
    python -m tricorder.pipeline new-env "Backyard"
    python -m tricorder.pipeline new-recording <env> data/walk.MOV [--name ... --fps 2 --max-frames 400 --hdr auto]
    python -m tricorder.pipeline new-recording <env> IMG_0001.HEIC IMG_0002.HEIC … | photos/   # a photos recording
    python -m tricorder.pipeline new-measurements <env> --name "Tape, Saturday"   # then add items in the app
    python -m tricorder.pipeline new-marks <env> --model model3d-1 --name "Elements"  # marks drawn on a model in the app
    python -m tricorder.pipeline new-run <env> identify --asset model3d-1 [--prior inventory-1] [--vlm qwen-local] [--start]
    python -m tricorder.pipeline new-run <env> layout --asset model3d-1 --recordings rec2 --marks rec3 --inventory inventory-1
    python -m tricorder.pipeline new-run <env> edit --asset model3d-1 --inventory inventory-1 --marks rec5 [--start]
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
from .models import (ASSET_KINDS, DATA, ENVS, IMAGE_EXT, RECORDING_KINDS, ROOT, RUN_KINDS, RUN_OUTPUT_IS_RECORDING, VIDEO_EXT, Asset,
                     Environment, FrameSettings, Recording, Run, RunSettings, Stage, next_id, now, slugify, unique_id, list_environments)

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
                  "contours.json", "footprint.json", "linework.json", "elements.json", "overlay.json", "site_plan.dxf", "site_plan.pdf",
                  "site_plan.blend", "site_plan_page*.png", "scene_dense_metric.ply", "preview.usdz", "thumb.jpg"],
    # the identify run publishes a generated marks recording; these files go into the recording dir
    "marks": ["entities.json", "faces.npy", "labels.json", "segments", "lift", "review", "inventory_map.png", "thumb.jpg"],
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
    "annotate": ["elements.json"],
    "draw": ["site_plan.pdf", "site_plan.dxf", "dem.tif", "contours.json", "overlay.json"],
    "segment": ["segments/index.json"],
    "name": ["segments/names.json"],
    "lift": ["faces.npy", "labels.json"],
    "entities": ["entities.json"],
    "review": ["review/review.json"],
    "select": ["edit/selection.json"],
    "cut": ["dense/scene_dense_mesh_clean.ply", "dense/scene_dense.ply", "edit/cut.json"],
    "complete": ["dense/scene_dense_mesh_texture.obj", "edit/complete.json"],
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
    "elements.json": "Named elements on the plan (marks + inventory)",
    "entities.json": "Entities: what is where, with footprints",
    "faces.npy": "Entity index per mesh face",
    "labels.json": "Labels and classes of the entities",
    "segments/index.json": "Segmented frames (masks)",
    "segments/names.json": "Names the vision-language model gave each mask",
    "review/review.json": "Per-entity review verdicts",
    "inventory_map.png": "Inventory map (top-down, labelled)",
    "edit/selection.json": "Faces and regions selected for removal / patching",
    "edit/cut.json": "What the cut removed",
    "edit/complete.json": "How the holes were completed",
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


def create_marks(env: Environment, name: str, model_id: str) -> Recording:
    """An empty marks recording on one 3D model; the app's mesh editor fills its items (points in the model's frame)."""
    model = Asset.load(env.id, model_id)
    if model.kind != "model3d":
        raise ValueError(f"{model_id} is a {ASSET_KINDS.get(model.kind, model.kind)}, marks are drawn on a 3D model")
    rec = Recording(id=next_id(env.dir / "recordings", "rec"), env_id=env.id, name=name, created_at=now(), kind="marks",
                    source={"model": model.id, "frame": model.frame or model.id})
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
    elif run.kind == "layout" and not any(k == "asset" for k, _, _ in run.pending_refs()):
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


def _ids(v) -> list[str]:
    return [v] if isinstance(v, str) else list(v or [])


def stage_annotate(run: Run) -> None:
    """Named elements on the plan: the inventory's entities merged with the element marks, in plan metres."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        cmd = [PY, str(SCRIPTS / "18_annotate.py"), str(run.dir), "--model", str(asset.dir), "--boundary", run.settings.boundary]
        marks = [str(Recording.load(run.env_id, r).dir) for r in _ids(run.inputs.get("marks"))]
        if marks:
            cmd += ["--marks", *marks]
        _check(_exec(cmd, log), "annotate")
        e = json.load(open(run.dir / "elements.json"))
        els = e.get("elements", [])
        return {"elements": len(els), "from_marks": sum(1 for x in els if x.get("source") == "mark"),
                "from_inventory": sum(1 for x in els if x.get("source") == "inventory"),
                "classes": sorted({x.get("cls", "") for x in els}), "override_walls": bool(e.get("override_walls")),
                "landuse": len(e.get("landuse", [])), "openings": len((e.get("boundaries", {}).get(e.get("boundary_source", "walls")) or {}).get("openings", [])),
                "boundary": e.get("boundary_source")}
    _stage(run, "annotate", fn)


def stage_draw(run: Run) -> None:
    """DEM, contours, footprint, DXF, PDF sheet, world file, app overlay."""
    def fn(log: Path) -> dict:
        env = Environment.load(run.env_id)
        _check(_exec([PY, str(SCRIPTS / "08_site_plan.py"), str(run.dir), "--contour", str(run.settings.contour_m),
                      "--scale", str(run.settings.sheet_scale), "--title", env.name, "--boundary", run.settings.boundary,
                      "--subtitle", f"existing conditions · {run.env_id} · {run.inputs.get('asset', '')} · {now()[:10]}"], log), "site plan drawing")
        o = json.load(open(run.dir / "overlay.json"))
        return {"contours": len(o.get("contours", [])), "measurements": len(o.get("measurements", [])),
                "sheet_scale": o.get("sheet_scale"), "contour_interval": o.get("contour_interval"),
                "elements": len(o.get("elements", []))}
    _stage(run, "draw", fn)


# ---- identify: segment, name, lift, entities, review

def _identify_env(run: Run) -> dict[str, str]:
    return {"TRICORDER_VLM": run.settings.vlm, "TRICORDER_SAM": run.settings.sam}


def _frames_dir(env_id: str, asset: Asset) -> Path:
    """Where the model's frames are (the scan's single recording for now; extended models carry prefixes)."""
    sources = model_sources(env_id, asset)
    if not sources:
        raise RuntimeError(f"{asset.id} does not record which recording its frames came from")
    return ENVS / env_id / "recordings" / sources[0]["recording"] / "images"


def stage_segment(run: Run) -> None:
    """Every region of a subset of the registered frames as a mask (SAM, automatic), or the prior inventory's masks."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        if run.inputs.get("prior"):
            prior = Recording.load(run.env_id, run.inputs["prior"])
            if not (prior.dir / "segments" / "names.json").exists():
                raise RuntimeError(f"{prior.id} is not a generated inventory (no named segments to carry over)")
            clone(prior.dir / "segments", run.dir / "segments")
            removed = set(asset.removed_entities)
            idx = json.load(open(run.dir / "segments" / "index.json"))
            with open(log, "a") as f:
                f.write(f"carried {len(idx.get('frames', []))} segmented frames from {prior.id}; "
                        f"{len(removed)} removed entities will be dropped at lift\n")
            (run.dir / "segments" / "carried_from.json").write_text(json.dumps({"prior": prior.id, "removed_entities": sorted(removed)}))
            return {"frames": len(idx.get("frames", [])), "masks": idx.get("masks", 0), "carried_from": prior.id}
        cmd = [PY, str(SCRIPTS / "13_segment.py"), str(run.dir), "--model", str(asset.dir), "--frames", str(_frames_dir(run.env_id, asset)),
               "--every", str(run.settings.every), "--max", str(run.settings.frames_cap)]
        _check(_exec(cmd, log, env=_identify_env(run)), "segmentation")
        idx = json.load(open(run.dir / "segments" / "index.json"))
        return {"frames": len(idx.get("frames", [])), "masks": idx.get("masks", 0), "sam": run.settings.sam}
    _stage(run, "segment", fn)


def stage_name(run: Run) -> None:
    """A vision-language model names the masks of every frame (set-of-mark prompting), once per frame."""
    def fn(log: Path) -> dict:
        if (run.dir / "segments" / "carried_from.json").exists():
            names = json.load(open(run.dir / "segments" / "names.json"))
            return {"frames": len(names.get("frames", {})), "named": names.get("named", 0), "vlm": "carried"}
        asset = Asset.load(run.env_id, run.inputs["asset"])
        cmd = [PY, str(SCRIPTS / "14_name.py"), str(run.dir), "--frames", str(_frames_dir(run.env_id, asset)), "--vlm", run.settings.vlm]
        _check(_exec(cmd, log, env=_identify_env(run)), "naming")
        names = json.load(open(run.dir / "segments" / "names.json"))
        return {"frames": len(names.get("frames", {})), "named": names.get("named", 0), "vlm": names.get("vlm", run.settings.vlm),
                "seconds_per_frame": names.get("seconds_per_frame")}
    _stage(run, "name", fn)


def stage_lift(run: Run) -> None:
    """Every named mask onto the mesh: pixels → rays → faces; votes per face across frames."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        cmd = [PY, str(SCRIPTS / "15_lift.py"), str(run.dir), "--model", str(asset.dir), "--frames", str(_frames_dir(run.env_id, asset))]
        _check(_exec(cmd, log), "lift")
        lab = json.load(open(run.dir / "labels.json"))
        return {"faces": lab.get("faces"), "labelled_faces": lab.get("labelled_faces"), "labels": len(lab.get("labels", []))}
    _stage(run, "lift", fn)


def stage_entities(run: Run) -> None:
    """Connected runs of same-label faces become entities with names, centroid, height, outline, footprint."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        _check(_exec([PY, str(SCRIPTS / "16_entities.py"), str(run.dir), "--model", str(asset.dir)], log), "entities")
        e = json.load(open(run.dir / "entities.json"))
        ents = e.get("entities", [])
        classes: dict[str, int] = {}
        for x in ents:
            classes[x["cls"]] = classes.get(x["cls"], 0) + 1
        return {"entities": len(ents), "classes": classes}
    _stage(run, "entities", fn)


def stage_review(run: Run) -> None:
    """Each entity re-projected into its best frame and shown to the model: one object? what is it?"""
    def fn(log: Path) -> dict:
        if not run.settings.review or run.settings.vlm == "none":
            with open(log, "a") as f:
                f.write("review disabled by settings\n")
            return {"reviewed": 0, "skipped": True}
        asset = Asset.load(run.env_id, run.inputs["asset"])
        cmd = [PY, str(SCRIPTS / "17_review.py"), str(run.dir), "--model", str(asset.dir), "--frames", str(_frames_dir(run.env_id, asset)),
               "--vlm", run.settings.vlm]
        _check(_exec(cmd, log, env=_identify_env(run)), "review")
        r = json.load(open(run.dir / "review" / "review.json"))
        return {"reviewed": r.get("reviewed", 0), "renamed": r.get("renamed", 0), "doubted": r.get("doubted", 0)}
    _stage(run, "review", fn)


# ---- edit: select, cut, complete

def _edit_cmd(run: Run, script: str) -> list[str]:
    asset = Asset.load(run.env_id, run.inputs["asset"])
    cmd = [PY, str(SCRIPTS / script), str(run.dir), "--model", str(asset.dir)]
    marks = [str(Recording.load(run.env_id, r).dir) for r in _ids(run.inputs.get("marks"))]
    return cmd + ["--marks", *marks]


def stage_select(run: Run) -> None:
    """Edit marks → faces of the clean mesh and ground regions to cut or patch."""
    def fn(log: Path) -> dict:
        _check(_exec(_edit_cmd(run, "19_edit_select.py"), log), "selection")
        s = json.load(open(run.dir / "edit" / "selection.json"))
        return {"removes": len([x for x in s.get("items", []) if x["cls"] == "remove"]),
                "patches": len([x for x in s.get("items", []) if x["cls"] == "patch"]),
                "faces": sum(x.get("faces", 0) for x in s.get("items", [])), "entities": s.get("removed_entities", [])}
    _stage(run, "select", fn)


def stage_cut(run: Run) -> None:
    """Remove the selected faces from the clean mesh and the matching points from the dense cloud (the run's own copies)."""
    def fn(log: Path) -> dict:
        asset = Asset.load(run.env_id, run.inputs["asset"])
        d = run.dir / "dense"
        if d.is_symlink():
            d.unlink()
        d.mkdir(exist_ok=True)
        for name in ("scene_dense.ply", "scene_dense_mesh_clean.ply", "sparse"):
            if (asset.dir / "dense" / name).exists() and not (d / name).exists():
                clone(asset.dir / "dense" / name, d / name)
        _check(_exec([PY, str(SCRIPTS / "20_edit_cut.py"), str(run.dir), "--model", str(asset.dir)], log), "cut")
        return json.load(open(run.dir / "edit" / "cut.json"))
    _stage(run, "cut", fn)


def stage_complete(run: Run) -> None:
    """Blender: cut the same regions out of the textured mesh, fill the holes on a fitted ground surface, texture the patch;
    then the fill as points into the dense cloud."""
    def fn(log: Path) -> dict:
        if not os.path.exists(BLENDER):
            raise RuntimeError(f"Blender not found at {BLENDER}")
        asset = Asset.load(run.env_id, run.inputs["asset"])
        _check(_exec([BLENDER, "--background", "--python", str(SCRIPTS / "21_edit_complete_blender.py"), "--",
                      "--run", str(run.dir), "--model", str(asset.dir)], log), "Blender edit")
        _check(_exec([PY, str(SCRIPTS / "22_edit_fill_cloud.py"), str(run.dir)], log), "cloud fill")
        return json.load(open(run.dir / "edit" / "complete.json"))
    _stage(run, "complete", fn)


def stage_preview(run: Run) -> None:
    """Decimated USDZ of the textured mesh for the app's 3D viewer. Metric + levelled for plans, levelled only for scans.
    An identify run's preview is its map; an edit's preview first carries the parent's poses and levelling over."""
    def fn(log: Path) -> dict:
        if run.kind == "identify":
            if (run.dir / "inventory_map.png").exists():
                metrics.make_thumbnail(run.dir / "inventory_map.png", run.dir / "thumb.jpg")
            return {"size": (run.dir / "thumb.jpg").stat().st_size if (run.dir / "thumb.jpg").exists() else 0}
        if not os.path.exists(BLENDER):
            raise RuntimeError(f"Blender not found at {BLENDER}")
        if run.kind == "edit":
            parent = Asset.load(run.env_id, run.inputs["asset"])
            for name in ("sparse", "database.db", "measure", "transform_preview.json", "preview_plan.json"):
                if (parent.dir / name).exists():
                    clone(parent.dir / name, run.dir / name)
            if (run.dir / "transform_preview.json").exists():
                render_plan(run, run.dir / "transform_preview.json", "preview_plan", log)
                if (run.dir / "preview_plan_grid.png").exists():
                    metrics.make_thumbnail(run.dir / "preview_plan_grid.png", run.dir / "thumb.jpg")
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
            "ortho": stage_ortho, "trace": stage_trace, "annotate": stage_annotate, "draw": stage_draw, "preview": stage_preview,
            "segment": stage_segment, "name": stage_name, "lift": stage_lift, "entities": stage_entities, "review": stage_review,
            "select": stage_select, "cut": stage_cut, "complete": stage_complete}


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
    elif run.kind == "edit":
        parent = Asset.load(run.env_id, run.inputs["asset"])
        for k in ("registered", "images", "reproj_px", "prompts"):
            if k in parent.metrics:
                m[k] = parent.metrics[k]
        c = run.stages["cut"].metrics
        for k in ("faces", "dense_points", "faces_removed", "points_removed"):
            if k in c:
                m[k] = c[k]
        m["entities_removed"] = len(run.stages["select"].metrics.get("entities", []))
        m["patches"] = run.stages["select"].metrics.get("patches", 0)
    elif run.kind == "identify":
        m.update({k: v for k, v in run.stages["entities"].metrics.items()})
        m["frames"] = run.stages["segment"].metrics.get("frames")
        m["masks"] = run.stages["segment"].metrics.get("masks")
        m["vlm"] = run.stages["name"].metrics.get("vlm", run.settings.vlm)
        m["labelled_faces"] = run.stages["lift"].metrics.get("labelled_faces")
        m["reviewed"] = run.stages["review"].metrics.get("reviewed", 0)
    else:
        m.update(run.stages["solve"].metrics)
        m.update(run.stages["trace"].metrics)
        m.update(run.stages["annotate"].metrics)
        m.update(run.stages["draw"].metrics)
        m["px_per_m"] = run.settings.px_per_m
    return m


def entity_items(entities: list[dict]) -> list[dict]:
    """Entities as marks items: what a generated marks recording carries, in the same shape as a person's marks."""
    out = []
    for e in entities:
        out.append({"id": e["id"], "role": "element", "cls": e["cls"], "shape": e.get("shape", "polygon"), "points": e.get("outline", []),
                    "name": e.get("name"), "note": e.get("description", ""), "material": e.get("material"), "entity": e["id"],
                    "source": "generated", "confidence": e.get("confidence"), "area_m2": e.get("area_m2"), "height_m": e.get("height_m"),
                    "frames": e.get("frames"), "color": e.get("color"), "at": now()})
    return out


def publish_recording(run: Run) -> Recording:
    """An identify run publishes its inventory as a generated marks recording on the model it ran on."""
    model = Asset.load(run.env_id, run.inputs["asset"])
    rid = run.output_asset if run.output_asset and run.output_asset.startswith("rec") else next_id(run.dir.parent.parent / "recordings", "rec")
    rec = Recording(id=rid, env_id=run.env_id, name=f"Inventory · {run.id}", created_at=now(), kind="marks",
                    source={"model": model.id, "frame": model.frame or model.id, "generated_by": run.id, "generated": True})
    rec.dir.mkdir(parents=True, exist_ok=True)
    for pattern in DELIVERABLES["marks"]:
        for src in sorted(glob.glob(str(run.dir / pattern))):
            src = Path(src)
            clone(src, rec.dir / src.relative_to(run.dir))
    ents = json.load(open(run.dir / "entities.json")).get("entities", []) if (run.dir / "entities.json").exists() else []
    rec.items = entity_items(ents)
    rec.source["metrics"] = asset_metrics(run)
    rec.thumbnail = "thumb.jpg" if (rec.dir / "thumb.jpg").exists() else None
    rec.save()
    run.output_asset = rec.id
    run.save()
    return rec


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
        asset.frame = asset.id
    elif run.kind == "extend":
        parent = Asset.load(run.env_id, run.inputs["asset"])
        asset.derived_from = parent.id
        old = model_sources(run.env_id, parent)
        asset.sources = old + [{"recording": r, "prefix": f"{r}/"} for r in run.inputs.get("recordings", [])
                               if r not in {s["recording"] for s in old}]
        asset.frame = asset.id                              # a full bundle adjustment moved the frame
    elif run.kind == "edit":
        parent = Asset.load(run.env_id, run.inputs["asset"])
        asset.derived_from = parent.id
        asset.sources = model_sources(run.env_id, parent)
        asset.frame = parent.frame or parent.id             # geometry edits keep the frame
        asset.metrics["features"] = parent.metrics.get("features", asset.metrics.get("features"))
        sel = run.dir / "edit" / "selection.json"
        if sel.exists():
            asset.removed_entities = list(parent.removed_entities) + list(json.load(open(sel)).get("removed_entities", []))
        asset.name = f"{ASSET_KINDS[kind]} · {run.id} (edited)"
    else:                                                   # layout: made on a model, in its frame
        model = Asset.load(run.env_id, run.inputs["asset"])
        asset.derived_from = model.id
        asset.frame = model.frame or model.id
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
    """A chained run's "@r5" slots become r5's published asset. Returns a reason to wait, or None to go ahead."""
    changed = False
    for parent_id in run.waits_for_all:
        try:
            parent = Run.load(run.env_id, parent_id)
        except KeyError:
            return f"run {parent_id} (this run's input) no longer exists"
        if parent.status != "done" or not parent.output_asset:
            return f"waiting for run {parent_id} ({parent.status})"
        changed = run.resolve_ref(parent_id, parent.output_asset) or changed
    if changed:
        run.save()
        _prepare(run)
    return None


def _launch_dependants(run: Run) -> None:
    """Queued runs that wait for this run's output start now (if nothing else they wait for is still working)."""
    env = Environment.load(run.env_id)
    for rid in env.run_ids():
        try:
            r = Run.load(run.env_id, rid)
        except Exception:
            continue
        if r.status != "queued" or run.id not in r.waits_for_all:
            continue
        others = [w for w in r.waits_for_all if w != run.id]
        ready = True
        for w in others:
            try:
                p = Run.load(run.env_id, w)
                ready = ready and p.status == "done" and bool(p.output_asset)
            except KeyError:
                ready = False
        if ready:
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
        if run.kind in RUN_OUTPUT_IS_RECORDING:
            publish_recording(run)
        else:
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


# ---------------------------------------------------------------- remote control (the app on another Mac)

def reconcile() -> list[str]:
    """Runs marked running whose process is gone become interrupted, on the machine where the pid means something.
    The app does this itself for a local checkout; a remote app asks for it before every mirror pull."""
    fixed = []
    for env in list_environments():
        for rid in env.run_ids():
            try:
                run = Run.load(env.id, rid)
            except Exception:
                continue
            if run.status != "running" or run.is_alive():
                continue
            run.status, run.pid, run.finished_at = "interrupted", None, now()
            for st in run.stages.values():
                if st.status == "running":
                    st.status, st.finished_at, st.error = "interrupted", now(), "process died"
            run.save()
            fixed.append(f"{env.id}/{rid}")
    return fixed


def cancel(env_id: str, run_id: str) -> bool:
    """SIGTERM a running run's process group; run_pipeline turns that into a clean 'cancelled'."""
    run = Run.load(env_id, run_id)
    if not run.is_alive():
        return False
    try:
        os.killpg(os.getpgid(run.pid), signal.SIGTERM)
    except ProcessLookupError:
        os.kill(run.pid, signal.SIGTERM)
    return True


# What the app on another Mac expects of this checkout: bump when a command the app relies on is added or changed.
PROTOCOL = 2


def health() -> dict:
    try:
        rev = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        rev = ""
    return {"protocol": PROTOCOL, "revision": rev,
            "colmap": shutil.which("colmap") is not None,
            "openmvs": os.access(ROOT / "tools" / "openmvs-install" / "bin" / "OpenMVS" / "DensifyPointCloud", os.X_OK)
                       or shutil.which("docker") is not None,
            "blender": os.access(BLENDER, os.X_OK), "python": True,
            "host": os.uname().nodename, "root": str(ROOT)}


def inbox() -> list[dict]:
    """Videos waiting in data/ (paths relative to ROOT), newest first."""
    DATA.mkdir(parents=True, exist_ok=True)
    vids = [p for p in DATA.iterdir() if p.suffix.lower() in VIDEO_EXT and p.is_file()]
    return [{"path": str(p.relative_to(ROOT)), "size": p.stat().st_size, "modified": p.stat().st_mtime}
            for p in sorted(vids, key=lambda p: p.stat().st_mtime, reverse=True)]


def trash(env_id: str, kind: str | None, item_id: str | None) -> Path:
    """Move an environment, or one of its recordings / runs / assets, into work/trash/ (recoverable by hand)."""
    _check_ids(env_id, *([item_id] if item_id else []))
    src = ENVS / env_id if kind is None else ENVS / env_id / kind / item_id
    if not src.exists():
        raise KeyError(str(src))
    dst = ROOT / "work" / "trash" / f"{now().replace(':', '-')}-{env_id}" / (f"{kind}-{item_id}" if kind else "environment")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    return dst


# ---------------------------------------------------------------- CLI

def _settings_from(a) -> RunSettings:
    return RunSettings(res_level=a.res_level, features=a.features, matcher=a.matcher, matching=a.matching,
                       measures=a.measures, max_faces=a.max_faces, px_per_m=a.px_per_m, contour_m=a.contour, sheet_scale=a.sheet_scale,
                       wall_jump_m=a.wall, edge_jump_m=a.edge, min_edge_m=a.min_edge, preview_faces=a.preview_faces,
                       vlm=a.vlm, sam=a.sam, every=a.every, frames_cap=a.frames_cap, review=a.review, boundary=a.boundary)


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
        p.add_argument("--vlm", default="qwen-local", choices=["qwen-local", "claude", "none"], help="identify: who names the masks")
        p.add_argument("--sam", default="facebook/sam-vit-base", help="identify: segmenter checkpoint")
        p.add_argument("--every", type=int, default=10, help="identify: every n-th registered frame")
        p.add_argument("--frames-cap", type=int, default=60, help="identify: at most this many frames")
        p.add_argument("--review", type=int, default=1, help="identify: 1 = re-project entities and ask the model to confirm")
        p.add_argument("--boundary", default="walls", choices=["walls", "footprint"], help="layout: which boundary the plan draws")
        p.add_argument("--label", default="")
        p.add_argument("--start", action="store_true", help="run the pipeline now (in this process)")

    p = sub.add_parser("new", help="environment + recording + scan run from a video")
    p.add_argument("video"); p.add_argument("--name"); add_frame_args(p); add_run_settings(p)
    p = sub.add_parser("new-env", help="create an empty environment"); p.add_argument("name")
    p = sub.add_parser("new-recording", help="add a video, or photos (files or a folder), to an environment")
    p.add_argument("env_id"); p.add_argument("paths", nargs="+"); p.add_argument("--name"); add_frame_args(p)
    p = sub.add_parser("new-measurements", help="add an empty measurement recording (the app fills it)")
    p.add_argument("env_id"); p.add_argument("--name", default="Measurements")
    p = sub.add_parser("new-marks", help="add an empty marks recording on a 3D model (the app's mesh editor fills it)")
    p.add_argument("env_id"); p.add_argument("--model", required=True, help="the 3D model asset the marks are drawn on")
    p.add_argument("--name", default="Marks")
    p = sub.add_parser("new-run", help="add a run to an environment")
    p.add_argument("env_id"); p.add_argument("kind", choices=list(RUN_KINDS))
    p.add_argument("--recording", help="input video recording id (scan)")
    p.add_argument("--asset", help="input 3D-model asset id (extend, identify, layout, edit), or @<run> for a chained run")
    p.add_argument("--recordings", nargs="*", default=[], help="extend: new video/photo recordings; layout: measurement recordings")
    p.add_argument("--marks", nargs="*", default=[], help="layout / edit: marks recordings (yours and generated inventories), or @<run>")
    p.add_argument("--prior", help="identify: a prior generated inventory (marks recording) to re-lift, or @<run>")
    p.add_argument("--after", help="wait for this run to finish first (usually implied by @<run> inputs)")
    add_run_settings(p)
    p = sub.add_parser("run", help="execute a run; finished stages are kept unless --redo names them")
    p.add_argument("env_id"); p.add_argument("run_id")
    p.add_argument("--redo", action="append", default=[], metavar="STAGE", help="reset this stage first (repeatable), e.g. --redo preview")
    p = sub.add_parser("list")
    p = sub.add_parser("reconcile", help="mark runs whose process died as interrupted (the app on another Mac asks before each mirror pull)")
    p = sub.add_parser("cancel", help="SIGTERM a running run"); p.add_argument("env_id"); p.add_argument("run_id")
    p = sub.add_parser("health", help="which tools this checkout has, as JSON")
    p = sub.add_parser("inbox", help="videos waiting in data/, as JSON")
    p = sub.add_parser("trash", help="move an environment, or one of its recordings / runs / assets, into work/trash/")
    p.add_argument("env_id"); p.add_argument("kind", nargs="?", choices=["recordings", "runs", "assets"]); p.add_argument("item_id", nargs="?")
    p = sub.add_parser("migrate-inventories", help="turn inventory assets from before 2026-10-03 into generated marks recordings")
    p.add_argument("env_id")
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
    if a.cmd == "new-marks":
        env = Environment.load(a.env_id)
        rec = create_marks(env, a.name, a.model)
        print(f"env {env.id}  recording {rec.id}  -> {rec.dir}")
        return 0
    if a.cmd == "new-run":
        env = Environment.load(a.env_id)
        inputs: dict = {slot["key"]: getattr(a, slot["key"], None) for slot in RUN_KINDS[a.kind]["slots"]}
        if not next(iter(inputs.values())):
            ap.error("scan needs --recording; every other kind needs --asset")
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
    if a.cmd == "migrate-inventories":
        env = Environment.load(a.env_id)
        mapping = {}
        for aid in env.asset_ids():
            d = json.load(open(ENVS / env.id / "assets" / aid / "asset.json"))
            if d.get("kind") != "inventory":
                continue
            run = Run.load(env.id, d["run_id"])
            rec = Recording(id=next_id(env.dir / "recordings", "rec"), env_id=env.id, name=f"Inventory · {run.id}", created_at=d["created_at"],
                            kind="marks", source={"model": d.get("derived_from"), "frame": d.get("frame") or d.get("derived_from"),
                                                  "generated_by": run.id, "generated": True, "metrics": d.get("metrics", {})})
            rec.dir.mkdir(parents=True, exist_ok=True)
            src = ENVS / env.id / "assets" / aid
            for item in src.iterdir():
                if item.name != "asset.json":
                    clone(item, rec.dir / item.name)
            ents = json.load(open(src / "entities.json")).get("entities", []) if (src / "entities.json").exists() else []
            rec.items = entity_items(ents)
            rec.thumbnail = "thumb.jpg" if (rec.dir / "thumb.jpg").exists() else None
            rec.save()
            run.output_asset = rec.id
            run.save()
            shutil.rmtree(src)
            mapping[aid] = rec.id
            print(f"{aid} -> recording {rec.id} ({len(rec.items)} entities)")
        for rid in env.run_ids():                       # runs that took the inventory as an asset now take the recording as marks
            p = ENVS / env.id / "runs" / rid / "run.json"
            d = json.load(open(p))
            inv = d.get("inputs", {}).pop("inventory", None) or d.get("inputs", {}).pop("prior_asset", None)
            if inv is not None:
                key = "prior" if d["kind"] == "identify" else "marks"
                if key == "prior":
                    d["inputs"][key] = mapping.get(inv, inv)
                else:
                    d["inputs"].setdefault("marks", [])
                    d["inputs"]["marks"] = list(d["inputs"]["marks"]) + [mapping.get(inv, inv)]
                d["stages"].pop("annotate", None) if False else None
                json.dump(d, open(p, "w"), indent=1)
                print(f"run {rid}: inventory {inv} -> {key} {mapping.get(inv, inv)}")
        return 0
    if a.cmd == "reconcile":
        for f in reconcile():
            print(f"interrupted {f}")
        return 0
    if a.cmd == "cancel":
        print("signalled" if cancel(a.env_id, a.run_id) else "not running")
        return 0
    if a.cmd == "health":
        print(json.dumps(health()))
        return 0
    if a.cmd == "inbox":
        print(json.dumps(inbox()))
        return 0
    if a.cmd == "trash":
        if bool(a.kind) != bool(a.item_id):
            ap.error("trash takes an environment, or an environment plus kind and id")
        print(f"trashed -> {trash(a.env_id, a.kind, a.item_id)}")
        return 0
    if a.cmd == "list":
        for e in list_environments():
            print(f"{e.id:24s} {e.name}")
            for r in e.recording_ids():
                rec = Recording.load(e.id, r)
                detail = (f"{len(rec.items)} measurements" if rec.kind == "measurements"
                          else f"{len(rec.items)} {'generated ' if rec.source.get('generated') else ''}marks on {rec.source.get('model', '?')}" if rec.kind == "marks"
                          else f"{rec.source.get('count', '?')} photos, frames={rec.frames.status}" if rec.kind == "photos"
                          else f"frames={rec.frames.status}")
                print(f"    recording {r:8s} {rec.name:28s} {detail}")
            for r in e.run_ids():
                run = Run.load(e.id, r)
                chain = f" after {','.join(run.waits_for_all)}" if run.waits_for_all else ""
                print(f"    run       {r:8s} {run.kind:12s} {run.status:10s} inputs={run.inputs}{chain} -> {run.output_asset}")
            for aid in e.asset_ids():
                asset = Asset.load(e.id, aid)
                print(f"    asset     {aid:10s} {asset.name:28s} from {asset.run_id}" + (f" (extends {asset.derived_from})" if asset.derived_from else ""))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
