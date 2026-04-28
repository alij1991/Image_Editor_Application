import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/exif_kelvin_reader.dart';

/// Phase XVI.31 — pin the EXIF → temperature-mode contract.
///
/// The pure [parseTemperatureTags] function is what the file-reading
/// wrapper boils down to once the bytes are decoded; testing it
/// directly with synthetic tag dictionaries means we don't have to
/// ship a fixture image per camera dialect.
void main() {
  IfdTag intTag(int value, {int tagId = 0xA403, String type = 'Short'}) {
    return IfdTag(
      tag: tagId,
      tagType: type,
      printable: '$value',
      values: IfdInts([value]),
    );
  }

  group('parseTemperatureTags (XVI.31)', () {
    test('empty tag map returns scalar default', () {
      expect(
        parseTemperatureTags(const {}),
        TemperatureExifResult.scalarDefault,
      );
    });

    test('Fujifilm MakerNote ColorTemperature picks Kelvin baseline', () {
      final result = parseTemperatureTags({
        'MakerNote ColorTemperature': intTag(5500),
      });
      expect(result.mode, TemperatureMode.kelvin);
      expect(result.baselineKelvin, 5500.0);
    });

    test('Olympus MakerNote WhiteBalanceTemperature picks Kelvin baseline',
        () {
      final result = parseTemperatureTags({
        'MakerNote WhiteBalanceTemperature': intTag(7200),
      });
      expect(result.mode, TemperatureMode.kelvin);
      expect(result.baselineKelvin, 7200.0);
    });

    test('plain EXIF WhiteBalance promotes to Kelvin with D65 default', () {
      // Standard EXIF WhiteBalance (0xA403) is just Auto/Manual — no
      // Kelvin attached — but its presence is enough signal that the
      // user is editing a camera-recorded photo, so we still hand the
      // slider a Kelvin display pivoted on D65.
      final result = parseTemperatureTags({
        'EXIF WhiteBalance': intTag(0),
      });
      expect(result.mode, TemperatureMode.kelvin);
      expect(result.baselineKelvin, 6500.0);
    });

    test('makernote Kelvin wins over plain EXIF WhiteBalance', () {
      // Cameras that include both the standard tag and a Kelvin
      // makernote should pivot on the more-specific value.
      final result = parseTemperatureTags({
        'EXIF WhiteBalance': intTag(0),
        'MakerNote ColorTemperature': intTag(4800),
      });
      expect(result.mode, TemperatureMode.kelvin);
      expect(result.baselineKelvin, 4800.0);
    });

    test('out-of-range Kelvin is rejected (sane bounds 1500..40000)', () {
      // A 0 here probably means "not measured" — falling back to D65
      // via the WhiteBalance default is safer than displaying "0 K".
      final result = parseTemperatureTags({
        'MakerNote ColorTemperature': intTag(0),
      });
      expect(result.mode, TemperatureMode.scalar);
    });

    test('no whitebalance tag at all returns scalar', () {
      final result = parseTemperatureTags({
        // Some unrelated tag that must not be misidentified.
        'EXIF ExposureTime': intTag(125),
      });
      expect(result.mode, TemperatureMode.scalar);
    });
  });

  group('readTemperatureExif file path (XVI.31)', () {
    test('non-existent path returns scalar default (no throw)', () async {
      final result = await readTemperatureExif('/does/not/exist.jpg');
      expect(result, TemperatureExifResult.scalarDefault);
    });

    test('garbage bytes degrade to scalar (no throw)', () async {
      // Write a few junk bytes to a temp file — the exif decoder
      // either returns an empty map or throws; either way the reader
      // must surface scalarDefault rather than blowing up the editor.
      final tmp = await _writeTempFile(Uint8List.fromList([0xDE, 0xAD]));
      addTearDown(tmp.deleteSync);
      final result = await readTemperatureExif(tmp.path);
      expect(result, TemperatureExifResult.scalarDefault);
    });
  });
}

Future<File> _writeTempFile(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('exif_kelvin_test_');
  final f = File('${dir.path}/img.jpg');
  await f.writeAsBytes(bytes);
  return f;
}
