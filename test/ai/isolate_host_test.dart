import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/runtime/isolate_interpreter_host.dart';
import 'package:image_editor/ai/runtime/ml_runtime.dart';

void main() {
  group('IsolateInterpreterHost', () {
    test('run forwards inputs to the underlying session', () async {
      final session = _FakeSession(
        onRun: (input) async => {
          'out': Uint8List.fromList([...input['in'] ?? const <int>[], 99]),
        },
      );
      final host = IsolateInterpreterHost(session);
      final result = await host.run({'in': Uint8List.fromList([1, 2, 3])});
      expect(result['out'], Uint8List.fromList([1, 2, 3, 99]));
      expect(session.runCount, 1);
    });

    test('throws MlRuntimeException after close', () async {
      final host = IsolateInterpreterHost(
        _FakeSession(onRun: (_) async => {}),
      );
      await host.close();
      expect(host.isClosed, true);
      expect(
        () => host.run({}),
        throwsA(isA<MlRuntimeException>()),
      );
    });

    test('serializes concurrent runs (second waits for first)', () async {
      int inflight = 0;
      int maxInflight = 0;
      final session = _FakeSession(
        onRun: (_) async {
          inflight++;
          maxInflight = maxInflight < inflight ? inflight : maxInflight;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inflight--;
          return {'ok': Uint8List(0)};
        },
      );
      final host = IsolateInterpreterHost(session);
      await Future.wait([host.run({}), host.run({}), host.run({})]);
      expect(maxInflight, 1);
      expect(session.runCount, 3);
    });

    test('close is idempotent', () async {
      final session = _FakeSession(onRun: (_) async => {});
      final host = IsolateInterpreterHost(session);
      await host.close();
      await host.close();
      expect(host.isClosed, true);
      expect(session.closeCount, 1);
    });

    test('descriptor exposes the session descriptor', () {
      final session = _FakeSession(onRun: (_) async => {});
      final host = IsolateInterpreterHost(session);
      expect(host.descriptor.id, 'fake');
    });
  });
}

class _FakeSession implements MlSession {
  _FakeSession({required this.onRun});

  final Future<Map<String, Uint8List>> Function(Map<String, Uint8List>) onRun;
  int runCount = 0;
  int closeCount = 0;

  @override
  final ModelDescriptor descriptor = const ModelDescriptor(
    id: 'fake',
    version: '1',
    runtime: ModelRuntime.mlkit,
    sizeBytes: 1,
    sha256: '',
    bundled: true,
  );

  @override
  Future<Map<String, Uint8List>> run(Map<String, Uint8List> inputs) async {
    runCount++;
    return onRun(inputs);
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}
