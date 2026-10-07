#!/usr/bin/env python3
"""Name: a vision-language model names every mask of every segmented frame, one call per frame (set-of-mark prompting).

    python scripts/14_name.py <run_dir> --frames <recording>/images [--vlm qwen-local | claude | none]

Reads  <run>/segments/index.json and <stem>.npz
Writes <run>/segments/som_<stem>.jpg   the frame with numbered outlines (what the model saw)
       <run>/segments/names.json       {"vlm", "model", "frames": {stem: {"1": {cls, material, name, description, confidence,
                                        label}, ...}}, "named", "ignored", "seconds_per_frame", "failed": [stems]}
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identify_common as ic  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--frames", required=True)
    ap.add_argument("--vlm", default="qwen-local", choices=["qwen-local", "claude", "none"])
    ap.add_argument("--retries", type=int, default=1)
    a = ap.parse_args()
    from PIL import Image

    run, frames = Path(a.run), Path(a.frames)
    seg = run / "segments"
    index = json.load(open(seg / "index.json"))
    vlm = ic.VLM(a.vlm)
    print(f"naming {len(index['frames'])} frames with {a.vlm} ({vlm.model_id})", flush=True)
    out = {"vlm": a.vlm, "model": vlm.model_id, "frames": {}, "named": 0, "ignored": 0, "failed": []}
    t0 = time.time()
    for k, fr in enumerate(index["frames"]):
        M, _ = ic.load_masks(seg / fr["file"])
        img = Image.open(frames / fr["name"]).convert("RGB").resize(tuple(fr["work"]), Image.BILINEAR)
        som = ic.som_image(img, M)
        som.save(seg / f"som_{fr['stem']}.jpg", quality=88)
        answers = None
        if a.vlm != "none":
            for attempt in range(a.retries + 1):
                text = vlm.ask(som, ic.PROMPT + (f"\nThere are exactly {len(M)} numbered regions, 1 to {len(M)}." if attempt else ""))
                try:
                    answers = ic.parse_json(text)
                    break
                except Exception as e:
                    print(f"  {fr['name']}: answer not JSON ({e}); {'retrying' if attempt < a.retries else 'giving up'}", flush=True)
                    (seg / f"raw_{fr['stem']}.txt").write_text(text)
        named = {}
        if isinstance(answers, dict):
            for key, ans in answers.items():
                try:
                    i = int(str(key).strip().strip("#"))
                except ValueError:
                    continue
                if not (1 <= i <= len(M)):
                    continue
                ans = ic.normalise_answer(ans)
                label = ic.label_of(ans)
                named[str(i)] = {**ans, "material": ic.norm_material(ans.get("material")), "label": label}
                if label:
                    out["named"] += 1
                else:
                    out["ignored"] += 1
        else:
            out["failed"].append(fr["stem"])
        out["frames"][fr["stem"]] = named
        labels = sorted({v["label"] for v in named.values() if v["label"]})
        print(f"  {k + 1}/{len(index['frames'])} {fr['name']}: {len(named)}/{len(M)} answered, {len(labels)} labels "
              f"({', '.join(labels[:8])}{'…' if len(labels) > 8 else ''}), {time.time() - t0:.0f}s", flush=True)
    out["seconds_per_frame"] = round(vlm.seconds / max(1, vlm.calls), 1)
    json.dump(out, open(seg / "names.json", "w"), indent=1)
    print(f"named {out['named']} regions ({out['ignored']} ignored, {len(out['failed'])} frames failed), "
          f"{out['seconds_per_frame']} s per call")
    return 0


if __name__ == "__main__":
    sys.exit(main())
