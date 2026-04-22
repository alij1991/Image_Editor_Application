import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/collage_notifier.dart';
import '../../data/collage_exporter.dart';
import '../../domain/collage_state.dart';
import '../../domain/collage_template.dart';
import '../widgets/collage_canvas.dart';

final _log = AppLogger('CollagePage');

/// VIII.6 — collage export resolution presets. The numeric value
/// is fed straight to `RenderRepaintBoundary.toImage(pixelRatio:)`.
///
/// `standard` matches the pre-VIII.6 default (close to the old 2.5×
/// hard-coded value, rounded up). `high` produces ~print quality on
/// most aspect ratios; `maximum` is for users who want to crop or
/// re-frame in a downstream editor without losing resolution.
enum CollageResolution {
  standard(3.0, 'Standard', '~3× device pixels'),
  high(5.0, 'High', '~5× device pixels'),
  maximum(8.0, 'Maximum', '~8× device pixels'),
  ;

  const CollageResolution(this.pixelRatio, this.label, this.description);

  final double pixelRatio;
  final String label;
  final String description;
}

/// Bottom-sheet picker for collage export resolution. Returns the
/// chosen pixelRatio, or `null` if the user dismissed it.
///
/// Top-level so widget tests can drive the pure picker without
/// pumping the full collage page + its providers.
Future<double?> showCollageResolutionPicker(BuildContext context) async {
  final selected = await showModalBottomSheet<CollageResolution>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _CollageResolutionSheet(),
  );
  return selected?.pixelRatio;
}

class _CollageResolutionSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Export resolution', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.sm),
            for (final option in CollageResolution.values)
              ListTile(
                key: Key('collage-res.${option.name}'),
                title: Text(option.label),
                subtitle: Text(option.description),
                trailing: Text(
                  '${option.pixelRatio.toStringAsFixed(0)}×',
                  style: theme.textTheme.titleSmall,
                ),
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
  }
}

/// Top-level page for the collage editor. Shows the live canvas up top
/// and a tabbed control bar at the bottom (Layout / Aspect / Border /
/// Background). Export renders the canvas via RepaintBoundary → PNG →
/// share_plus.
class CollagePage extends ConsumerStatefulWidget {
  const CollagePage({super.key});

  @override
  ConsumerState<CollagePage> createState() => _CollagePageState();
}

class _CollagePageState extends ConsumerState<CollagePage>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  late final TabController _tabs;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    // Hydrate any previously-saved session from disk. Fire-and-forget
    // — the UI renders the default template immediately, and the
    // notifier swaps state in once [CollageRepository.load] resolves.
    // If the user starts editing before the load lands the in-memory
    // edits are overwritten by the restored state, but load is fast
    // (<10 ms for a single JSON file) so the race window is small.
    unawaited(
      Future.microtask(
        () => ref.read(collageNotifierProvider.notifier).hydrate(),
      ),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _pickImageFor(int index) async {
    _log.i('pick tapped', {'idx': index});
    Haptics.tap();
    final picker = ImagePicker();
    try {
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      ref.read(collageNotifierProvider.notifier).setCellImage(index, picked.path);
    } catch (e, st) {
      _log.e('pick failed', error: e, stackTrace: st);
      if (!mounted) return;
      UserFeedback.error(context, 'Could not load image: $e');
    }
  }

  Future<void> _export() async {
    if (_isExporting) return;
    final pixelRatio = await showCollageResolutionPicker(context);
    if (pixelRatio == null) return;
    if (!mounted) return;
    setState(() => _isExporting = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('Canvas not mounted');
      }
      const exporter = CollageExporter();
      final file = await exporter.export(
        boundary: boundary,
        pixelRatio: pixelRatio,
      );
      _log.i('export ok', {'path': file.path});
      if (!mounted) return;
      UserFeedback.success(context, 'Saved · ${file.uri.pathSegments.last}');
      try {
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'image/png')],
          subject: 'My collage',
        );
      } catch (e) {
        _log.w('share failed', {'err': e.toString()});
      }
    } catch (e, st) {
      _log.e('export failed', error: e, stackTrace: st);
      if (!mounted) return;
      UserFeedback.error(context, 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(collageNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Collage'),
        actions: [
          IconButton(
            tooltip: 'Export & share',
            icon: _isExporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: _isExporting ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: CollageCanvas(
                    state: state,
                    onCellTap: _pickImageFor,
                  ),
                ),
              ),
            ),
          ),
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Layout'),
              Tab(text: 'Aspect'),
              Tab(text: 'Borders'),
              Tab(text: 'Background'),
            ],
          ),
          SizedBox(
            // Tall enough to fit the Borders tab's three stacked
            // slider rows without forcing an internal scroll. Other
            // tabs are horizontal and centre inside this box cleanly.
            height: 180,
            child: TabBarView(
              controller: _tabs,
              children: [
                _LayoutTab(state: state),
                _AspectTab(state: state),
                _BorderTab(state: state),
                _BackgroundTab(state: state),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LayoutTab extends ConsumerWidget {
  const _LayoutTab({required this.state});
  final CollageState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(Spacing.md),
      itemCount: CollageTemplates.all.length,
      separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
      itemBuilder: (ctx, i) {
        final t = CollageTemplates.all[i];
        final selected = t.id == state.template.id;
        return _TemplateThumb(
          template: t,
          selected: selected,
          onTap: () {
            Haptics.tap();
            ref.read(collageNotifierProvider.notifier).setTemplate(t);
          },
        );
      },
    );
  }
}

class _TemplateThumb extends StatelessWidget {
  const _TemplateThumb({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final CollageTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 72,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            width: selected ? 2 : 1,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(
                  painter: _TemplateThumbPainter(
                    cells: template.cells,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              template.name,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateThumbPainter extends CustomPainter {
  _TemplateThumbPainter({required this.cells, required this.color});
  final List<CollageCellRect> cells;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final r in cells) {
      canvas.drawRect(
        Rect.fromLTWH(
          r.left * size.width,
          r.top * size.height,
          r.width * size.width,
          r.height * size.height,
        ),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TemplateThumbPainter old) =>
      old.cells != cells || old.color != color;
}

class _AspectTab extends ConsumerWidget {
  const _AspectTab({required this.state});
  final CollageState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          for (final a in CollageAspect.values) ...[
            ChoiceChip(
              label: Text(a.label),
              selected: state.aspect == a,
              onSelected: (_) {
                Haptics.tap();
                ref.read(collageNotifierProvider.notifier).setAspect(a);
              },
            ),
            const SizedBox(width: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

class _BorderTab extends ConsumerWidget {
  const _BorderTab({required this.state});
  final CollageState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(collageNotifierProvider.notifier);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      children: [
        _SliderRow(
          label: 'Inner gap',
          value: state.innerBorder,
          min: 0,
          max: 32,
          onChanged: notifier.setInnerBorder,
        ),
        _SliderRow(
          label: 'Outer margin',
          value: state.outerMargin,
          min: 0,
          max: 48,
          onChanged: notifier.setOuterMargin,
        ),
        _SliderRow(
          label: 'Corner radius',
          value: state.cornerRadius,
          min: 0,
          max: 40,
          onChanged: notifier.setCornerRadius,
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 100, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.toStringAsFixed(0),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

class _BackgroundTab extends ConsumerWidget {
  const _BackgroundTab({required this.state});
  final CollageState state;

  static const List<Color> _swatches = [
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFEDE7D9),
    Color(0xFFF5C6BC),
    Color(0xFFBFD7EA),
    Color(0xFFC1E1C1),
    Color(0xFFFFE8A3),
    Color(0xFF2E2E2E),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(collageNotifierProvider.notifier);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          for (final c in _swatches) ...[
            _Swatch(
              color: c,
              selected: state.backgroundColor.toARGB32() == c.toARGB32(),
              onTap: () {
                Haptics.tap();
                notifier.setBackgroundColor(c);
              },
            ),
            const SizedBox(width: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            width: selected ? 3 : 1,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}
