import 'package:image_picker/image_picker.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/document_detector.dart';

final _log = AppLogger('PickerCapture');

/// Thin wrapper around `image_picker` used by the Manual and Auto
/// detectors. Returns the picked file path(s) or throws
/// [ScannerCancelledException] when the user backs out of the picker.
class ImagePickerCapture {
  ImagePickerCapture();

  final ImagePicker _picker = ImagePicker();

  Future<List<String>> pickFromCamera() async {
    _log.d('camera');
    final picked = await _picker.pickImage(source: ImageSource.camera);
    if (picked == null) throw const ScannerCancelledException();
    _log.i('camera ok', {'path': picked.path});
    return [picked.path];
  }

  Future<List<String>> pickFromGallery({bool multi = true}) async {
    _log.d('gallery', {'multi': multi});
    if (multi) {
      final picked = await _picker.pickMultiImage();
      if (picked.isEmpty) throw const ScannerCancelledException();
      _log.i('gallery ok', {'count': picked.length});
      return picked.map((x) => x.path).toList();
    }
    final one = await _picker.pickImage(source: ImageSource.gallery);
    if (one == null) throw const ScannerCancelledException();
    return [one.path];
  }
}
