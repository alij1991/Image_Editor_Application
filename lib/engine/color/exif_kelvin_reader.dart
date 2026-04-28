import 'dart:io';

import 'package:exif/exif.dart';

import '../../core/logging/app_logger.dart';

final _log = AppLogger('ExifKelvinReader');

/// Phase XVI.31 — read white-balance hints out of an image's EXIF and
/// figure out whether the temperature slider can usefully display
/// Kelvin values. JPEGs from phones almost never carry an explicit
/// Kelvin tag in standard EXIF (the `WhiteBalance` field is just
/// `Auto` / `Manual`), but a handful of makernote dialects do:
///
///   - Fujifilm `MakerNote ColorTemperature` (raw integer Kelvin)
///   - Olympus `MakerNote WhiteBalanceTemperature` (raw integer Kelvin)
///
/// When present we expose the actual Kelvin so the slider can pivot
/// around the camera's recorded baseline ("5500K daylight" instead of
/// the pivot-on-D65 default). When absent we still set Kelvin display
/// mode whenever any whitebalance metadata is found — at least the
/// user sees Kelvin numbers instead of an opaque -1..+1 — and pivot
/// on D65 (6500 K).
///
/// The reader silent-fallbacks: any IO error / decode error / missing
/// EXIF returns [TemperatureExifResult.scalarDefault] so the editor
/// degrades to the existing -1..+1 slider with no toast.
class TemperatureExifResult {
  const TemperatureExifResult({
    required this.mode,
    required this.baselineKelvin,
  });

  /// The default for any image we couldn't read or that has no white-
  /// balance metadata. Slider stays in scalar mode.
  static const scalarDefault =
      TemperatureExifResult(mode: TemperatureMode.scalar, baselineKelvin: 6500);

  final TemperatureMode mode;

  /// Kelvin value the slider treats as "no shift" (slider position 0).
  /// Defaults to D65 (6500 K) so a user-visible label of "6500 K" at
  /// the centre matches Lightroom's "as shot" position when no
  /// makernote tag is available.
  final double baselineKelvin;

  @override
  bool operator ==(Object other) =>
      other is TemperatureExifResult &&
      other.mode == mode &&
      other.baselineKelvin == baselineKelvin;

  @override
  int get hashCode => Object.hash(mode, baselineKelvin);

  @override
  String toString() =>
      'TemperatureExifResult(mode: $mode, baselineKelvin: $baselineKelvin)';
}

enum TemperatureMode {
  /// Display the underlying op value verbatim (e.g. "+0.50"). Default
  /// when no EXIF whitebalance metadata is available.
  scalar,

  /// Display the slider position as a Kelvin number computed from the
  /// shader's exact temperature mapping pivoted on [TemperatureExifResult.baselineKelvin].
  kelvin,
}

/// Inspect the file at [path] and return the temperature display mode
/// the slider should use. Errors degrade silently to
/// [TemperatureExifResult.scalarDefault] — never throws.
Future<TemperatureExifResult> readTemperatureExif(String path) async {
  try {
    final file = File(path);
    if (!file.existsSync()) {
      return TemperatureExifResult.scalarDefault;
    }
    final bytes = await file.readAsBytes();
    final tags = await readExifFromBytes(bytes);
    return parseTemperatureTags(tags);
  } catch (e, st) {
    _log.w('exif read failed', {'err': '$e', 'st': '$st', 'path': path});
    return TemperatureExifResult.scalarDefault;
  }
}

/// Pure function over an already-decoded EXIF tag map. Split out so
/// tests can drive synthetic tag dictionaries without touching disk.
TemperatureExifResult parseTemperatureTags(Map<String, IfdTag> tags) {
  if (tags.isEmpty) return TemperatureExifResult.scalarDefault;

  // Look for an explicit Kelvin value first — these are honest Kelvin
  // integers in the makernote so we can pivot the slider on the actual
  // camera-recorded white balance.
  for (final key in const [
    'MakerNote ColorTemperature',          // Fujifilm
    'MakerNote WhiteBalanceTemperature',   // Olympus
    'MakerNote ColorTempAsShot',           // some Canons
    'MakerNote WB_RGGBLevelsAsShot',       // Canon — rough — not parsed
  ]) {
    final tag = tags[key];
    if (tag == null) continue;
    final kelvin = _coerceKelvin(tag);
    if (kelvin != null) {
      _log.d('kelvin tag found', {'key': key, 'kelvin': kelvin});
      return TemperatureExifResult(
        mode: TemperatureMode.kelvin,
        baselineKelvin: kelvin,
      );
    }
  }

  // Fall back to the standard `EXIF WhiteBalance` (0xA403, value
  // 0=Auto / 1=Manual). Any presence tells us the camera recorded a
  // white-balance choice — promote the slider to Kelvin display so the
  // user gets meaningful units, even though we can't pivot off
  // anything more specific than D65.
  if (tags.containsKey('EXIF WhiteBalance')) {
    return const TemperatureExifResult(
      mode: TemperatureMode.kelvin,
      baselineKelvin: 6500,
    );
  }

  return TemperatureExifResult.scalarDefault;
}

/// Coerce an [IfdTag] into a plausible Kelvin reading.
///
/// EXIF integer + rational tags both collapse to an int via
/// `firstAsInt()` (Ratio.toInt is integer division — fine for Kelvin
/// where fractional precision is irrelevant). Returns null when the
/// value is outside 1500..40000 K (the Tanner Helland model's safe
/// range — anything past the edges is probably a tag-id collision and
/// shouldn't drive the slider).
double? _coerceKelvin(IfdTag tag) {
  if (tag.values.length == 0) return null;
  final int raw;
  try {
    raw = tag.values.firstAsInt();
  } catch (_) {
    return null;
  }
  if (raw < 1500 || raw > 40000) return null;
  return raw.toDouble();
}
