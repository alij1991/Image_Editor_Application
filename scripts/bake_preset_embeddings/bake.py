#!/usr/bin/env python3
"""Bake `assets/presets/preset_embeddings.json` (Phase XVI.66c).

Goal: produce one MobileViT-v2 embedding per built-in preset so the
runtime "For You" rail can cosine-rank presets against the user's
photo. Embeddings are L2-normalised so the runtime kNN over them
collapses to a dot product (matching `PresetSuggester._cosine`'s
fast path).

Strategy: every preset in a given canonical category is intended for
photos of that category's character (Portrait → faces, Landscape →
horizons, B&W → high-contrast monochrome, etc.). For the bake we
synthesise one **representative reference image** per category using
PIL primitives, run MobileViT-v2 on it once, and assign the resulting
embedding to every preset in that category. The runtime then picks
the closest category for the source photo and surfaces the presets
from that bucket.

If you ever want per-preset embeddings (e.g. you collect distinct
reference photos for each preset), drop them into a `references/`
sibling directory and modify `_reference_for` to use them. The
JSON schema is preset-keyed, not category-keyed, so the swap doesn't
touch any runtime code.

Usage:
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    python bake.py

Outputs:
    assets/presets/preset_embeddings.json
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Tuple

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageFilter

# Repo layout — scripts/bake_preset_embeddings/bake.py → repo root is ../..
REPO_ROOT = Path(__file__).resolve().parents[2]
MODEL_PATH = REPO_ROOT / "assets/models/bundled/mobilevit_v2_1_0_fp32.onnx"
PRESETS_DART = REPO_ROOT / "lib/engine/presets/built_in_presets.dart"
OUT_PATH = REPO_ROOT / "assets/presets/preset_embeddings.json"
INPUT_SIZE = 256  # MobileViT-v2's native training resolution.
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
MODEL_ID = "mobilevit_v2_1_0_fp32"
LIBRARY_VERSION = 1


# -----------------------------------------------------------------------------
# Preset enumeration — parses lib/engine/presets/built_in_presets.dart for the
# (id, category) pairs of every Preset literal. Avoids hard-coding the list
# here so adding a built-in preset doesn't require updating two files.
# -----------------------------------------------------------------------------

# Match `id: 'something',` and the next `category: 'something',` within the
# same Preset literal. Both `const Preset(...)` and `Preset(...)` forms exist
# in the source so the match must allow either prefix.
_PRESET_RE = re.compile(
    r"Preset\(\s*"
    r"(?:[^()]*?id:\s*'(?P<id>[^']+)')\s*,?\s*"
    r"(?:[^()]*?name:\s*'[^']*')\s*,?\s*"
    r"(?:[^()]*?category:\s*'(?P<category>[^']+)')",
    re.DOTALL,
)


def _strip_dart_comments(src: str) -> str:
    """Remove `//`-line comments and `/* ... */` block comments from
    Dart source. Necessary because some preset block comments contain
    unbalanced parens (e.g. "(deep reds, rich blues)") that defeat
    the `[^()]*?` regex below."""
    # Block comments first — the line-comment pass would otherwise stop
    # at the first `//` inside a `/* ... */` block.
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    # Line comments. Strip from `//` to EOL but keep the newline so
    # line numbers / line-anchored matches still work.
    src = re.sub(r"//[^\n]*", "", src)
    return src


def parse_built_in_presets() -> list[Tuple[str, str]]:
    """Return [(id, category), ...] for every entry in built_in_presets.dart."""
    src = _strip_dart_comments(PRESETS_DART.read_text(encoding="utf-8"))
    out = []
    for m in _PRESET_RE.finditer(src):
        out.append((m.group("id"), m.group("category")))
    if not out:
        raise RuntimeError(
            f"No Preset literals matched in {PRESETS_DART}. "
            f"Has the file format changed? Update _PRESET_RE."
        )
    return out


# -----------------------------------------------------------------------------
# Reference image synthesis — one per canonical category. PIL primitives only
# so the bake is reproducible and dependency-free beyond Pillow.
# -----------------------------------------------------------------------------


def _portrait_reference() -> Image.Image:
    """Warm-toned skin/face composition: a peach oval over a soft brown
    backdrop with a darker hair zone above. Approximates the colour
    distribution of a casual portrait."""
    img = Image.new("RGB", (INPUT_SIZE, INPUT_SIZE), (88, 64, 52))
    d = ImageDraw.Draw(img)
    # Hair zone (darker, top quarter).
    d.rectangle([0, 0, INPUT_SIZE, INPUT_SIZE // 4], fill=(40, 30, 25))
    # Face oval (skin tone, centred).
    cx, cy = INPUT_SIZE // 2, INPUT_SIZE * 5 // 9
    rx, ry = INPUT_SIZE // 4, INPUT_SIZE // 3
    d.ellipse(
        [cx - rx, cy - ry, cx + rx, cy + ry],
        fill=(232, 188, 158),
    )
    # Eye + lip zones to break the oval.
    d.ellipse([cx - 22, cy - 12, cx - 8, cy + 2], fill=(50, 40, 35))
    d.ellipse([cx + 8, cy - 12, cx + 22, cy + 2], fill=(50, 40, 35))
    d.rectangle(
        [cx - 18, cy + ry // 2 + 8, cx + 18, cy + ry // 2 + 16],
        fill=(180, 90, 78),
    )
    return img.filter(ImageFilter.GaussianBlur(radius=4))


def _landscape_reference() -> Image.Image:
    """Sky/ground horizon split: blue-cyan sky top, green-brown ground
    bottom, with a warm sun-glow gradient near the horizon. Approximates
    a daylight landscape photo."""
    img = Image.new("RGB", (INPUT_SIZE, INPUT_SIZE))
    px = img.load()
    horizon = INPUT_SIZE * 5 // 8
    for y in range(INPUT_SIZE):
        for x in range(INPUT_SIZE):
            if y < horizon:
                # Sky: gradient from light cyan top → warm peach near
                # horizon (sunset approximation).
                t = y / horizon
                r = int(120 + 100 * t)
                g = int(170 + 60 * t)
                b = int(230 - 80 * t)
                px[x, y] = (min(255, r), min(255, g), max(60, min(255, b)))
            else:
                # Ground: muted green/brown gradient deepening with depth.
                t = (y - horizon) / (INPUT_SIZE - horizon)
                r = int(80 + 40 * t)
                g = int(110 + 30 * (1 - t))
                b = int(60 + 20 * (1 - t))
                px[x, y] = (r, g, b)
    return img.filter(ImageFilter.GaussianBlur(radius=2))


def _film_reference() -> Image.Image:
    """Warm sepia gradient with subtle noise — a stand-in for the "shot
    on Portra / Kodachrome / vintage" look the film category targets."""
    img = Image.new("RGB", (INPUT_SIZE, INPUT_SIZE))
    px = img.load()
    for y in range(INPUT_SIZE):
        for x in range(INPUT_SIZE):
            # Diagonal warm gradient.
            t = (x + y) / (2 * INPUT_SIZE)
            r = int(180 - 30 * t)
            g = int(140 - 50 * t)
            b = int(80 - 50 * t)
            px[x, y] = (max(60, r), max(40, g), max(20, b))
    # Add deterministic film grain (no rng seed needed — we want the
    # bake to be byte-stable across runs, so use a tiny fixed pattern).
    rng = np.random.default_rng(seed=42)
    arr = np.array(img, dtype=np.float32)
    noise = rng.normal(0, 6, arr.shape).astype(np.float32)
    arr = np.clip(arr + noise, 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def _bw_reference() -> Image.Image:
    """High-contrast monochrome composition: dark midground, bright
    skyline highlight, deep shadows. Targets the kind of subject B&W
    presets pop on."""
    img = Image.new("L", (INPUT_SIZE, INPUT_SIZE), 32)
    d = ImageDraw.Draw(img)
    # Bright sky-ish band.
    d.rectangle([0, 0, INPUT_SIZE, INPUT_SIZE // 3], fill=210)
    # Mid-tone land mass.
    d.rectangle(
        [0, INPUT_SIZE // 3, INPUT_SIZE, INPUT_SIZE * 2 // 3],
        fill=120,
    )
    # Dark foreground.
    d.rectangle(
        [0, INPUT_SIZE * 2 // 3, INPUT_SIZE, INPUT_SIZE],
        fill=20,
    )
    img = img.filter(ImageFilter.GaussianBlur(radius=3))
    return img.convert("RGB")


def _bold_reference() -> Image.Image:
    """High-saturation, high-contrast scene with cyan / magenta /
    orange splashes — approximates the "Cyberpunk / Dramatic"
    style the bold category targets."""
    img = Image.new("RGB", (INPUT_SIZE, INPUT_SIZE), (20, 8, 40))
    d = ImageDraw.Draw(img)
    # Cyan glow upper left.
    d.ellipse([-50, -50, 140, 140], fill=(40, 200, 220))
    # Magenta glow lower right.
    d.ellipse(
        [INPUT_SIZE - 140, INPUT_SIZE - 140, INPUT_SIZE + 50, INPUT_SIZE + 50],
        fill=(220, 40, 180),
    )
    # Orange streak across middle.
    d.rectangle(
        [0, INPUT_SIZE // 2 - 12, INPUT_SIZE, INPUT_SIZE // 2 + 12],
        fill=(245, 130, 30),
    )
    return img.filter(ImageFilter.GaussianBlur(radius=6))


def _popular_reference() -> Image.Image:
    """Balanced mid-tone outdoor scene — neither high-contrast nor
    high-saturation. Acts as a neutral baseline for the "popular"
    category presets that target everyday photos."""
    img = Image.new("RGB", (INPUT_SIZE, INPUT_SIZE), (140, 130, 115))
    d = ImageDraw.Draw(img)
    # Soft sky band.
    d.rectangle(
        [0, 0, INPUT_SIZE, INPUT_SIZE // 2],
        fill=(160, 175, 195),
    )
    # Subject silhouette mid-frame.
    d.ellipse(
        [
            INPUT_SIZE // 3,
            INPUT_SIZE // 3,
            INPUT_SIZE * 2 // 3,
            INPUT_SIZE * 2 // 3,
        ],
        fill=(95, 105, 90),
    )
    return img.filter(ImageFilter.GaussianBlur(radius=4))


_REFERENCES = {
    "popular": _popular_reference,
    "portrait": _portrait_reference,
    "landscape": _landscape_reference,
    "film": _film_reference,
    "bw": _bw_reference,
    "bold": _bold_reference,
}


def _reference_for(category: str) -> Image.Image:
    fn = _REFERENCES.get(category)
    if fn is None:
        raise RuntimeError(
            f"No reference image factory for category '{category}'. "
            f"Update _REFERENCES."
        )
    return fn()


# -----------------------------------------------------------------------------
# Embedder runner — mirrors PresetEmbedderService's preprocessing exactly so
# the runtime cosine matches what we baked.
# -----------------------------------------------------------------------------


def _imagenet_chw(img: Image.Image) -> np.ndarray:
    """RGB PIL → [1, 3, H, W] ImageNet-normalised float32 tensor."""
    img = img.convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)
    arr = np.asarray(img, dtype=np.float32) / 255.0  # HWC
    arr = (arr - IMAGENET_MEAN) / IMAGENET_STD
    chw = np.transpose(arr, (2, 0, 1))  # CHW
    return chw[np.newaxis, ...].astype(np.float32)


def _l2_normalise(v: np.ndarray) -> np.ndarray:
    norm = float(np.linalg.norm(v))
    if norm <= 0:
        return v
    return v / norm


def _embed(session: ort.InferenceSession, img: Image.Image) -> np.ndarray:
    """Run MobileViT-v2 on [img] and return its L2-normalised embedding."""
    tensor = _imagenet_chw(img)
    # Pick the input by HuggingFace convention; fall back to first.
    in_names = [i.name for i in session.get_inputs()]
    name = next(
        (n for n in in_names if n.lower().endswith("pixel_values") or n.lower() == "input"),
        in_names[0],
    )
    raw = session.run(None, {name: tensor})[0]
    # Drop batch dim. MobileViT-v2's exported output is typically
    # [1, C] (pooled features) or [1, num_classes] for the
    # classification head; either shape works for kNN.
    flat = np.asarray(raw, dtype=np.float32).reshape(-1)
    return _l2_normalise(flat)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() -> int:
    if not MODEL_PATH.exists():
        print(f"FAIL: model not found at {MODEL_PATH}", file=sys.stderr)
        return 1
    if not PRESETS_DART.exists():
        print(f"FAIL: built_in_presets.dart not found at {PRESETS_DART}",
              file=sys.stderr)
        return 1

    print(f"Loading {MODEL_PATH.name} …")
    session = ort.InferenceSession(
        MODEL_PATH.as_posix(),
        providers=["CPUExecutionProvider"],
    )

    # 1. Embed each category once.
    print("Embedding category references …")
    cat_embeddings: dict[str, np.ndarray] = {}
    for cat in _REFERENCES:
        ref = _reference_for(cat)
        emb = _embed(session, ref)
        cat_embeddings[cat] = emb
        print(f"  {cat:10s}  dim={len(emb)}  ‖v‖={np.linalg.norm(emb):.4f}")

    embedding_dim = len(next(iter(cat_embeddings.values())))
    if any(len(v) != embedding_dim for v in cat_embeddings.values()):
        print("FAIL: embedding dimensions differ across categories",
              file=sys.stderr)
        return 1

    # 2. Walk built-in presets, assign each its category's embedding.
    print(f"Walking presets in {PRESETS_DART.relative_to(REPO_ROOT)} …")
    presets = parse_built_in_presets()
    print(f"  parsed {len(presets)} preset(s)")
    entries = []
    skipped = []
    for preset_id, category in presets:
        emb = cat_embeddings.get(category)
        if emb is None:
            skipped.append((preset_id, category))
            continue
        entries.append({
            "presetId": preset_id,
            "embedding": [float(v) for v in emb],
        })

    if skipped:
        print("WARN: skipped presets with no category reference:")
        for pid, cat in skipped:
            print(f"  - {pid} (category={cat})")

    # 3. Build + write the library JSON. Schema must match
    # `PresetEmbeddingLibrary.parse` exactly.
    payload = {
        "version": LIBRARY_VERSION,
        "modelId": MODEL_ID,
        "embeddingDim": embedding_dim,
        "entries": entries,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(
        json.dumps(payload, indent=2, sort_keys=False),
        encoding="utf-8",
    )
    size_kb = OUT_PATH.stat().st_size / 1024
    print(
        f"WROTE {OUT_PATH.relative_to(REPO_ROOT)}  "
        f"({len(entries)} entries, dim={embedding_dim}, {size_kb:.1f} KB)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
