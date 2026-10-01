"""A small picture of what each stage produced, for the app's pipeline view: <run>/previews/<stage>.jpg.

Cheap by design (seconds), best-effort (a missing preview never fails a stage), and top-down where the data is spatial:
    sfm / register   the sparse cloud and the camera path, seen from above (the cameras' plane is the ground)
    dense            a sub-sample of the dense cloud, coloured, same view
    landmarks        the levelled preview plan
    solve            the measurements and how well they agree (residual bars)
    ortho            the orthomosaic
    trace            the wall lines and the dimensioned boundary over the orthomosaic
    draw             the PDF sheet's first page
    preview          nothing: the app shows the USDZ itself
    frames           the recording's thumbnail

    python -m tricorder.previews <env> <run> [stage ...]     # (re)render for an existing run; no stages = all done ones
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

from .models import Recording, Run

MAX_W = 960


def _plt():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _save(fig, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(dst), dpi=100, facecolor="white", bbox_inches="tight", pad_inches=0.05)
    plt = _plt()
    plt.close(fig)


def _thumb(src: Path, dst: Path, width: int = MAX_W) -> bool:
    from .metrics import make_thumbnail
    return src.exists() and make_thumbnail(src, dst, width)


def _read_ply_xyz_rgb(path: Path, max_points: int):
    import open3d as o3d
    p = o3d.io.read_point_cloud(str(path))
    P = np.asarray(p.points)
    C = np.asarray(p.colors) if p.has_colors() else None
    if len(P) > max_points:
        idx = np.random.default_rng(0).choice(len(P), max_points, replace=False)
        P = P[idx]
        C = C[idx] if C is not None else None
    return P, C


def _camera_centres(run: Run):
    """Camera centres from dense/sparse/images.txt (COLMAP text: qw qx qy qz tx ty tz per image)."""
    f = run.dir / "dense" / "sparse" / "images.txt"
    if not f.exists():
        return np.zeros((0, 3))
    out = []
    lines = [l for l in open(f) if l.strip() and not l.startswith("#")]
    for line in lines[::2]:
        p = line.split()
        q = np.array([float(x) for x in p[1:5]])
        t = np.array([float(x) for x in p[5:8]])
        w, x, y, z = q
        R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        out.append(-R.T @ t)
    return np.array(out) if out else np.zeros((0, 3))


def _ground_frame(cams: np.ndarray):
    """A basis whose first two axes span the cameras' plane (a walked site: that plane is roughly the ground)."""
    if len(cams) < 3:
        return np.eye(3), np.zeros(3)
    c0 = cams.mean(axis=0)
    _, _, vt = np.linalg.svd(cams - c0, full_matrices=False)
    return vt, c0


def _topdown(run: Run, cloud: Path, dst: Path, max_points: int, title: str, highlight=None) -> bool:
    if not cloud.exists():
        return False
    P, C = _read_ply_xyz_rgb(cloud, max_points)
    cams = _camera_centres(run)
    B, c0 = _ground_frame(cams if len(cams) else P)
    Q = (P - c0) @ B.T
    lo, hi = np.percentile(Q[:, :2], 2, axis=0), np.percentile(Q[:, :2], 98, axis=0)
    keep = np.all((Q[:, :2] >= lo - 0.1 * (hi - lo)) & (Q[:, :2] <= hi + 0.1 * (hi - lo)), axis=1)
    Q, C = Q[keep], (C[keep] if C is not None else None)
    plt = _plt()
    fig = plt.figure(figsize=(9.6, 6.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.scatter(Q[:, 0], Q[:, 1], s=0.3, c=C if C is not None else "#555", marker=".", linewidths=0, rasterized=True)
    if len(cams):
        K = (cams - c0) @ B.T
        ax.plot(K[:, 0], K[:, 1], "-", color="#d97757", linewidth=1.0, alpha=0.9)
        if highlight is not None and len(highlight):
            H = (highlight - c0) @ B.T
            ax.scatter(H[:, 0], H[:, 1], s=6, c="#d97757", zorder=5)
    ax.set_aspect("equal"); ax.axis("off")
    ax.text(0.01, 0.01, title, transform=ax.transAxes, fontsize=9, color="#444", ha="left", va="bottom")
    _save(fig, dst)
    return True


def preview_sfm(run: Run, dst: Path) -> bool:
    n = run.stages["sfm" if "sfm" in run.stages else "register"].metrics.get("registered")
    return _topdown(run, run.dir / "sparse_points.ply", dst, 400_000, f"sparse cloud · {n or '?'} cameras")


def preview_register(run: Run, dst: Path) -> bool:
    m = run.stages["register"].metrics
    return _topdown(run, run.dir / "sparse_points.ply", dst, 400_000,
                    f"extended sparse cloud · {m.get('registered', '?')} cameras, {m.get('new_registered', '?')} new")


def preview_dense(run: Run, dst: Path) -> bool:
    return _topdown(run, run.dir / "dense" / "scene_dense.ply", dst, 350_000, "dense cloud, from above")


def preview_landmarks(run: Run, dst: Path) -> bool:
    return _thumb(run.dir / "preview_plan_grid.png", dst)


def preview_solve(run: Run, dst: Path) -> bool:
    t = run.dir / "transform.json"
    if not t.exists():
        return False
    j = json.load(open(t))
    res = j.get("residuals", [])
    plt = _plt()
    fig = plt.figure(figsize=(6.4, 3.2))
    ax = fig.add_axes([0.28, 0.14, 0.68, 0.78])
    if res:
        ids = [r["id"] for r in res]
        vals = [r["residual_cm"] for r in res]
        cols = ["#b9452c" if abs(v) > 5 else "#4f7f5a" for v in vals]
        ax.barh(range(len(res)), vals, color=cols)
        ax.set_yticks(range(len(res))); ax.set_yticklabels([f"{i} · {r['meters']:.2f} m" for i, r in zip(ids, res)], fontsize=8)
        ax.axvline(0, color="#999", linewidth=0.8)
        ax.set_xlabel("residual vs mean scale (cm)", fontsize=8)
        ax.tick_params(axis="x", labelsize=8)
        ax.invert_yaxis()
        ax.set_title(f"scale {j.get('scale', 0):.4f} m/unit · spread {j.get('spread_pct', 0):.1f} %", fontsize=9)
    else:
        ax.axis("off")
        ax.text(0.5, 0.5, f"scale {j.get('scale', 0):.4f} m/unit\n" + ("estimated from the camera height (±10 %)" if j.get("estimated") else "no measurements"),
                ha="center", va="center", fontsize=10, color="#444")
    _save(fig, dst)
    return True


def preview_ortho(run: Run, dst: Path) -> bool:
    return _thumb(run.dir / "orthomosaic.png", dst)


def preview_trace(run: Run, dst: Path) -> bool:
    lw, oj, png = run.dir / "linework.json", run.dir / "orthomosaic.json", run.dir / "orthomosaic.png"
    if not (lw.exists() and oj.exists()):
        return False
    L, o = json.load(open(lw)), json.load(open(oj))
    x0, y1, w, h = o["x_min"], o["y_max"], o["width_m"], o["height_m"]
    plt = _plt()
    fig = plt.figure(figsize=(9.6, 9.6 * h / max(w, 1e-6)))
    ax = fig.add_axes([0, 0, 1, 1])
    if png.exists():
        im = plt.imread(str(png))
        ax.imshow(im, extent=(x0, x0 + w, y1 - h, y1), alpha=0.35, interpolation="bilinear")
    for s in L.get("walls", []):
        ax.plot([s[0][0], s[1][0]], [s[0][1], s[1][1]], color="#d97757", linewidth=1.6)
    for k, poly in enumerate(L.get("polygons", [])):
        pts = np.array(poly["points"] + poly["points"][:1])
        ax.plot(pts[:, 0], pts[:, 1], color="#222", linewidth=2.6 if k == 0 else 1.2)
        if k == 0:
            n = len(poly["points"])
            for i in range(n):
                a, b = np.array(poly["points"][i]), np.array(poly["points"][(i + 1) % n])
                if poly["lengths"][i] < 1.0:
                    continue
                m = (a + b) / 2
                ax.text(m[0], m[1], f"{poly['lengths'][i]:.2f}", fontsize=7, ha="center", va="center", color="#222",
                        bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))
    ax.set_xlim(x0, x0 + w); ax.set_ylim(y1 - h, y1); ax.set_aspect("equal"); ax.axis("off")
    _save(fig, dst)
    return True


def preview_draw(run: Run, dst: Path) -> bool:
    return _thumb(run.dir / "site_plan_page1.png", dst, 1200)


RENDERERS = {"sfm": preview_sfm, "register": preview_register, "dense": preview_dense, "landmarks": preview_landmarks,
             "solve": preview_solve, "ortho": preview_ortho, "trace": preview_trace, "draw": preview_draw}


def render_stage(run: Run, stage: str) -> str | None:
    """Render the preview for a finished stage; returns its path relative to the run dir, or None."""
    fn = RENDERERS.get(stage)
    if fn is None:
        return None
    rel = f"previews/{stage}.jpg"
    try:
        return rel if fn(run, run.dir / rel) else None
    except Exception as e:                       # a preview is a nicety
        print(f"preview for {stage} skipped: {e}", file=sys.stderr)
        return None


def render_frames(rec: Recording) -> str | None:
    return rec.thumbnail


def main(argv=None) -> int:
    a = argv if argv is not None else sys.argv[1:]
    if len(a) < 2:
        print(__doc__)
        return 2
    from .pipeline import STAGE_OUTPUTS, _outputs
    run = Run.load(a[0], a[1])
    stages = a[2:] or [s for s, st in run.stages.items() if st.status == "done"]
    for s in stages:
        rel = render_stage(run, s)
        if rel:
            run.stages[s].preview = rel
        run.stages[s].outputs = _outputs(run.dir, STAGE_OUTPUTS.get(s, []))
        print(f"{s:10s} {rel or '-':24s} {len(run.stages[s].outputs)} outputs")
    run.save()
    return 0


if __name__ == "__main__":
    sys.exit(main())
