"""Scan / run data model, stored as JSON manifests under work/scans/.

work/scans/<scan_id>/scan.json              one video capture: video metadata, frame extraction, notes
work/scans/<scan_id>/images/                extracted frames (shared by every run of the scan)
work/scans/<scan_id>/thumb.jpg
work/scans/<scan_id>/runs/<run_id>/run.json  one pipeline execution: settings, stages, metrics, plan
work/scans/<scan_id>/runs/<run_id>/logs/<stage>.log
work/scans/<scan_id>/runs/<run_id>/{images -> ../../images, database.db, sparse/, dense/, measure/, ...}

Everything here is private, local data; work/ is git-ignored.
"""
from __future__ import annotations

import json
import os
import re
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SCANS = ROOT / "work" / "scans"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
RUN_STAGES = ["sfm", "dense", "landmarks", "plan"]      # "frames" lives on the scan
STAGE_LABELS = {"frames": "Frames", "sfm": "COLMAP", "dense": "OpenMVS", "landmarks": "Landmarks", "plan": "Plan"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".mkv", ".avi"}


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return (s or "scan")[:48]


def unique_id(base: str, parent: Path) -> str:
    cand, n = base, 2
    while (parent / cand).exists():
        cand, n = f"{base}-{n}", n + 1
    return cand


# ---------------------------------------------------------------- stages

@dataclass
class Stage:
    status: str = "pending"          # pending | running | done | failed | cancelled | skipped
    started_at: str | None = None
    finished_at: str | None = None
    metrics: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    log: str | None = None           # path relative to the owning directory

    @property
    def duration_s(self) -> float | None:
        if self.started_at and self.finished_at:
            return time.mktime(time.strptime(self.finished_at, "%Y-%m-%dT%H:%M:%S")) - \
                time.mktime(time.strptime(self.started_at, "%Y-%m-%dT%H:%M:%S"))
        return None

    def to_json(self) -> dict:
        d = asdict(self)
        d["duration_s"] = self.duration_s
        return d


# ---------------------------------------------------------------- scan

@dataclass
class FrameSettings:
    fps: float = 2.0
    max_frames: int = 400
    hdr: str = "auto"                # auto | none | hlg | pq


@dataclass
class Scan:
    id: str
    name: str
    created_at: str
    video: dict[str, Any]                       # path (relative to ROOT), size, duration_s, width, height, fps, color_transfer, hdr
    frames: Stage = field(default_factory=Stage)
    frame_settings: FrameSettings = field(default_factory=FrameSettings)
    notes: str = ""
    site: str | None = None
    thumbnail: str | None = None                # relative to scan dir

    @property
    def dir(self) -> Path:
        return SCANS / self.id

    def save(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        d = asdict(self)
        d["frames"] = self.frames.to_json()
        tmp = self.dir / "scan.json.tmp"
        tmp.write_text(json.dumps(d, indent=1))
        os.replace(tmp, self.dir / "scan.json")

    @classmethod
    def load(cls, scan_id: str) -> "Scan":
        if not ID_RE.match(scan_id):
            raise KeyError(scan_id)
        p = SCANS / scan_id / "scan.json"
        if not p.exists():
            raise KeyError(scan_id)
        d = json.loads(p.read_text())
        fr = d.pop("frames", {}); fr.pop("duration_s", None)
        fs = d.pop("frame_settings", {})
        return cls(frames=Stage(**fr), frame_settings=FrameSettings(**fs), **d)

    def run_ids(self) -> list[str]:
        rd = self.dir / "runs"
        if not rd.exists():
            return []
        return sorted((p.name for p in rd.iterdir() if (p / "run.json").exists()),
                      key=lambda r: int(r[1:]) if r[1:].isdigit() else 0)

    def to_json(self) -> dict:
        d = asdict(self)
        d["frames"] = self.frames.to_json()
        d["dir"] = str(self.dir)
        return d


def list_scans() -> list[Scan]:
    SCANS.mkdir(parents=True, exist_ok=True)
    out = []
    for p in SCANS.iterdir():
        if (p / "scan.json").exists():
            try:
                out.append(Scan.load(p.name))
            except Exception:
                continue
    return sorted(out, key=lambda s: s.created_at, reverse=True)


# ---------------------------------------------------------------- run

@dataclass
class RunSettings:
    res_level: int = 2
    features: str = "SIFT"           # SIFT | ALIKED
    matcher: str = "BRUTEFORCE"      # BRUTEFORCE | LIGHTGLUE
    matching: str = "vocab"          # vocab | sequential | exhaustive
    relaxed: int = 1
    measures: int = 4
    max_faces: int = 4_000_000

    def env(self) -> dict[str, str]:
        return {"RES_LEVEL": str(self.res_level), "FEATURES": self.features, "MATCHER": self.matcher,
                "MATCHING": self.matching, "RELAXED": str(self.relaxed), "MEASURES": str(self.measures),
                "MAX_FACES": str(self.max_faces)}


@dataclass
class Run:
    id: str
    scan_id: str
    created_at: str
    settings: RunSettings = field(default_factory=RunSettings)
    status: str = "queued"           # queued | running | done | failed | cancelled
    pid: int | None = None
    started_at: str | None = None
    finished_at: str | None = None
    stages: dict[str, Stage] = field(default_factory=lambda: {s: Stage() for s in RUN_STAGES})
    plan_versions: list[dict[str, Any]] = field(default_factory=list)
    label: str = ""

    @property
    def dir(self) -> Path:
        return SCANS / self.scan_id / "runs" / self.id

    def save(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        d = asdict(self)
        d["stages"] = {k: v.to_json() for k, v in self.stages.items()}
        tmp = self.dir / "run.json.tmp"
        tmp.write_text(json.dumps(d, indent=1))
        os.replace(tmp, self.dir / "run.json")

    @classmethod
    def load(cls, scan_id: str, run_id: str) -> "Run":
        if not ID_RE.match(scan_id) or not ID_RE.match(run_id):
            raise KeyError(run_id)
        p = SCANS / scan_id / "runs" / run_id / "run.json"
        if not p.exists():
            raise KeyError(run_id)
        d = json.loads(p.read_text())
        stages = {}
        for k, v in d.pop("stages", {}).items():
            v.pop("duration_s", None)
            stages[k] = Stage(**v)
        for k in RUN_STAGES:
            stages.setdefault(k, Stage())
        settings = RunSettings(**d.pop("settings", {}))
        return cls(stages=stages, settings=settings, **d)

    def is_alive(self) -> bool:
        if self.status != "running" or not self.pid:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def to_json(self) -> dict:
        d = asdict(self)
        d["stages"] = {k: v.to_json() for k, v in self.stages.items()}
        d["dir"] = str(self.dir)
        d["alive"] = self.is_alive()
        return d


ARTIFACTS = [
    ("sparse_points.ply", "Sparse point cloud (COLMAP)", "sfm"),
    ("dense/scene_dense.ply", "Dense point cloud", "dense"),
    ("dense/scene_dense_mesh.ply", "Mesh, raw", "dense"),
    ("dense/scene_dense_mesh_clean.ply", "Mesh, cleaned + decimated", "dense"),
    ("dense/scene_dense_mesh_texture.obj", "Textured mesh (OBJ + MTL + JPG)", "dense"),
    ("preview_plan_grid.png", "Preview plan, unscaled, 1 m grid", "landmarks"),
    ("preview_plan.blend", "Preview Blender scene", "landmarks"),
    ("measure/prompts.json", "Measurement prompts", "landmarks"),
    ("plan_grid.png", "Site plan, true scale, 1 m grid", "plan"),
    ("plan.png", "Site plan, true scale, plain", "plan"),
    ("plan.blend", "Blender scene at true scale", "plan"),
    ("dense/scene_dense_metric.ply", "Dense cloud in metres", "plan"),
    ("transform.json", "Scale / level / north + residuals", "plan"),
]


def artifacts(run: Run) -> list[dict]:
    out = []
    for rel, label, stage in ARTIFACTS:
        p = run.dir / rel
        if p.exists():
            out.append({"path": rel, "label": label, "stage": stage, "size": p.stat().st_size,
                        "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(p.stat().st_mtime))})
    return out
