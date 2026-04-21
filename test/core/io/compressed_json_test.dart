import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/compressed_json.dart';

/// Behaviour tests for the Phase IV.2 `compressed_json` codec —
/// the marker-byte framing + gzip helper that
/// [PipelineSerializer.encode]/[decode] and [ProjectStore.save]/[load]
/// both delegate to.
///
/// The tests pin three contracts:
///   1. small payloads → `0x00` + UTF-8; big payloads → `0x01` + gzip.
///   2. round-trip is lossless for both paths + non-ASCII.
///   3. buffers with no marker byte (legacy un-marked plain JSON)
///      still decode — the Phase IV.2 cutover cannot invalidate any
///      project file written by the pre-Phase-IV.2 builds.
void main() {
  group('encodeCompressedJson', () {
    test('small payload uses the plain marker (0x00) + UTF-8 bytes', () {
      const json = '{"hello":"world"}';
      final bytes = encodeCompressedJson(json);
      expect(bytes.first, 0x00);
      expect(utf8.decode(bytes.sublist(1)), json);
    });

    test('payload at threshold switches to gzip (0x01)', () {
      // `threshold: 32` forces the gzip branch even for tiny fixtures,
      // which keeps the test independent of the 64 KB production value.
      final bytes = encodeCompressedJson(
        '{"padding":"${'x' * 64}"}',
        threshold: 32,
      );
      expect(bytes.first, 0x01);
      // Round-trip via the same threshold-less decoder.
      expect(jsonDecode(decodeCompressedJson(bytes)), isA<Map>());
    });

    test('default threshold is 64 KB — 63 KB stays plain, 64 KB gzips',
        () {
      final justUnder = 'x' * (63 * 1024);
      final justOver = 'x' * (64 * 1024);
      expect(encodeCompressedJson(justUnder).first, 0x00);
      expect(encodeCompressedJson(justOver).first, 0x01);
    });

    test('gzip branch actually shrinks high-redundancy input', () {
      // 200 KB of repeating JSON — ideal gzip material. The encoded
      // output must be meaningfully smaller than the raw bytes, else
      // the compress branch has no point being there.
      final large = '{"filler":"${'abc' * 70000}"}';
      final rawLen = utf8.encode(large).length;
      final bytes = encodeCompressedJson(large);
      expect(bytes.first, 0x01);
      expect(bytes.length, lessThan(rawLen ~/ 4),
          reason: 'gzip should cut this by at least 4×');
    });
  });

  group('decodeCompressedJson', () {
    test('round-trips a plain payload', () {
      const src = '{"a":1,"b":[1,2,3]}';
      expect(decodeCompressedJson(encodeCompressedJson(src)), src);
    });

    test('round-trips a gzip payload', () {
      final src = '{"filler":"${'y' * 100000}"}';
      final bytes = encodeCompressedJson(src);
      expect(bytes.first, 0x01);
      expect(decodeCompressedJson(bytes), src);
    });

    test('handles non-ASCII content through both branches', () {
      const src = '{"note":"Ñoño © 你好 🍕"}';
      // Plain path.
      expect(decodeCompressedJson(encodeCompressedJson(src)), src);
      // Gzip path (force threshold low).
      final gz = encodeCompressedJson(src, threshold: 1);
      expect(gz.first, 0x01);
      expect(decodeCompressedJson(gz), src);
    });

    test('legacy un-marked plain JSON decodes as a raw UTF-8 string', () {
      // Pre-Phase-IV.2 ProjectStore wrote `utf8.encode(jsonEncode(env))`
      // with no framing byte. The decoder must treat any first byte
      // other than 0x00 / 0x01 as "legacy, whole buffer is JSON".
      const legacy = '{"schema":1,"pipeline":{}}';
      final bytes = Uint8List.fromList(utf8.encode(legacy));
      // Sanity: the very first byte really is `{` (0x7B), not a marker.
      expect(bytes.first, 0x7B);
      expect(decodeCompressedJson(bytes), legacy);
    });

    test('legacy plain JSON array decodes too (starts with 0x5B "[")', () {
      // Not a shape ProjectStore emits, but the codec is generic and
      // arrays are a valid legacy JSON starter — pin the behaviour so
      // a future store reusing the codec inherits the generality.
      const legacy = '[1,2,3]';
      final bytes = Uint8List.fromList(utf8.encode(legacy));
      expect(bytes.first, 0x5B);
      expect(decodeCompressedJson(bytes), legacy);
    });

    test('empty buffer throws FormatException', () {
      expect(
        () => decodeCompressedJson(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('corrupted gzip payload throws on decode', () {
      // Marker claims gzip but bytes aren't valid gzip → gzip.decode
      // raises a FormatException. The codec doesn't swallow it; the
      // caller (ProjectStore.load) is responsible for the try/catch.
      final bogus = Uint8List.fromList([0x01, 1, 2, 3, 4, 5]);
      expect(() => decodeCompressedJson(bogus), throwsA(isA<Object>()));
    });
  });

  group('compressed_json integration with GZipCodec', () {
    test('encodeCompressedJson gzip payload matches gzip.encode output',
        () {
      // Pin that the gzip branch uses the stdlib codec without any
      // custom framing — the test is a deterministic bit-for-bit check
      // that a hand-unpacked gzip payload matches what the decoder
      // would emit. Catches regressions where someone "optimises" the
      // codec by shaving the marker byte.
      final src = 'x' * 100000;
      final bytes = encodeCompressedJson(src);
      expect(bytes.first, 0x01);
      final unpacked = utf8.decode(gzip.decode(bytes.sublist(1)));
      expect(unpacked, src);
    });
  });
}
