import 'package:flutter/material.dart';

/// XVI.131 (F1) — a11y wrapper for a discrete, selectable, tappable
/// control whose role + selection state are otherwise conveyed only
/// visually (e.g. a preset tile or a collage-template thumbnail —
/// selected-ness is just a coloured border / accent, invisible to a
/// screen reader).
///
/// Produces ONE merged semantics node exposing the label + selected +
/// button flags and a tap action, so VoiceOver/TalkBack announce
/// "<label>, selected, button" and can activate it. The visual [child]
/// is purely presentational — its inner semantics (e.g. a duplicate name
/// Text) are excluded so the announcement isn't doubled. Owns its own
/// transparent [Material] so the ink ripple works without relying on an
/// ancestor.
class AccessibleTile extends StatelessWidget {
  const AccessibleTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.tooltip,
    this.borderRadius,
  });

  /// Screen-reader label — typically the item's name.
  final String label;

  /// Whether this tile is the currently-selected one (announced as the
  /// node's "selected" state).
  final bool selected;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Optional sighted-user hint shown on long-hover/press. Independent of
  /// [label] (which is the screen-reader announcement).
  final String? tooltip;

  /// Presentational content. Its inner semantics are excluded so the
  /// merged node announces only [label].
  final Widget child;

  /// Ripple clip radius, matched to the visual container.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    Widget tile = MergeSemantics(
      child: Semantics(
        label: label,
        selected: selected,
        // InkWell contributes the tap action + focusability but not the
        // button flag — set it here so screen readers announce a button.
        button: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: borderRadius,
            child: ExcludeSemantics(child: child),
          ),
        ),
      ),
    );
    final tip = tooltip;
    if (tip != null) {
      tile = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        child: tile,
      );
    }
    return tile;
  }
}
