"""Blender headless: cut the selected voxels out of the textured mesh, then close every hole in each item's region on the
actual hole boundary (the loop of boundary edges the cut left, or the loop around a "patch here" point), on a surface
fitted to that loop, with a patch material whose texture is cloned from the surrounding ground at the right scale.

    Blender --background --python scripts/21_edit_complete_blender.py -- --run <run_dir> --model <model3d asset>

Reads  <run>/edit/selection.json + voxels_*.npy; <model>/dense/scene_dense_mesh_texture.obj (+ .mtl, textures)
Writes <run>/dense/scene_dense_mesh_texture.obj/.mtl + copied textures + scene_dense_mesh_texture_patch_<n>_map_Kd.jpg (placeholders,
       the real crops are written by 22_edit_fill_cloud.py), <run>/dense/scene_dense_mesh_clean.ply (the same geometry),
       <run>/edit/complete.json {faces_before, faces_after, faces_removed, faces_added, items: [{id, faces_removed, loops, faces_added,
       texture, atlas, uv_center, tile_m, triangles: [[[x,y,z] x3] ...] (model frame, for the cloud fill)}]}
All geometry is rebuilt with numpy (no edit mode): a 4M-face mesh goes through in seconds.
"""
import argparse
import json
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--model", required=True)
args = ap.parse_args(argv)
run, model = Path(args.run), Path(args.model)
OFF = 1 << 20


def keys_of(cells):
    c = cells.astype(np.int64) + OFF
    return (c[:, 0] << 42) | (c[:, 1] << 21) | c[:, 2]


def point_in_polygon(xy, poly):
    x, y = xy[:, 0], xy[:, 1]
    inside = np.zeros(len(xy), dtype=bool)
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        crosses = (y0 > y) != (y1 > y)
        with np.errstate(divide="ignore", invalid="ignore"):
            xi = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
        inside ^= crosses & (x < xi)
    return inside


def polygon_area(xy):
    x, y = xy[:, 0], xy[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def boundary_vertices(F2, vert_ok):
    """Vertices on boundary edges (edges with one face), restricted to vert_ok."""
    e = np.concatenate([F2[:, [0, 1]], F2[:, [1, 2]], F2[:, [2, 0]]])
    e.sort(axis=1)
    e = e[vert_ok[e[:, 0]] & vert_ok[e[:, 1]]]
    if len(e) == 0:
        return np.zeros(0, dtype=np.int64)
    u, counts = np.unique(e, axis=0, return_counts=True)
    return np.unique(u[counts == 1].ravel())


def blob_outline(blob):
    """Edge cells of a blob (cells with a non-blob 4-neighbour) chained greedily into a closed ring: (row, col) list."""
    H, W = blob.shape
    pad = np.zeros((H + 2, W + 2), dtype=bool)
    pad[1:-1, 1:-1] = blob
    edge = pad & ~(pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:]) if False else None
    inner = pad[1:-1, 1:-1]
    nb = np.zeros_like(inner, dtype=int)
    nb += pad[:-2, 1:-1]; nb += pad[2:, 1:-1]; nb += pad[1:-1, :-2]; nb += pad[1:-1, 2:]
    cells = np.argwhere(inner & (nb < 4)).astype(float)
    if len(cells) < 3:
        return []
    left = np.ones(len(cells), dtype=bool)
    i = int(np.lexsort((cells[:, 1], cells[:, 0]))[0])
    order = [i]
    left[i] = False
    while left.any():
        d = np.linalg.norm(cells[left] - cells[order[-1]], axis=1)
        j = int(np.nonzero(left)[0][d.argmin()])
        if d.min() > 2.5:                                     # the chain broke: a thin neck; stop here
            break
        order.append(j)
        left[j] = False
    if len(order) < max(3, 0.6 * len(cells)):
        return []
    return [(int(cells[k, 0]), int(cells[k, 1])) for k in order]


def flood(mask_empty, seeds):
    """Cells of mask_empty reachable (8-connected) from the seed cells. Returns a boolean mask."""
    H, W = mask_empty.shape
    out = np.zeros_like(mask_empty)
    stack = [(int(r), int(c)) for r, c in seeds if 0 <= r < H and 0 <= c < W and mask_empty[r, c]]
    for r, c in stack:
        out[r, c] = True
    while stack:
        r, c = stack.pop()
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                rr, cc = r + dr, c + dc
                if 0 <= rr < H and 0 <= cc < W and mask_empty[rr, cc] and not out[rr, cc]:
                    out[rr, cc] = True
                    stack.append((rr, cc))
    return out


def hole_outlines(kept_xy, bbox_lo, bbox_hi, cell, seeds_xy, region=None):
    """Holes as polygons (levelled XY): empty cells of a raster over the bbox, flooded from the seed points (or every cell
    of the region polygon), traced as a contour. A flood that reaches the raster border is open country, not a hole:
    for a region item it is clipped to the region, for a point patch it is dropped."""
    W = int(np.ceil((bbox_hi[0] - bbox_lo[0]) / cell)) + 1
    H = int(np.ceil((bbox_hi[1] - bbox_lo[1]) / cell)) + 1
    occ = np.zeros((H, W), dtype=bool)
    if len(kept_xy):
        ij = np.floor((kept_xy - bbox_lo) / cell).astype(int)
        ok = (ij[:, 0] >= 0) & (ij[:, 0] < W) & (ij[:, 1] >= 0) & (ij[:, 1] < H)
        occ[ij[ok, 1], ij[ok, 0]] = True
    empty = ~occ
    if region is not None:
        gy, gx = np.mgrid[0:H, 0:W]
        centres = np.c_[gx.ravel() * cell + bbox_lo[0] + cell / 2, gy.ravel() * cell + bbox_lo[1] + cell / 2]
        inside = point_in_polygon(centres, region).reshape(H, W)
        seeds = np.argwhere(empty & inside)
    else:
        seeds = [((p[1] - bbox_lo[1]) / cell, (p[0] - bbox_lo[0]) / cell) for p in seeds_xy]
        seeds = [(int(r), int(c)) for r, c in seeds]
    filled = flood(empty, seeds)
    touches_border = filled[0, :].any() or filled[-1, :].any() or filled[:, 0].any() or filled[:, -1].any()
    if touches_border:
        if region is None:
            return [], "open to the outside"
        gy, gx = np.mgrid[0:H, 0:W]
        centres = np.c_[gx.ravel() * cell + bbox_lo[0] + cell / 2, gy.ravel() * cell + bbox_lo[1] + cell / 2]
        filled &= point_in_polygon(centres, region).reshape(H, W)
    polys = []
    remaining = filled.copy()
    for _ in range(12):
        if not remaining.any():
            break
        # one blob at a time: flood from the first remaining cell
        r0, c0 = np.argwhere(remaining)[0]
        blob = flood(remaining, [(r0, c0)])
        remaining &= ~blob
        if blob.sum() < 4:
            continue
        # a little dilation so the outline reaches the rim faces
        grown = blob.copy()
        grown[1:, :] |= blob[:-1, :]; grown[:-1, :] |= blob[1:, :]; grown[:, 1:] |= blob[:, :-1]; grown[:, :-1] |= blob[:, 1:]
        contour = blob_outline(grown)
        if len(contour) < 3:
            continue
        pts = np.array([[c * cell + bbox_lo[0] + cell / 2, r * cell + bbox_lo[1] + cell / 2] for r, c in contour])
        if len(pts) > 16:
            pts = pts[::2]
        polys.append(pts)
    return polys, f"{int(filled.sum())} empty cells"


def snap_rim(outline, bverts_xy, bverts_ids, cell):
    """The rim of a hole as existing boundary vertices: those within 1.5 cells of the outline, ordered along it.
    Falls back to the outline points themselves (as new vertices) where the rim is missing."""
    if len(bverts_ids) == 0:
        return [("new", p) for p in outline]
    # perimeter parameter of each outline vertex
    seg = np.linalg.norm(np.diff(np.vstack([outline, outline[:1]]), axis=0), axis=1)
    t_out = np.r_[0, np.cumsum(seg)[:-1]]
    total = seg.sum()
    # nearest outline segment for each boundary vertex
    d_all = np.linalg.norm(bverts_xy[:, None, :] - outline[None, :, :], axis=2)
    near = d_all.min(axis=1) < 1.5 * cell
    ring = []
    for i in np.nonzero(near)[0]:
        j = int(d_all[i].argmin())
        a, b = outline[j], outline[(j + 1) % len(outline)]
        ab = b - a
        u = float(np.clip(np.dot(bverts_xy[i] - a, ab) / max(np.dot(ab, ab), 1e-12), 0, 1))
        ring.append((t_out[j] + u * seg[j], ("old", int(bverts_ids[i]))))
    # outline points where no rim vertex is near (gaps in the mesh rim)
    for j, p in enumerate(outline):
        if not (near & (d_all.argmin(axis=1) == j)).any():
            ring.append((t_out[j], ("new", p)))
    ring.sort(key=lambda t: t[0])
    out = []
    for _, item in ring:                                      # drop a rim vertex listed twice in a row
        if out and item[0] == "old" and out[-1][0] == "old" and out[-1][1] == item[1]:
            continue
        out.append(item)
    return out


sel = json.load(open(run / "edit" / "selection.json"))
T = np.array(sel["levelled"])
Ti = np.linalg.inv(T)
vox = sel["voxel_units"]
s = sel["est_scale"]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=str(model / "dense" / "scene_dense_mesh_texture.obj"), forward_axis="Y", up_axis="Z")
objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not objs:
    sys.exit("nothing imported")
if len(objs) > 1:
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active or objs[0]
me = obj.data
M = np.array(obj.matrix_world)
nv, nf, nl = len(me.vertices), len(me.polygons), len(me.loops)
co = np.empty(nv * 3); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
co = (M @ np.c_[co, np.ones(nv)].T).T[:, :3]
lt = np.empty(nf, dtype=np.int32); me.polygons.foreach_get("loop_total", lt)
if not np.all(lt == 3):
    sys.exit("the textured mesh is not triangulated")
vi = np.empty(nl, dtype=np.int32); me.loops.foreach_get("vertex_index", vi); F = vi.reshape(-1, 3)
mi = np.empty(nf, dtype=np.int32); me.polygons.foreach_get("material_index", mi)
uv_layer = me.uv_layers.active
uv = np.empty(nl * 2); uv_layer.data.foreach_get("uv", uv); uv = uv.reshape(-1, 2)
materials = list(me.materials)
print(f"imported {nv} vertices, {nf} faces, {len(materials)} materials", flush=True)

atlas, atlas_px = {}, {}
for k, mat in enumerate(materials):
    img = None
    if mat and mat.node_tree:
        for node in mat.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image:
                img = node.image
    atlas[k] = bpy.path.abspath(img.filepath) if img else None
    atlas_px[k] = tuple(img.size) if img else (0, 0)

CO_L = (T @ np.c_[co, np.ones(nv)].T).T[:, :3]            # vertices, levelled
C = co[F].mean(axis=1)
CL = (T @ np.c_[C, np.ones(nf)].T).T[:, :3]
cell_keys = keys_of(np.floor(CL / vox))

# 1. cut
gone_all = np.zeros(nf, dtype=bool)
per_item_gone = []
for it in sel["items"]:
    cells = np.load(run / "edit" / it["voxels"])
    gone = np.isin(cell_keys, np.unique(keys_of(cells))) if len(cells) else np.zeros(nf, dtype=bool)
    per_item_gone.append(gone)
    gone_all |= gone
keep = ~gone_all
F2 = F[keep]
UV2 = uv.reshape(-1, 3, 2)[keep].reshape(-1, 2)
MI2 = mi[keep]
kept_centroids_L = CL[keep]
print(f"cut {int(gone_all.sum())} faces", flush=True)

# 2. fill: find each item's holes on a raster of the kept faces, snap the rim vertices onto the hole outline, triangulate
new_verts, new_faces, new_uv, new_mat = [], [], [], []
vcount = nv
report = []
cell = 0.05 / s
bvert_ids_all = boundary_vertices(F2, np.ones(nv, dtype=bool))
bvert_xy_all = CO_L[bvert_ids_all, :2] if len(bvert_ids_all) else np.zeros((0, 2))
for n, it in enumerate(sel["items"]):
    rep = {"id": it["id"], "faces_removed": int(per_item_gone[n].sum()), "loops": 0, "faces_added": 0, "texture": None, "atlas": None,
           "uv_center": None, "tile_m": None, "triangles": []}
    a_, b_, c_ = it["plane"]
    if it.get("fill_polygon"):
        region = np.array(it["fill_polygon"], dtype=float)
        lo, hi = region.min(axis=0) - 0.4 / s, region.max(axis=0) + 0.4 / s
        seeds_xy = [region.mean(axis=0)]
    elif it.get("seed"):
        seed = np.array(it["seed"], dtype=float)
        radius = float(it.get("radius") or 4.0 / s)
        lo, hi = seed - radius, seed + radius
        region = None
        seeds_xy = [seed]
    else:
        report.append(rep)
        continue
    local = np.all((kept_centroids_L[:, :2] >= lo) & (kept_centroids_L[:, :2] <= hi), axis=1)
    outlines, note = hole_outlines(kept_centroids_L[local, :2], lo, hi, cell, seeds_xy, region)
    print(f"  {it['id']}: {len(outlines)} hole outline(s) ({note})", flush=True)
    bsel = np.all((bvert_xy_all >= lo) & (bvert_xy_all <= hi), axis=1) if len(bvert_xy_all) else np.zeros(0, dtype=bool)
    b_ids, b_xy = bvert_ids_all[bsel], bvert_xy_all[bsel]
    tris_item, verts_item = [], []
    for outline in outlines:
        area = abs(polygon_area(outline))
        if area < (0.03 / s) ** 2:
            continue
        ring = snap_rim(outline, b_xy, b_ids, cell)
        if len(ring) < 3:
            continue
        # ring coordinates (levelled) and ids; new rim points get the plane height
        ring_xy, ring_ids = [], []
        old_ids = [i for kind, i in ring if kind == "old"]
        if len(old_ids) >= 3:
            Lr = CO_L[old_ids]
            A = np.c_[Lr[:, 0], Lr[:, 1], np.ones(len(Lr))]
            try:
                pa, pb, pc = np.linalg.lstsq(A, Lr[:, 2], rcond=None)[0]
            except Exception:
                pa, pb, pc = a_, b_, c_
            if abs(pa) > 0.6 or abs(pb) > 0.6:                 # a wild rim (walls in it): trust the ring plane
                pa, pb, pc = a_, b_, c_
        else:
            pa, pb, pc = a_, b_, c_
        for kind, v in ring:
            if kind == "old":
                ring_xy.append(CO_L[v, :2]); ring_ids.append(int(v))
            else:
                z = pa * v[0] + pb * v[1] + pc
                verts_item.append((Ti @ np.array([v[0], v[1], z, 1.0]))[:3])
                ring_xy.append(np.array(v)); ring_ids.append(vcount); vcount += 1
        ring_xy = np.array(ring_xy)
        step = max(0.12 / s, np.sqrt(area) / 12)
        gx, gy = np.meshgrid(np.arange(outline[:, 0].min() + step / 2, outline[:, 0].max(), step),
                             np.arange(outline[:, 1].min() + step / 2, outline[:, 1].max(), step))
        g = np.c_[gx.ravel(), gy.ravel()]
        if len(g):
            g = g[point_in_polygon(g, ring_xy)]
            if len(g) and len(ring_xy) * len(g) < 4e6:
                d = np.min(np.linalg.norm(g[:, None, :] - ring_xy[None, :, :], axis=2), axis=1)
                g = g[d > step * 0.6]
        pts2 = [Vector((float(x), float(y))) for x, y in ring_xy] + [Vector((float(x), float(y))) for x, y in g]
        edges = [(i, (i + 1) % len(ring_xy)) for i in range(len(ring_xy))]
        try:
            vo, eo, fo, ov, oe, of_ = delaunay_2d_cdt(pts2, edges, [list(range(len(ring_xy)))], 2, 1e-7)
        except Exception as ex:
            print(f"    triangulation failed ({ex})", flush=True)
            continue
        out_ids = np.empty(len(vo), dtype=np.int64)
        for i, v in enumerate(vo):
            orig = [j for j in ov[i] if j < len(ring_xy)]
            if orig:
                out_ids[i] = ring_ids[orig[0]]
            else:
                z = pa * v.x + pb * v.y + pc
                verts_item.append((Ti @ np.array([v.x, v.y, z, 1.0]))[:3])
                out_ids[i] = vcount; vcount += 1
        tri_idx = np.array([f for f in fo if len(f) == 3], dtype=np.int64)
        if len(tri_idx) == 0:
            continue
        P2 = np.array([[v.x, v.y] for v in vo])
        cen = P2[tri_idx].mean(axis=1)
        tri_idx = tri_idx[point_in_polygon(cen, ring_xy)]
        if len(tri_idx) == 0:
            continue
        tris = out_ids[tri_idx]
        up_sign = np.sign(np.linalg.det(T[:3, :3]))
        if polygon_area(P2[tri_idx[0]]) * up_sign < 0:
            tris = tris[:, [0, 2, 1]]
        tris_item.append(tris)
        rep["loops"] += 1
        print(f"    hole {area * s * s:.3f} m²: rim {len(old_ids)} mesh vertices + {len(ring) - len(old_ids)} new, {len(tris)} faces", flush=True)
    if tris_item:
        tris = np.vstack(tris_item)
        tex_name = f"scene_dense_mesh_texture_patch_{n}_map_Kd.jpg"
        # the ring: kept faces around the holes, with their texel coordinates, for 22_edit_fill_cloud.py to paint the patch from
        all_outline = np.vstack(outlines)
        olo, ohi = all_outline.min(axis=0) - 0.35 / s, all_outline.max(axis=0) + 0.35 / s
        near = np.nonzero(keep & np.all((CL[:, :2] >= olo) & (CL[:, :2] <= ohi), axis=1))[0]
        if len(near) > 4000:
            near = near[np.linspace(0, len(near) - 1, 4000).astype(int)]
        ring_uv = [[round(float(CL[f, 0]), 4), round(float(CL[f, 1]), 4), round(float(uv[f * 3:f * 3 + 3, 0].mean()), 5),
                    round(float(uv[f * 3:f * 3 + 3, 1].mean()), 5), int(mi[f])] for f in near]
        rep["ring_uv"] = ring_uv
        rep["atlases"] = {str(k): atlas[k] for k in atlas}
        rep["uv_bbox"] = [[float(olo[0]), float(olo[1])], [float(ohi[0]), float(ohi[1])]]
        mat = bpy.data.materials.new(f"patch_{n}")
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        img = bpy.data.images.new(f"patch_{n}", 512, 512)
        img.filepath_raw = str(run / "dense" / tex_name)
        img.file_format = "JPEG"
        img.save()
        tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
        tex.image = img
        mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        materials.append(mat)
        mat_index = len(materials) - 1
        tile_m = 0.6
        samples = np.array(it.get("ring_samples") or [])
        if len(samples):
            skeys = np.unique(keys_of(np.floor(samples / vox)))
            cand = np.nonzero(np.isin(cell_keys, skeys) & keep)[0]
            if len(cand):
                f0 = int(cand[len(cand) // 2])
                k = int(mi[f0])
                rep["atlas"] = atlas.get(k)
                uvf = uv[f0 * 3:f0 * 3 + 3]
                rep["uv_center"] = [float(v) for v in uvf.mean(axis=0)]
                Wpx, Hpx = atlas_px.get(k, (0, 0))
                edge_m = np.linalg.norm(co[F[f0, 1]] - co[F[f0, 0]]) * s
                edge_px = np.linalg.norm((uvf[1] - uvf[0]) * np.array([Wpx, Hpx]))
                if edge_m > 1e-6 and edge_px > 1e-3:
                    tile_m = float(np.clip(768 / (edge_px / edge_m), 0.25, 3.0))
        rep["tile_m"] = tile_m
        rep["texture"] = tex_name
        all_new = np.vstack(verts_item) if verts_item else np.zeros((0, 3))
        new_verts.append(all_new)
        CO_all = np.vstack([co] + new_verts)
        tri_pts_L = (T @ np.c_[CO_all[tris.ravel()], np.ones(tris.size)].T).T[:, :2].reshape(-1, 3, 2)
        span = np.maximum(ohi - olo, 1e-6)
        new_uv.append(((tri_pts_L - olo) / span).reshape(-1, 2))          # the patch image covers the holes' bbox
        new_faces.append(tris)
        new_mat.append(np.full(len(tris), mat_index, dtype=np.int32))
        rep["faces_added"] = int(len(tris))
        rep["triangles"] = [[[round(float(c), 4) for c in CO_all[v]] for v in t] for t in tris[:20000]]
    else:
        vcount -= sum(len(v) for v in verts_item)
    print(f"  {it['id']}: removed {rep['faces_removed']} faces, {rep['loops']} hole(s) filled, {rep['faces_added']} faces added", flush=True)
    report.append(rep)

F_all = np.vstack([F2] + new_faces) if new_faces else F2
UV_all = np.vstack([UV2] + new_uv) if new_uv else UV2
MI_all = np.concatenate([MI2] + new_mat) if new_mat else MI2
CO_all = np.vstack([co] + new_verts) if new_verts else co
used = np.unique(F_all)
remap = np.full(len(CO_all), -1, dtype=np.int64); remap[used] = np.arange(len(used))
CO_all = CO_all[used]; F_all = remap[F_all]

me2 = bpy.data.meshes.new("edited")
me2.vertices.add(len(CO_all)); me2.vertices.foreach_set("co", CO_all.ravel())
me2.loops.add(len(F_all) * 3); me2.loops.foreach_set("vertex_index", F_all.ravel().astype(np.int32))
me2.polygons.add(len(F_all))
me2.polygons.foreach_set("loop_start", (np.arange(len(F_all)) * 3).astype(np.int32))
me2.polygons.foreach_set("loop_total", np.full(len(F_all), 3, dtype=np.int32))
me2.polygons.foreach_set("material_index", MI_all.astype(np.int32))
me2.update(calc_edges=True)
me2.validate()
uvl = me2.uv_layers.new(name="UVMap")
uvl.data.foreach_set("uv", UV_all.ravel())
for mat in materials:
    me2.materials.append(mat)
obj2 = bpy.data.objects.new("edited", me2)
bpy.context.scene.collection.objects.link(obj2)
bpy.data.objects.remove(obj, do_unlink=True)
bpy.ops.object.select_all(action="DESELECT")
obj2.select_set(True)
bpy.context.view_layer.objects.active = obj2
out_obj = run / "dense" / "scene_dense_mesh_texture.obj"
out_obj.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.obj_export(filepath=str(out_obj), forward_axis="Y", up_axis="Z", export_selected_objects=True, export_materials=True,
                      path_mode="COPY", export_normals=False, export_uv=True, export_triangulated_mesh=True, apply_modifiers=False)
bpy.ops.wm.ply_export(filepath=str(run / "dense" / "scene_dense_mesh_clean.ply"), forward_axis="Y", up_axis="Z", export_selected_objects=True,
                      export_uv=False, export_normals=False, export_colors="NONE", ascii_format=False, apply_modifiers=False)
json.dump({"faces_before": int(nf), "faces_after": int(len(F_all)), "faces_removed": int(gone_all.sum()),
           "faces_added": int(sum(r["faces_added"] for r in report)), "items": report}, open(run / "edit" / "complete.json", "w"))
print(f"wrote {out_obj} ({nf} -> {len(F_all)} faces)")
