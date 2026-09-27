"""Migrate the old scan/run layout (work/scans/<scan>/runs/<r>) into environments, recordings, runs and assets.

    python -m tricorder.migrate

Each scan becomes an environment with one recording (the video, its frames); each run becomes a reconstruct run
whose finished landmarks publish a 3D-scan asset; a finished plan stage becomes a separate plan run + site-plan asset.
Directories are moved, deliverables are cloned (APFS: free). Leftovers of a scan folder end up in work/_migrated/.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

from . import pipeline
from .models import ASSET_KINDS, ENVS, ROOT, Asset, Environment, FrameSettings, Recording, Run, RunSettings, Stage, list_environments, now

SCANS = ROOT / "work" / "scans"
LEFTOVERS = ROOT / "work" / "_migrated"


def _move(src: Path, dst: Path) -> None:
    if src.exists() or src.is_symlink():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))


def migrate_scan(sdir: Path) -> None:
    scan = json.loads((sdir / "scan.json").read_text())
    env = Environment(id=sdir.name, name=scan.get("name", sdir.name), created_at=scan.get("created_at", now()), notes=scan.get("notes", ""))
    if env.dir.exists():
        print(f"skip {sdir.name}: environment exists")
        return
    env.save()

    # recording: video + frames
    rec = Recording(id="rec1", env_id=env.id, name=env.name, created_at=env.created_at,
                    frames=Stage.from_json(scan.get("frames")), frame_settings=FrameSettings(**scan.get("frame_settings", {})),
                    thumbnail=scan.get("thumbnail"))
    rec.dir.mkdir(parents=True)
    for name in ("images", "logs", "thumb.jpg"):
        _move(sdir / name, rec.dir / name)
    src_video = Path(scan["video"]["path"])
    src_video = src_video if src_video.is_absolute() else ROOT / src_video
    info = dict(scan["video"])
    if src_video.exists():
        local = rec.dir / f"video{src_video.suffix.lower()}"
        pipeline.clone(src_video, local)
        info["path"] = os.path.relpath(local, ROOT)
        info["original"] = str(src_video)
    rec.source = info
    rec.save()

    # runs
    for rdir in sorted((sdir / "runs").iterdir() if (sdir / "runs").exists() else []):
        if not (rdir / "run.json").exists():
            continue
        old = json.loads((rdir / "run.json").read_text())
        stages = {k: Stage.from_json(v) for k, v in old.get("stages", {}).items()}
        run = Run(id=rdir.name, env_id=env.id, kind="scan", inputs={"recording": rec.id}, created_at=old.get("created_at", now()),
                  settings=RunSettings(**{k: v for k, v in old.get("settings", {}).items() if k in RunSettings.__dataclass_fields__}),
                  status=old.get("status", "queued"), started_at=old.get("started_at"), finished_at=old.get("finished_at"),
                  stages={k: stages.get(k, Stage()) for k in ("sfm", "dense", "landmarks")}, label=old.get("label", ""))
        plan_stage = stages.get("plan", Stage())
        _move(rdir, run.dir)
        pipeline._link(run.dir / "images", f"../../recordings/{rec.id}/images")
        (run.dir / "run.json").unlink(missing_ok=True)
        run.save()
        if run.stages["landmarks"].status == "done":
            asset = pipeline.publish(run)
            asset.created_at = run.stages["landmarks"].finished_at or run.created_at    # history order, not migration time
            asset.save()
            print(f"  {env.id}/{run.id} -> {asset.id}")
            if plan_stage.status == "done" and (run.dir / "transform.json").exists():
                prun = pipeline.create_run(env, "layout", {"asset": asset.id}, run.settings, "migrated plan")
                for name in ("transform.json", "plan.png", "plan_grid.png", "plan.json", "plan.blend"):
                    _move(run.dir / name, prun.dir / name)
                _move(run.dir / "dense" / "scene_dense_metric.ply", prun.dir / "scene_dense_metric.ply")
                _move(run.dir / "logs" / "plan.log", prun.dir / "logs" / "solve.log")
                prun.stages["solve"] = plan_stage
                prun.status, prun.created_at = "done", plan_stage.finished_at or run.created_at
                prun.save()
                passet = pipeline.publish(prun)
                passet.created_at = prun.created_at
                passet.save()
                print(f"  {env.id}/{prun.id} -> {passet.id}")

    _move(sdir, LEFTOVERS / sdir.name)
    print(f"migrated {env.id}: recording {rec.id}, runs {env.run_ids()}, assets {env.asset_ids()}")


# ---------------------------------------------------------------- v2: 3D Model / Site Plan vocabulary, constraints.json

KIND_MAP = {"scan3d": "model3d", "plan2d": "site_plan"}
RUN_MAP = {"reconstruct": "scan", "plan": "layout"}


def answers_to_constraints(measure: Path) -> bool:
    """answers.json (keyed by prompt id) -> constraints.json (points carried along, source recorded)."""
    a, p, c = measure / "answers.json", measure / "prompts.json", measure / "constraints.json"
    if c.exists() or not a.exists() or not p.exists():
        return False
    answers, prompts = json.load(open(a)), json.load(open(p))
    by_id = {x["id"]: x for x in prompts["prompts"]}
    out = {"distances": [], "skipped_prompts": [], "level": None, "north": None}
    for pid, ans in answers.items():
        pr = by_id.get(pid)
        if not pr:
            continue
        if pr["type"] == "distance":
            if ans.get("skipped"):
                out["skipped_prompts"].append(pid)
            elif ans.get("value"):
                out["distances"].append({"id": f"m-{pid}", "source": "prompt", "prompt_id": pid, "a": pr["a"]["xyz"], "b": pr["b"]["xyz"],
                                         "meters": float(ans["value"]), "note": "", "at": ans.get("at")})
        elif pr["type"] == "ground" and ans.get("confirmed") is not None:
            out["level"] = {"source": "prompt", "confirmed": bool(ans["confirmed"]), "points": [pt["xyz"] for pt in pr["points"]]}
        elif pr["type"] == "north" and ans.get("bearing") is not None:
            out["north"] = {"source": "prompt", "frame": pr.get("frame"), "forward": pr.get("forward"), "bearing": float(ans["bearing"])}
    c.write_text(json.dumps(out, indent=1))
    a.rename(measure / "answers.legacy.json")
    return True


def rename_kinds() -> None:
    for env in list_environments():
        id_map: dict[str, str] = {}
        for aid in env.asset_ids():
            adir = env.dir / "assets" / aid
            d = json.loads((adir / "asset.json").read_text())
            new_kind = KIND_MAP.get(d.get("kind"))
            if new_kind:
                new_id = aid.replace(d["kind"], new_kind, 1)
                d["kind"], d["id"], d["name"] = new_kind, new_id, f"{ASSET_KINDS[new_kind]} · {d.get('run_id', '')}"
                shutil.move(str(adir), str(env.dir / "assets" / new_id))
                adir = env.dir / "assets" / new_id
                (adir / "asset.json").write_text(json.dumps(d, indent=1))
                id_map[aid] = new_id
                print(f"  {env.id}: asset {aid} -> {new_id}")
            if d["kind"] == "model3d" and answers_to_constraints(adir / "measure"):
                print(f"  {env.id}: {adir.name}/measure/answers.json -> constraints.json")
        for rid in env.run_ids():
            rdir = env.dir / "runs" / rid
            d = json.loads((rdir / "run.json").read_text())
            changed = False
            if d.get("kind") in RUN_MAP:
                d["kind"] = RUN_MAP[d["kind"]]; changed = True
            if d.get("output_asset") in id_map:
                d["output_asset"] = id_map[d["output_asset"]]; changed = True
            if d.get("inputs", {}).get("asset") in id_map:
                d["inputs"]["asset"] = id_map[d["inputs"]["asset"]]; changed = True
                for link in ("dense", "measure"):
                    pipeline._link(rdir / link, f"../../assets/{d['inputs']['asset']}/{link}")
            if "plan" in d.get("stages", {}):
                d["stages"]["solve"] = d["stages"].pop("plan"); changed = True
            if changed:
                (rdir / "run.json").write_text(json.dumps(d, indent=1))
                print(f"  {env.id}: run {rid} -> {d['kind']}")


def main() -> int:
    if SCANS.exists():
        for sdir in sorted(SCANS.iterdir()):
            if (sdir / "scan.json").exists():
                migrate_scan(sdir)
        if not any(SCANS.iterdir()):
            SCANS.rmdir()
    rename_kinds()
    return 0


if __name__ == "__main__":
    sys.exit(main())
