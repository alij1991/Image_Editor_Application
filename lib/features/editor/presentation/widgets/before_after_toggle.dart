import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('BeforeAfterToggle');

/// Compare-with-original button.
///
/// Two gestures, two intents:
///   * **Tap** latches the original view on or off — stays put until
///     tapped again. The everyday "did my edit help?" check.
///   * **Hold** is a transient peek — original visible only while
///     pressed, then snaps back to whatever latched state we were in.
///
/// Both routes call [EditorSession.setAllOpsEnabledTransient], which
/// emits a [SetAllOpsEnabled] event the history bloc *doesn't* record
/// — it's a view-only toggle, so nothing pollutes the undo stack.
class BeforeAfterToggle extends StatefulWidget {
  const BeforeAfterToggle({required this.session, super.key});

  final EditorSession session;

  @override
  State<BeforeAfterToggle> createState() => _BeforeAfterToggleState();
}

class _BeforeAfterToggleState extends State<BeforeAfterToggle> {
  /// True while a long-press is in flight. Independent of [_latched]
  /// so a peek over a latched view still snaps back to latched on
  /// release rather than dropping to "edited".
  bool _holding = false;

  /// True when the user has tapped to latch the original view on. The
  /// session shows "before" until tapped a second time.
  bool _latched = false;

  bool get _showingOriginal => _holding || _latched;

  void _syncSession(bool wasShowing, bool nowShowing) {
    if (wasShowing == nowShowing) return;
    widget.session.setAllOpsEnabledTransient(!nowShowing);
  }

  void _onLongPressStart() {
    if (_holding) return;
    _log.i('peek original (hold)');
    Haptics.tap();
    final wasShowing = _showingOriginal;
    setState(() => _holding = true);
    _syncSession(wasShowing, _showingOriginal);
  }

  void _onLongPressEnd() {
    if (!_holding) return;
    _log.i('release peek');
    final wasShowing = _showingOriginal;
    setState(() => _holding = false);
    _syncSession(wasShowing, _showingOriginal);
  }

  void _onTap() {
    _log.i('toggle latch', {'to': !_latched});
    Haptics.tap();
    final wasShowing = _showingOriginal;
    setState(() => _latched = !_latched);
    _syncSession(wasShowing, _showingOriginal);
  }

  @override
  void dispose() {
    // If this widget is torn down while showing the original, hand
    // the edited state back to the session so a route swap can't
    // strand the canvas in compare mode.
    if (_showingOriginal) {
      widget.session.setAllOpsEnabledTransient(true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: _latched
          ? 'Tap to return to your edits'
          : 'Tap to compare with original — hold for a quick peek',
      child: GestureDetector(
        onLongPressStart: (_) => _onLongPressStart(),
        onLongPressEnd: (_) => _onLongPressEnd(),
        onLongPressCancel: _onLongPressEnd,
        child: IconButton(
          icon: Icon(
            _showingOriginal ? Icons.visibility_off : Icons.compare,
            color: _showingOriginal ? colorScheme.primary : null,
          ),
          onPressed: _onTap,
        ),
      ),
    );
  }
}
