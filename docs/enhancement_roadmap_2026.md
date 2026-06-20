# Enhancement Roadmap — 2026 SOTA Upgrades & New Capabilities

Companion to `docs/release_audit_2026.md` (blockers + test plan). This doc =
**how every feature can be improved, and what to add**, grounded in
2025–2026 state-of-the-art, with **mobile-export availability and license
verified at source** (we got burned before assuming exports exist —
every "export?" claim here is grounded in a real file/repo or flagged
"self-export / no export").

**Two hard gates applied to every recommendation:**
1. **Mobile-feasible** — a real ONNX/CoreML/TFLite export (or a clean
   self-export path), fits the iOS ~3 GB/app ceiling (model still runs
   ≤1024 per our decode-resolution pattern).
2. **License-clean** — MIT/Apache/BSD (or a knowingly-accepted exception).
   Non-commercial/GPL models are flagged 🔴 and excluded from the paid build.

**Cross-cutting export-blocker cheat-sheet** (recurring dead-ends — don't
plan on these): SSM/Mamba & RWKV ops (no CoreML/ONNX), 5D `grid_sample`
(blocks direct 3D-LUT export — use hybrid CNN+shader), diffusion at SOTA
face/bokeh/relight/photoreal quality (infeasible on phone), data-dependent
SVD (killed photo_wct2). **FP16 is the cheapest lever** — ~halves model
size near-losslessly and is often the difference between "marginal" and
"ships".

---

## TL;DR — the moves that matter, ranked by impact ÷ effort

| # | Move | Type | On-device? | License | Effort |
|---|---|---|---|---|---|
| 1 | **Auto-tone / one-tap "Auto"** via Zero-DCE++ (320 KB, CoreML-ready) | NEW (we have nothing) | ✅ | non-comm? → use as **low-light**; pair NILUT (MIT) for looks | Low |
| 2 | **Low-light / "Night" enhance** — Zero-DCE++ | NEW | ✅ | — | Low |
| 3 | **Replace the non-commercial models** (CodeFormer/RMBG/RVM) | Blocker-driven | ✅ | → permissive | Med (face = hard) |
| 4 | **Super-res upgrade** — RealPLKSR (ready ONNX) + SAFMN++ tiny tier | Drop-in | ✅ | Apache/MIT | Low |
| 5 | **Ship depth (DA2-Small, Apache) → real portrait/bokeh** | NEW headline | ✅ | Apache | Med |
| 6 | **Blind denoise** — SCUNet (handles clean input; arbitrary res) | Drop-in | ✅ | Apache-ish | Low–Med |
| 7 | **Colorization** — DDColor-tiny (download-on-demand) | NEW | ✅ | Apache | Med |
| 8 | **On-device AI assistant** — VLM → EditOperations | NEW differentiator | ✅ | OS/Apache | Med |
| 9 | **Auto-tagging + alt-text** — Florence-2 (MIT) | NEW (a11y + search) | ✅ | MIT | Low |
| 10 | **Cloud generative tier** — text inpaint + outpaint (IP-safe API) | NEW (expected) | ☁️ thin proxy | n/a | Med |

---

## Part 1 — Drop-in upgrades to EXISTING features

### 1.1 Super-resolution — **the highest-confidence win** (start here)
Current: Real-ESRGAN x2 (17 MB) + x4 (67 MB).
- **RealPLKSR** — *pre-exported ONNX x2 & x4 exist* (`darktable-org/upscale-realplksr-onnx`). SwinIR-Small-class quality at Real-ESRGAN speed, reparameterized large kernels suit on-device. **Lowest-risk upgrade in the whole roadmap — finished export, ship it.**
- **SAFMN++ / Real_SAFMN++** — few-MB, AIM-2025 efficient-SR winner; ONNX export script in-repo. Add as a "Fast / battery" tier.
- **Watch (don't build yet):** one-step diffusion SR — **OSEDiff** (proven on OPPO Find X8), **AdcSR** (CVPR'25, 9.3× faster), **NanoSD** (CVPR'26, ~20 ms on mobile NPU). All Android-NPU-first, **no iOS/CoreML export today**.

### 1.2 Background removal / matting — fix licenses + raise the ceiling
Current: MediaPipe / MODNet / U²-Netp(dead) / RVM(🔴 GPL) / RMBG-1.4(🔴 NC) / BiRefNet(hidden, iOS-OOM).
- **Drop the 🔴 tiers (RMBG-1.4, RVM).** Promote **BiRefNet (MIT)** and **U²-Net (Apache)**; keep MODNet (Apache) but **fix its 512² square squash** (use aspect-preserving target dims like RVM did).
- **New premium tier — BEN2 (MIT, ONNX 223 MB):** best trimap-free hair/edge matte available, license-clean. **Memory-gate it: run ≤768², not 1024²** (BiRefNet-family activations hit ~3.45 GB at 1024² — exactly what OOM'd our BiRefNet-Lite), then guided-upsample the alpha.
- **Alt (license caveat): RMBG-2.0** has a finished INT8 CoreML package (233 MB) and is a clear jump over RMBG-1.4 — but **requires a commercial license**; only if we pay BRIA. BEN2 is the free path.
- **Video/portrait tier:** **MatAnyone (CVPR'25)** has a real CoreML port (5 stateless modules) — sharper than RVM, replaces the GPL dependency for the hair tier (higher integration cost: stateful).

### 1.3 Inpainting / object removal — keep, add one Android tier
Current: LaMa (Apache, 208 MB) + MI-GAN (MIT, 28 MB); per-region tiling shipped (XVI.107).
- **AOT-GAN (58 MB)** — Qualcomm AI Hub ships ready **ONNX/TFLite** (LaMa-class quality, ¼ the size). **No CoreML/iOS export** — Android-only unless we self-convert. Add as an Android "sharp eraser" tier; keep tiled-MI-GAN as the iOS baseline.
- **New capability — generative erase/fill:** Apple's official **CoreML Stable-Diffusion inpainting** (6-bit palettized) is the only Apple-blessed on-device generative-inpaint path. Premium iOS-only opt-in (hundreds of MB, multi-second, prompt UX). Or do it via the cloud tier (Part 3) for cross-platform.
- **Avoid:** PixelHacker / PowerPaint / BrushNet / ZITS++ / MAT — strong on paper, **no mobile exports**.

### 1.4 Denoise / deblur — fix the over-smoothing at the root
Current: DnCNN (fixed 1024², over-smooths clean) + NAFNet deblur (1024 cap). We added a wet/dry blend as a band-aid.
- **Denoise → SCUNet (blind), FP16 ONNX** (`deepghs/image_restoration`, verified). Blind training = **behaves on near-clean input** (kills the #1 complaint) and **runs at arbitrary resolution via a 256-px tiler** (kills the 1024 cap). Same ORT path as DnCNN. Keep the wet/dry blend as a user strength.
- **Deblur → deepghs NAFNet-GoPro/REDS FP16 ONNX + tiler** — real exported weights, no 1024 cap. (Avoid EVSSM/FFTformer — Mamba/FFT ops don't export.)
- **The architecturally-correct fix for "strength":** prototype **RCD** (controllable denoise, strength 0 = identity) to replace the wet/dry hack with a true single-pass slider. Self-export; defer.

### 1.5 Face restoration — shrink + de-risk (license is the gate)
Current: CodeFormer 377 MB (🔴 **non-commercial** — blocker).
- **If we license/accept CodeFormer:** swap to **`codeformer.fp16.onnx` (189 MB)** — identical weights, ~½ size, keeps the fidelity input. Pure win on size/memory.
- **License-clean reality:** **every** quality face-restorer (CodeFormer, GFPGAN, GPEN, RestoreFormer++) traces to StyleGAN2/FFHQ/DFDNet non-commercial provenance. There is **no clean permissive drop-in at this quality** in 2026. Options: (a) drop face-restore from the paid build, (b) license CodeFormer, (c) keep the classical portrait-beauty (eye/teeth/smooth) which is already license-clean and ship that as "portrait enhance" instead. **Recommend (c) for v1, revisit (b).**
- All 2025–26 quality leaders (OSDFace, DiffBIR, HonestFace…) are 1–3 B-param diffusion → infeasible.

### 1.6 Harmonization / style transfer
Current: Harmonizer (Apache, 19 MB — keep) + Magenta style transfer (🟢 Apache but **hard 384²** → preview-quality) + photo_wct2 (dead).
- **Keep Harmonizer** (PCT-Net is +1.4 dB but has no ONNX — not worth a from-scratch port).
- **Photoreal color transfer → CAP-VSTNet (self-export):** reversible-residual, **no SVD** (unlike photo_wct2, it *can* export). Retire the low-quality Magenta path. (**Neural Preset is a dead end** — no code/weights, non-commercial.)
- If keeping Magenta: it's a stylized "filter," not a high-res result — joint-bilateral upsample its 384 output against source luma, or label it a preview/share effect.

---

## Part 2 — NEW on-device capabilities (license-clean, mobile-verified)

### 2.1 Auto-tone / one-tap "Auto" — **biggest UX win per effort; we have nothing**
Every consumer editor's most-used button; we lack it entirely.
- **Zero-DCE++ (320 KB, CoreML-ready)** — unsupervised per-pixel tone curve; brightens *without* the smoothing failure mode. One-tap "Auto" / "Low Light".
- **NILUT (<1 MB, MIT, ONNX-clean after self-export)** — implicit neural LUT; an "AI Looks" row of blendable looks in one tiny net.
- **Learned 3D-LUT (Zeng, FiveK)** via **hybrid path**: export only the CNN predictor; apply the LUT in our existing `LutAssetCache`/shader (5D `grid_sample` won't export). Full auto-retouch.

### 2.2 Low-light / night enhance — new category, models are kilobytes
- **Zero-DCE++** (same as above) as a dedicated "Low Light" op.
- **DarkIR-m (self-export, ~6.5 MB FP16)** — 2025 all-in-one denoise+deblur+low-light for night phone shots, if we want one button for dark+noisy+blurry. Higher integration cost.

### 2.3 Depth → real portrait mode / bokeh — **marquee differentiator**
Today: only a shader heuristic; the Lens Blur op is a dead control (audit C2).
- **Ship Depth-Anything V2 Small** — Apple **CoreML** variant on iOS (~17 ms ANE), or the **ONNX `model_quantized.onnx` (27.3 MB, Apache)** cross-platform. (Fix the manifest size bug.) **Don't** use DA3 yet (only 105 MB fp32 export) or Depth Pro (1.9 GB).
- **Bokeh = a pipeline, not a model:** subject mask (reuse our segmentation) → DA2 depth → joint-bilateral upsample depth vs source luma → depth→circle-of-confusion with an aperture slider → variable-radius scatter blur in the lens-blur `.frag` → **highlight-bloom pass** (the thing that separates real portrait mode from Gaussian blur). No learned bokeh model is worth the weight in 2026.

### 2.4 Colorization — real new headline feature
- **DDColor-tiny (Apache)** — self-export from `piddnad/ddcolor_paper_tiny` (220 MB `.pth`) via the official `export_onnx.py`; download-on-demand; decode at native res. (The prebuilt ONNX is the 980 MB DDColor-L — unusable. DeOldify is archived.)

### 2.5 On-device AI assistant — **the headline differentiator**
Natural-language edit commands → our parametric `EditOperation`s ("brighten the sky, remove the trash can"). This is where on-device genuinely wins in 2026 (free, private, offline) and it maps perfectly to our parametric pipeline (the VLM emits structured ops).
- **iOS:** Apple **Foundation Models** framework (~3 B on-device, free, offline; text + the Vision framework for image understanding/OCR).
- **Android:** **Gemini Nano via ML Kit GenAI** / **Gemma 3n** (MediaPipe LLM Inference with image input).
- **Cross-version fallback (bundle):** a 2–3 B VLM at int4 (~2–2.5 GB) — **Qwen2.5-VL-3B** / **SmolVLM2** (proven on iPhone) — via our existing `OrtRuntime`/ONNX pattern.

### 2.6 Auto-tagging + accessibility alt-text
- **Florence-2 (0.23 B, MIT)** — one tiny model: captioning + dense tags + grounding + OCR, structured output straight into a tag/search pipeline; slots into `OrtRuntime`. Or OS APIs (ML Kit Image Description / Apple Vision). Doubles as the a11y alt-text source (audit F1).

---

## Part 3 — Generative editing: the honest on-device-vs-cloud call

**The frontier (Gemini "Nano Banana", GPT-image, Seedream; open: Qwen-Image-Edit 28 B, FLUX.2 32 B, FLUX.1 Kontext 12 B) is cloud/data-center-only — none is phone-feasible.** On-device generation is real **only at SD-1.5-class quality** (~8 s/512 px iPhone, ~15 s Android, 6–8 GB RAM, OOM-prone, stylized-only). **Every** mainstream competitor (Google Magic Editor, Pixel Studio, Samsung Generative Edit, Adobe Firefly mobile, Photoroom) routes *generation* to the cloud — even the "on-device AI" flagships.

**Recommendation — hybrid, no GPU backend:**
- **Keep everything we have on-device** (the privacy moat).
- **Add a thin cloud "Generative tier"** for the two features 2026 buyers
  now expect and we lack: **text-prompted inpaint/fill** and
  **outpaint/expand**. Architecture: **Cloudflare Worker proxy** (hides the
  API key, meters credits; free tier ≈ $0) in front of an **IP-safe API —
  Bria** (100% licensed data, indemnified, gen-fill ~$0.03, expand ~$0.02);
  FLUX.1 Kontext / Seedream as cost alternatives. **RevenueCat** for
  subscription + consumable credits.
- **Hard requirements** before shipping generative (from the audit): Apple
  5.1.2 explicit in-app consent before any photo leaves the device; in-app
  AI-report control; input/output safety filtering; preserve C2PA/IPTC
  provenance on export.
- **Defer:** on-device SD-1.5 generative *effects* (poor effort/quality vs
  cloud) unless we specifically want an offline/free "fun" tier. Watch
  few-step on-device DiT distillations (SnapGen++/NanoFLUX class) for
  late-2026+.

**Do NOT** build/host a GPU model fleet, promise on-device photoreal
generation, or trust "on-device" marketing from Pixel/Galaxy (it's cloud).

---

## Part 4 — Suggested sequencing (after P0/P1 blockers clear)

1. **License-clean drop-ins that are also quality wins** (no new UX):
   RealPLKSR/SAFMN++ super-res, SCUNet denoise + NAFNet-export deblur,
   BiRefNet/BEN2 matting (replacing RMBG/RVM), MODNet aspect fix.
2. **Depth + real bokeh** (DA2-Small) — turns the dead Lens-Blur control
   into a marquee feature.
3. **Auto-tone + low-light** (Zero-DCE++/NILUT) — fills the most glaring
   capability gap, tiny models.
4. **Colorization** (DDColor-tiny) — a headline restoration feature.
5. **On-device AI assistant + auto-tagging/alt-text** — the differentiator
   + the a11y win, reusing our runtime + pipeline patterns.
6. **Cloud generative tier** (text inpaint + outpaint via IP-safe API) — the
   expected-by-2026 features, monetized, without compromising the privacy
   story for the on-device core.

Every model above is re-verified mobile-exportable and license-clean (or its
caveat is stated). Before integrating any, run it through the (finished) AI
Test Lab against the real corpus and gate on the metric thresholds — no more
ship-then-pray.
