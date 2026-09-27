#!/usr/bin/env python3
"""Turn measurement recordings (two pixels on a frame + the metres you taped) into 3D constraints for one model.

    python scripts/measure_project.py <run_dir> --model <model3d asset dir> --recordings <rec dir> [<rec dir> ...]

For each item the two pixels are undistorted with the frame's camera (pycolmap, the original OPENCV model the scan
used), cast as rays from that frame's pose, and intersected with the model's mesh; the hits are the constraint's
endpoints in the model's own frame. Items whose frame the model never registered, or whose ray misses the mesh, are
reported and skipped. Also records the cameras' "up" and their centres (for the camera-height scale estimate).

Writes <run_dir>/measure/constraints.json (see tricorder/models.py) with source "snapshot".
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def load_mesh_scene(model: Path):
    import open3d as o3d
    for name in ("dense/scene_dense_mesh_clean.ply", "dense/scene_dense_mesh.ply", "dense/scene_dense_mesh_texture.obj"):
        p = model / name
        if p.exists():
            mesh = o3d.io.read_triangle_mesh(str(p))
            if len(mesh.triangles):
                scene = o3d.t.geometry.RaycastingScene()
                scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh))
                return scene, name
    sys.exit(f"no mesh under {model}/dense")


def pose(im):
    cfw = im.cam_from_world() if callable(im.cam_from_world) else im.cam_from_world
    R = np.asarray(cfw.rotation.matrix())
    return R, np.asarray(im.projection_center())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--recordings", nargs="*", default=[])
    a = ap.parse_args()
    import open3d as o3d
    import pycolmap

    run, model = Path(a.run), Path(a.model)
    sparse = model / "sparse" / "0"
    if not sparse.exists():
        sys.exit(f"{sparse} missing: the model asset has no original camera poses (re-run its scan to publish them)")
    rec = pycolmap.Reconstruction(str(sparse))
    by_name = {im.name: im for im in rec.images.values()}
    scene, mesh_name = load_mesh_scene(model)

    ups, centres = [], []
    for im in rec.images.values():
        R, C = pose(im)
        ups.append(R.T @ np.array([0.0, -1.0, 0.0]))      # camera y points down; -y is "up" in the phone
        centres.append(C)
    up = np.mean(ups, axis=0); up /= np.linalg.norm(up)

    out = {"distances": [], "skipped_prompts": [], "level": None, "north": None, "up": up.tolist(),
           "cameras": np.round(np.array(centres), 4).tolist(), "skipped": [], "mesh": mesh_name}

    def hit(im, uv):
        cam = rec.cameras[im.camera_id]
        d_cam = np.asarray(cam.cam_ray_from_img(np.array(uv, dtype=float)))
        R, C = pose(im)
        d = R.T @ d_cam
        d /= np.linalg.norm(d)
        rays = o3d.core.Tensor([[*C, *d]], dtype=o3d.core.Dtype.Float32)
        t = scene.cast_rays(rays)["t_hit"][0].item()
        if not np.isfinite(t):
            return None
        return (C + t * d).tolist()

    for rdir in a.recordings:
        rj = Path(rdir) / "recording.json"
        r = json.load(open(rj))
        rid = r.get("id", Path(rdir).name)
        for item in r.get("items", []):
            frame = item.get("frame", "")
            im = by_name.get(frame)
            if im is None:
                out["skipped"].append({"recording": rid, "item": item.get("id"), "reason": f"frame {frame} is not registered in this model"})
                continue
            pa, pb = hit(im, item["a"]), hit(im, item["b"])
            if pa is None or pb is None:
                out["skipped"].append({"recording": rid, "item": item.get("id"), "reason": "a point does not land on the mesh"})
                continue
            out["distances"].append({"id": f"{rid}/{item.get('id', len(out['distances']) + 1)}", "source": "snapshot", "recording": rid,
                                     "frame": frame, "a": pa, "b": pb, "meters": float(item["meters"]), "note": item.get("note", ""),
                                     "at": item.get("at")})
        n = r.get("north")
        if n and n.get("bearing") is not None and out["north"] is None:
            im = by_name.get(n.get("frame", ""))
            if im is not None:
                R, _ = pose(im)
                out["north"] = {"source": "snapshot", "recording": rid, "frame": n["frame"], "forward": (R.T @ np.array([0.0, 0.0, 1.0])).tolist(),
                                "bearing": float(n["bearing"])}
    (run / "measure").mkdir(parents=True, exist_ok=True)
    json.dump(out, open(run / "measure" / "constraints.json", "w"), indent=1)
    for d in out["distances"]:
        print(f"  {d['id']:14s} {d['frame']}  {d['meters']:.2f} m  = {np.linalg.norm(np.array(d['a']) - np.array(d['b'])):.3f} model units")
    for s in out["skipped"]:
        print(f"  skipped {s['recording']}/{s['item']}: {s['reason']}")
    print(f"{len(out['distances'])} constraint(s) from {len(a.recordings)} measurement recording(s); mesh {mesh_name}; "
          f"north {'set' if out['north'] else 'not set'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
