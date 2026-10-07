"""Environment / recording / run / asset data model, stored as JSON manifests under work/environments/.

work/environments/<env>/environment.json                 one site: name, notes
work/environments/<env>/recordings/<rec>/recording.json  raw data: a filmed walk (the video, its metadata, frame extraction, notes)
work/environments/<env>/recordings/<rec>/images/         frames extracted from the video (derived; shared by every run)
work/environments/<env>/runs/<run>/run.json              one processing job: kind, inputs, settings, stages, output asset
work/environments/<env>/runs/<run>/logs/<stage>.log
work/environments/<env>/runs/<run>/                      working files (database.db, sparse/, dense/, measure/, ...)
work/environments/<env>/assets/<asset>/asset.json        a deliverable made by a run (3D model, site plan); its files live next to it

A run consumes recordings and/or earlier assets through its kind's input *slots* and publishes exactly one asset.
Assets are immutable: running again publishes a new asset and the earlier ones stay as history.
Runs can be chained: a run whose input names another run's output ("@r5") waits for that run and is launched by it.
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

# A run kind is a recipe: input slots (what it consumes, by recording / asset kind), stages, one output asset kind.
# Slot keys are the keys of Run.inputs: a single-valued slot holds an id, a multi-valued one a list of ids.
RUN_KINDS: dict[str, dict[str, Any]] = {
    "scan": {"label": "Environment scan", "output": "model3d", "stages": ["sfm", "dense", "landmarks", "preview"],
             "slots": [{"key": "recording", "label": "Video", "accepts": ["video"], "min": 1, "max": 1}],
             "blurb": "A filmed walk becomes a textured 3D model: COLMAP poses, OpenMVS dense cloud, mesh, texture."},
    "extend": {"label": "Extend scan", "output": "model3d", "stages": ["register", "dense", "landmarks", "preview"],
               "slots": [{"key": "asset", "label": "3D model", "accepts": ["model3d"], "min": 1, "max": 1},
                         {"key": "recordings", "label": "New footage", "accepts": ["video", "photos"], "min": 1, "max": 8}],
               "blurb": "New videos or photos are registered into an existing model's cameras; everything is re-optimised and re-meshed."},
    "identify": {"label": "Identify", "output": "marks", "stages": ["segment", "name", "lift", "entities", "review", "preview"],
                 "slots": [{"key": "asset", "label": "3D model", "accepts": ["model3d"], "min": 1, "max": 1},
                           {"key": "prior", "label": "Prior inventory", "accepts": ["marks"], "min": 0, "max": 1}],
                 "blurb": "What is where: every region of the frames is segmented, named by a vision-language model, lifted onto the "
                          "mesh and clustered into named entities with footprints. Publishes a generated marks recording (the inventory); "
                          "given a prior inventory it re-lifts its masks instead of naming again."},
    "layout": {"label": "Layout", "output": "site_plan", "stages": ["solve", "ortho", "trace", "annotate", "draw", "preview"],
               "slots": [{"key": "asset", "label": "3D model", "accepts": ["model3d"], "min": 1, "max": 1},
                         {"key": "recordings", "label": "Measurements", "accepts": ["measurements"], "min": 0, "max": 8},
                         {"key": "marks", "label": "Marks", "accepts": ["marks"], "min": 0, "max": 12}],
               "blurb": "A 3D model plus tape measurements becomes a site plan: true scale, orthomosaic, wall lines, DXF and PDF. "
                        "Marks (yours and the generated inventory) put every named element on the plan with areas, lengths and counts."},
    "edit": {"label": "Edit", "output": "model3d", "stages": ["select", "cut", "complete", "preview"],
             "slots": [{"key": "asset", "label": "3D model", "accepts": ["model3d"], "min": 1, "max": 1},
                       {"key": "marks", "label": "Marks", "accepts": ["marks"], "min": 1, "max": 12}],
             "blurb": "Remove marked entities or regions from the model and complete the ground where they stood; patch marked holes. "
                      "Publishes a new 3D model in the same frame, so measurements and marks still apply."},
}
# A run's output is an asset kind, except identify, which publishes a recording (a generated marks recording).
RUN_OUTPUT_IS_RECORDING = {"identify"}
# Chains the app offers as one recipe: each step is a run; a later step's slots take the earlier runs' outputs ("@r5").
CHAINS: dict[str, dict[str, Any]] = {
    "survey": {"label": "Site plan from video", "runs": ["scan", "identify", "layout"],
               "blurb": "Scan, identify what is where, then lay out, in one go. Add measurements now for true scale or later for a re-solve."},
    "cleanup": {"label": "Clean up", "runs": ["edit", "identify", "layout"],
                "blurb": "Remove what you marked, carry the inventory onto the new model, lay it out again."},
}
ASSET_KINDS = {"model3d": "3D Model", "site_plan": "Site Plan"}
RECORDING_KINDS = {"video": "Video", "photos": "Photos", "measurements": "Measurements", "marks": "Marks"}
STAGE_LABELS = {"frames": "Frames", "sfm": "COLMAP", "register": "Register", "dense": "OpenMVS", "landmarks": "Landmarks",
                "preview": "Preview", "solve": "Scale & level", "ortho": "Orthomosaic", "trace": "Linework", "annotate": "Elements",
                "draw": "Drawing", "segment": "Segment", "name": "Name", "lift": "Lift", "entities": "Entities", "review": "Review",
                "select": "Select", "cut": "Cut", "complete": "Complete"}
# Element and edit classes a mark can carry (the app's picker and the layout's layers).
MARK_CLASSES = {"element": ["wall", "fence", "window", "door", "stairs", "area", "tree", "object"], "edit": ["remove", "patch"]}
MATERIALS = ["grass", "brick", "concrete", "sand", "gravel", "deck", "garden", "soil", "tiles", "stone", "asphalt", "other"]
IMAGE_EXT = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".dng", ".tif", ".tiff"}

# measure/constraints.json in a layout run (written by scripts/measure_project.py from the measurement recordings,
# read by scripts/solve_scale.py):
#   {"distances": [{"id", "source": "snapshot" | "mesh", "recording", "frame", "a": [x,y,z], "b": [x,y,z], "meters", "note", "at"}],
#    "north": {"source", "frame", "forward": [x,y,z], "bearing"} | null, "up": [x,y,z], "cameras": [[x,y,z], ...]}
# Points are in the model's own coordinate frame.
#
# A marks recording (kind "marks"): items drawn on one 3D model in the app's mesh editor, points in that model's frame:
#   source: {"model": "model3d-1", "frame": "model3d-1"}
#   items: [{id, role: "element" | "edit", cls, shape: "point" | "line" | "polygon", points: [[x,y,z], ...], name, note,
#            material, text, entity: "e12" | null, source: "human" | "accepted" | "generated", at}]
# The inventory an identify run publishes is a *generated* marks recording: source adds {"generated_by": "r6", "generated": true,
# "metrics": {...}}, every entity is an item (role element, entity = its id, source "generated", plus confidence, description,
# area_m2, height_m), and the recording dir holds entities.json, faces.npy, labels.json, segments/, lift/, review/, inventory_map.png.
# A `patch` edit mark with shape "point" means "fill the hole around this point".
# A measurement item may be two mesh points instead of two pixels:
#   {id, source: "mesh", model: "model3d-1", a3d: [x,y,z], b3d: [x,y,z], meters, note, at}


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
    outputs: list[dict[str, Any]] = field(default_factory=list)   # files this stage left behind: {path, label, size}
    preview: str | None = None       # a small picture of the stage's result, relative to the owning directory

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
    kind: str = "video"                          # video | photos | measurements | marks
    source: dict[str, Any] = field(default_factory=dict)   # video: path (relative to ROOT), size, duration_s, width, height, fps, hdr ...
                                                 # photos: path (the photos/ folder, relative to ROOT), count, size, originals
                                                 # marks: model (the 3D model the marks were drawn on), frame (its coordinate frame)
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
    wall_jump_m: float = 0.5         # linework: how tall a vertical surface must be to count as a wall or fence
    edge_jump_m: float = 0.08        # (reserved) height step that counts as an edge or curb
    min_edge_m: float = 1.2          # linework: boundary jogs shorter than this are absorbed
    sheet_scale: int = 100           # wanted PDF sheet scale 1:N
    preview_faces: int = 300_000     # decimation target for the in-app 3D preview
    boundary: str = "walls"          # layout: the boundary the plan draws: "walls" (perimeter walls chained, footprint where no wall) | "footprint"
    # identify
    vlm: str = "qwen-local"          # qwen-local (Qwen2.5-VL through MLX) | claude (hosted, ANTHROPIC_API_KEY) | none (classes from votes only)
    sam: str = "facebook/sam-vit-base"   # the segmenter checkpoint
    every: int = 10                  # identify: every n-th registered frame
    frames_cap: int = 60             # identify: at most this many frames
    review: int = 1                  # identify: re-project each entity into its best frame and ask the model to confirm

    def env(self) -> dict[str, str]:
        return {"RES_LEVEL": str(self.res_level), "FEATURES": self.features, "MATCHER": self.matcher,
                "MATCHING": self.matching, "RELAXED": str(self.relaxed), "MEASURES": str(self.measures),
                "MAX_FACES": str(self.max_faces)}


@dataclass
class Run:
    id: str
    env_id: str
    kind: str                                    # scan | extend | identify | layout | edit
    inputs: dict[str, Any]                       # by slot key: scan {"recording": "rec1"}; extend / layout {"asset": "model3d-1", "recordings": [...]}
                                                 # "@r5" as an asset id (in any asset slot) means "the asset run r5 publishes" (a chained run)
    created_at: str
    settings: RunSettings = field(default_factory=RunSettings)
    status: str = "queued"                       # queued | running | done | failed | cancelled | interrupted
    pid: int | None = None
    started_at: str | None = None
    finished_at: str | None = None
    stages: dict[str, Stage] = field(default_factory=dict)
    output_asset: str | None = None
    label: str = ""
    after: str | None = None                     # the run this one waits for (chained); launched when it finishes

    def __post_init__(self) -> None:
        for s in RUN_KINDS[self.kind]["stages"]:
            self.stages.setdefault(s, Stage())

    @property
    def dir(self) -> Path:
        return ENVS / self.env_id / "runs" / self.id

    @property
    def stage_names(self) -> list[str]:
        return RUN_KINDS[self.kind]["stages"]

    def recording_ids(self) -> list[str]:
        """Every recording this run consumes, whichever slot holds it (chained "@run" references excluded)."""
        ids = []
        for slot in RUN_KINDS[self.kind]["slots"]:
            v = self.inputs.get(slot["key"])
            if slot["accepts"][0] in RECORDING_KINDS:
                ids += [x for x in ([v] if isinstance(v, str) else list(v or [])) if isinstance(x, str) and not x.startswith("@")]
        return ids

    @property
    def asset_id(self) -> str | None:
        return self.inputs.get("asset")

    def asset_slots(self) -> list[str]:
        """The keys of this run's slots that take assets."""
        return [slot["key"] for slot in RUN_KINDS[self.kind]["slots"] if slot["accepts"][0] in ASSET_KINDS]

    def pending_refs(self) -> list[tuple[str, int | None, str]]:
        """Slot values still naming another run's output ("@r5"): [(slot key, index in a list slot or None, run id)]."""
        out = []
        for slot in RUN_KINDS[self.kind]["slots"]:
            v = self.inputs.get(slot["key"])
            if isinstance(v, str) and v.startswith("@"):
                out.append((slot["key"], None, v[1:]))
            elif isinstance(v, list):
                for i, x in enumerate(v):
                    if isinstance(x, str) and x.startswith("@"):
                        out.append((slot["key"], i, x[1:]))
        return out

    def resolve_ref(self, run_id: str, output_id: str) -> bool:
        """Replace every "@run_id" in the inputs by the id of what that run published."""
        changed = False
        for key, idx, ref in self.pending_refs():
            if ref != run_id:
                continue
            if idx is None:
                self.inputs[key] = output_id
            else:
                self.inputs[key][idx] = output_id
            changed = True
        return changed

    @property
    def waits_for_all(self) -> list[str]:
        """Every run this one waits for: the runs its slots reference, plus an explicit `after`."""
        ids = list(dict.fromkeys(r for _, _, r in self.pending_refs()))
        if self.after and self.after not in ids:
            ids.append(self.after)
        return ids

    @property
    def waits_for(self) -> str | None:
        """The first run this one waits for, if any (chained runs)."""
        w = self.waits_for_all
        return w[0] if w else None

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
    derived_from: str | None = None              # model3d made by an extend or edit run: the model it grew out of
    sources: list[dict[str, Any]] = field(default_factory=list)   # model3d: the frames it was built from,
                                                 # [{"recording": "rec1", "prefix": ""}, {"recording": "rec4", "prefix": "rec4/"}]
    frame: str | None = None                     # the model whose coordinate frame this asset shares (a scan or extend
                                                 # defines a new frame: itself; an edit keeps its parent's; an inventory
                                                 # or a site plan: the model it was made on)
    removed_entities: list[str] = field(default_factory=list)   # model3d from an edit: inventory entity ids it removed

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
