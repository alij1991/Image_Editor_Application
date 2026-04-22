import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/save_to_files.dart';
import '../../../../core/theme/spacing.dart';
import '../../application/providers.dart';
import '../../data/ocr_service.dart';
import '../../domain/models/scan_models.dart';

final _log = AppLogger('ScanExport');

/// Export page: pick format + page size, give the file a name, and
/// share / save. Phase B wires PDF, DOCX, plain text, and JPEG-zip.
class ScannerExportPage extends ConsumerStatefulWidget {
  const ScannerExportPage({super.key});

  @override
  ConsumerState<ScannerExportPage> createState() => _ScannerExportPageState();
}

class _ScannerExportPageState extends ConsumerState<ScannerExportPage> {
  ExportOptions _options = const ExportOptions();
  late final TextEditingController _titleController;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerNotifierProvider);
    final session = state.session;
    if (session == null || session.pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          // Home affordance — the export route is reached via
          // `context.go`, so there's no implicit back arrow. Without
          // this the user is stuck on the export screen.
          leading: IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => context.go('/'),
          ),
          title: const Text('Export'),
        ),
        body: const Center(child: Text('No scan to export.')),
      );
    }
    final theme = Theme.of(context);
    final isOcrFormat = _options.format == ExportFormat.text ||
        (_options.format != ExportFormat.jpegZip && _options.includeOcr);

    return Scaffold(
      appBar: AppBar(
        // Home affordance — same Home/leading slot as the empty
        // export branch so the user always has a visible escape to
        // the main menu, even mid-config.
        leading: IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Export'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Spacing.lg),
          children: [
            Text('Document title', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                hintText: 'Optional — used as file name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            Text('Format', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final fmt in ExportFormat.values)
                  ChoiceChip(
                    avatar: Icon(_iconFor(fmt), size: 18),
                    label: Text(fmt.label),
                    selected: fmt == _options.format,
                    onSelected: (_) {
                      setState(() => _options = _options.copyWith(format: fmt));
                    },
                  ),
              ],
            ),
            if (_options.format == ExportFormat.pdf ||
                _options.format == ExportFormat.jpegZip) ...[
              const SizedBox(height: Spacing.lg),
              Text('Page size', style: theme.textTheme.titleSmall),
              const SizedBox(height: Spacing.xs),
              Wrap(
                spacing: Spacing.sm,
                children: [
                  for (final size in PageSize.values)
                    ChoiceChip(
                      label: Text(size.label),
                      selected: size == _options.pageSize,
                      onSelected: (_) {
                        setState(() =>
                            _options = _options.copyWith(pageSize: size));
                      },
                    ),
                ],
              ),
            ],
            if (_options.format != ExportFormat.text) ...[
              const SizedBox(height: Spacing.lg),
              Text('Image quality (${_options.jpegQuality})',
                  style: theme.textTheme.titleSmall),
              Slider(
                value: _options.jpegQuality.toDouble(),
                min: 50,
                max: 100,
                divisions: 10,
                label: '${_options.jpegQuality}',
                onChanged: (v) => setState(
                  () => _options = _options.copyWith(jpegQuality: v.round()),
                ),
              ),
            ],
            if (_options.format != ExportFormat.jpegZip) ...[
              const SizedBox(height: Spacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Make text searchable (OCR)'),
                subtitle: const Text(
                  'Runs on-device. Needed for text export; optional for '
                  'PDF and Word.',
                ),
                value: isOcrFormat,
                onChanged: _options.format == ExportFormat.text
                    ? null // forced on
                    : (v) => setState(
                          () => _options = _options.copyWith(includeOcr: v),
                        ),
              ),
              if (isOcrFormat) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  'OCR script',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Wrap(
                  key: const Key('export.ocr-script-picker'),
                  spacing: Spacing.xs,
                  children: [
                    for (final s in OcrScript.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: _options.ocrScript == s,
                        onSelected: (_) => setState(
                          () => _options = _options.copyWith(ocrScript: s),
                        ),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: Spacing.xl),
            FilledButton.icon(
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: Text(_isExporting ? 'Exporting…' : 'Save & share'),
              onPressed: _isExporting ? null : () => _export(session),
            ),
            const SizedBox(height: Spacing.sm),
            TextButton(
              onPressed: _isExporting ? null : () => context.go('/scanner/review'),
              child: const Text('Back to review'),
            ),
          ],
        ),
      ),
    );
  }

  /// Show a snackbar with a "Save to Files" action — non-blocking so
  /// the share sheet can still open. Pulled out of `_export` so the
  /// flow stays readable.
  Future<void> _offerSaveToFiles(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Saved · open Files to choose a destination'),
        action: SnackBarAction(
          label: 'Save to Files',
          onPressed: () async {
            final result = await SaveToFiles.save(path);
            if (!mounted) return;
            switch (result) {
              case SaveToFilesResult.success:
                UserFeedback.success(context, 'Saved to Files');
              case SaveToFilesResult.cancelled:
                // No-op — the user dismissed the picker.
                break;
              case SaveToFilesResult.unsupported:
                UserFeedback.info(context, 'Save to Files unavailable');
              case SaveToFilesResult.error:
                UserFeedback.error(context, 'Save to Files failed');
            }
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  IconData _iconFor(ExportFormat fmt) => switch (fmt) {
        ExportFormat.pdf => Icons.picture_as_pdf_outlined,
        ExportFormat.docx => Icons.description_outlined,
        ExportFormat.text => Icons.short_text,
        ExportFormat.jpegZip => Icons.folder_zip_outlined,
      };

  Future<void> _export(ScanSession session) async {
    setState(() => _isExporting = true);
    final title = _titleController.text.trim();
    if (title.isNotEmpty) {
      ref.read(scannerNotifierProvider.notifier).setTitle(title);
    }
    final format = _options.format;
    _log.i('export start', {
      'format': format.name,
      'pages': session.pages.length,
      'size': _options.pageSize.name,
      'q': _options.jpegQuality,
      'ocr': _options.includeOcr,
    });
    try {
      // OCR pass if needed (text export or user opted-in for PDF/DOCX).
      final needsOcr = format == ExportFormat.text ||
          ((format == ExportFormat.pdf || format == ExportFormat.docx) &&
              _options.includeOcr);
      if (needsOcr) {
        await ref.read(scannerNotifierProvider.notifier).runOcrIfMissing();
      }
      final current = ref.read(scannerNotifierProvider).session ?? session;
      final sessionToExport =
          title.isEmpty ? current : current.copyWith(title: title);

      File file;
      String mime;
      switch (format) {
        case ExportFormat.pdf:
          file = await ref
              .read(pdfExporterProvider)
              .export(sessionToExport, options: _options);
          mime = 'application/pdf';
          break;
        case ExportFormat.docx:
          file = await ref
              .read(docxExporterProvider)
              .export(sessionToExport, options: _options);
          mime =
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
          break;
        case ExportFormat.text:
          file = await ref.read(textExporterProvider).export(sessionToExport);
          mime = 'text/plain';
          break;
        case ExportFormat.jpegZip:
          file =
              await ref.read(jpegZipExporterProvider).export(sessionToExport);
          mime = 'application/zip';
          break;
      }

      // Persist the session to history so the user can re-export later.
      await ref.read(scannerNotifierProvider.notifier).persistCurrent();
      ref.invalidate(scanHistoryProvider);

      _log.i('export ok', {'path': file.path, 'fmt': format.name});
      if (!mounted) return;
      UserFeedback.success(context, 'Saved · ${file.uri.pathSegments.last}');
      // VIII.17 — on iOS, give the user a one-tap "Save to Files"
      // affordance alongside Share. The native picker is faster than
      // Share → "Save to Files" → pick destination.
      if (mounted && SaveToFiles.isAvailable) {
        await _offerSaveToFiles(context, file.path);
      }
      // Share is best-effort — the file is already on disk, so a share
      // failure doesn't invalidate the export itself. Log and swallow.
      try {
        await Share.shareXFiles(
          [XFile(file.path, mimeType: mime)],
          subject: title.isEmpty ? 'Scanned document' : title,
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
}
