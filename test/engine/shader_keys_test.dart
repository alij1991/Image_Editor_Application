import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/rendering/shader_keys.dart';

void main() {
  group('ShaderKeys', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('every key is unique', () {
      final set = ShaderKeys.all.toSet();
      expect(set.length, ShaderKeys.all.length);
    });

    test('every key points at an existing asset in the bundle', () async {
      // The asset bundle in test mode serves assets declared in pubspec.yaml.
      for (final key in ShaderKeys.all) {
        final data = await rootBundle.load(key);
        expect(
          data.lengthInBytes,
          greaterThan(0),
          reason: 'Shader asset $key must be present',
        );
      }
    });

    test('all 26 shaders are declared', () {
      // XVI.23 added shaders/texture.frag.
      // XVI.27 added shaders/color_grading_3wheel.frag.
      // XVI.46 added shaders/lens_distortion.frag.
      expect(ShaderKeys.all.length, 26);
    });
  });
}
