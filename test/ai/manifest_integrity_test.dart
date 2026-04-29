import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:image_editor/ai/models/model_manifest.dart';

/// Integrity tests for the shipped `assets/models/manifest.json`.
///
/// Phase IV.9's goal was to pin real sha256 hashes for every
/// downloadable model so the post-download verification gate actually
/// rejects tampered payloads. This file locks in that state:
///
///   - Every **pinned** downloadable has a 64-char lowercase hex sha256.
///   - Every remaining PLACEHOLDER lives in the explicit deferred
///     allow-list and is justified by an upstream block that IMPROVEMENTS
///     tracks.
///   - Bundled entries may carry PLACEHOLDER sha256 — the integrity
///     model for bundled models is "assets are content-addressed by
///     Flutter, so a rogue asset can't slip in without rebuilding the app."
///
/// Future pins just shrink the allow-list. A new downloadable that
/// sneaks in with PLACEHOLDER sha256 fails this test immediately.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Models that are expected to still carry a PLACEHOLDER sha256.
  /// Each entry must be justified — when the deferred reason clears,
  /// remove the entry and the pinning-completeness check starts
  /// enforcing it.
  ///
  /// Phase XIII.7 resolved the `magenta_style_transfer` deferral:
  /// the model was fetched from Kaggle's API v1 tar.gz endpoint,
  /// unpacked manually, and now ships as a bundled asset with a
  /// real sha256. The entry stayed in this allow-list through IV.9
  /// → XII; removing it now that the tflite is in assets/models/
  /// bundled/magenta_style_transfer_int8.tflite.
  ///
  /// Phase XVI.50 adds `dncnn_color_int8`: the AI-tier denoiser
  /// substitutes for FFDNet per the user's XVI.50 model selection.
  /// The architecture (service + AdjustmentKind + AI-coord wiring)
  /// is shipped, but the URL + sha256 are deferred until a specific
  /// community ONNX export is verified end-to-end. Drop this entry
  /// when both URL and hash are filled in `assets/models/manifest.json`.
  ///
  /// Phase XVI.51 adds `migan_512_fp32`: the MI-GAN mobile inpaint
  /// strategy lives alongside LaMa as the "Fast" picker tier. The
  /// architecture is in place; the URL + sha256 await verification
  /// of the Sanster/MIGAN HuggingFace export the manifest comment
  /// points at.
  ///
  /// Phase XVI.52 adds `segformer_b0_ade20k_512_int8`: the SegFormer
  /// sky segmenter sits alongside the bundled DeepLabV3 ADE20K model
  /// as a "high quality" sky-detection toggle. URL + sha256 await
  /// verification of the onnx-community export.
  ///
  /// Phase XVI.53 adds `real_esrgan_x2_fp16`: Real-ESRGAN-x2plus
  /// drives the "Enhance 2× (Fast)" default super-res tier alongside
  /// the existing x4 service. URL + sha256 await verification of
  /// the onnx-community export.
  ///
  /// Phase XVI.54 adds `harmonizer_eccv_2022`: the Harmonizer
  /// white-box filter regressor plugs into compose-on-bg as the AI
  /// harmonisation tier. Local plan called for bundled but
  /// OrtRuntime doesn't yet support bundled ONNX; downloaded for
  /// now. URL + sha256 await verification of an ONNX export of the
  /// ZHKKKe/Harmonizer PyTorch weights.
  ///
  /// Phase XVI.55 adds `nafnet_32_deblur_fp16`: the NAFNet-32
  /// deblur model (Chen 2022, ECCV) drives the AI sharpen tier in
  /// the Detail panel. Picked over MIMO-UNet+ on quality (33.71 dB
  /// GoPro PSNR vs 32.45). URL + sha256 await verification of the
  /// onnx-community/NAFNet-32-deblur-FP16 export.
  ///
  /// Phase XVI.56 adds `restoreformer_pp_fp16`: the RestoreFormer++
  /// face restoration model (Wang 2023). Lighter cousin of
  /// GFPGAN/CodeFormer at ~75 MB FP16 — close to GFPGAN's quality on
  /// mild-to-moderate face degradation. URL + sha256 await
  /// verification of the community ONNX export.
  const deferredDownloadables = <String>{
    'dncnn_color_int8',
    'migan_512_fp32',
    'segformer_b0_ade20k_512_int8',
    'real_esrgan_x2_fp16',
    'harmonizer_eccv_2022',
    'nafnet_32_deblur_fp16',
    'restoreformer_pp_fp16',
  };

  group('manifest.json — sha256 pinning integrity', () {
    late ModelManifest manifest;

    setUpAll(() async {
      final raw = await rootBundle.loadString('assets/models/manifest.json');
      manifest = ModelManifest.parse(raw);
    });

    test('every downloadable has a pinned sha256 OR is deferred', () {
      final unpinned = manifest.downloadable
          .where((d) => d.sha256.startsWith('PLACEHOLDER'))
          .map((d) => d.id)
          .toSet();
      expect(
        unpinned,
        equals(deferredDownloadables),
        reason: 'downloadable models must pin a real sha256 — placeholder '
            'entries must live in `deferredDownloadables` with a justifying '
            'comment (Phase IV.9).',
      );
    });

    test('pinned sha256 values are 64-char lowercase hex', () {
      final hexChars = RegExp(r'^[0-9a-f]{64}$');
      for (final d in manifest.downloadable) {
        if (d.sha256.startsWith('PLACEHOLDER')) continue;
        expect(hexChars.hasMatch(d.sha256), isTrue,
            reason: '${d.id}: sha256 "${d.sha256}" is not 64-char lowercase hex');
      }
    });

    test('pinned models expose a non-empty download URL', () {
      for (final d in manifest.downloadable) {
        if (d.sha256.startsWith('PLACEHOLDER')) continue;
        expect(d.url, isNotNull,
            reason: '${d.id}: pinned but url is null — nothing to verify against');
        expect(d.url, isNotEmpty,
            reason: '${d.id}: pinned but url is empty');
      }
    });

    test('pinned byte sizes are positive', () {
      for (final d in manifest.downloadable) {
        if (d.sha256.startsWith('PLACEHOLDER')) continue;
        expect(d.sizeBytes, greaterThan(0),
            reason: '${d.id}: pinned sizeBytes must be positive');
      }
    });

    test('ids are unique across the entire manifest', () {
      final ids = manifest.descriptors.map((d) => d.id).toList();
      final unique = ids.toSet();
      expect(ids.length, unique.length,
          reason: 'duplicate model id in manifest.json: ${ids..sort()}');
    });

    test('deferred allow-list stays disjoint from pinned set', () {
      // Catches a hand-edit mistake: adding a model to the allow-list
      // at the same time it's pinned in the manifest would silently
      // leave a dead entry in the allow-list. Keep the two accurate.
      for (final id in deferredDownloadables) {
        final d = manifest.byId(id);
        expect(d, isNotNull,
            reason: 'deferredDownloadables contains "$id" but it is not in '
                'the manifest — remove the entry or restore the model.');
        expect(d!.sha256.startsWith('PLACEHOLDER'), isTrue,
            reason: '"$id" is in deferredDownloadables but its sha256 is '
                'pinned — drop it from the allow-list.');
      }
    });

    test('LaMa + RMBG + modnet + real_esrgan_x4 are pinned (Phase I.5 + IV.9)',
        () {
      // Explicit per-model regression target. Phase I.5 landed the
      // first two; Phase IV.9 landed the second two. A silent
      // unpinning of any of them must trip this test.
      for (final id in const [
        'lama_inpaint',
        'rmbg_1_4_int8',
        'modnet',
        'real_esrgan_x4',
      ]) {
        final d = manifest.byId(id);
        expect(d, isNotNull, reason: 'missing manifest entry for $id');
        expect(d!.sha256.startsWith('PLACEHOLDER'), isFalse,
            reason: '$id must remain pinned — the verification gate '
                'depends on it.');
        expect(d.sha256.length, 64,
            reason: '$id sha256 has unexpected length ${d.sha256.length}');
      }
    });
  });
}
