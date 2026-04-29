# Bake `assets/presets/preset_embeddings.json` (Phase XVI.66c)

Runs MobileViT-v2 over a synthesised reference image per preset
category and writes the resulting L2-normalised embeddings into
`assets/presets/preset_embeddings.json` so the runtime "For You"
preset rail can rank built-in presets by cosine similarity to the
user's photo.

## One-shot run

```bash
cd scripts/bake_preset_embeddings
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python bake.py
```

`bake.py` reads `lib/engine/presets/built_in_presets.dart` to discover
every `(presetId, category)` pair, synthesises one PIL reference image
per canonical category, runs MobileViT-v2-1.0 once per category, and
assigns each preset its category's embedding. Re-run after adding a
built-in preset; the JSON is byte-stable across runs (deterministic
PIL primitives + a fixed-seed grain RNG).

## Why one embedding per category, not per preset

Every built-in preset is intentionally aimed at one of the canonical
categories (`popular | portrait | landscape | film | bw | bold`).
Using a single reference per category keeps the bake reproducible
and fast (~1s on a phone-class CPU) without needing 28 distinct
photographic references stashed in the repo. The runtime kNN
collapses to a "category match" suggester — when the user's photo
embeds closer to landscape than to portrait, every landscape-category
preset surfaces.

If you want per-preset distinguishability (e.g. ranking individual
landscape presets by similarity), drop a real photo per preset into
`scripts/bake_preset_embeddings/references/<presetId>.jpg` and
modify `bake.py`'s `_reference_for` to prefer that file over the
synthesised category reference. The output JSON schema doesn't
change.

## Output

`assets/presets/preset_embeddings.json` matching `PresetEmbeddingLibrary.parse`:

```json
{
  "version": 1,
  "modelId": "mobilevit_v2_1_0_fp32",
  "embeddingDim": <encoder output size>,
  "entries": [
    {"presetId": "builtin.natural", "embedding": [0.012, -0.043, ...]},
    ...
  ]
}
```

The JSON is bundled into the app via the existing
`assets/presets/` declaration in `pubspec.yaml`.
