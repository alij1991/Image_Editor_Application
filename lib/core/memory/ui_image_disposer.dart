import 'dart:ui' as ui;

/// A reference-counted wrapper around [ui.Image] so multiple consumers can
/// share one decoded image without prematurely disposing it.
///
/// Usage:
///   final handle = UiImageHandle(decoded);
///   handle.retain();  // when another consumer starts using it
///   handle.release(); // when a consumer is done
///
/// The underlying image is disposed when the retain count hits zero.
/// Crucial for the blueprint's memory discipline where a 20 MP image is
/// ~75 MB uncompressed and GC alone is too slow to keep up.
class UiImageHandle {
  UiImageHandle(this._image) : _refCount = 1;

  ui.Image? _image;
  int _refCount;
  bool _disposed = false;

  ui.Image? get image => _image;

  int get refCount => _refCount;

  bool get isDisposed => _disposed;

  void retain() {
    if (_disposed) {
      throw StateError('UiImageHandle: retain() on disposed image');
    }
    _refCount++;
  }

  void release() {
    if (_disposed) return;
    _refCount--;
    if (_refCount <= 0) {
      _disposed = true;
      _image?.dispose();
      _image = null;
    }
  }
}
