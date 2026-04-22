import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Ping-pong pool for intermediate [ui.Image]s produced by multi-pass
/// [ShaderRenderer] chains.
///
/// Why this exists (Phase VI.1):
///
/// A 5-pass color chain allocates four intermediate `ui.Image`s per
/// frame (pass 0..N-2 each call `Picture.toImageSync`; the final pass
/// writes to the screen canvas). Each `ui.Image` is GPU-texture backed,
/// and at 60 fps under slider drag that's 240 GPU texture allocations
/// per second for a single editor session.
///
/// Flutter's `dart:ui` is immutable: we can't literally "write into" a
/// pre-existing `ui.Image`. What we CAN do is bound the peak intermediate
/// lifetime to exactly two slots, keep those slots alive across frames,
/// and install each newly minted image into the slot opposite the one
/// the current pass reads from. That pattern:
///
///   1. Keeps `Picture::toImageSync`'s backing GPU texture allocation
///      in Skia's `GrResourceCache` warm path — the cache keys on
///      width/height/format, so a same-size request on the next frame
///      reuses the same underlying Metal/GL texture rather than
///      round-tripping through the driver.
///   2. Caps peak intermediate memory at 2 × (w × h × 4) bytes regardless
///      of pass count (vs. the old path's transient 2 during hand-off).
///   3. Centralises intermediate disposal so the renderer's paint loop
///      doesn't have to thread `sourceIsIntermediate` bookkeeping through
///      every branch.
///
/// ## Contract
///
/// - Caller owns pool lifetime; the pool doesn't register a finalizer.
///   Call [dispose] when the session ends.
/// - [beginFrame] MUST be called before the first [install] of every
///   paint. It resets the ping-pong cursor so slot 0 always receives
///   pass 0's output, slot 1 always receives pass 1's, etc. — which is
///   what lets Skia's texture cache recognise the size-matched slots.
/// - [install] takes ownership of the passed image. On the third install
///   per frame, the slot-0 image from pass 0 is disposed (pass 2 reads
///   from slot 1, so pass 0's output is safely dead). Same pattern on
///   every even install from that point.
/// - Dimension changes flush both slots. Intra-frame dimension changes
///   are a bug — the renderer uses one intermediate size per paint.
///
/// ## Non-goals
///
/// - This is NOT a general-purpose `ui.Image` cache. It retains exactly
///   two slots at one resolution. Presets / LUTs / curves keep their own
///   caches elsewhere.
/// - It does not participate in `didHaveMemoryPressure` today. A future
///   item (Phase VI #11) will wire that in — for now the slots are tiny
///   (~8 MB at 1920 × 1080 × 4 × 2) and dropping them on pressure would
///   only re-allocate on the next frame.
class ShaderTexturePool {
  ShaderTexturePool();

  ui.Image? _slotA;
  ui.Image? _slotB;

  /// Dimensions the pool is currently sized for. Zero until the first
  /// [beginFrame] call. A dimension change flushes both slots.
  int _width = 0;
  int _height = 0;

  /// Number of installs since the last [beginFrame]. Parity determines
  /// which slot the next [install] writes to.
  int _cursor = 0;

  bool _disposed = false;

  /// Reset the ping-pong cursor and (if dimensions changed) flush both
  /// slots. Call at the top of every [ShaderRenderer.paint] before the
  /// pass loop runs.
  void beginFrame({required int width, required int height}) {
    assert(!_disposed, 'beginFrame on disposed ShaderTexturePool');
    _cursor = 0;
    if (_width != width || _height != height) {
      _slotA?.dispose();
      _slotB?.dispose();
      _slotA = null;
      _slotB = null;
      _width = width;
      _height = height;
    }
  }

  /// Install [image] as the most-recent slot, disposing the prior
  /// occupant of the slot we're writing to (two installs ago — safe
  /// because the current pass reads from the OTHER slot).
  ///
  /// Caller passes ownership to the pool; do NOT dispose [image] after
  /// this returns. Returns [image] for fluent chaining.
  ui.Image install(ui.Image image) {
    assert(!_disposed, 'install on disposed ShaderTexturePool');
    assert(image.width == _width && image.height == _height,
        'install dimensions mismatch pool (pool=${_width}x$_height, '
        'image=${image.width}x${image.height}) — call beginFrame first');
    if (_cursor.isEven) {
      _slotA?.dispose();
      _slotA = image;
    } else {
      _slotB?.dispose();
      _slotB = image;
    }
    _cursor++;
    return image;
  }

  /// Returns the most-recently installed image, or null if no installs
  /// have happened this frame yet.
  ui.Image? get latest {
    if (_cursor == 0) return null;
    // After install, cursor advances. The slot just written is
    // (cursor - 1) % 2.
    return _cursor.isOdd ? _slotA : _slotB;
  }

  /// Dispose both slots and mark the pool terminal. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _slotA?.dispose();
    _slotB?.dispose();
    _slotA = null;
    _slotB = null;
  }

  @visibleForTesting
  bool get isDisposed => _disposed;

  @visibleForTesting
  int get cursor => _cursor;

  @visibleForTesting
  ({ui.Image? slotA, ui.Image? slotB}) get debugSlots =>
      (slotA: _slotA, slotB: _slotB);

  @visibleForTesting
  ({int width, int height}) get debugDimensions =>
      (width: _width, height: _height);
}
