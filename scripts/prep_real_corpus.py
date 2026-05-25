#!/usr/bin/env python3
"""
XVI.99 — Prepare a real-photo entry in the AI Test Lab corpus.

The synthetic corpus (B2) is too easy to reproduce on-device AI
regressions; this script wires a real user-supplied photo into the
lab with a derived ground-truth sky mask so the Tier-1 gate can
actually grade ops against the failure scenes the user reports.

Run:
    python3 scripts/prep_real_corpus.py \
        --input  assets/test_images/real/IMG.jpeg \
        --id     tulip_bench_portrait \
        --sky-top-fraction 0.40 \
        --max-dim 2048

Produces, in `assets/test_images/real/`:
    <id>.png             — resized RGB copy (long edge ≤ --max-dim)
    <id>.sky_mask.png    — derived binary sky mask (255 = sky, 0 = not)

The script also emits a JSON snippet on stdout that the developer
pastes into the lab test's hard-coded fixture list — we keep this
out of the bundled assets manifest because real-photo entries are
gitignored.

Sky-mask derivation:
    For each pixel (x, y) in the resized image, mark as sky when
    y < sky_top_fraction * height
        AND blueness ≥ 0.05      (B clearly above max(R, G))
        AND brightness ≥ 0.35    (mean RGB above mid-low)
    Then run a small morphological close (5×5 dilate then erode) to
    fill the per-pixel pinholes that the colour heuristic leaves
    around clouds + haze. The result is a conservative mask: every
    pixel below the horizon constraint, every mountain pixel, and
    every tulip pixel is marked as NOT sky — which is exactly what
    we need for false-positive-rate measurement.

    Pass --review to also dump `<id>.preview.png`, a 3-panel
    side-by-side (source / mask / source-multiplied-by-mask) so you
    can eyeball-verify the GT before relying on it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageFilter


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", required=True, type=Path,
                   help="Source photo path (jpg / jpeg / png / heic).")
    p.add_argument("--id", required=True,
                   help="Stable id used in the lab test's fixture map.")
    p.add_argument("--max-dim", type=int, default=2048,
                   help="Resize so the long edge is at most this many "
                        "pixels. Default 2048 — keeps tests fast while "
                        "preserving the failure mode.")
    p.add_argument("--sky-top-fraction", type=float, default=0.40,
                   help="Mark only pixels in the top fraction of the "
                        "frame as candidate sky. 0.40 = upper 40 %% of "
                        "the resized image. Tune per-photo.")
    p.add_argument("--blueness-threshold", type=float, default=0.05,
                   help="Min normalised blueness (B - max(R,G))/255 for "
                        "a candidate sky pixel.")
    p.add_argument("--brightness-threshold", type=float, default=0.35,
                   help="Min mean-RGB/255 for a candidate sky pixel. "
                        "Filters out dark mountain silhouettes.")
    p.add_argument("--review", action="store_true",
                   help="Also dump a 3-panel preview PNG for eyeball-"
                        "verification.")
    p.add_argument("--out-dir", type=Path,
                   default=Path("assets/test_images/real"),
                   help="Where to write the resized source + mask.")
    return p.parse_args()


def resize(im: Image.Image, max_dim: int) -> Image.Image:
    w, h = im.size
    long_edge = max(w, h)
    if long_edge <= max_dim:
        return im.convert("RGB")
    scale = max_dim / long_edge
    nw = round(w * scale)
    nh = round(h * scale)
    return im.convert("RGB").resize((nw, nh), Image.LANCZOS)


def build_sky_mask(im: Image.Image, *, sky_top_fraction: float,
                   blueness_threshold: float,
                   brightness_threshold: float) -> Image.Image:
    w, h = im.size
    top_cutoff = int(h * sky_top_fraction)
    px = im.load()
    mask = Image.new("L", (w, h), 0)
    out = mask.load()
    for y in range(top_cutoff):
        for x in range(w):
            r, g, b = px[x, y]
            max_rg = r if r > g else g
            blueness = (b - max_rg) / 255
            brightness = (r + g + b) / (3 * 255)
            if (blueness >= blueness_threshold
                    and brightness >= brightness_threshold):
                out[x, y] = 255
    # 5×5 close to plug haze pinholes near the horizon. We're not
    # aiming for surgical precision — the mask just needs to be
    # right about "tulip ≠ sky" and "bench ≠ sky".
    mask = mask.filter(ImageFilter.MaxFilter(5))
    mask = mask.filter(ImageFilter.MinFilter(5))
    return mask


def write_preview(source: Image.Image, mask: Image.Image,
                  out_path: Path) -> None:
    w, h = source.size
    masked = Image.new("RGB", (w, h), (0, 0, 0))
    masked.paste(source, mask=mask)
    panel = Image.new("RGB", (w * 3, h), (40, 40, 40))
    panel.paste(source, (0, 0))
    panel.paste(mask.convert("RGB"), (w, 0))
    panel.paste(masked, (w * 2, 0))
    panel.thumbnail((3000, 1500), Image.LANCZOS)
    panel.save(out_path, optimize=True)
    print(f"  wrote preview {out_path}")


def main() -> None:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    src = Image.open(args.input)
    src.load()
    print(f"loaded {args.input}  mode={src.mode} size={src.size}")
    sized = resize(src, args.max_dim)
    print(f"resized to {sized.size}")
    mask = build_sky_mask(
        sized,
        sky_top_fraction=args.sky_top_fraction,
        blueness_threshold=args.blueness_threshold,
        brightness_threshold=args.brightness_threshold,
    )
    coverage = sum(1 for p in mask.getdata() if p > 0) / (mask.width
                                                          * mask.height)
    print(f"sky_mask coverage = {coverage:.4f}")
    src_out = args.out_dir / f"{args.id}.png"
    mask_out = args.out_dir / f"{args.id}.sky_mask.png"
    sized.save(src_out, optimize=True)
    mask.save(mask_out, optimize=True)
    print(f"  wrote {src_out}")
    print(f"  wrote {mask_out}")
    if args.review:
        write_preview(sized, mask,
                      args.out_dir / f"{args.id}.preview.png")
    snippet = {
        "id": args.id,
        "path": str(src_out),
        "width": sized.width,
        "height": sized.height,
        "category": "real_landscape",
        "groundTruth": {
            "sky_mask": str(mask_out),
        },
        "expectedOps": ["sky_replace"],
        "notes": (
            "Real-photo lab fixture (gitignored). Source: user-supplied. "
            "Sky mask derived by scripts/prep_real_corpus.py."
        ),
    }
    print("\n--- Add to lab fixture map ---")
    print(json.dumps(snippet, indent=2))


if __name__ == "__main__":
    main()
