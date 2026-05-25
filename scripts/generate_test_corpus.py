#!/usr/bin/env python3
"""
XVI.96 (B2) — Synthetic test-corpus generator for the AI Test Lab.

Builds the first cut of `assets/test_images/`: high-res procedural
photos with perfect, mathematically-derived ground truth. Deterministic
(uses a fixed seed) so anyone can regenerate the corpus by running:

    python3 scripts/generate_test_corpus.py

The synthetic corpus is intentionally chosen for the deterministic CI
gate. Real-world Unsplash CC0 photos with hand-painted ground truth
are tracked separately as B2b — they're what the device-side
perceptual gate (Tier 2) will use.

Outputs:
    assets/test_images/portrait_silhouette.{png, alpha.png}
    assets/test_images/portrait_complex_hair.{png, alpha.png}
    assets/test_images/landscape_clear_sky.{png, sky_mask.png}
    assets/test_images/landscape_horizon_objects.{png, sky_mask.png}
    assets/test_images/clean_grid.png
    assets/test_images/noisy_grid.png
    assets/test_images/sharp_grid.png
    assets/test_images/blurred_grid.png
    assets/test_images/multi_subject.png
    assets/test_images/object_on_clutter.{png, object_mask.png}
    assets/test_images/manifest.json
"""
from __future__ import annotations

import json
import math
import os
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets" / "test_images"
SEED = 20260524

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _ensure_out() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)


def _save(img: Image.Image, name: str) -> str:
    path = OUT_DIR / name
    img.save(path, optimize=True)
    rel = path.relative_to(ROOT).as_posix()
    print(f"  wrote {rel} ({path.stat().st_size // 1024} KB)")
    return rel


def _gradient(width: int, height: int, top: tuple[int, int, int],
              bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        r = round(top[0] * (1 - t) + bottom[0] * t)
        g = round(top[1] * (1 - t) + bottom[1] * t)
        b = round(top[2] * (1 - t) + bottom[2] * t)
        for x in range(width):
            pixels[x, y] = (r, g, b)
    return img


def _draw_grid(img: Image.Image, *, step: int, line_colour: tuple[int, int, int]) -> None:
    draw = ImageDraw.Draw(img)
    w, h = img.size
    for x in range(0, w, step):
        draw.line([(x, 0), (x, h - 1)], fill=line_colour, width=2)
    for y in range(0, h, step):
        draw.line([(0, y), (w - 1, y)], fill=line_colour, width=2)


def _add_gaussian_noise(img: Image.Image, sigma: float) -> Image.Image:
    rng = random.Random(SEED)
    out = img.copy()
    pixels = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b = pixels[x, y]
            nr = max(0, min(255, int(r + rng.gauss(0, sigma))))
            ng = max(0, min(255, int(g + rng.gauss(0, sigma))))
            nb = max(0, min(255, int(b + rng.gauss(0, sigma))))
            pixels[x, y] = (nr, ng, nb)
    return out


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------


def gen_portrait_silhouette() -> tuple[str, str]:
    """Simple head+shoulders silhouette. Ground truth = perfect alpha."""
    w, h = 1024, 1536
    bg = _gradient(w, h, top=(40, 70, 120), bottom=(10, 20, 50))
    fg_layer = Image.new("RGB", (w, h))
    alpha = Image.new("L", (w, h), 0)
    draw_fg = ImageDraw.Draw(fg_layer)
    draw_a = ImageDraw.Draw(alpha)

    # Head: circle centred at (512, 480), radius 220.
    cx, cy, r = 512, 480, 220
    draw_fg.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(30, 30, 40))
    draw_a.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)

    # Shoulders: rounded rect spanning y=680..1400.
    sx, sy = 220, 680
    ex, ey = 804, 1400
    draw_fg.rounded_rectangle([sx, sy, ex, ey], radius=120, fill=(30, 30, 40))
    draw_a.rounded_rectangle([sx, sy, ex, ey], radius=120, fill=255)

    # Soft 2 px feather on alpha to mimic anti-aliasing real edges.
    alpha = alpha.filter(ImageFilter.GaussianBlur(radius=1.5))

    img = Image.composite(fg_layer, bg, alpha)
    return (_save(img, "portrait_silhouette.png"),
            _save(alpha, "portrait_silhouette.alpha.png"))


def gen_portrait_complex_hair() -> tuple[str, str]:
    """Portrait + radial 'hair fronds' that stress matte boundaries."""
    w, h = 1024, 1536
    bg = _gradient(w, h, top=(80, 60, 110), bottom=(20, 10, 30))
    fg_layer = Image.new("RGB", (w, h))
    alpha = Image.new("L", (w, h), 0)
    draw_fg = ImageDraw.Draw(fg_layer)
    draw_a = ImageDraw.Draw(alpha)

    cx, cy, r = 512, 520, 230
    # Hair fronds: 80 radial 1-2 px wide lines from head circumference.
    rng = random.Random(SEED + 1)
    for i in range(80):
        angle = (i / 80) * math.pi - math.pi  # top semicircle
        length = rng.randint(80, 200)
        # Slight noise on the angle.
        angle += rng.gauss(0, 0.05)
        x0 = cx + r * math.cos(angle)
        y0 = cy + r * math.sin(angle)
        x1 = cx + (r + length) * math.cos(angle)
        y1 = cy + (r + length) * math.sin(angle)
        draw_fg.line([(x0, y0), (x1, y1)], fill=(20, 20, 25), width=2)
        draw_a.line([(x0, y0), (x1, y1)], fill=255, width=2)

    # Head + shoulders.
    draw_fg.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(40, 30, 35))
    draw_a.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    sx, sy, ex, ey = 220, 720, 804, 1420
    draw_fg.rounded_rectangle([sx, sy, ex, ey], radius=120, fill=(40, 30, 35))
    draw_a.rounded_rectangle([sx, sy, ex, ey], radius=120, fill=255)

    alpha = alpha.filter(ImageFilter.GaussianBlur(radius=1.0))
    img = Image.composite(fg_layer, bg, alpha)
    return (_save(img, "portrait_complex_hair.png"),
            _save(alpha, "portrait_complex_hair.alpha.png"))


def gen_landscape_clear_sky() -> tuple[str, str]:
    """Sky top half, ground bottom half, clean horizon line."""
    w, h = 2048, 1536
    horizon = h // 2

    sky = _gradient(w, horizon, top=(110, 170, 220), bottom=(200, 220, 240))
    ground = _gradient(w, h - horizon, top=(100, 130, 70), bottom=(50, 70, 30))

    img = Image.new("RGB", (w, h))
    img.paste(sky, (0, 0))
    img.paste(ground, (0, horizon))

    # Sky mask: 1 above horizon, 0 below.
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rectangle([0, 0, w, horizon - 1], fill=255)

    return (_save(img, "landscape_clear_sky.png"),
            _save(mask, "landscape_clear_sky.sky_mask.png"))


def gen_landscape_horizon_objects() -> tuple[str, str]:
    """Landscape with triangular 'trees' sticking up into the sky.

    Reproduces the XVI.93a regression scene: pixels that LOOK skyish
    near the horizon (because of vegetation reflectance) must NOT be
    classified as sky.
    """
    w, h = 2048, 1536
    horizon = int(h * 0.55)

    sky = _gradient(w, horizon, top=(120, 180, 230), bottom=(210, 230, 245))
    ground = _gradient(w, h - horizon, top=(110, 140, 80), bottom=(40, 60, 25))

    img = Image.new("RGB", (w, h))
    img.paste(sky, (0, 0))
    img.paste(ground, (0, horizon))

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rectangle([0, 0, w, horizon - 1], fill=255)

    # Add a row of triangular 'trees' along the horizon. The mask
    # must mark these as NON-sky (we erase them from the sky band).
    draw_img = ImageDraw.Draw(img)
    draw_mask = ImageDraw.Draw(mask)
    tree_count = 7
    spacing = w / tree_count
    for i in range(tree_count):
        cx = int(spacing * (i + 0.5))
        top_y = horizon - 140 - (i % 3) * 40
        base_half = 80
        tri = [(cx, top_y), (cx - base_half, horizon), (cx + base_half, horizon)]
        draw_img.polygon(tri, fill=(35, 60, 30))
        draw_mask.polygon(tri, fill=0)

    # Also add a brightly-coloured flower row near horizon (yellow/red
    # patches whose pixel brightness can fool a sky heuristic).
    flower_y = horizon - 30
    for x in range(0, w, 80):
        draw_img.ellipse([x, flower_y, x + 30, flower_y + 30],
                          fill=(220, 200, 90))

    return (_save(img, "landscape_horizon_objects.png"),
            _save(mask, "landscape_horizon_objects.sky_mask.png"))


def gen_clean_and_noisy_grid() -> tuple[str, str]:
    """Clean reference + noisy version for Reduce-Noise tests."""
    w, h = 1024, 1024
    clean = _gradient(w, h, top=(200, 200, 200), bottom=(80, 80, 80))
    _draw_grid(clean, step=64, line_colour=(40, 40, 40))
    # Add some "structure": coloured circles.
    draw = ImageDraw.Draw(clean)
    for i, c in enumerate([(220, 80, 80), (80, 200, 100), (90, 100, 220)]):
        cx = 200 + i * 300
        draw.ellipse([cx - 80, 320, cx + 80, 480], fill=c, outline=(20, 20, 20),
                     width=3)

    noisy = _add_gaussian_noise(clean, sigma=20.0)
    return (_save(clean, "clean_grid.png"),
            _save(noisy, "noisy_grid.png"))


def gen_sharp_and_blurred_grid() -> tuple[str, str]:
    """Sharp reference + blurred version for AI Deblur tests."""
    w, h = 1024, 1024
    sharp = Image.new("RGB", (w, h), (245, 245, 245))
    _draw_grid(sharp, step=48, line_colour=(20, 20, 20))
    draw = ImageDraw.Draw(sharp)
    # Text-like blocks with hard edges.
    for r in range(6):
        for c in range(6):
            x0 = 60 + c * 150
            y0 = 60 + r * 150
            draw.rectangle([x0, y0, x0 + 100, y0 + 100],
                            fill=(60 + r * 20, 80 + c * 20, 120))

    blurred = sharp.filter(ImageFilter.GaussianBlur(radius=2.0))
    return (_save(sharp, "sharp_grid.png"),
            _save(blurred, "blurred_grid.png"))


def gen_multi_subject() -> str:
    """Three distinct shapes for MobileSAM tap tests."""
    w, h = 1024, 1024
    img = Image.new("RGB", (w, h), (240, 235, 220))
    draw = ImageDraw.Draw(img)
    # Circle top-left, square top-right, triangle bottom-centre.
    draw.ellipse([100, 100, 400, 400], fill=(220, 90, 90),
                 outline=(60, 20, 20), width=4)
    draw.rectangle([624, 100, 924, 400], fill=(100, 180, 220),
                   outline=(20, 60, 80), width=4)
    draw.polygon([(512, 600), (300, 920), (724, 920)],
                 fill=(120, 200, 100), outline=(40, 70, 30))
    return _save(img, "multi_subject.png")


def gen_object_on_clutter() -> tuple[str, str]:
    """Central object + cluttered background; mask = object region."""
    w, h = 1024, 1024
    rng = random.Random(SEED + 2)
    img = Image.new("RGB", (w, h), (200, 200, 200))
    draw = ImageDraw.Draw(img)
    # Background clutter: many small random rectangles.
    for _ in range(180):
        x0 = rng.randint(0, w - 40)
        y0 = rng.randint(0, h - 40)
        sz = rng.randint(20, 80)
        col = (rng.randint(80, 230), rng.randint(80, 230), rng.randint(80, 230))
        draw.rectangle([x0, y0, x0 + sz, y0 + sz], fill=col)

    # Central object: blue circle 350 px diameter.
    cx, cy, r = 512, 512, 175
    draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                 fill=(40, 80, 200), outline=(10, 30, 80), width=6)

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return (_save(img, "object_on_clutter.png"),
            _save(mask, "object_on_clutter.object_mask.png"))


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------


def build_manifest(assets: dict) -> None:
    manifest = {
        "version": 1,
        "generatedBy": "scripts/generate_test_corpus.py",
        "seed": SEED,
        "notes": (
            "Synthetic corpus for the deterministic CI gate (Tier 1). "
            "Real Unsplash CC0 photos with hand-painted ground truth land "
            "in a follow-up (B2b)."
        ),
        "images": [
            {
                "id": "portrait_silhouette",
                "path": assets["portrait_silhouette"][0],
                "width": 1024,
                "height": 1536,
                "category": "portrait",
                "groundTruth": {
                    "alpha": assets["portrait_silhouette"][1],
                },
                "expectedOps": [
                    "bg_removal", "face_restore", "compose_on_bg",
                ],
            },
            {
                "id": "portrait_complex_hair",
                "path": assets["portrait_complex_hair"][0],
                "width": 1024,
                "height": 1536,
                "category": "portrait_complex",
                "groundTruth": {
                    "alpha": assets["portrait_complex_hair"][1],
                },
                "expectedOps": [
                    "bg_removal",
                ],
                "notes": "Hair-detail matte stress test.",
            },
            {
                "id": "landscape_clear_sky",
                "path": assets["landscape_clear_sky"][0],
                "width": 2048,
                "height": 1536,
                "category": "landscape",
                "groundTruth": {
                    "sky_mask": assets["landscape_clear_sky"][1],
                },
                "expectedOps": [
                    "sky_replace", "smart_crop",
                ],
            },
            {
                "id": "landscape_horizon_objects",
                "path": assets["landscape_horizon_objects"][0],
                "width": 2048,
                "height": 1536,
                "category": "landscape_complex",
                "groundTruth": {
                    "sky_mask": assets["landscape_horizon_objects"][1],
                },
                "expectedOps": [
                    "sky_replace",
                ],
                "notes": (
                    "Reproduces the XVI.93a regression scene: trees + "
                    "flowers along the horizon. Sky mask must NOT leak "
                    "into vegetation."
                ),
            },
            {
                "id": "clean_grid",
                "path": assets["clean_and_noisy_grid"][0],
                "width": 1024,
                "height": 1024,
                "category": "reference_clean",
                "groundTruth": {
                    "noisy_variant": assets["clean_and_noisy_grid"][1],
                },
                "expectedOps": [
                    "reduce_noise_identity",
                ],
                "notes": "Reduce-noise on a clean image must NOT soften it.",
            },
            {
                "id": "noisy_grid",
                "path": assets["clean_and_noisy_grid"][1],
                "width": 1024,
                "height": 1024,
                "category": "reference_noisy",
                "groundTruth": {
                    "clean_reference": assets["clean_and_noisy_grid"][0],
                },
                "expectedOps": [
                    "reduce_noise_recovery",
                ],
                "notes": "Reduce-noise must recover ~30 dB PSNR vs clean.",
            },
            {
                "id": "sharp_grid",
                "path": assets["sharp_and_blurred_grid"][0],
                "width": 1024,
                "height": 1024,
                "category": "reference_sharp",
                "groundTruth": {
                    "blurred_variant": assets["sharp_and_blurred_grid"][1],
                },
                "expectedOps": [
                    "deblur_identity",
                ],
                "notes": "AI Deblur on a sharp image must NOT soften it.",
            },
            {
                "id": "blurred_grid",
                "path": assets["sharp_and_blurred_grid"][1],
                "width": 1024,
                "height": 1024,
                "category": "reference_blurred",
                "groundTruth": {
                    "sharp_reference": assets["sharp_and_blurred_grid"][0],
                },
                "expectedOps": [
                    "deblur_recovery",
                ],
                "notes": "AI Deblur must raise Laplacian variance ≥1.3x.",
            },
            {
                "id": "multi_subject",
                "path": assets["multi_subject"],
                "width": 1024,
                "height": 1024,
                "category": "multi_subject",
                "groundTruth": {
                    "tap_points": [
                        {"label": "circle",   "x": 250, "y": 250},
                        {"label": "square",   "x": 774, "y": 250},
                        {"label": "triangle", "x": 512, "y": 800},
                    ],
                },
                "expectedOps": [
                    "mobile_sam_tap",
                ],
            },
            {
                "id": "object_on_clutter",
                "path": assets["object_on_clutter"][0],
                "width": 1024,
                "height": 1024,
                "category": "inpaint",
                "groundTruth": {
                    "object_mask": assets["object_on_clutter"][1],
                },
                "expectedOps": [
                    "inpaint",
                ],
            },
        ],
    }
    path = OUT_DIR / "manifest.json"
    with path.open("w") as f:
        json.dump(manifest, f, indent=2)
    print(f"  wrote {path.relative_to(ROOT).as_posix()}")


def main() -> None:
    _ensure_out()
    print(f"Generating synthetic test corpus into {OUT_DIR}")
    assets = {
        "portrait_silhouette": gen_portrait_silhouette(),
        "portrait_complex_hair": gen_portrait_complex_hair(),
        "landscape_clear_sky": gen_landscape_clear_sky(),
        "landscape_horizon_objects": gen_landscape_horizon_objects(),
        "clean_and_noisy_grid": gen_clean_and_noisy_grid(),
        "sharp_and_blurred_grid": gen_sharp_and_blurred_grid(),
        "multi_subject": gen_multi_subject(),
        "object_on_clutter": gen_object_on_clutter(),
    }
    build_manifest(assets)
    print("Done.")


if __name__ == "__main__":
    main()
