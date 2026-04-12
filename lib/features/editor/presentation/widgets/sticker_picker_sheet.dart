import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';

final _log = AppLogger('StickerPickerSheet');

/// Emoji-based sticker picker. Phase 7 uses Unicode emoji so we don't
/// need image assets; real PNG/SVG stickers ship when the
/// `assets/stickers/` library is populated in a later phase.
class StickerPickerSheet extends StatelessWidget {
  const StickerPickerSheet({required this.id, super.key});

  /// Id to assign to the new layer. Caller generates a UUID.
  final String id;

  static Future<StickerLayer?> show(
    BuildContext context, {
    required String id,
  }) {
    return showModalBottomSheet<StickerLayer>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StickerPickerSheet(id: id),
    );
  }

  static const Map<String, List<String>> _categories = {
    'Smileys': [
      '😀', '😁', '😂', '🤣', '😃', '😄', '😅', '😆',
      '😉', '😊', '😇', '🙂', '🙃', '😋', '😎', '😍',
      '😘', '🥰', '😗', '😙', '😚', '🙂‍↕️', '🙂‍↔️', '🥲',
    ],
    'Gestures': [
      '👍', '👎', '👌', '🤌', '🤏', '✌️', '🤞', '🤟',
      '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️',
      '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳',
    ],
    'Hearts': [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
      '💘', '💝', '💟', '♥️', '💌',
    ],
    'Nature': [
      '🌸', '🌼', '🌻', '🌺', '🌷', '🌹', '🥀', '🌿',
      '🍀', '🍁', '🍂', '🍃', '🌲', '🌳', '🌴', '🌵',
      '🌾', '🌱', '🌊', '⭐', '🌟', '✨', '⚡', '🔥',
    ],
    'Objects': [
      '⭐', '🎉', '🎊', '🎈', '🎁', '🎀', '🏆', '🥇',
      '🎯', '🎨', '🎭', '🎬', '🎵', '🎶', '🎸', '🎤',
      '💎', '💰', '👑', '🕶️', '📷', '🎞️', '🖼️', '🏷️',
    ],
    'Food': [
      '🍎', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐',
      '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑',
      '🍔', '🍕', '🌮', '🌯', '🥗', '🍰', '🧁', '🍩',
    ],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: _categories.length,
      child: Padding(
        padding: const EdgeInsets.only(top: Spacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: Spacing.lg),
                Text('Stickers', style: theme.textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            TabBar(
              isScrollable: true,
              tabs: [
                for (final cat in _categories.keys) Tab(text: cat),
              ],
            ),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: TabBarView(
                children: [
                  for (final entry in _categories.entries)
                    _EmojiGrid(
                      emoji: entry.value,
                      onTap: (char) {
                        _log.i('sticker picked', {'char': char});
                        final layer = StickerLayer(
                          id: id,
                          character: char,
                          fontSize: 120,
                        );
                        Navigator.of(context).pop(layer);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({required this.emoji, required this.onTap});

  final List<String> emoji;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(Spacing.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 64,
        mainAxisSpacing: Spacing.sm,
        crossAxisSpacing: Spacing.sm,
      ),
      itemCount: emoji.length,
      itemBuilder: (context, index) {
        final char = emoji[index];
        return InkResponse(
          onTap: () => onTap(char),
          radius: 24,
          child: Center(
            child: Text(char, style: const TextStyle(fontSize: 34)),
          ),
        );
      },
    );
  }
}
