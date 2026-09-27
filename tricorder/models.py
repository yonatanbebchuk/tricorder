"""Environment / recording / run / asset data model, stored as JSON manifests under work/environments/.

work/environments/<env>/environment.json                 one site: name, notes
work/environments/<env>/recordings/<rec>/recording.json  raw data: a filmed walk (the video, its metadata, frame extraction, notes)
work/environments/<env>/recordings/<rec>/images/         frames extracted from the video (derived; shared by every run)
work/environments/<env>/runs/<run>/run.json              one processing job: kind, inputs, settings, stages, output asset
work/environments/<env>/runs/<run>/logs/<stage>.log
work/environments/<env>/runs/<run>/                      working files (database.db, sparse/, dense/, measure/, ...)
work/environments/<env>/assets/<asset>/asset.json        a deliverable made by a run (3D scan, site plan); its files live next to it

A run consumes either a recording (scan) or an earlier asset (layout) and publishes exactly one asset.
Assets are immutable: running again publishes a new asset and the earlier ones stay as history.
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
ENVS = ROOT / "work" / "environments"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".mkv", ".avi"}

RUN_KINDS: dict[str, dict[str, Any]] = {
    "scan": {"label": "Environment scan", "input": "recording", "output": "model3d",
             "stages": ["sfm", "dense", "landmarks", "preview"]},
    "layout": {"label": "Layout", "input": "model3d", "output": "site_plan", "stages": ["solve", "ortho", "draw", "preview"]},
}
ASSET_KINDS = {"model3d": "3D Model", "site_plan": "Site Plan"}
STAGE_LABELS = {"frames": "Frames", "sfm": "COLMAP", "dense": "OpenMVS", "landmarks": "Landmarks", "preview": "Preview",
                "solve": "Scale & level", "ortho": "Orthomosaic", "draw": "Drawing"}

# measure/constraints.json in a layout run (written by scripts/measure_project.py from the measurement recordings,
# read by scripts/solve_scale.py):
#   {"distances": [{"id", "source": "snapshot", "recording", "frame", "a": [x,y,z], "b": [x,y,z], "meters", "note", "at"}],
#    "north": {"source", "frame", "forward": [x,y,z], "bearing"} | null, "up": [x,y,z], "cameras": [[x,y,z], ...]}
# Points are in the model's own coordinate frame.


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return (s or "environment")[:48]


def unique_id(base: str, parent: Path) -> str:
    cand, n = base, 2
    while (parent / cand).exists():
        cand, n = f"{base}-{n}", n + 1
    return cand


def next_id(parent: Path, prefix: str) -> str:
    """rec1, rec2 … / r1, r2 … / model3d-1 …: the first unused number under parent."""
    n = 1
    while (parent / f"{prefix}{n}").exists():
        n += 1
    return f"{prefix}{n}"


def save_json(path: Path, d: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(d, indent=1))
    os.replace(tmp, path)


def _check_ids(*ids: str) -> None:
    for i in ids:
        if not ID_RE.match(i):
            raise KeyError(i)


# ---------------------------------------------------------------- stages

@dataclass
class Stage:
    status: str = "pending"          # pending | running | done | failed | cancelled | skipped | interrupted
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

    @classmethod
    def from_json(cls, d: dict | None) -> "Stage":
        d = dict(d or {})
        d.pop("duration_s", None)
        return cls(**d)

    def to_json(self) -> dict:
        d = asdict(self)
        d["duration_s"] = self.duration_s
        return d


# ---------------------------------------------------------------- environment

@dataclass
class Environment:
    id: str
    name: str
    created_at: str
    notes: str = ""

    @property
    def dir(self) -> Path:
        return ENVS / self.id

    def save(self) -> None:
        save_json(self.dir / "environment.json", asdict(self))

    @classmethod
    def load(cls, env_id: str) -> "Environment":
        _check_ids(env_id)
        p = ENVS / env_id / "environment.json"
        if not p.exists():
            raise KeyError(env_id)
        return cls(**json.loads(p.read_text()))

    def _ids(self, sub: str, manifest: str, key) -> list[str]:
        d = self.dir / sub
        if not d.exists():
            return []
        return sorted((p.name for p in d.iterdir() if (p / manifest).exists()), key=key)

    def recording_ids(self) -> list[str]:
        return self._ids("recordings", "recording.json", _num_key("rec"))

    def run_ids(self) -> list[str]:
        return self._ids("runs", "run.json", _num_key("r"))

    def asset_ids(self) -> list[str]:
        return self._ids("assets", "asset.json", lambda a: (a.rsplit("-", 1)[0], int(a.rsplit("-", 1)[1]) if a.rsplit("-", 1)[-1].isdigit() else 0))

    def to_json(self) -> dict:
        d = asdict(self)
        d["dir"] = str(self.dir)
        return d


def _num_key(prefix: str):
    def key(s: str):
        rest = s[len(prefix):]
        return int(rest) if rest.isdigit() else 0
    return key


def list_environments() -> list[Environment]:
    ENVS.mkdir(parents=True, exist_ok=True)
    out = []
    for p in ENVS.iterdir():
        if (p / "environment.json").exists():
            try:
                out.append(Environment.load(p.name))
            except Exception:
                continue
    return sorted(out, key=lambda e: e.created_at, reverse=True)


# ---------------------------------------------------------------- recording

@dataclass
class FrameSettings:
    fps: float = 2.0
    max_frames: int = 400
    hdr: str = "auto"                # auto | none | hlg | pq


@dataclass
class Recording:
    id: str
    env_id: str
    name: str
    created_at: str
    kind: str = "video"                          # video | measurements (photos and designs later)
    source: dict[str, Any] = field(default_factory=dict)   # video: path (relative to ROOT), size, duration_s, width, height, fps, hdr ...
    frames: Stage = field(default_factory=Stage)
    frame_settings: FrameSettings = field(default_factory=FrameSettings)
    notes: str = ""
    thumbnail: str | None = None                 # relative to the recording dir
    # measurements: things you taped on site, each tied to a frame of a video recording of this environment
    #   items: [{id, recording, frame, a: [u, v], b: [u, v], meters, note, image_size: [w, h], at}]
    #   north: {recording, frame, bearing} | null      compass bearing of that frame's viewing direction
    items: list[dict[str, Any]] = field(default_factory=list)
    north: dict[str, Any] | None = None

    @property
    def dir(self) -> Path:
        return ENVS / self.env_id / "recordings" / self.id

    @property
    def video_path(self) -> Path:
        p = Path(self.source.get("path", ""))
        return p if p.is_absolute() else ROOT / p

    def save(self) -> None:
        d = asdict(self)
        d["frames"] = self.frames.to_json()
        save_json(self.dir / "recording.json", d)

    @classmethod
    def load(cls, env_id: str, rec_id: str) -> "Recording":
        _check_ids(env_id, rec_id)
        p = ENVS / env_id / "recordings" / rec_id / "recording.json"
        if not p.exists():
            raise KeyError(rec_id)
        d = json.loads(p.read_text())
        return cls(frames=Stage.from_json(d.pop("frames", None)), frame_settings=FrameSettings(**d.pop("frame_settings", {})), **d)

    def to_json(self) -> dict:
        d = asdict(self)
        d["frames"] = self.frames.to_json()
        d["dir"] = str(self.dir)
        return d


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
    px_per_m: int = 50               # orthomosaic resolution
    contour_m: float = 0.25          # contour interval
    sheet_scale: int = 100           # wanted PDF sheet scale 1:N
    preview_faces: int = 300_000     # decimation target for the in-app 3D preview

    def env(self) -> dict[str, str]:
        return {"RES_LEVEL": str(self.res_level), "FEATURES": self.features, "MATCHER": self.matcher,
                "MATCHING": self.matching, "RELAXED": str(self.relaxed), "MEASURES": str(self.measures),
                "MAX_FACES": str(self.max_faces)}


@dataclass
class Run:
    id: str
    env_id: str
    kind: str                                    # scan | layout
    inputs: dict[str, Any]                       # scan: {"recording": "rec1"}; layout: {"asset": "model3d-1", "recordings": ["rec2", ...]}
    created_at: str
    settings: RunSettings = field(default_factory=RunSettings)
    status: str = "queued"                       # queued | running | done | failed | cancelled | interrupted
    pid: int | None = None
    started_at: str | None = None
    finished_at: str | None = None
    stages: dict[str, Stage] = field(default_factory=dict)
    output_asset: str | None = None
    label: str = ""

    def __post_init__(self) -> None:
        for s in RUN_KINDS[self.kind]["stages"]:
            self.stages.setdefault(s, Stage())

    @property
    def dir(self) -> Path:
        return ENVS / self.env_id / "runs" / self.id

    @property
    def stage_names(self) -> list[str]:
        return RUN_KINDS[self.kind]["stages"]

    def save(self) -> None:
        d = asdict(self)
        d["stages"] = {k: v.to_json() for k, v in self.stages.items()}
        save_json(self.dir / "run.json", d)

    @classmethod
    def load(cls, env_id: str, run_id: str) -> "Run":
        _check_ids(env_id, run_id)
        p = ENVS / env_id / "runs" / run_id / "run.json"
        if not p.exists():
            raise KeyError(run_id)
        d = json.loads(p.read_text())
        stages = {k: Stage.from_json(v) for k, v in d.pop("stages", {}).items()}
        return cls(stages=stages, settings=RunSettings(**d.pop("settings", {})), **d)

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


# ---------------------------------------------------------------- asset

@dataclass
class Asset:
    id: str
    env_id: str
    kind: str                                    # model3d | site_plan
    name: str
    run_id: str
    created_at: str
    files: list[dict[str, Any]] = field(default_factory=list)   # {path, label, size}
    metrics: dict[str, Any] = field(default_factory=dict)
    notes: str = ""

    @property
    def dir(self) -> Path:
        return ENVS / self.env_id / "assets" / self.id

    def save(self) -> None:
        save_json(self.dir / "asset.json", asdict(self))

    @classmethod
    def load(cls, env_id: str, asset_id: str) -> "Asset":
        _check_ids(env_id, asset_id)
        p = ENVS / env_id / "assets" / asset_id / "asset.json"
        if not p.exists():
            raise KeyError(asset_id)
        return cls(**json.loads(p.read_text()))

    def to_json(self) -> dict:
        d = asdict(self)
        d["dir"] = str(self.dir)
        return d
