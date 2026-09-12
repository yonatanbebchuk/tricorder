"""Local web UI for the backyard scanner: upload a video, launch run_all.sh, watch stages and logs, grab outputs.

    make ui            # http://127.0.0.1:8765
    .venv/bin/uvicorn ui.server:app --port 8765 --reload

Everything is local: runs are subprocesses of this server (run_all.sh under caffeinate), state is read
back from work/<name>/run_all.log and the DONE / FAILED marker files, so runs started from the terminal
show up too.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel

ROOT = Path(__file__).resolve().parent.parent
DATA, WORK, STATIC = ROOT / "data", ROOT / "work", ROOT / "ui" / "static"
STAGES = ["input", "frames", "sfm", "dense", "landmarks", "plan"]
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".mkv", ".avi"}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
MARK_RE = re.compile(r"^######## (?:(\d)\. (\w[\w-]*)|(done) in (\d+) min).*?\[(\d\d:\d\d:\d\d), \+(\d+)m\].*$", re.M)
OUTPUTS = [
    ("images", "Extracted frames (folder)", True),
    ("sparse_points.ply", "Sparse point cloud (COLMAP)", False),
    ("dense/scene_dense.ply", "Dense point cloud (OpenMVS)", False),
    ("dense/scene_dense_mesh.ply", "Mesh, untextured", False),
    ("dense/scene_dense_mesh_texture.obj", "Textured mesh (OBJ + MTL + JPG)", False),
    ("dense/scene_dense_mesh_clean.ply", "Mesh, fragments removed (what gets textured)", False),
    ("plan_grid.png", "Site plan, true scale, 1 m grid", False),
    ("plan.png", "Site plan, true scale, plain", False),
    ("plan.blend", "Blender scene at true scale (editable)", False),
    ("dense/scene_dense_metric.ply", "Dense cloud in metres (CloudCompare)", False),
    ("transform.json", "Scale / level / north transform + residuals", False),
    ("preview_plan_grid.png", "Preview site plan with 1 m grid (unscaled)", False),
    ("preview_plan.png", "Preview site plan, plain", False),
    ("preview_plan.blend", "Blender scene (editable)", False),
    ("transform_preview.json", "Levelling transform used for the preview", False),
    ("run_all.log", "Full log", False),
]

app = FastAPI(title="Backyard Scanner")
procs: dict[str, subprocess.Popen] = {}


def run_dir(name: str) -> Path:
    if not NAME_RE.match(name):
        raise HTTPException(400, "bad run name")
    return WORK / name


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def is_running(name: str, d: Path, pidfile: str = "run.pid") -> bool:
    p = procs.get(name)
    if p is not None and p.poll() is None:
        return True
    pidf = d / pidfile
    if pidf.exists():
        try:
            return pid_alive(int(pidf.read_text().strip()))
        except ValueError:
            return False
    if pidfile != "run.pid":
        return False
    # not launched by this server (terminal run): treat a log that is still being written as running
    log = d / "run_all.log"
    if log.exists() and not (d / "DONE").exists() and not (d / "FAILED").exists():
        return time.time() - log.stat().st_mtime < 180
    return False


def parse_segments(text: str) -> list[dict]:
    """Split run_all.log into stage segments using the '######## N. name [hh:mm:ss, +Xm]' markers."""
    marks = list(MARK_RE.finditer(text))
    segs = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        body = text[m.end():end]
        if m.group(3):
            segs.append({"idx": 6, "name": "done", "time": m.group(5), "elapsed_min": int(m.group(6)),
                         "total_min": int(m.group(4)), "body": body})
        else:
            segs.append({"idx": int(m.group(1)), "name": m.group(2), "time": m.group(5),
                         "elapsed_min": int(m.group(6)), "body": body})
    return segs


def stage_summary(idx: int, body: str) -> dict:
    out = {}
    if idx == 1:
        m = re.search(r"wrote (\d+) images.*?sharpness median (\d+), min (\d+)", body)
        if m:
            out = {"images": int(m[1]), "sharpness_median": int(m[2]), "sharpness_min": int(m[3])}
    if idx == 2:
        models = re.findall(r"model (\d+): (\d+) registered images", body)
        m = re.search(r"Registered images: (\d+)", body)
        p = re.search(r"Points: (\d+)", body)
        e = re.search(r"Mean reprojection error: ([\d.]+)px", body)
        if m:
            out = {"registered": int(m[1]), "points": int(p[1]) if p else None,
                   "reproj_px": float(e[1]) if e else None, "submodels": len(models)}
    if idx == 3:
        m = re.search(r"Point-cloud 'scene_dense.ply' saved: (\d+) points", body)
        f = re.findall(r"Mesh saved: (\d+) vertices, (\d+) faces", body)
        if m:
            out["dense_points"] = int(m[1])
        if f:
            out["faces"] = int(f[0][1])
    return out


def run_detail(name: str) -> dict:
    d = run_dir(name)
    if not d.exists():
        raise HTTPException(404, "no such run")
    log = d / "run_all.log"
    text = log.read_text(errors="replace") if log.exists() else ""
    segs = parse_segments(text)
    running = is_running(name, d)
    plan_running = is_running(name + ":plan", d, pidfile="plan.pid")
    done = (d / "DONE").exists()
    failed_stage = (d / "FAILED").read_text().strip() if (d / "FAILED").exists() else None
    if (d / "PLAN_FAILED").exists():
        failed_stage = "plan"
    status = "running" if (running or plan_running) else "done" if done else "failed" if failed_stage else "interrupted" if segs else "empty"
    running = running or plan_running
    latest = max((s["idx"] for s in segs), default=-1)
    stages = []
    for i, sname in enumerate(STAGES):
        seg = next((s for s in reversed(segs) if s["idx"] == i), None)   # a resumed run appends fresh markers
        if seg is None:
            st = "pending"
        elif failed_stage and failed_stage.split("-")[0] == sname:
            st = "failed"
        elif "skipping" in seg["body"]:
            st = "skipped"
        elif i == 5:
            st = "done" if (d / "PLAN_DONE").exists() else "failed" if (d / "PLAN_FAILED").exists() else "running" if plan_running else "interrupted"
        elif i < latest:
            st = "done"
        else:  # latest segment
            st = "running" if running else "done" if done else "failed" if failed_stage else "interrupted"
        sub = [l[4:].strip() for l in seg["body"].splitlines() if l.startswith("==> ")] if seg else []
        stages.append({"idx": i, "name": sname, "status": st, "time": seg["time"] if seg else None,
                       "elapsed_min": seg["elapsed_min"] if seg else None,
                       "substep": sub[-1] if sub else None, "summary": stage_summary(i, seg["body"]) if seg else {}})
    # durations: next stage start - this start
    for i, s in enumerate(stages):
        mine = next((k for k in range(len(segs) - 1, -1, -1) if segs[k]["idx"] == i), None)
        nxt = segs[mine + 1] if mine is not None and mine + 1 < len(segs) else None
        if s["elapsed_min"] is not None and nxt is not None and nxt["elapsed_min"] >= s["elapsed_min"]:
            s["duration_min"] = nxt["elapsed_min"] - s["elapsed_min"]
    total = next((s["total_min"] for s in reversed(segs) if s["idx"] == 6), None)
    outputs = []
    for rel, label, is_dir in OUTPUTS:
        p = d / rel
        if p.exists():
            size = sum(f.stat().st_size for f in p.iterdir()) if is_dir else p.stat().st_size
            outputs.append({"path": rel, "label": label, "size": size, "is_dir": is_dir,
                            "count": len(list(p.iterdir())) if is_dir else None})
    video = re.search(r"^video: (.*)$", text, re.M)
    settings = re.search(r"^settings: (.*)$", text, re.M)
    transform = json.load(open(d / "transform.json")) if (d / "transform.json").exists() else None
    if transform:
        transform.pop("matrix", None)
    answers = json.load(open(d / "measure" / "answers.json")) if (d / "measure" / "answers.json").exists() else {}
    return {"name": name, "status": status, "failed_stage": failed_stage, "total_min": total,
            "prompts_available": (d / "measure" / "prompts.json").exists(), "answers": answers,
            "transform": transform, "plan_done": (d / "PLAN_DONE").exists(), "plan_running": plan_running,
            "started": time.strftime("%Y-%m-%d %H:%M", time.localtime(log.stat().st_mtime)) if log.exists() else None,
            "log_mtime": log.stat().st_mtime if log.exists() else None,
            "video": video[1] if video else None, "settings": settings[1] if settings else None,
            "stages": stages, "outputs": outputs}


@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC / "index.html").read_text()


@app.get("/api/videos")
def videos():
    DATA.mkdir(exist_ok=True)
    vids = [p for p in DATA.iterdir() if p.suffix.lower() in VIDEO_EXT]
    return [{"name": p.name, "size": p.stat().st_size, "mtime": p.stat().st_mtime}
            for p in sorted(vids, key=lambda p: -p.stat().st_mtime)]


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
    return {"name": dest.name, "size": dest.stat().st_size}


class RunRequest(BaseModel):
    video: str
    name: str
    fps: float = 2.0
    max_frames: int = 400
    res_level: int = 2
    features: str = "SIFT"       # SIFT | ALIKED
    matcher: str = "BRUTEFORCE"  # BRUTEFORCE | LIGHTGLUE
    matching: str = "vocab"      # vocab | sequential | exhaustive
    measures: int = 4


@app.post("/api/runs")
def start_run(req: RunRequest):
    video = DATA / Path(req.video).name
    if not video.exists():
        raise HTTPException(404, "video not found in data/")
    d = run_dir(req.name)
    if is_running(req.name, d):
        raise HTTPException(409, "that run is already running")
    d.mkdir(parents=True, exist_ok=True)
    if req.features not in ("SIFT", "ALIKED") or req.matcher not in ("BRUTEFORCE", "LIGHTGLUE") \
            or req.matching not in ("vocab", "sequential", "exhaustive"):
        raise HTTPException(400, "bad option")
    env = dict(os.environ, FPS=str(req.fps), MAXF=str(req.max_frames), RES_LEVEL=str(req.res_level),
               FEATURES=req.features, MATCHER=req.matcher, MATCHING=req.matching, MEASURES=str(req.measures))
    cmd = [str(ROOT / "run_all.sh"), str(video), req.name]
    if shutil.which("caffeinate"):
        cmd = ["caffeinate", "-i", "-s"] + cmd
    p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    procs[req.name] = p
    return {"name": req.name, "pid": p.pid}     # run_all.sh writes its own run.pid


@app.get("/api/runs")
def list_runs():
    WORK.mkdir(exist_ok=True)
    out = []
    for d in sorted(WORK.iterdir(), key=lambda p: -p.stat().st_mtime):
        if d.is_dir() and NAME_RE.match(d.name) and (d / "run_all.log").exists():
            det = run_detail(d.name)
            out.append({k: det[k] for k in ("name", "status", "started", "total_min", "video")}
                       | {"stages": [{"name": s["name"], "status": s["status"]} for s in det["stages"]]})
    return out


@app.get("/api/runs/{name}")
def get_run(name: str):
    return run_detail(name)


@app.get("/api/runs/{name}/log")
def get_log(name: str, stage: int | None = None, tail_kb: int = 256):
    d = run_dir(name)
    log = d / "run_all.log"
    if not log.exists():
        return {"text": "", "truncated": False}
    text = log.read_text(errors="replace")
    if stage is not None:
        seg = next((s for s in parse_segments(text) if s["idx"] == stage), None)
        text = seg["body"] if seg else ""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    truncated = len(text) > tail_kb * 1024
    if truncated:
        text = text[-tail_kb * 1024:]
        text = text[text.find("\n") + 1:]
    return {"text": text, "truncated": truncated}


@app.get("/api/runs/{name}/file/{path:path}")
def get_file(name: str, path: str):
    d = run_dir(name)
    p = (d / path).resolve()
    if d.resolve() not in p.parents or not p.is_file():
        raise HTTPException(404, "no such file")
    return FileResponse(p, filename=p.name)


@app.get("/api/runs/{name}/prompts")
def get_prompts(name: str):
    d = run_dir(name)
    p = d / "measure" / "prompts.json"
    if not p.exists():
        raise HTTPException(404, "no prompts yet (stage 4 not run)")
    data = json.load(open(p))
    a = d / "measure" / "answers.json"
    data["answers"] = json.load(open(a)) if a.exists() else {}
    return data


class Answer(BaseModel):
    prompt_id: str
    value: float | None = None       # metres, for distance prompts
    skipped: bool | None = None
    confirmed: bool | None = None    # ground prompt
    bearing: float | None = None     # north prompt, degrees


@app.post("/api/runs/{name}/answers")
def post_answer(name: str, ans: Answer):
    d = run_dir(name)
    a = d / "measure" / "answers.json"
    if not (d / "measure" / "prompts.json").exists():
        raise HTTPException(404, "no prompts")
    data = json.load(open(a)) if a.exists() else {}
    entry = {k: v for k, v in ans.model_dump().items() if k != "prompt_id" and v is not None}
    if not entry:
        data.pop(ans.prompt_id, None)
    else:
        data[ans.prompt_id] = entry
    a.write_text(json.dumps(data, indent=1))
    return {"ok": True, "answers": data}


@app.post("/api/runs/{name}/plan")
def start_plan(name: str):
    d = run_dir(name)
    if is_running(name, d) or is_running(name + ":plan", d, pidfile="plan.pid"):
        raise HTTPException(409, "a job is already running for this run")
    if not (d / "dense" / "scene_dense_mesh_texture.obj").exists():
        raise HTTPException(400, "no textured mesh yet")
    p = subprocess.Popen([str(ROOT / "scripts" / "make_plan.sh"), str(d)], cwd=ROOT, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    procs[name + ":plan"] = p
    (d / "plan.pid").write_text(str(p.pid))
    return {"ok": True, "pid": p.pid}


@app.post("/api/runs/{name}/cancel")
def cancel(name: str):
    d = run_dir(name)
    pid = None
    p = procs.get(name)
    if p is not None and p.poll() is None:
        pid = p.pid
    elif (d / "run.pid").exists():
        pid = int((d / "run.pid").read_text().strip() or 0)
    if not pid or not pid_alive(pid):
        raise HTTPException(409, "not running")
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    (d / "FAILED").write_text("cancelled")
    return {"ok": True}


@app.post("/api/runs/{name}/reveal")
def reveal(name: str):
    d = run_dir(name)
    subprocess.Popen(["open", str(d)])
    return {"ok": True}


@app.get("/api/health")
def health():
    return {"ok": True, "root": str(ROOT), "blender": os.path.exists("/Applications/Blender.app"),
            "openmvs": (ROOT / "tools/openmvs-install/bin/OpenMVS/DensifyPointCloud").exists(),
            "colmap": shutil.which("colmap") is not None}
