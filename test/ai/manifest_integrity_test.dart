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
  /// Phase XVI.64 verified URL + sha256 for 6 of the 9 entries that
  /// XVI.50–58 left placeholder. XVI.65 then ran the
  /// `scripts/onnx_export/` convert scripts to produce + pin
  /// harmonizer_eccv_2022 (0.6 MB graph, then re-exported to 19 MB
  /// inline once the external-data-sidecar bug surfaced) and
  /// dncnn_deepinv_color_fp32 (2.7 MB inline). PhotoWCT2 stays the
  /// only deferred entry — see below.
  ///
  /// `photo_wct2_fp16` (Phase XVI.57): DEFERRED INDEFINITELY. The
  /// upstream chiutaiyin/PhotoWCT2 is TensorFlow, AND the
  /// stylization core uses `tf.linalg.svd` with a data-dependent
  /// rank truncation that can't ONNX-export to a static graph.
  /// See scripts/onnx_export/convert_photo_wct2.py header for
  /// the full reasoning and three alternative paths if this is
  /// ever revived.
  ///
  /// XVI.64 + XVI.65 cumulatively renamed four pinned entries to
  /// match what the verified public / converted exports actually
  /// are:
  ///   * `mobilevit_v2_0_5_int8` → `mobilevit_v2_1_0_fp32` (XVI.64)
  ///   * `nafnet_32_deblur_fp16` → `nafnet_deblur_2025may_fp32` (XVI.64)
  ///   * `restoreformer_pp_fp16` → `restoreformer_pp_fp32` (XVI.64)
  ///   * `dncnn_color_int8` → `dncnn_deepinv_color_fp32` (XVI.65)
  ///
  /// Phase XVI.67 added `birefnet_lite_fp32` — the BiRefNet-Lite
  /// premium matter. The manifest URL points to a likely-correct
  /// HuggingFace path; the sha256 must be filled in once the file
  /// is downloaded and verified (e.g.
  /// `shasum -a 256 <downloaded_file>`). See the manifest entry's
  /// `$comment` field for the verification process. Remove this
  /// entry from the allow-list once the hash is pinned so the
  /// strict-pinning check starts enforcing it like every other
  /// downloadable.
  ///
  /// Phase XVI.67 audit also added 7 manifest-only entries for
  /// future service implementations (per docs/model_audit_2026.md
  /// prioritised roadmap). Each one ships URL + sizeBytes as
  /// best-effort + PLACEHOLDER sha256; the verification process
  /// runs the same way as the single XVI.67 BiRefNet-Lite entry.
  /// Remove from this allow-list once the file is downloaded, the
  /// real sha256 is pinned in the manifest, and the corresponding
  /// service code lands.
  ///
  /// XVI.68 verification (web access added) pruned 4 entries that
  /// have no community ONNX export available: AOT-GAN, SAFMN, PCT-
  /// Net, and DDColor. Split mobile_sam_encoder_decoder into
  /// encoder + decoder. CodeFormer URL re-pointed to
  /// facefusion/models-3.0.0 (377 MB); YOLOv8n URL re-pointed to
  /// Kalray/yolov8 (12.8 MB). Those 4 remain unverified.
  ///
  /// XVI.71 PINNED `birefnet_lite_fp32` — re-baked locally via
  /// scripts/onnx_export/inline_onnx_model.py and hosted as a
  /// release asset on alij1991/Image_Editor_Application/releases/
  /// models-v1. The inlined copy loads with full graph
  /// optimisation on any ORT version, sidestepping the 1.23.0
  /// regression entirely. Entry removed from the allow-list so
  /// the strict sha256 enforcement applies.
  ///
  /// XVI.78a PINNED `mobile_sam_encoder` (28.2 MB, sha256
  /// 580f5fb6…) + `mobile_sam_decoder` (16.5 MB, sha256
  /// 93915fc7…) — both downloaded via direct curl + shasum from
  /// Acly/MobileSAM and verified. Services land in XVI.78b
  /// (MobileSamSegmenter — encoder runs once per image, decoder
  /// runs per tap) + XVI.78c (tap-to-segment UI in Remove
  /// Object). Encoder takes HWC fp32 at native source resolution
  /// (no fixed 1024 input — the manifest's previous schema note
  /// was wrong; corrected XVI.78a after probing the .onnx
  /// directly).
  ///
  /// XVI.79a PINNED `codeformer_fp32` (377 MB, sha256
  /// 21710e7a…) after a Python probe of the facefusion export
  /// confirmed the model produces real face-restoration output
  /// (test input: solid pink rectangle → output recognisably
  /// face-shaped). Promoted to PRIMARY face-restoration tier in
  /// XVI.79b after `restoreformer_pp_fp32` was discovered to
  /// emit rainbow noise regardless of input — RestoreFormer++
  /// stays in the manifest as a tombstone but is no longer wired.
  const deferredDownloadables = <String>{
    'photo_wct2_fp16',
    'yolov8n_coco_fp32',
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

    test('LaMa + modnet + real_esrgan_x4 are pinned (Phase I.5 + IV.9)',
        () {
      // Explicit per-model regression target. Phase I.5 landed the
      // first; Phase IV.9 landed the rest. A silent unpinning of any
      // of them must trip this test.
      // XVI.111 — `rmbg_1_4_int8` removed: RMBG-1.4 is CC-BY-NC and
      // was dropped from the manifest for commercial licensing.
      for (final id in const [
        'lama_inpaint',
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

    test('dropped non-commercial models are absent (XVI.111/.112)', () {
      // Models pulled from the manifest for commercial licensing so
      // they can't be downloaded:
      //   XVI.111 — RMBG-1.4 (CC-BY-NC), RVM (GPL-3.0)
      //   XVI.112 — CodeFormer (S-Lab NC), RestoreFormer++ (broken +
      //             NC lineage); no permissive face-restore exists.
      for (final id in const [
        'rmbg_1_4_int8',
        'rvm_mobilenetv3_fp32',
        'codeformer_fp32',
        'restoreformer_pp_fp32',
      ]) {
        expect(manifest.byId(id), isNull,
            reason: '$id is non-commercially-licensed and must stay out '
                'of the manifest');
      }
    });
  });
}
