"""Shared pieces of the identify stages: the taxonomy the vision-language model answers in, how its answers map onto
mark classes, the VLM backends (local Qwen2.5-VL through MLX, hosted Claude), mask packing and set-of-mark drawing."""
from __future__ import annotations

import base64
import io
import json
import os
import re
import time
from pathlib import Path

import numpy as np

# What the model is asked to answer with (per region), and how that maps onto the element classes of a mark.
TAXONOMY = ["wall", "fence", "window", "door", "stairs", "ground", "tree", "bush", "object", "building", "roof", "sky",
            "person", "vehicle", "other"]
MATERIALS = ["grass", "brick", "concrete", "sand", "gravel", "deck", "garden", "soil", "tiles", "stone", "asphalt", "other"]
CLASS_MAP = {"wall": "wall", "building": "wall", "fence": "fence", "window": "window", "door": "door", "stairs": "stairs",
             "ground": "area", "tree": "tree", "bush": "bush", "object": "object"}      # the rest is ignored (sky, person ...)
SYNONYMS = {"barbecue": "grill", "bbq": "grill", "barbeque": "grill", "trash can": "bin", "garbage can": "bin", "garbage bin": "bin",
            "trash bin": "bin", "rubbish bin": "bin", "dustbin": "bin", "wheelie bin": "bin", "bicycle": "bike", "lawn": "grass",
            "paving": "brick", "pavers": "brick", "patio": "brick", "decking": "deck", "wooden deck": "deck", "flower bed": "garden",
            "flowerbed": "garden", "garden bed": "garden", "planter bed": "garden", "sandbox": "sand", "sand pit": "sand",
            "sandpit": "sand", "dirt": "soil", "mulch": "garden", "hedge": "bush", "shrub": "bush", "shrubs": "bush", "bushes": "bush"}

# Names the model tends to file under "object" that are element classes of their own (or should be ignored).
NAME_TO_CLASS = {"window": "window", "windows": "window", "bay window": "window", "door": "door", "gate": "fence", "fence": "fence",
                 "wall": "wall", "house wall": "wall", "stairs": "stairs", "steps": "stairs", "staircase": "stairs", "tree": "tree",
                 "trees": "tree", "bush": "bush", "hedge": "bush", "shrub": "bush", "roof": "roof", "sky": "sky", "person": "person",
                 "car": "vehicle", "shadow": "other", "leaves": "other", "fallen leaves": "other"}

PROMPT = (
    "This is a photo of an outdoor property (a backyard, garden or house exterior). Regions of the photo are outlined and "
    "numbered. For EVERY number, say what that region is.\n"
    "Answer with JSON only: one array per number, [cls, material, name, confidence], like\n"
    '{"1": ["ground", "grass", "lawn", 0.9], "2": ["object", null, "grill", 0.8], "3": ["window", null, "bay window", 0.9]}\n'
    f"cls is one of: {', '.join(TAXONOMY)}. 'ground' is any walkable or planted surface (lawn, paving, sand, gravel, decking, soil, "
    "a flower bed) and gets a material from: " + ", ".join(MATERIALS) + "; everything else has material null. 'wall' is a wall of "
    "a house or shed, 'building' a whole facade, 'fence' a fence or gate, 'stairs' steps, 'window' and 'door' are their own classes, "
    "'object' is any movable thing (furniture, grill, bin, bike, pot, toy, hose). name: 1 to 3 lowercase words (e.g. 'grill', 'bin', "
    "'sand pit'). confidence 0 to 1. Do not skip numbers; use 'other' if unsure. No prose, no descriptions."
)


def norm_name(s: str | None) -> str:
    s = (s or "").strip().lower()
    s = re.sub(r"^(a|an|the)\s+", "", s)
    s = re.sub(r"[^a-z0-9 ]+", "", s).strip()
    return SYNONYMS.get(s, s)


def norm_material(s: str | None) -> str | None:
    if not s:
        return None
    s = norm_name(s)
    return s if s in MATERIALS else SYNONYMS.get(s, "other")


def normalise_answer(ans) -> dict:
    """An answer as a dict {cls, material, name, confidence, description}, from the compact array form or the dict form;
    names that are classes of their own ('window' filed under 'object') move to that class."""
    if isinstance(ans, (list, tuple)):
        keys = ["cls", "material", "name", "confidence"]
        ans = {k: (ans[i] if i < len(ans) else None) for i, k in enumerate(keys)}
    elif not isinstance(ans, dict):
        return {"cls": "other", "material": None, "name": "", "confidence": 0.3, "description": ""}
    cls = str(ans.get("cls") or "other").strip().lower()
    name = norm_name(ans.get("name"))
    if cls in ("object", "other", "building") and name in NAME_TO_CLASS:
        cls = NAME_TO_CLASS[name]
    if cls == "ground" and not ans.get("material") and name in MATERIALS:
        ans["material"] = name
    try:
        conf = float(ans.get("confidence") if ans.get("confidence") is not None else 0.5)
    except (TypeError, ValueError):
        conf = 0.5
    return {"cls": cls, "material": ans.get("material"), "name": name, "confidence": max(0.0, min(1.0, conf)),
            "description": str(ans.get("description") or "")[:120]}


def label_of(ans: dict) -> str | None:
    """The lift label of an answer: 'area:grass', 'object:grill', 'fence' ...; None when the region is ignored."""
    cls = CLASS_MAP.get(str(ans.get("cls", "")).strip().lower())
    if cls is None:
        return None
    if cls == "area":
        return f"area:{norm_material(ans.get('material')) or 'other'}"
    if cls == "object":
        return f"object:{norm_name(ans.get('name')) or 'object'}"
    return cls


# ---------------------------------------------------------------- geometry shared by the stages

CAMERA_HEIGHT_M = 1.5


def est_scale(model: Path, T: np.ndarray) -> float:
    """Metres per model unit from the median camera height above the levelled ground (phone at chest height), so size
    thresholds can be in metres before any tape measurement exists."""
    try:
        import pycolmap
        rec = pycolmap.Reconstruction(str(model / "sparse" / "0"))
        C = np.array([np.asarray(im.projection_center()) for im in rec.images.values()])
        Z = (T @ np.c_[C, np.ones(len(C))].T).T[:, 2]
        h = float(np.median(Z[Z > 0])) if np.any(Z > 0) else float(np.median(np.abs(Z)))
        return CAMERA_HEIGHT_M / h if h > 1e-6 else 1.0
    except Exception as e:
        print(f"scale estimate failed ({e}); assuming 1 m per unit")
        return 1.0


def levelled_transform(model: Path) -> np.ndarray:
    p = model / "transform_preview.json"
    return np.array(json.load(open(p))["matrix"]) if p.exists() else np.eye(4)


def point_in_polygon(xy: np.ndarray, poly: np.ndarray) -> np.ndarray:
    """Vectorised even-odd test: which of the points (n, 2) lie inside the polygon (m, 2)."""
    x, y = xy[:, 0], xy[:, 1]
    inside = np.zeros(len(xy), dtype=bool)
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        crosses = ((y0 > y) != (y1 > y))
        with np.errstate(divide="ignore", invalid="ignore"):
            xi = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
        inside ^= crosses & (x < xi)
    return inside


# ---------------------------------------------------------------- masks

def load_masks(path: Path):
    z = np.load(path)
    shape = tuple(int(v) for v in z["shape"])
    M = np.unpackbits(z["masks"], axis=-1)[..., : shape[-1]].astype(bool)
    return M, z


def som_image(img, masks, labels: list[str] | None = None):
    """Set-of-mark: coloured outlines and a numbered badge at each mask's most interior point. Returns a PIL image."""
    import cv2
    rgb = np.array(img).copy()
    H, W = rgb.shape[:2]
    rng = np.random.default_rng(7)
    for i, m in enumerate(masks):
        color = tuple(int(c) for c in rng.integers(40, 230, 3))
        mu8 = m.astype(np.uint8)
        cnts, _ = cv2.findContours(mu8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(rgb, cnts, -1, color, 2)
        dist = cv2.distanceTransform(mu8, cv2.DIST_L2, 3)
        y, x = np.unravel_index(int(dist.argmax()), dist.shape)
        text = labels[i] if labels else str(i + 1)
        fs = 0.55 if max(H, W) <= 1100 else 0.8
        (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, fs, 2)
        x0, y0 = int(np.clip(x - tw / 2 - 4, 0, W - tw - 8)), int(np.clip(y - th / 2 - 4, 0, H - th - 8))
        cv2.rectangle(rgb, (x0, y0), (x0 + tw + 8, y0 + th + 8), (255, 255, 255), -1)
        cv2.rectangle(rgb, (x0, y0), (x0 + tw + 8, y0 + th + 8), color, 2)
        cv2.putText(rgb, text, (x0 + 4, y0 + th + 3), cv2.FONT_HERSHEY_SIMPLEX, fs, (0, 0, 0), 2, cv2.LINE_AA)
    from PIL import Image
    return Image.fromarray(rgb)


# ---------------------------------------------------------------- VLM backends

def parse_json(text: str) -> dict:
    """The model's answer as one dict, tolerant of code fences, trailing prose, an array of one-key objects, and a
    truncated tail (entries are then recovered one by one)."""
    t = text.strip()
    t = re.sub(r"^```(?:json)?", "", t).strip()
    t = re.sub(r"```$", "", t).strip()

    def merge(v):
        if isinstance(v, dict):
            return v
        if isinstance(v, list):
            out = {}
            for e in v:
                if isinstance(e, dict):
                    out.update(e)
            return out
        raise ValueError("not an object")

    try:
        return merge(json.loads(t))
    except Exception:
        pass
    starts = [i for i in (t.find("{"), t.find("[")) if i >= 0]
    if starts:
        i = min(starts)
        j = max(t.rfind("}"), t.rfind("]"))
        if j > i:
            s = t[i:j + 1]
            s = re.sub(r",\s*([}\]])", r"\1", s).replace("None", "null").replace("True", "true").replace("False", "false")
            try:
                return merge(json.loads(s))
            except Exception:
                pass
    # entry by entry: "12": [...] or "12": {...}
    out = {}
    for m in re.finditer(r'"(\d+)"\s*:\s*(\[[^\[\]]*\]|\{[^{}]*\})', t):
        try:
            out[m.group(1)] = json.loads(m.group(2).replace("None", "null"))
        except Exception:
            continue
    if out:
        return out
    raise ValueError("no JSON object in answer")


class VLM:
    """ask(image, prompt) -> text. Backends: qwen-local (mlx_vlm), claude (anthropic SDK)."""

    def __init__(self, kind: str):
        self.kind = kind
        self.calls = 0
        self.seconds = 0.0
        if kind == "qwen-local":
            from mlx_vlm import load
            from mlx_vlm.utils import load_config
            self.model_id = os.environ.get("TRICORDER_QWEN", "mlx-community/Qwen2.5-VL-7B-Instruct-4bit")
            self.model, self.processor = load(self.model_id)
            self.config = load_config(self.model_id)
        elif kind == "claude":
            import anthropic
            self.model_id = os.environ.get("TRICORDER_CLAUDE_MODEL", "claude-opus-5")
            self.client = anthropic.Anthropic()                 # ANTHROPIC_API_KEY, or an `ant auth login` profile
        elif kind == "none":
            self.model_id = "none"
        else:
            raise ValueError(f"unknown VLM {kind!r}")

    def ask(self, image, prompt: str, max_tokens: int = 2000) -> str:
        t0 = time.time()
        try:
            if self.kind == "qwen-local":
                return self._ask_qwen(image, prompt, max_tokens)
            if self.kind == "claude":
                return self._ask_claude(image, prompt, max_tokens)
            return "{}"
        finally:
            self.calls += 1
            self.seconds += time.time() - t0

    def _ask_qwen(self, image, prompt, max_tokens):
        import tempfile
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
            image.save(f.name, quality=90)
            path = f.name
        try:
            formatted = apply_chat_template(self.processor, self.config, prompt, num_images=1)
            res = generate(self.model, self.processor, formatted, image=[path], max_tokens=max_tokens, temperature=0.0, verbose=False)
            return res.text if hasattr(res, "text") else str(res)
        finally:
            os.unlink(path)

    def _ask_claude(self, image, prompt, max_tokens):
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=90)
        data = base64.standard_b64encode(buf.getvalue()).decode("utf-8")
        response = self.client.messages.create(
            model=self.model_id, max_tokens=max(4096, max_tokens),
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}},
                {"type": "text", "text": prompt}]}])
        if response.stop_reason == "refusal":
            return "{}"
        return "".join(b.text for b in response.content if b.type == "text")
