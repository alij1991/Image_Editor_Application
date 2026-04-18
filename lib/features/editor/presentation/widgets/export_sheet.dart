import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../data/export_service.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('ExportSheet');

/// Bottom sheet that lets the user pick the format / quality / size of
/// an exported image and either share it or save a copy.
///
/// The sheet keeps its own state (format, quality, size) so the user
/// can experiment without committing to anything; the actual encode
/// only runs when they tap Share. A successful export hands the
/// resulting file to `share_plus` so the user can route it to Photos /
/// Files / Messages — the same path Apple Photos / Snapseed take.
class ExportSheet extends StatefulWidget {
  const ExportSheet({required this.session, super.key});

  final EditorSession session;

  static Future<void> show(BuildContext context, EditorSession session) {
    _log.i('opened');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ExportSheet(session: session),
    );
  }

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

/// Resize presets shown as chips. `null` = "Original" — clamp at the
/// source's native long-edge.
const Map<String, int?> _kSizePresets = {
  'Original': null,
  '4K': 3840,
  '2K': 2048,
  '1080p': 1920,
  '720p': 1280,
};

/// Formats the user can actually pick today. WebP is in the
/// [ExportFormat] enum (so the API stays forward-compatible) but not
/// in this list — the `image` 4.x encoder is PNG-only for WebP, so
/// surfacing the chip would let the user select an option that
/// errors at share time. Re-add when image: ^5.x lands with real
/// WebP encode.
const List<ExportFormat> _kAvailableFormats = [
  ExportFormat.jpeg,
  ExportFormat.png,
];

class _ExportSheetState extends State<ExportSheet> {
  ExportFormat _format = ExportFormat.jpeg;
  int _quality = 92;
  String _sizeLabel = 'Original';
  bool _busy = false;

  // Live preview of the rendered output. The thumbnail is rendered
  // once at sheet open (against the same shader chain the canvas
  // uses, but downscaled to 256-px long-edge for cheap turnaround)
  // and reused for every format/quality change — encoding artifacts
  // aren't visible at thumbnail size, so re-rendering per change
  // would cost a lot for nothing.
  ui.Image? _preview;
  bool _previewLoading = true;
  Object? _previewError;

  @override
  void initState() {
    super.initState();
    _renderPreview();
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _renderPreview() async {
    final svc = ExportService();
    try {
      // Decode the source at 256-px long-edge — same render path the
      // editor preview uses, just at thumbnail resolution. Disposes
      // the source after rendering to avoid pinning the decoded
      // bytes for the lifetime of the sheet.
      final src = await svc.decodeFullRes(
        sourcePath: widget.session.sourcePath,
        maxLongEdge: 256,
      );
      try {
        final image = await svc.renderToImage(
          source: src,
          passes: widget.session.previewController.passes.value,
          geometry: widget.session.previewController.geometry.value,
        );
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _preview?.dispose();
          _preview = image;
          _previewLoading = false;
          _previewError = null;
        });
      } finally {
        src.dispose();
      }
    } catch (e, st) {
      _log.w('preview render failed', {'error': e.toString()});
      _log.e('preview trace', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _previewLoading = false;
        _previewError = e;
      });
    }
  }

  Future<void> _onShare() async {
    if (_busy) return;
    setState(() => _busy = true);
    Haptics.tap();
    final svc = ExportService();
    try {
      final session = widget.session;
      final result = await svc.export(
        sourcePath: session.sourcePath,
        passes: session.previewController.passes.value,
        geometry: session.previewController.geometry.value,
        format: _format,
        quality: _quality,
        maxLongEdge: _kSizePresets[_sizeLabel],
      );
      _log.i('export ok', {
        'format': result.format.name,
        'bytes': result.bytes,
        'w': result.width,
        'h': result.height,
        'ms': result.elapsed.inMilliseconds,
      });
      if (!mounted) return;
      // Hand off to the share sheet. The user can pick "Save to
      // Photos" or any other destination from there.
      final shareResult = await Share.shareXFiles(
        [XFile(result.file.path, mimeType: result.format.mimeType)],
        text: 'Exported with Image Editor',
      );
      _log.i('share result', {'status': shareResult.status.name});
      if (!mounted) return;
      Haptics.impact();
      Navigator.of(context).pop();
      UserFeedback.success(context,
          'Exported (${_kbDisplay(result.bytes)}, ${result.format.label})');
    } on ExportException catch (e) {
      _log.w('export failed', {'msg': e.message});
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, e.message);
    } catch (e, st) {
      _log.e('export crashed', error: e, stackTrace: st);
      if (!mounted) return;
      Haptics.warning();
      UserFeedback.error(context, 'Unexpected export error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _kbDisplay(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qualityEnabled = _format == ExportFormat.jpeg;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Export', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Render the current edits at full resolution and share '
                'the file. The original photo is never touched.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.md),

              // Live thumbnail preview of the rendered output. Reuses
              // the same shader chain the canvas runs, just at 256-px
              // long-edge for a fast turnaround. Tap → re-render in
              // case the user wants to reflect very recent edits
              // applied while the sheet was open.
              _PreviewCard(
                image: _preview,
                loading: _previewLoading,
                error: _previewError,
                onRefresh: _previewLoading ? null : _renderPreview,
              ),
              const SizedBox(height: Spacing.lg),

              // Format chips
              Text('Format', style: theme.textTheme.titleSmall),
              const SizedBox(height: Spacing.xs),
              Wrap(
                spacing: Spacing.xs,
                children: [
                  for (final f in _kAvailableFormats)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: _format == f,
                      onSelected: _busy
                          ? null
                          : (sel) {
                              if (sel) setState(() => _format = f);
                            },
                    ),
                ],
              ),
              const SizedBox(height: Spacing.lg),

              // Quality slider (JPEG only)
              Row(
                children: [
                  Text('Quality', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    qualityEnabled ? '$_quality' : '—',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: qualityEnabled
                          ? null
                          : theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Slider(
                min: 1,
                max: 100,
                divisions: 99,
                value: _quality.toDouble(),
                label: '$_quality',
                onChanged: qualityEnabled && !_busy
                    ? (v) => setState(() => _quality = v.round())
                    : null,
              ),
              if (!qualityEnabled)
                Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: Text(
                    'PNG is lossless — quality has no effect.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: Spacing.lg),

              // Size chips
              Text('Long-edge size', style: theme.textTheme.titleSmall),
              const SizedBox(height: Spacing.xs),
              Wrap(
                spacing: Spacing.xs,
                children: [
                  for (final entry in _kSizePresets.entries)
                    ChoiceChip(
                      label: Text(entry.key),
                      selected: _sizeLabel == entry.key,
                      onSelected: _busy
                          ? null
                          : (sel) {
                              if (sel) setState(() => _sizeLabel = entry.key);
                            },
                    ),
                ],
              ),
              const SizedBox(height: Spacing.xl),

              // Action row
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _onShare,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share),
                      label: Text(_busy ? 'Rendering…' : 'Share / Save'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'Tap "Save to Photos" in the share sheet to keep a '
                'copy in your gallery.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact preview card pinned above the format chips. Shows the
/// rendered output at a fixed height; loading state and errors get a
/// graceful fallback so a missing-source / decode-failure doesn't
/// strand the user — they can still proceed with the share path.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.image,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final ui.Image? image;
  final bool loading;
  final Object? error;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aspect = image == null
        ? 16 / 10.0
        : image!.width / image!.height;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: aspect.clamp(0.5, 2.5),
        child: Container(
          color: theme.colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image != null)
                RawImage(image: image, fit: BoxFit.contain)
              else if (loading)
                const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          'Preview unavailable — share will still work.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (image != null && onRefresh != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Refresh preview',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      onPressed: onRefresh,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
