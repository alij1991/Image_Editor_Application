import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/memory/memory_budget.dart';
import '../../../../engine/history/memento_store.dart';
import '../../../../engine/proxy/proxy_manager.dart';
import 'editor_session.dart';
import 'editor_state.dart';

final _log = AppLogger('EditorNotifier');

/// Root editor state controller. Exposes the current session as a
/// [StateNotifier] so the UI can `watch` it and rebuild when the session
/// changes (open / close / error).
///
/// Slider widgets do NOT watch this notifier while dragging — they talk
/// directly to `session.previewController` via the imperative path.
class EditorNotifier extends StateNotifier<EditorState> {
  EditorNotifier({
    required ProxyManager proxyManager,
    required MemoryBudget memoryBudget,
  })  : _proxyManager = proxyManager,
        _memoryBudget = memoryBudget,
        super(const EditorIdle()) {
    _log.i('created', {
      'maxRamMementos': memoryBudget.maxRamMementos,
      'maxProxyEntries': memoryBudget.maxProxyEntries,
    });
  }

  final ProxyManager _proxyManager;
  final MemoryBudget _memoryBudget;
  EditorSession? _activeSession;

  EditorSession? get activeSession => _activeSession;

  /// Open [sourcePath] as a new editing session. Loads the preview proxy,
  /// constructs the session, and emits [EditorReady].
  Future<void> openSession(String sourcePath) async {
    _log.i('openSession requested', {'path': sourcePath});
    await closeSession();
    state = EditorLoading(sourcePath: sourcePath);
    try {
      final proxy = await _proxyManager.obtain(sourcePath);
      _log.d('proxy obtained', {
        'width': proxy.image?.width,
        'height': proxy.image?.height,
      });
      // Phase V.2: size the RAM-resident memento ring to the device
      // tier so 12 GB phones actually use their headroom instead of
      // spilling to disk and re-reading for every undo.
      final session = await EditorSession.start(
        sourcePath: sourcePath,
        proxy: proxy,
        mementoStore: MementoStore(
          ramRingCapacity: _memoryBudget.maxRamMementos,
        ),
      );
      _activeSession = session;
      session.rebuildPreview();
      // Kick off the 128 px preset-strip proxy build in the background —
      // the tiles show a shimmer until it resolves, then live previews.
      unawaited(session.ensureThumbnailProxy());
      state = EditorReady(session: session);
      _log.i('session ready', {'path': sourcePath});
    } catch (e, stackTrace) {
      _log.e(
        'openSession failed',
        error: e,
        stackTrace: stackTrace,
        data: {'path': sourcePath},
      );
      state = EditorError(message: 'Failed to load image: $e', cause: e);
    }
  }

  Future<void> closeSession() async {
    final s = _activeSession;
    _activeSession = null;
    if (s != null) {
      _log.i('closeSession', {'path': s.sourcePath});
      await s.dispose();
    }
    state = const EditorIdle();
  }

  @override
  void dispose() {
    _log.i('notifier dispose');
    final s = _activeSession;
    _activeSession = null;
    if (s != null) {
      // fire-and-forget; dispose cannot be async
      s.dispose();
    }
    super.dispose();
  }
}
