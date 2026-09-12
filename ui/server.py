"""Local web UI for the scanner: scans, runs, stage logs, measurements, plans.

    make ui        # http://127.0.0.1:8765
State comes from the JSON manifests written by scanner.pipeline (work/scans/**/scan.json, run.json); the
server never parses logs. Pipeline work runs as detached subprocesses (python -m scanner.pipeline ...).
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from scanner import metrics, pipeline
from scanner.models import (DATA, ROOT, VIDEO_EXT, FrameSettings, Run, RunSettings, Scan, artifacts, list_scans, now)

STATIC = ROOT / "ui" / "static"
app = FastAPI(title="Backyard Scanner")


def _scan(sid: str) -> Scan:
    try:
        return Scan.load(sid)
    except KeyError:
        raise HTTPException(404, "no such scan")


def _run(sid: str, rid: str) -> Run:
    try:
        return Run.load(sid, rid)
    except KeyError:
        raise HTTPException(404, "no such run")


def _reconcile(run: Run) -> Run:
    """A run whose process died without updating its manifest is marked interrupted."""
    if run.status == "running" and not run.is_alive():
        run.status = "interrupted"
        for st in run.stages.values():
            if st.status == "running":
                st.status, st.finished_at, st.error = "interrupted", now(), "process died"
        run.pid = None
        run.save()
    return run


def run_summary(run: Run) -> dict:
    d = run.to_json()
    d["artifacts"] = artifacts(run)
    d["thumbnail"] = "thumb.jpg" if (run.dir / "thumb.jpg").exists() else None
    d["prompts_available"] = (run.dir / "measure" / "prompts.json").exists()
    a = run.dir / "measure" / "answers.json"
    d["answers"] = json.load(open(a)) if a.exists() else {}
    t = run.dir / "transform.json"
    if t.exists():
        tj = json.load(open(t)); tj.pop("matrix", None); d["transform"] = tj
    else:
        d["transform"] = None
    return d


def scan_summary(scan: Scan, with_runs: bool = True) -> dict:
    d = scan.to_json()
    if with_runs:
        d["runs"] = [run_summary(_reconcile(Run.load(scan.id, r))) for r in scan.run_ids()]
    return d


# ---------------------------------------------------------------- pages & health

@app.get("/", response_class=HTMLResponse)
def index():
    return HTMLResponse((STATIC / "index.html").read_text(), headers={"Cache-Control": "no-store"})


@app.get("/api/health")
def health():
    import shutil
    return {"ok": True, "root": str(ROOT), "blender": os.path.exists(pipeline.BLENDER),
            "openmvs": (ROOT / "tools/openmvs-install/bin/OpenMVS/DensifyPointCloud").exists(),
            "colmap": shutil.which("colmap") is not None}


# ---------------------------------------------------------------- videos

@app.get("/api/videos")
def videos():
    DATA.mkdir(exist_ok=True)
    used = {s.video.get("path") for s in list_scans()}
    vids = [p for p in DATA.iterdir() if p.suffix.lower() in VIDEO_EXT]
    return [{"name": p.name, "size": p.stat().st_size, "mtime": p.stat().st_mtime,
             "used": os.path.relpath(p, ROOT) in used} for p in sorted(vids, key=lambda p: -p.stat().st_mtime)]


@app.post("/api/upload")
async def upload(file: UploadFile = File(...)):
    DATA.mkdir(exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", file.filename or "video")
    if Path(safe).suffix.lower() not in VIDEO_EXT:
        raise HTTPException(400, "not a video file")
    dest = DATA / safe
    if dest.exists():
        dest = DATA / f"{dest.stem}_{int(time.time())}{dest.suffix}"
    with open(dest, "wb") as f:
        while chunk := await file.read(8 << 20):
            f.write(chunk)
    return {"name": dest.name, "size": dest.stat().st_size, "info": metrics.video_info(dest)}


# ---------------------------------------------------------------- scans

class NewScan(BaseModel):
    video: str
    name: str | None = None
    fps: float = 2.0
    max_frames: int = 400
    hdr: str = "auto"
    start: bool = True
    settings: RunSettings | None = None


class ScanPatch(BaseModel):
    name: str | None = None
    notes: str | None = None
    site: str | None = None


@app.get("/api/scans")
def get_scans():
    return [scan_summary(s) for s in list_scans()]


@app.post("/api/scans")
def new_scan(req: NewScan):
    video = DATA / Path(req.video).name
    if not video.exists():
        raise HTTPException(404, "video not found in data/")
    if req.hdr not in ("auto", "none", "hlg", "pq"):
        raise HTTPException(400, "bad hdr option")
    scan = pipeline.create_scan(video, req.name, FrameSettings(fps=req.fps, max_frames=req.max_frames, hdr=req.hdr))
    run = pipeline.create_run(scan, req.settings or RunSettings())
    if req.start:
        pipeline.launch(["run", scan.id, run.id])
    return {"scan_id": scan.id, "run_id": run.id}


@app.get("/api/scans/{sid}")
def get_scan(sid: str):
    return scan_summary(_scan(sid))


@app.patch("/api/scans/{sid}")
def patch_scan(sid: str, req: ScanPatch):
    scan = _scan(sid)
    for k, v in req.model_dump().items():
        if v is not None:
            setattr(scan, k, v)
    scan.save()
    return scan_summary(scan, with_runs=False)


@app.delete("/api/scans/{sid}")
def delete_scan(sid: str):
    import shutil
    scan = _scan(sid)
    for rid in scan.run_ids():
        if _reconcile(Run.load(sid, rid)).status == "running":
            raise HTTPException(409, "a run is still running")
    shutil.rmtree(scan.dir)
    return {"ok": True}


@app.get("/api/scans/{sid}/file/{path:path}")
def scan_file(sid: str, path: str):
    scan = _scan(sid)
    p = (scan.dir / path).resolve()
    if scan.dir.resolve() not in p.parents or not p.is_file():
        raise HTTPException(404, "no such file")
    return FileResponse(p, filename=p.name)


@app.get("/api/scans/{sid}/log")
def scan_log(sid: str, tail_kb: int = 256):
    return _tail(_scan(sid).dir / "logs" / "frames.log", tail_kb)


# ---------------------------------------------------------------- runs

class NewRun(BaseModel):
    settings: RunSettings = RunSettings()
    label: str = ""
    start: bool = True


@app.post("/api/scans/{sid}/runs")
def new_run(sid: str, req: NewRun):
    scan = _scan(sid)
    if req.settings.features not in ("SIFT", "ALIKED") or req.settings.matcher not in ("BRUTEFORCE", "LIGHTGLUE") \
            or req.settings.matching not in ("vocab", "sequential", "exhaustive"):
        raise HTTPException(400, "bad option")
    run = pipeline.create_run(scan, req.settings, req.label)
    if req.start:
        pipeline.launch(["run", scan.id, run.id])
    return {"scan_id": scan.id, "run_id": run.id}


@app.get("/api/scans/{sid}/runs/{rid}")
def get_run(sid: str, rid: str):
    d = run_summary(_reconcile(_run(sid, rid)))
    d["scan"] = scan_summary(_scan(sid), with_runs=False)
    return d


@app.post("/api/scans/{sid}/runs/{rid}/start")
def start_run(sid: str, rid: str):
    run = _reconcile(_run(sid, rid))
    if run.status == "running":
        raise HTTPException(409, "already running")
    pipeline.launch(["run", sid, rid])
    return {"ok": True}


@app.post("/api/scans/{sid}/runs/{rid}/cancel")
def cancel_run(sid: str, rid: str):
    run = _reconcile(_run(sid, rid))
    if run.status != "running" or not run.pid:
        raise HTTPException(409, "not running")
    try:
        os.killpg(os.getpgid(run.pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    return {"ok": True}


@app.delete("/api/scans/{sid}/runs/{rid}")
def delete_run(sid: str, rid: str):
    import shutil
    run = _reconcile(_run(sid, rid))
    if run.status == "running":
        raise HTTPException(409, "cancel it first")
    shutil.rmtree(run.dir)
    return {"ok": True}


def _tail(path: Path, tail_kb: int) -> dict:
    if not path.exists():
        return {"text": "", "truncated": False}
    text = path.read_text(errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    truncated = len(text) > tail_kb * 1024
    if truncated:
        text = text[-tail_kb * 1024:]
        text = text[text.find("\n") + 1:]
    return {"text": text, "truncated": truncated}


@app.get("/api/scans/{sid}/runs/{rid}/log")
def run_log(sid: str, rid: str, stage: str = "sfm", tail_kb: int = 256):
    run = _run(sid, rid)
    if stage == "frames":
        return _tail(_scan(sid).dir / "logs" / "frames.log", tail_kb)
    if stage not in run.stages:
        raise HTTPException(400, "bad stage")
    return _tail(run.dir / "logs" / f"{stage}.log", tail_kb)


@app.get("/api/scans/{sid}/runs/{rid}/file/{path:path}")
def run_file(sid: str, rid: str, path: str):
    run = _run(sid, rid)
    p = (run.dir / path).resolve()
    if run.dir.resolve() not in p.parents or not p.is_file():
        raise HTTPException(404, "no such file")
    return FileResponse(p, filename=p.name)


@app.post("/api/scans/{sid}/runs/{rid}/reveal")
def reveal(sid: str, rid: str):
    subprocess.Popen(["open", str(_run(sid, rid).dir)])
    return {"ok": True}


# ---------------------------------------------------------------- measurements & plan

@app.get("/api/scans/{sid}/runs/{rid}/prompts")
def get_prompts(sid: str, rid: str):
    run = _run(sid, rid)
    p = run.dir / "measure" / "prompts.json"
    if not p.exists():
        raise HTTPException(404, "no prompts yet")
    data = json.load(open(p))
    a = run.dir / "measure" / "answers.json"
    data["answers"] = json.load(open(a)) if a.exists() else {}
    return data


class Answer(BaseModel):
    prompt_id: str
    value: float | None = None
    skipped: bool | None = None
    confirmed: bool | None = None
    bearing: float | None = None


@app.post("/api/scans/{sid}/runs/{rid}/answers")
def post_answer(sid: str, rid: str, ans: Answer):
    run = _run(sid, rid)
    a = run.dir / "measure" / "answers.json"
    if not (run.dir / "measure" / "prompts.json").exists():
        raise HTTPException(404, "no prompts")
    data = json.load(open(a)) if a.exists() else {}
    entry = {k: v for k, v in ans.model_dump().items() if k != "prompt_id" and v is not None}
    if entry:
        entry["at"] = now()
        data[ans.prompt_id] = entry
    else:
        data.pop(ans.prompt_id, None)
    a.write_text(json.dumps(data, indent=1))
    return {"ok": True, "answers": data}


@app.post("/api/scans/{sid}/runs/{rid}/plan")
def start_plan(sid: str, rid: str, px_per_m: int = 50):
    run = _reconcile(_run(sid, rid))
    if run.status == "running":
        raise HTTPException(409, "a job is already running for this run")
    if not (run.dir / "dense" / "scene_dense_mesh_texture.obj").exists():
        raise HTTPException(400, "no textured mesh yet")
    pipeline.launch(["plan", sid, rid, "--px-per-m", str(px_per_m)])
    return {"ok": True}
