# AI Test Strategy 2026 — Validating AI Ops Before Commit

**Status:** Strategy. Implementation tracked as Deliverables B–D in
`docs/editor_audit_plan.md` (XVI.94+).

**Why this doc exists.** The XVI.78–XVI.93 streak shipped 16 commits in
one session; roughly half did not actually fix the reported problem on
first device test. The pattern was always the same: form a hypothesis
from the code, ship a fix, learn from the device that it was wrong or
regressed. `flutter test` only covers pure-Dart helpers — the real
ONNX/LiteRT inference, the CoreML compile, and the Skia composite only
exist on device. So we ship blind, the user tests, and we ship blind
again. The XVI.93a sky-mask guided filter is the smoking gun: device
log showed `beforeCoverage=0.453 → afterCoverage=0.531` — the fix
expanded the mask we were trying to tighten. Nothing in our test
harness could have caught that.

This document defines a quality validation loop we run **before**
calling an AI fix "done."

---

## 1 · Metric survey

Five families of metric matter for what we ship:

| Family | Examples | What it measures | When to use |
|---|---|---|---|
| Full-reference pixel | PSNR, MSE | Per-pixel fidelity vs a known good | Identity-preserving ops on clean input ("denoise on clean photo should not move pixels much") |
| Full-reference perceptual | SSIM, LPIPS, DISTS | Human-perceived similarity | Restoration ops where pixel-exact is too strict (face restore, deblur, harmonize) |
| Reference-free sharpness | Laplacian variance, NIQE, BRISQUE | How "in focus" / "natural" the output is | Sharpen / deblur / denoise side-effect check |
| Mask agreement | Mask IoU, Boundary IoU, matting SAD/Grad | Segmentation correctness | BG removal, sky replace, selfie segmenter, MobileSAM |
| Behavioural | Has-output, dims-match, alpha-channel-present | Did the op produce a usable artefact at all | Smoke test for every op |

Key takeaways from the 2024-2026 literature: SSIM/PSNR are cheap and
interpretable but biased toward signal fidelity, not perception
([Snapcorn][1]). LPIPS and DISTS align better with human judgment for
restoration tasks ([PMC7817470][2]). For segmentation, plain mask IoU
under-penalises boundary errors on large objects — Boundary IoU
(Cheng et al., CVPR 2021) is the modern default ([CVPR 2021][3]).
Inpainting and matting have their own conventions: PSNR/SSIM/LPIPS
plus mask-edge metrics like Color/Texture/Edge Consistency
([Frontiers 2025][4]; [SayedNadim/Inpainting-Evaluation-Metrics][5]).
MLPerf Mobile already ships a Flutter benchmarking app
([mlcommons/mobile_app_open][6]) — useful precedent for the harness.

---

## 2 · Per-op metric assignment + pass/fail

| Op | Primary metric | Reference-free guard | Pass criteria |
|---|---|---|---|
| AI Deblur on **sharp** input | SSIM vs input | ΔLaplacianVar ≥ 0 | SSIM ≥ 0.97 AND ΔLapVar ≥ 0 (must not soften) |
| AI Deblur on **blurry** input | ΔLaplacianVar | — | output Lap-var ≥ 1.3× input Lap-var |
| Reduce Noise on **clean** input | SSIM vs input | — | SSIM ≥ 0.96 (near-identity) |
| Reduce Noise on **noisy** input | PSNR vs clean reference | — | PSNR ≥ 30 dB and SSIM ≥ 0.85 |
| Face Restore (CodeFormer) | LPIPS vs input (within face crop) | NIQE | LPIPS ≤ 0.25, no NIQE regression |
| BG Removal (every tier) | Boundary IoU vs hand-painted alpha | — | IoU ≥ 0.85, Boundary IoU ≥ 0.70 |
| Sky Replace | Mask coverage vs labeled sky | Δ in non-sky region | coverage within ±5 % of label; ≤ 0.5 % pixels outside label changed colour by > 5/255 |
| Smart Crop | Subject-bbox containment | — | crop contains 100 % of labeled subject AND area ≤ 1.3× subject bbox |
| MobileSAM tap-to-segment | Boundary IoU vs hand-painted mask | — | IoU ≥ 0.80 per tap |
| Inpaint (LaMa / MI-GAN) | LPIPS in mask + ECON across seam | — | LPIPS ≤ 0.30, no visible seam (ECON ≤ 0.05) |
| Compose-on-BG (harmoniser) | Colour-stat match (mean/std) | LPIPS | ΔLab mean ≤ 5, ΔLab std ≤ 3 |
| Style transfer | LPIPS bound vs input | — | LPIPS in (0.2, 0.6) — moved enough but not destroyed |

Reference-free guards (Laplacian variance, NIQE) are tie-breakers when
no ground truth exists. The over-arching rule: **no AI op may regress
its primary metric beyond 5 % vs the last green run** without an
explicit waiver in the commit message.

---

## 3 · Test corpus design

Bundle under `assets/test_images/` (or download on first lab visit if
> 30 MB). All sources Unsplash CC0 or generated.

| Category | Count | Resolution | Purpose |
|---|---|---|---|
| Portraits — clean hair | 2 | 4K | RMBG / MODNet / RVM / U²-Netp / face restore |
| Portraits — complex hair (curls/strands) | 2 | 4K | Matte boundary stress, guided-filter validation |
| Landscapes — clear sky + horizon | 2 | 4K | Sky replace ground truth (one with flowers near horizon → the XVI.93 regression scene) |
| Landscapes — overcast / sunset sky | 1 | 4K | Sky-replace edge case |
| Low-light noisy photo | 2 | full | Reduce-noise positive case |
| Motion-blurred / defocused | 2 | full | AI Deblur positive case |
| Multi-subject street scene | 1 | 4K | MobileSAM tap test (multiple targets) |
| Object-on-clutter | 1 | 4K | Inpaint (remove the object) |

For BG removal, sky replace, and SAM, ship **hand-painted alpha mattes
/ binary masks alongside each image** (`portrait_clean_01.png` +
`portrait_clean_01.alpha.png`). These are the ground truth that
mask-IoU / Boundary-IoU compare against.

For Reduce Noise positive cases, capture clean→noisy pairs (or add
synthetic Gaussian noise at known σ) so a PSNR-vs-clean reference
exists.

---

## 4 · Lab architecture

Route `/dev/ai-test-lab`, gated behind `kDebugMode || envFlag`. Three
panes:

1. **Image carousel** — bundled corpus + metadata (resolution, has-alpha,
   labeled-mask path, expected category).
2. **Op picker** — every AI op (BG removal × 5 tiers, Deblur, Reduce
   Noise, Face Restore, Inpaint × 2, Smart Crop, Sky Replace,
   MobileSAM, Compose-on-BG, Harmoniser).
3. **Run controls** — "Run this op on this image", "Run this op on all
   images", "Run all ops on this image", "Run full matrix".

Results pane: before / after with a swipe slider, the computed metric
value, and a colour chip (green = pass, amber = within 5 % of
threshold, red = fail). Each run writes a JSON record to
`getApplicationSupportDirectory()/ai_lab/runs/<ts>.json` containing
{op, image, params, metric values, pass/fail}, plus a thumbnail of
the output. The lab indexes those records so we can diff a new run
against the last green run for that op+image.

**Implementation choice:** pure-Flutter, in-app. Avoids the simulator
flakiness MLPerf's mobile app fights with. Runs on the same device
the user runs the editor on — so the inference path, the CoreML
compile, the Skia composite, and the memory ceiling are all the real
production stack. Trades CI-friendliness for fidelity; we make up for
the lost CI gate with a manual checklist (Deliverable D).

---

## 5 · Commit-flow integration — tiered

Split the gate by what the metric actually needs to run:

**Tier 1 — deterministic, run on CI** (simulator, no GPU needed):
Mask IoU, Boundary IoU, PSNR, SSIM, matting SAD/Grad/Conn, behavioural
"has-output" / "dims-match" / "alpha-present" smoke tests, Laplacian
variance. These are pure numerical comparisons against bundled
ground-truth assets — they don't depend on CoreML, GPU acceleration,
or perceptual networks. Wire into `integration_test/` and `flutter
test integration_test` so every push runs the segmentation matrix.

**Tier 2 — perceptual, run manually on real device** (developer loop):
LPIPS, DISTS, NIQE, BRISQUE, harmoniser colour-stat checks. These
either pull a perceptual network (LPIPS / DISTS) we don't want
spinning up on every CI run, or depend on natural-scene statistics
that simulator-rendered output can falsify. Run via `/dev/ai-test-lab`
on the device after each AI-touching change; paste the result table
into the commit message under a `Lab:` trailer.

`scripts/run-ai-lab.sh` orchestrates both:

1. Builds + runs the deterministic CI matrix (Tier 1), exits non-zero
   on regression.
2. Prints the Tier 2 manual checklist for the developer to run on
   device, formatted so the output drops cleanly into the commit
   message.

Pre-commit hook (opt-in via `.git/hooks/pre-commit`) detects whether
any file under `lib/ai/services/` or `lib/ai/inference/` was touched;
if so it requires (a) Tier 1 CI green AND (b) a `Lab:` trailer with
Tier 2 results — refuses the commit otherwise.

**Mandatory protocol going forward** (replaces the XVI.78–93 ship-then-pray
loop):

1. Code change.
2. `flutter analyze && flutter test` — green.
3. `flutter test integration_test` (Tier 1) — green.
4. Open `/dev/ai-test-lab` on device, run the affected op (Tier 2).
5. **Commit only if every affected metric passes** (or document the
   regression + waiver in the commit body).
6. Push.

---

## 6 · Phased delivery

| Phase | Deliverable | Exit criteria |
|---|---|---|
| A (this doc) | strategy + thresholds | user sign-off |
| B (XVI.94–96) | lab screen + corpus + metric impls | matrix runnable end-to-end on device |
| C (XVI.97) | baseline run against current main | pass/fail table in `docs/ai_lab_baseline_2026-05.md` |
| D (XVI.98) | commit-flow integration | first lab-gated AI fix lands |

After C lands, the **fix priority queue is reordered by what the lab
finds failing** — not by the XVI.81 audit tiering (which assumed each
op worked correctly).

---

## Sources

- [Eureka PatSnap — Perceptual Metrics Face-Off: LPIPS vs SSIM vs PSNR][1]
- [PMC — Comparison of Full-Reference Image Quality Models][2]
- [Cheng et al., CVPR 2021 — Boundary IoU][3]
- [Frontiers 2025 — High-Resolution Image Inpainting Evaluation][4]
- [SayedNadim/Inpainting-Evaluation-Metrics][5]
- [mlcommons/mobile_app_open — MLPerf Mobile, Flutter implementation][6]
- [arXiv 2410.10488 — No-Reference Sharpness Metric, 2024][7]
- [arXiv 2103.16562 — Boundary IoU paper][3]
- [vibe-studio.ai — Flutter golden tests + screenshot diffs][8]

[1]: https://eureka.patsnap.com/article/perceptual-metrics-face-off-lpips-vs-ssim-vs-psnr
[2]: https://pmc.ncbi.nlm.nih.gov/articles/PMC7817470/
[3]: https://openaccess.thecvf.com/content/CVPR2021/papers/Cheng_Boundary_IoU_Improving_Object-Centric_Image_Segmentation_Evaluation_CVPR_2021_paper.pdf
[4]: https://www.frontiersin.org/journals/artificial-intelligence/articles/10.3389/frai.2025.1614608/full
[5]: https://github.com/SayedNadim/Inpainting-Evaluation-Metrics
[6]: https://github.com/mlcommons/mobile_app_open
[7]: https://arxiv.org/html/2410.10488v1
[8]: https://vibe-studio.ai/insights/flutter-widget-testing-best-practices-golden-tests-and-screenshot-diffs
