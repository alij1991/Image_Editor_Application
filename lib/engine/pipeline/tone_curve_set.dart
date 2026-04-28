/// Channel selector for the curves editor.
///
/// - **Master** applies its curve to each RGB channel via the LUT's row 0.
/// - **Red / Green / Blue** apply per-channel post-master via rows 1-3.
/// - **Luma (XVI.24)** applies post-master+RGB on the perceptual Y of
///   the resulting RGB, scaling the rgb vector by the mapped-to-original
///   luma ratio. Lives on row 4 of the LUT. Lightroom calls this the
///   "Light" curve (5th tab); Photoshop calls it "Luminosity".
enum ToneCurveChannel { master, red, green, blue, luma }

extension ToneCurveChannelExt on ToneCurveChannel {
  /// Short user-facing label for the channel chip row.
  String get label {
    switch (this) {
      case ToneCurveChannel.master:
        return 'Master';
      case ToneCurveChannel.red:
        return 'Red';
      case ToneCurveChannel.green:
        return 'Green';
      case ToneCurveChannel.blue:
        return 'Blue';
      case ToneCurveChannel.luma:
        return 'Luma';
    }
  }

  /// Parameter key inside the toneCurve op's `parameters` map. Master
  /// stays `points` for backwards compatibility with v1 sessions; the
  /// per-channel keys are new in v2 (red/green/blue) and v3 (luma).
  String get paramKey {
    switch (this) {
      case ToneCurveChannel.master:
        return 'points';
      case ToneCurveChannel.red:
        return 'red';
      case ToneCurveChannel.green:
        return 'green';
      case ToneCurveChannel.blue:
        return 'blue';
      case ToneCurveChannel.luma:
        return 'luma';
    }
  }
}

/// Snapshot of all five curves authored against a single toneCurve op
/// (Master/R/G/B/Luma). Channels with `null` lists are at the identity
/// diagonal — the session skips baking those rows so RGB-untouched
/// edits stay cheap.
class ToneCurveSet {
  const ToneCurveSet({
    this.master,
    this.red,
    this.green,
    this.blue,
    this.luma,
  });

  final List<List<double>>? master;
  final List<List<double>>? red;
  final List<List<double>>? green;
  final List<List<double>>? blue;

  /// XVI.24 — perceptual luma curve, applied post-master+RGB by scaling
  /// the resulting rgb by `curve(Y)/Y`. Null = identity.
  final List<List<double>>? luma;

  /// True when every channel is null (or identity-shaped) — caller
  /// should drop the toneCurve op rather than pay the LUT bake cost.
  bool get isAllIdentity =>
      master == null &&
      red == null &&
      green == null &&
      blue == null &&
      luma == null;

  List<List<double>>? channel(ToneCurveChannel c) {
    switch (c) {
      case ToneCurveChannel.master:
        return master;
      case ToneCurveChannel.red:
        return red;
      case ToneCurveChannel.green:
        return green;
      case ToneCurveChannel.blue:
        return blue;
      case ToneCurveChannel.luma:
        return luma;
    }
  }

  ToneCurveSet withChannel(ToneCurveChannel c, List<List<double>>? points) {
    switch (c) {
      case ToneCurveChannel.master:
        return ToneCurveSet(
            master: points, red: red, green: green, blue: blue, luma: luma);
      case ToneCurveChannel.red:
        return ToneCurveSet(
            master: master, red: points, green: green, blue: blue, luma: luma);
      case ToneCurveChannel.green:
        return ToneCurveSet(
            master: master, red: red, green: points, blue: blue, luma: luma);
      case ToneCurveChannel.blue:
        return ToneCurveSet(
            master: master, red: red, green: green, blue: points, luma: luma);
      case ToneCurveChannel.luma:
        return ToneCurveSet(
            master: master, red: red, green: green, blue: blue, luma: points);
    }
  }

  /// Stable cache key for the LUT baker. Rounds to 4 decimals so
  /// sub-pixel drag jitter doesn't bust the cache. A null channel
  /// renders as `_` (the identity sentinel).
  String get cacheKey {
    final buf = StringBuffer();
    for (final c in ToneCurveChannel.values) {
      if (buf.isNotEmpty) buf.write('|');
      buf.write(c.name[0]);
      buf.write(':');
      final pts = channel(c);
      if (pts == null) {
        buf.write('_');
        continue;
      }
      for (int i = 0; i < pts.length; i++) {
        if (i > 0) buf.write(';');
        buf
          ..write(pts[i][0].toStringAsFixed(4))
          ..write(',')
          ..write(pts[i][1].toStringAsFixed(4));
      }
    }
    return buf.toString();
  }
}
