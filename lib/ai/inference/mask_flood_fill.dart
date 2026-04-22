import 'dart:typed_data';

/// Flood-fill operations for RGBA masks used by the inpaint / matte
/// pipelines.
class MaskFloodFill {
  const MaskFloodFill._();

  /// Return a copy of [maskRgba] with every black region that is
  /// **fully enclosed** by white pixels flipped to white. Pixels whose
  /// black neighbourhood reaches the image border are untouched.
  ///
  /// The use case is the lasso-style user: they draw an outline around
  /// an object expecting the interior to be filled. Without this pass
  /// their mask is a hair-line loop, LaMa only gets the stroke pixels
  /// (not the enclosed object), and the result looks like nothing
  /// happened. With this pass, a closed outline becomes a filled
  /// region automatically.
  ///
  /// Algorithm (flood-fill from the border):
  ///   1. Seed a BFS queue with every BLACK pixel on the image border.
  ///   2. 4-connected expansion through black pixels — each visited
  ///      pixel is "connected to the border via black".
  ///   3. Any black pixel not reached by that BFS is by definition
  ///      enclosed by white. Flip it to white in the output.
  ///
  /// Runs in O(width × height) on a single uint8 visited bitmap.
  /// Threshold on the R channel; a pixel is "white" when R ≥ 128 (the
  /// same threshold LaMa's mask tensor builder uses).
  ///
  /// Returns a tuple of (filled mask, count of filled pixels) so the
  /// caller can log or decide whether to apply the change (e.g. skip
  /// when nothing was filled so we don't spam the history).
  static MaskFloodFillResult fillEnclosedBlackRegions({
    required Uint8List maskRgba,
    required int width,
    required int height,
  }) {
    if (maskRgba.length != width * height * 4) {
      throw ArgumentError(
        'maskRgba length ${maskRgba.length} != ${width * height * 4}',
      );
    }
    final visited = Uint8List(width * height);
    final queue = <int>[];

    bool isBlack(int idx) => maskRgba[idx * 4] < 128;

    void seed(int idx) {
      if (visited[idx] == 1) return;
      if (!isBlack(idx)) return;
      visited[idx] = 1;
      queue.add(idx);
    }

    // Seed from the top and bottom rows.
    for (int x = 0; x < width; x++) {
      seed(x);
      seed((height - 1) * width + x);
    }
    // Seed from the left and right columns (corners handled above).
    for (int y = 1; y < height - 1; y++) {
      seed(y * width);
      seed(y * width + width - 1);
    }

    // 4-connected BFS through the black region.
    while (queue.isNotEmpty) {
      final idx = queue.removeLast();
      final x = idx % width;
      final y = idx ~/ width;
      if (x > 0) {
        final n = idx - 1;
        if (visited[n] == 0 && isBlack(n)) {
          visited[n] = 1;
          queue.add(n);
        }
      }
      if (x < width - 1) {
        final n = idx + 1;
        if (visited[n] == 0 && isBlack(n)) {
          visited[n] = 1;
          queue.add(n);
        }
      }
      if (y > 0) {
        final n = idx - width;
        if (visited[n] == 0 && isBlack(n)) {
          visited[n] = 1;
          queue.add(n);
        }
      }
      if (y < height - 1) {
        final n = idx + width;
        if (visited[n] == 0 && isBlack(n)) {
          visited[n] = 1;
          queue.add(n);
        }
      }
    }

    // Every black pixel not marked is enclosed. Flip it to white.
    final out = Uint8List.fromList(maskRgba);
    int filled = 0;
    for (int i = 0; i < width * height; i++) {
      if (visited[i] == 0 && isBlack(i)) {
        final pix = i * 4;
        out[pix] = 255;
        out[pix + 1] = 255;
        out[pix + 2] = 255;
        if (out[pix + 3] < 255) out[pix + 3] = 255;
        filled++;
      }
    }
    return MaskFloodFillResult(maskRgba: out, filledPixels: filled);
  }
}

class MaskFloodFillResult {
  const MaskFloodFillResult({
    required this.maskRgba,
    required this.filledPixels,
  });

  /// The updated RGBA mask. Same buffer identity-wise as the input
  /// when no pixels were filled, so callers can skip a re-upload.
  final Uint8List maskRgba;

  /// Number of pixels flipped from black to white. Zero means the
  /// mask had no enclosed holes (typical of painted brush strokes) —
  /// the caller can skip any change notification.
  final int filledPixels;
}
