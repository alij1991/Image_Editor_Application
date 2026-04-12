import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/app_logger.dart';

final _log = AppLogger('MementoStore');

/// A Memento captures the rendered-bytes output of an operation that
/// cannot be reversed analytically (LaMa inpainting, style transfer,
/// colorization, etc.).
///
/// Per the blueprint, the last N=3 mementos are kept in RAM; older ones
/// spill to disk under `ApplicationDocumentsDirectory/mementos/`. A single
/// session's mementos share one directory so `dispose` can wipe them in
/// bulk on session close.
class Memento {
  Memento({
    required this.id,
    required this.opId,
    required this.width,
    required this.height,
    this.inMemory,
    this.diskPath,
  }) : assert(
          inMemory != null || diskPath != null,
          'Memento must have at least one backing store',
        );

  final String id;
  final String opId;
  final int width;
  final int height;
  Uint8List? inMemory;
  String? diskPath;

  /// Return the pixel bytes, loading from disk if we've been spilled.
  Future<Uint8List> readBytes() async {
    if (inMemory != null) return inMemory!;
    if (diskPath == null) {
      throw StateError('Memento has no backing store');
    }
    return File(diskPath!).readAsBytes();
  }

  bool get isInMemory => inMemory != null;
}

class MementoStore {
  MementoStore({this.ramRingCapacity = 3});

  final int ramRingCapacity;
  final List<Memento> _ring = [];
  Directory? _diskDir;

  Future<void> init() async {
    if (_diskDir != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _diskDir = Directory(p.join(docs.path, 'mementos'));
      await _diskDir!.create(recursive: true);
      _log.d('init', {'dir': _diskDir!.path});
    } catch (e) {
      // In unit tests without platform channels, path_provider throws.
      // Treat this as non-fatal — the store becomes RAM-only.
      _log.w('init failed, running RAM-only', {'error': e.toString()});
      _diskDir = null;
    }
  }

  int get ramCount => _ring.where((m) => m.isInMemory).length;
  int get totalCount => _ring.length;

  /// Store [bytes] as a new Memento. Returns the created Memento. If the
  /// ring is over capacity, the oldest in-RAM entry is spilled to disk.
  Future<Memento> store({
    required String opId,
    required int width,
    required int height,
    required Uint8List bytes,
  }) async {
    await init();
    final memento = Memento(
      id: const Uuid().v4(),
      opId: opId,
      width: width,
      height: height,
      inMemory: bytes,
    );
    _ring.add(memento);
    _log.i('store', {
      'id': memento.id,
      'opId': opId,
      'bytes': bytes.length,
      'ringSize': _ring.length,
    });
    await _enforceRamRing();
    return memento;
  }

  /// Explicitly drop a memento (called when the history entry that owned
  /// it is evicted past the history limit).
  Future<void> drop(String mementoId) async {
    final m = _ring.firstWhereOrNull((x) => x.id == mementoId);
    if (m == null) return;
    _ring.remove(m);
    _log.d('drop', {'id': mementoId});
    if (m.diskPath != null) {
      final f = File(m.diskPath!);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {
          // Ignore — swept by clear() on session close.
        }
      }
    }
    m.inMemory = null;
  }

  /// Wipe everything. Called on session close.
  Future<void> clear() async {
    _log.d('clear', {'count': _ring.length});
    for (final m in _ring) {
      m.inMemory = null;
      if (m.diskPath != null) {
        final f = File(m.diskPath!);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
    _ring.clear();
    if (_diskDir != null && await _diskDir!.exists()) {
      try {
        await _diskDir!.delete(recursive: true);
      } catch (_) {}
      _diskDir = null;
    }
  }

  Memento? lookup(String mementoId) =>
      _ring.firstWhereOrNull((m) => m.id == mementoId);

  Future<void> _enforceRamRing() async {
    final inMem = _ring.where((m) => m.isInMemory).toList();
    if (inMem.length <= ramRingCapacity) return;
    if (_diskDir == null) {
      _log.w('spill requested but disk unavailable — keeping in RAM');
      return;
    }
    final overflow = inMem.length - ramRingCapacity;
    _log.i('spill to disk', {'count': overflow});
    for (int i = 0; i < overflow; i++) {
      final m = inMem[i];
      final bytes = m.inMemory;
      if (bytes == null) continue;
      final path = p.join(_diskDir!.path, '${m.id}.bin');
      final file = File(path);
      await file.writeAsBytes(bytes);
      m.diskPath = path;
      m.inMemory = null;
    }
  }
}
