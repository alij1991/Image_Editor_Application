import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';

final _log = AppLogger('StickerPickerSheet');

/// Emoji-based sticker picker. Phase 7 uses Unicode emoji so we don't
/// need image assets; real PNG/SVG stickers ship when the
/// `assets/stickers/` library is populated in a later phase.
///
/// Two browse modes:
///   - **Categories** (default): tab bar with grids per category.
///   - **Search**: typing in the search field hides the tabs and
///     shows a flat filtered grid across every category. Filter
///     matches the keyword tags below — typing "fire" surfaces the
///     flame emoji even though no category is named "fire".
class StickerPickerSheet extends StatefulWidget {
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

  @override
  State<StickerPickerSheet> createState() => _StickerPickerSheetState();
}

/// Catalogue of (emoji, keyword tags). Tags are searched case-
/// insensitively. Keep tags lower-case and English-only — i18n is a
/// follow-up.
class _Sticker {
  const _Sticker(this.char, this.tags);
  final String char;
  final List<String> tags;
}

const Map<String, List<_Sticker>> _kCategories = {
  'Smileys': [
    _Sticker('😀', ['grin', 'happy', 'smile']),
    _Sticker('😁', ['grin', 'beam', 'happy']),
    _Sticker('😂', ['joy', 'tears', 'laugh', 'lol']),
    _Sticker('🤣', ['rofl', 'laugh', 'roll']),
    _Sticker('😃', ['smile', 'happy']),
    _Sticker('😄', ['smile', 'happy']),
    _Sticker('😅', ['sweat', 'nervous', 'laugh']),
    _Sticker('😆', ['laugh', 'satisfied']),
    _Sticker('😉', ['wink', 'flirt']),
    _Sticker('😊', ['blush', 'smile', 'happy']),
    _Sticker('😇', ['halo', 'angel']),
    _Sticker('🙂', ['slight', 'smile']),
    _Sticker('🙃', ['upside', 'down']),
    _Sticker('😋', ['yum', 'tongue']),
    _Sticker('😎', ['cool', 'sunglasses']),
    _Sticker('😍', ['heart', 'eyes', 'love']),
    _Sticker('😘', ['kiss', 'love']),
    _Sticker('🥰', ['hearts', 'love']),
    _Sticker('🥲', ['tear', 'happy', 'sad']),
    _Sticker('😢', ['cry', 'sad', 'tear']),
    _Sticker('😭', ['cry', 'sob', 'sad']),
    _Sticker('😡', ['angry', 'mad']),
    _Sticker('🤔', ['think', 'hmm']),
    _Sticker('🤯', ['mind', 'blown', 'shock']),
  ],
  'Gestures': [
    _Sticker('👍', ['thumbs', 'up', 'good', 'like']),
    _Sticker('👎', ['thumbs', 'down', 'bad', 'dislike']),
    _Sticker('👌', ['ok', 'okay']),
    _Sticker('✌️', ['peace', 'victory']),
    _Sticker('🤞', ['fingers', 'crossed', 'luck']),
    _Sticker('🤟', ['love', 'rock']),
    _Sticker('🤘', ['rock', 'horns']),
    _Sticker('🤙', ['call', 'shaka']),
    _Sticker('👈', ['point', 'left']),
    _Sticker('👉', ['point', 'right']),
    _Sticker('👆', ['point', 'up']),
    _Sticker('👇', ['point', 'down']),
    _Sticker('☝️', ['index', 'up', 'one']),
    _Sticker('👋', ['wave', 'hi', 'hello', 'bye']),
    _Sticker('🙌', ['raised', 'hands', 'celebrate', 'praise']),
    _Sticker('👏', ['clap', 'applause']),
    _Sticker('🙏', ['pray', 'thanks', 'please']),
    _Sticker('💪', ['flex', 'strong', 'arm', 'muscle']),
  ],
  'Hearts': [
    _Sticker('❤️', ['heart', 'red', 'love']),
    _Sticker('🧡', ['heart', 'orange']),
    _Sticker('💛', ['heart', 'yellow']),
    _Sticker('💚', ['heart', 'green']),
    _Sticker('💙', ['heart', 'blue']),
    _Sticker('💜', ['heart', 'purple']),
    _Sticker('🖤', ['heart', 'black']),
    _Sticker('🤍', ['heart', 'white']),
    _Sticker('💔', ['broken', 'heart', 'sad']),
    _Sticker('💕', ['hearts', 'love', 'two']),
    _Sticker('💞', ['hearts', 'revolving', 'love']),
    _Sticker('💓', ['heart', 'beating', 'love']),
    _Sticker('💖', ['sparkling', 'heart', 'love']),
    _Sticker('💘', ['cupid', 'arrow', 'love']),
    _Sticker('💝', ['gift', 'heart', 'love']),
  ],
  'Nature': [
    _Sticker('🌸', ['cherry', 'blossom', 'flower', 'pink']),
    _Sticker('🌼', ['flower', 'daisy', 'yellow']),
    _Sticker('🌻', ['sunflower', 'flower', 'yellow']),
    _Sticker('🌺', ['hibiscus', 'flower', 'tropical']),
    _Sticker('🌷', ['tulip', 'flower']),
    _Sticker('🌹', ['rose', 'flower', 'red', 'love']),
    _Sticker('🍀', ['clover', 'luck', 'green']),
    _Sticker('🍁', ['leaf', 'maple', 'autumn', 'fall']),
    _Sticker('🍂', ['leaves', 'autumn', 'fall']),
    _Sticker('🌿', ['herb', 'green', 'leaf']),
    _Sticker('🌳', ['tree', 'green']),
    _Sticker('🌲', ['evergreen', 'tree', 'pine']),
    _Sticker('🌴', ['palm', 'tree', 'tropical']),
    _Sticker('🌵', ['cactus', 'desert']),
    _Sticker('🌊', ['wave', 'water', 'ocean', 'sea']),
    _Sticker('☀️', ['sun', 'sunny', 'bright']),
    _Sticker('⛅', ['sun', 'cloud', 'partly']),
    _Sticker('☁️', ['cloud', 'cloudy']),
    _Sticker('🌧️', ['rain', 'cloud']),
    _Sticker('⛈️', ['storm', 'thunder', 'lightning']),
    _Sticker('🌈', ['rainbow', 'colorful']),
    _Sticker('⭐', ['star', 'yellow']),
    _Sticker('🌟', ['glowing', 'star', 'sparkle']),
    _Sticker('✨', ['sparkles', 'glitter', 'shine']),
    _Sticker('⚡', ['lightning', 'bolt', 'thunder']),
    _Sticker('🔥', ['fire', 'flame', 'lit', 'hot']),
    _Sticker('❄️', ['snowflake', 'cold', 'winter']),
    _Sticker('🌙', ['moon', 'crescent', 'night']),
  ],
  'Animals': [
    _Sticker('🐶', ['dog', 'puppy', 'pet']),
    _Sticker('🐱', ['cat', 'kitten', 'pet']),
    _Sticker('🐭', ['mouse']),
    _Sticker('🐰', ['rabbit', 'bunny']),
    _Sticker('🦊', ['fox']),
    _Sticker('🐻', ['bear']),
    _Sticker('🐼', ['panda', 'bear']),
    _Sticker('🐨', ['koala', 'bear']),
    _Sticker('🐯', ['tiger']),
    _Sticker('🦁', ['lion']),
    _Sticker('🐮', ['cow']),
    _Sticker('🐷', ['pig']),
    _Sticker('🐸', ['frog']),
    _Sticker('🦄', ['unicorn']),
    _Sticker('🐝', ['bee', 'honey']),
    _Sticker('🦋', ['butterfly']),
    _Sticker('🐢', ['turtle', 'slow']),
    _Sticker('🐬', ['dolphin']),
    _Sticker('🐳', ['whale']),
    _Sticker('🦈', ['shark']),
  ],
  'Objects': [
    _Sticker('🎉', ['party', 'celebration', 'confetti']),
    _Sticker('🎊', ['confetti', 'ball', 'celebration']),
    _Sticker('🎈', ['balloon', 'party']),
    _Sticker('🎁', ['gift', 'present', 'wrapped']),
    _Sticker('🎀', ['ribbon', 'bow']),
    _Sticker('🏆', ['trophy', 'winner', 'gold']),
    _Sticker('🥇', ['medal', 'gold', 'first']),
    _Sticker('🎯', ['target', 'bullseye', 'dart']),
    _Sticker('🎨', ['art', 'palette', 'paint']),
    _Sticker('🎬', ['clapper', 'movie', 'film']),
    _Sticker('🎵', ['note', 'music']),
    _Sticker('🎤', ['microphone', 'sing', 'karaoke']),
    _Sticker('💎', ['diamond', 'gem']),
    _Sticker('💰', ['money', 'bag', 'cash']),
    _Sticker('👑', ['crown', 'royal', 'queen', 'king']),
    _Sticker('🕶️', ['sunglasses', 'shades', 'cool']),
    _Sticker('📷', ['camera', 'photo']),
    _Sticker('🖼️', ['frame', 'picture']),
    _Sticker('🏷️', ['label', 'tag']),
  ],
  'Food': [
    _Sticker('🍎', ['apple', 'red', 'fruit']),
    _Sticker('🍊', ['orange', 'fruit']),
    _Sticker('🍋', ['lemon', 'fruit', 'sour']),
    _Sticker('🍌', ['banana', 'fruit']),
    _Sticker('🍉', ['watermelon', 'fruit']),
    _Sticker('🍇', ['grapes', 'fruit']),
    _Sticker('🍓', ['strawberry', 'fruit', 'red']),
    _Sticker('🍑', ['peach', 'fruit']),
    _Sticker('🥭', ['mango', 'fruit', 'tropical']),
    _Sticker('🍍', ['pineapple', 'fruit', 'tropical']),
    _Sticker('🥑', ['avocado', 'fruit', 'green']),
    _Sticker('🍅', ['tomato', 'red']),
    _Sticker('🍔', ['burger', 'hamburger', 'food']),
    _Sticker('🍕', ['pizza', 'food']),
    _Sticker('🌮', ['taco', 'food', 'mexican']),
    _Sticker('🍰', ['cake', 'slice', 'dessert']),
    _Sticker('🧁', ['cupcake', 'dessert']),
    _Sticker('🍩', ['donut', 'dessert']),
    _Sticker('🍪', ['cookie', 'dessert']),
    _Sticker('🍫', ['chocolate', 'bar', 'dessert']),
    _Sticker('🍿', ['popcorn']),
    _Sticker('☕', ['coffee', 'hot', 'drink']),
    _Sticker('🍺', ['beer', 'drink']),
    _Sticker('🍷', ['wine', 'drink']),
  ],
  'Travel': [
    _Sticker('✈️', ['plane', 'airplane', 'flight', 'travel']),
    _Sticker('🚗', ['car', 'auto']),
    _Sticker('🚕', ['taxi', 'cab']),
    _Sticker('🚙', ['suv', 'car']),
    _Sticker('🚌', ['bus']),
    _Sticker('🚲', ['bicycle', 'bike']),
    _Sticker('🛴', ['scooter']),
    _Sticker('🏍️', ['motorcycle', 'bike']),
    _Sticker('🚀', ['rocket', 'launch', 'space']),
    _Sticker('🛸', ['ufo', 'flying', 'saucer']),
    _Sticker('🗺️', ['map', 'world']),
    _Sticker('🏖️', ['beach', 'umbrella', 'sand']),
    _Sticker('🏔️', ['mountain', 'snow']),
    _Sticker('🗽', ['liberty', 'statue', 'newyork']),
    _Sticker('🗼', ['tower', 'tokyo']),
    _Sticker('🏰', ['castle']),
  ],
};

class _StickerPickerSheetState extends State<StickerPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Flat filtered list when [_query] is non-empty, sorted with
  /// exact-tag matches first, then prefix matches, then substring
  /// matches.
  List<_Sticker> _filtered() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <(_Sticker, int)>[];
    for (final cat in _kCategories.values) {
      for (final s in cat) {
        int score = 0;
        for (final tag in s.tags) {
          if (tag == q) {
            score += 100;
          } else if (tag.startsWith(q)) {
            score += 50;
          } else if (tag.contains(q)) {
            score += 10;
          }
        }
        if (score > 0) hits.add((s, score));
      }
    }
    hits.sort((a, b) => b.$2.compareTo(a.$2));
    return hits.map((e) => e.$1).toList();
  }

  void _pick(String char) {
    _log.i('sticker picked', {'char': char});
    final layer = StickerLayer(
      id: widget.id,
      character: char,
      fontSize: 120,
    );
    Navigator.of(context).pop(layer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searching = _query.trim().isNotEmpty;
    return DefaultTabController(
      length: _kCategories.length,
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
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: searching
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  hintText: 'Search by tag (heart, fire, taco…)',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
              ),
            ),
            if (!searching)
              TabBar(
                isScrollable: true,
                tabs: [for (final cat in _kCategories.keys) Tab(text: cat)],
              ),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: searching
                  ? _SearchResults(stickers: _filtered(), onTap: _pick)
                  : TabBarView(
                      children: [
                        for (final entry in _kCategories.entries)
                          _StickerGrid(
                            stickers: entry.value,
                            onTap: _pick,
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

class _StickerGrid extends StatelessWidget {
  const _StickerGrid({required this.stickers, required this.onTap});

  final List<_Sticker> stickers;
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
      itemCount: stickers.length,
      itemBuilder: (context, index) {
        final s = stickers[index];
        return InkResponse(
          onTap: () => onTap(s.char),
          radius: 24,
          child: Center(
            child: Text(s.char, style: const TextStyle(fontSize: 34)),
          ),
        );
      },
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.stickers, required this.onTap});

  final List<_Sticker> stickers;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    if (stickers.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off,
                size: 36,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'No matches — try "heart", "fire", "smile"…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _StickerGrid(stickers: stickers, onTap: onTap);
  }
}
