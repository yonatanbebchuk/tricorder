#!/usr/bin/env python3
"""Review: each entity, outlined on the photo that saw most of it, shown to the vision-language model: one thing? what is it?

    python scripts/17_review.py <run_dir> --model <model3d asset> --frames <recording>/images [--vlm qwen-local] [--max 60]

Reads  <run>/entities.json, segments/index.json, segments/entity_masks.json, segments/<stem>.npz
Writes <run>/review/<eid>.jpg      the crop the model saw
       <run>/review/montage.jpg    a sheet of the first crops
       <run>/review/review.json    {"reviewed", "renamed", "doubted", "verdicts": {eid: {agree, cls, name, material, one_thing, confidence}}}
       and updates <run>/entities.json: confidence, and name/cls when the model disagrees confidently (the old ones kept as "was")
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402

PROMPT = ("In this photo one region is outlined in orange. Earlier it was identified as '{name}' ({what}). Look at the outlined region "
          "only. Reply with JSON only: {{\"agree\": true or false, \"cls\": one of {tax}, \"material\": one of {mats} or null, "
          "\"name\": 1 to 3 lowercase words, \"one_thing\": true if the outline covers a single thing or surface and false if it mixes "
          "several, \"confidence\": 0 to 1}}.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--model", required=True)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--vlm", default="qwen-local", choices=["qwen-local", "claude", "none"])
    ap.add_argument("--max", type=int, default=60)
    a = ap.parse_args()
    import cv2
    from PIL import Image

    run, frames = Path(a.run), Path(a.frames)
    seg, rev = run / "segments", run / "review"
    rev.mkdir(exist_ok=True)
    E = json.load(open(run / "entities.json"))
    index = {f["stem"]: f for f in json.load(open(seg / "index.json"))["frames"]}
    emasks = json.load(open(seg / "entity_masks.json"))
    vlm = ic.VLM(a.vlm)
    out = {"reviewed": 0, "renamed": 0, "doubted": 0, "verdicts": {}}
    crops = []
    t0 = time.time()
    for e in E["entities"][: a.max]:
        masks = emasks.get(e["id"], [])
        if not masks:
            continue
        # the frame whose mask covered the most of this entity: masks are listed in lift order; prefer the largest mask
        best, best_area = None, -1
        cache = {}
        for stem, mi in masks:
            if stem not in index:
                continue
            if stem not in cache:
                cache[stem] = ic.load_masks(seg / index[stem]["file"])[0]
            ar = int(cache[stem][mi].sum())
            if ar > best_area:
                best, best_area = (stem, mi), ar
        if best is None:
            continue
        stem, mi = best
        fr = index[stem]
        img = np.array(Image.open(frames / fr["name"]).convert("RGB").resize(tuple(fr["work"]), Image.BILINEAR))
        m = cache[stem][mi].astype(np.uint8)
        cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(img, cnts, -1, (217, 119, 87), 3)
        ys, xs = np.nonzero(m)
        H, W = m.shape
        pad = int(0.35 * max(xs.max() - xs.min(), ys.max() - ys.min(), 80))
        x0, x1 = max(0, xs.min() - pad), min(W, xs.max() + pad)
        y0, y1 = max(0, ys.min() - pad), min(H, ys.max() + pad)
        crop = Image.fromarray(img[y0:y1, x0:x1])
        crop.save(rev / f"{e['id']}.jpg", quality=88)
        crops.append((e, crop))
        what = e["cls"] + (f", {e['material']}" if e.get("material") else "")
        verdict = None
        if a.vlm != "none":
            text = vlm.ask(crop, PROMPT.format(name=e["name"], what=what, tax=", ".join(ic.TAXONOMY), mats=", ".join(ic.MATERIALS)), max_tokens=300)
            try:
                v = ic.parse_json(text)
                n = ic.normalise_answer({"cls": v.get("cls", e["cls"]), "material": v.get("material"), "name": v.get("name"), "confidence": v.get("confidence")})
                verdict = {"agree": bool(v.get("agree", True)), "cls": n["cls"], "material": ic.norm_material(n["material"]),
                           "name": n["name"] or e["name"], "one_thing": bool(v.get("one_thing", True)), "confidence": n["confidence"], "frame": fr["name"]}
            except Exception as ex:
                print(f"  {e['id']}: answer not JSON ({ex})", flush=True)
        if verdict:
            out["verdicts"][e["id"]] = verdict
            out["reviewed"] += 1
            new_label = ic.label_of({"cls": verdict["cls"], "material": verdict["material"], "name": verdict["name"]})
            e["review"] = {"agree": verdict["agree"], "cls": verdict["cls"], "name": verdict["name"], "material": verdict["material"],
                           "confidence": verdict["confidence"], "frame": verdict["frame"]}
            if verdict["agree"]:
                e["confidence"] = round(min(1.0, max(e["confidence"], 0.5 + 0.5 * verdict["confidence"])), 2)
            else:                                           # a second opinion lowers the confidence; the name stays yours to change
                e["confidence"] = round(min(e["confidence"], 0.4), 2)
                out["doubted"] += 1
                if verdict["confidence"] >= 0.6 and new_label:
                    out["renamed"] += 1                     # counted as "would rename": shown in the app as the model's second opinion
            if not verdict["one_thing"]:
                e["mixed"] = True
                out["doubted"] += 1
            print(f"  {e['id']:5s} {e['name']:20s} -> {'agree' if verdict['agree'] else 'DISAGREE: ' + verdict['name']}"
                  f"  ({verdict['confidence']:.2f}, {'one' if verdict['one_thing'] else 'mixed'})  {time.time() - t0:.0f}s", flush=True)
    json.dump(E, open(run / "entities.json", "w"), indent=1)
    json.dump(out, open(rev / "review.json", "w"), indent=1)
    # montage of the first 20 crops
    try:
        tiles = []
        for e, crop in crops[:20]:
            c = crop.copy(); c.thumbnail((240, 180))
            tile = Image.new("RGB", (240, 200), "white"); tile.paste(c, ((240 - c.size[0]) // 2, 0))
            arr = np.array(tile)
            cv2.putText(arr, f"{e['id']} {e['name']}"[:30], (4, 194), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (30, 30, 30), 1, cv2.LINE_AA)
            tiles.append(arr)
        if tiles:
            cols = 5
            rows = int(np.ceil(len(tiles) / cols))
            sheet = np.full((rows * 200, cols * 240, 3), 255, np.uint8)
            for i, t in enumerate(tiles):
                r, c = divmod(i, cols)
                sheet[r * 200:(r + 1) * 200, c * 240:(c + 1) * 240] = t
            Image.fromarray(sheet).save(rev / "montage.jpg", quality=85)
    except Exception as ex:
        print(f"montage not drawn: {ex}", file=sys.stderr)
    print(f"reviewed {out['reviewed']} entities: {out['renamed']} renamed, {out['doubted']} doubted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
