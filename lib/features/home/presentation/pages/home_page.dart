import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../core/theme/theme_mode_controller.dart';
import '../../../editor/data/project_store.dart';

final _log = AppLogger('HomePage');

/// Landing page with gallery + camera CTAs and a hint card explaining
/// what the editor does. Phase 12 will add a gallery / recent edits
/// section here.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// True while the system image-picker dialog is open. Guards against
  /// a second tap queueing another pickImage() call (the picker
  /// plugin's behaviour on rapid double-tap is platform-specific —
  /// safer to gate at the UI layer). Also drives the CTA tiles' busy
  /// styling so the user sees the tap registered.
  bool _picking = false;

  /// Cached project summaries for the recent-projects strip. Filled
  /// lazily on init and refreshed when the user returns from the
  /// editor (so a freshly-saved session shows up). Empty list = no
  /// saved projects yet.
  List<ProjectSummary> _recents = const [];

  /// User-entered search query — when non-empty the strip shows only
  /// projects whose custom title or source-path basename contains the
  /// query (case-insensitive substring). The search field appears
  /// once the user has more than 5 saved sessions; below that the
  /// strip itself is the entire scan surface.
  final TextEditingController _recentsSearch = TextEditingController();
  String _recentsQuery = '';

  /// True until the first ProjectStore.list() call resolves. Drives a
  /// shimmer-style skeleton row so the UI doesn't flicker between
  /// nothing → strip when storage is slow on first launch.
  bool _recentsLoading = true;

  final ProjectStore _store = ProjectStore();

  @override
  void initState() {
    super.initState();
    _refreshRecents();
  }

  @override
  void dispose() {
    _recentsSearch.dispose();
    super.dispose();
  }

  Future<void> _refreshRecents() async {
    try {
      final list = await _store.list();
      if (!mounted) return;
      // Hide projects with no edits so the strip doesn't show every
      // photo the user ever opened — only the ones they actually
      // tweaked. Cap at 50 so the disk-walk doesn't dominate; the
      // search field handles the case where the user has more.
      final filtered = list.where((p) => p.opCount > 0).take(50).toList();
      setState(() {
        _recents = filtered;
        _recentsLoading = false;
      });
    } catch (e, st) {
      _log.w('recents load failed', {'error': e.toString()});
      _log.e('recents trace', error: e, stackTrace: st);
      if (mounted) setState(() => _recentsLoading = false);
    }
  }

  /// The list shown in the strip — `_recents` filtered by the
  /// current query. Returns the unfiltered list when the query is
  /// empty.
  List<ProjectSummary> _visibleRecents() {
    final q = _recentsQuery.trim().toLowerCase();
    if (q.isEmpty) return _recents;
    return _recents.where((p) {
      final name = p.sourcePath.split('/').last.toLowerCase();
      final title = p.customTitle?.toLowerCase() ?? '';
      return name.contains(q) || title.contains(q);
    }).toList();
  }

  Future<void> _openRecent(BuildContext context, ProjectSummary p) async {
    _log.i('recent tapped', {'path': p.sourcePath, 'ops': p.opCount});
    Haptics.tap();
    if (!File(p.sourcePath).existsSync()) {
      // The original photo got moved or deleted. Drop the dead
      // project entry and tell the user.
      _log.w('recent missing source', {'path': p.sourcePath});
      await _store.delete(p.sourcePath);
      await _refreshRecents();
      if (!context.mounted) return;
      UserFeedback.info(
        context,
        'Original photo no longer available — entry removed.',
      );
      return;
    }
    if (!context.mounted) return;
    // Routing back into the editor will re-hydrate the project via
    // EditorSession.start → ProjectStore.load.
    await context.push('/editor', extra: p.sourcePath);
    if (mounted) await _refreshRecents();
  }

  Future<void> _showRecentMenu(
    BuildContext context,
    ProjectSummary p,
  ) async {
    Haptics.tap();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text(
                'Forget session',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'rename':
        await _renameRecent(context, p);
      case 'delete':
        await _confirmDeleteRecent(context, p);
    }
  }

  Future<void> _renameRecent(BuildContext context, ProjectSummary p) async {
    // Tiny dialog with a TextField pre-filled with the current name.
    // Saves through ProjectStore.save with the same pipeline JSON
    // re-loaded from disk so we don't lose state.
    final controller = TextEditingController(
      text: p.customTitle ?? p.sourcePath.split('/').last,
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Trip to Big Sur',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null) return;
    final trimmed = newName.trim();
    final pipeline = await _store.load(p.sourcePath);
    if (pipeline == null) {
      _log.w('rename: pipeline missing', {'path': p.sourcePath});
      if (!context.mounted) return;
      UserFeedback.error(context, 'Could not rename — session not found.');
      return;
    }
    await _store.save(
      sourcePath: p.sourcePath,
      pipeline: pipeline,
      customTitle: trimmed,
    );
    await _refreshRecents();
    if (!context.mounted) return;
    UserFeedback.info(
      context,
      trimmed.isEmpty ? 'Custom name cleared' : 'Renamed to "$trimmed"',
    );
  }

  Future<void> _confirmDeleteRecent(
    BuildContext context,
    ProjectSummary p,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this session?'),
        content: Text(
          'The original photo at ${p.sourcePath.split('/').last} '
          'is left untouched. Only the edit history will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.delete(p.sourcePath);
    await _refreshRecents();
    if (!context.mounted) return;
    UserFeedback.info(context, 'Session forgotten');
  }

  Future<void> _pickFrom(BuildContext context, ImageSource source) async {
    if (_picking) {
      _log.d('pick rejected — already picking', {'source': source.name});
      return;
    }
    _log.i('pick tapped', {'source': source.name});
    Haptics.tap();
    setState(() => _picking = true);
    final picker = ImagePicker();
    try {
      final picked = await picker.pickImage(source: source);
      if (picked == null) {
        _log.d('pick cancelled', {'source': source.name});
        return;
      }
      _log.i('picked', {'path': picked.path, 'name': picked.name});
      if (!context.mounted) return;
      // Use push so we land back on home when the user pops out of
      // the editor — that's where _refreshRecents() runs to surface
      // their freshly-saved session.
      await context.push('/editor', extra: picked.path);
      if (mounted) await _refreshRecents();
    } catch (e, st) {
      _log.e('pick failed', error: e, stackTrace: st);
      if (!context.mounted) return;
      UserFeedback.error(context, 'Could not load image: $e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image Editor'),
        actions: [
          IconButton(
            tooltip: 'Scan history',
            icon: const Icon(Icons.history),
            onPressed: () {
              _log.i('history tapped');
              context.go('/scanner/history');
            },
          ),
          const _ThemeToggleAction(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              _log.i('settings tapped');
              context.push('/settings');
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          // Wrap the column so the layout never overflows on short
          // viewports (some Android phones, landscape orientation, or
          // when the system is showing extra UI like a Now Playing
          // notch). The Spacer below collapses gracefully when there's
          // less than the full viewport available.
          padding: const EdgeInsets.all(Spacing.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom -
                  kToolbarHeight -
                  Spacing.xl * 2,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const Spacer(),
                  Icon(
                    Icons.auto_fix_high,
                    size: 96,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    'Image Editor',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Professional, non-destructive photo editing',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Spacing.xl),
                  _HintCard(),
                  if (_recentsLoading) ...[
                    const SizedBox(height: Spacing.xl),
                    const _RecentProjectsSkeleton(),
                  ] else if (_recents.isNotEmpty) ...[
                    const SizedBox(height: Spacing.xl),
                    if (_recents.length > 5) ...[
                      _RecentsSearchField(
                        controller: _recentsSearch,
                        onChanged: (v) => setState(() => _recentsQuery = v),
                      ),
                      const SizedBox(height: Spacing.sm),
                    ],
                    _RecentProjectsRow(
                      projects: _visibleRecents(),
                      query: _recentsQuery,
                      onTap: (p) => _openRecent(context, p),
                      onLongPress: (p) => _showRecentMenu(context, p),
                    ),
                  ],
                  const Spacer(),
                  // Primary CTA row: three big tiles mirroring Google Photos /
                  // Apple Photos' create-surface UX.
                  Row(
                    children: [
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.auto_fix_high,
                          label: 'Edit photo',
                          busy: _picking,
                          onTap: _picking
                              ? null
                              : () {
                                  _log.i('edit tapped');
                                  Haptics.tap();
                                  _pickFrom(context, ImageSource.gallery);
                                },
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.document_scanner_outlined,
                          label: 'Scan document',
                          onTap: _picking
                              ? null
                              : () {
                                  _log.i('scan tapped');
                                  Haptics.tap();
                                  context.go('/scanner');
                                },
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: _CtaTile(
                          icon: Icons.grid_view_rounded,
                          label: 'Make collage',
                          onTap: _picking ? null : () async {
                            _log.i('collage tapped');
                            Haptics.tap();
                            // The /collage route is wired by the collage
                            // feature module. If the module isn't loaded
                            // yet (route not registered) GoRouter throws
                            // — catch it and show a friendly message so
                            // the home page stays resilient.
                            // Two failure modes: GoError = route not
                            // registered (collage module unloaded → show
                            // a friendly hint); anything else = real
                            // bug, surface so it gets reported instead
                            // of being swallowed as "coming soon".
                            try {
                              context.go('/collage');
                            } on GoError catch (e) {
                              _log.w('collage route missing',
                                  {'msg': e.message});
                              UserFeedback.info(
                                context,
                                'Collage — coming soon',
                              );
                            } catch (e, st) {
                              _log.e('collage navigation failed',
                                  error: e, stackTrace: st);
                              UserFeedback.error(
                                context,
                                'Could not open collage: $e',
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  // Secondary row: camera shortcut (direct-capture).
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Take a photo'),
                    onPressed: _picking
                        ? null
                        : () => _pickFrom(context, ImageSource.camera),
                  ),
                  const SizedBox(height: Spacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pulsing placeholder shown while ProjectStore.list() resolves. Same
/// dimensions as [_RecentTile] so the layout doesn't jump when real
/// data lands. The opacity tween is cheap and runs on the platform's
/// vsync — no extra dependency for a shimmer effect.
class _RecentProjectsSkeleton extends StatefulWidget {
  const _RecentProjectsSkeleton();

  @override
  State<_RecentProjectsSkeleton> createState() =>
      _RecentProjectsSkeletonState();
}

class _RecentProjectsSkeletonState extends State<_RecentProjectsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.xs),
          child: Text(
            'Continue editing',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        ),
        SizedBox(
          height: 116,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              final t = 0.4 + 0.4 * _ctrl.value;
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
                itemBuilder: (context, _) => Container(
                  width: 96,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: t),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Horizontal strip of recent edit sessions. Each tile shows the
/// source-photo thumbnail, file name, op count, and a relative
/// timestamp. Tap to resume the session; long-press for the delete
/// confirm.
class _RecentProjectsRow extends StatelessWidget {
  const _RecentProjectsRow({
    required this.projects,
    required this.onTap,
    required this.onLongPress,
    this.query = '',
  });

  final List<ProjectSummary> projects;
  final ValueChanged<ProjectSummary> onTap;
  final ValueChanged<ProjectSummary> onLongPress;

  /// The active search query — used to switch the section header
  /// between "Continue editing" and a result count, and to render
  /// the no-results empty state instead of an empty strip.
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searching = query.trim().isNotEmpty;
    final header = searching
        ? '${projects.length} match${projects.length == 1 ? "" : "es"}'
        : 'Continue editing';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.xs),
          child: Text(
            header,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (projects.isEmpty)
          Container(
            height: 116,
            alignment: Alignment.center,
            child: Text(
              'No sessions match "$query"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: projects.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, i) => _RecentTile(
                project: projects[i],
                onTap: () => onTap(projects[i]),
                onLongPress: () => onLongPress(projects[i]),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact search field above the recents strip. Hidden when the
/// user has 5 or fewer sessions — the strip itself is browseable
/// at that scale and the field would just add chrome.
class _RecentsSearchField extends StatelessWidget {
  const _RecentsSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              )
            : null,
        hintText: 'Search recent sessions',
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.project,
    required this.onTap,
    required this.onLongPress,
  });

  final ProjectSummary project;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileName = project.sourcePath.split('/').last;
    final displayName = project.displayLabel(fileName);
    final file = File(project.sourcePath);
    return SizedBox(
      width: 96,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: file.existsSync()
                    ? Image.file(
                        file,
                        fit: BoxFit.cover,
                        // Decode at thumbnail resolution — the tile
                        // is 96 dp wide, so we ask for ~3× pixel
                        // density (≈ 288) to look sharp on hi-DPI
                        // displays without bloating the image cache
                        // with the full source. A bare Image.file
                        // would decode the full 12-megapixel photo
                        // for a 96 px thumbnail.
                        cacheWidth: 288,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, _, _) =>
                            _MissingThumb(theme: theme),
                      )
                    : _MissingThumb(theme: theme),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: project.customTitle != null
                            ? FontWeight.w600
                            : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                    Text(
                      '${project.opCount} edit${project.opCount == 1 ? "" : "s"} '
                      '· ${_relative(project.savedAt)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relative(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return DateFormat.MMMd().format(ts);
  }
}

class _MissingThumb extends StatelessWidget {
  const _MissingThumb({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Large tappable tile used in the 3-CTA row on the home screen.
/// Mirrors the create-surface tiles in Google Photos / Apple Photos:
/// big icon, single-word label, generous touch target.
class _CtaTile extends StatelessWidget {
  const _CtaTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;

  /// Null disables the tile (the InkWell goes unresponsive and the
  /// tile fades). Used by the home page to gate against double-taps
  /// while the system image-picker is open.
  final VoidCallback? onTap;

  /// When true, replace the icon with a small spinner so the user
  /// sees that the tile they just tapped is doing work. Disables
  /// taps independently of [onTap] for clarity.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled && !busy ? 0.5 : 1.0,
      child: Material(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: Spacing.lg,
              horizontal: Spacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  )
                else
                  Icon(icon,
                      size: 32, color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(height: Spacing.sm),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tips_and_updates_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: Spacing.sm),
                Text('Quick tips', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            const _HintLine(
              icon: Icons.palette_outlined,
              text:
                  '6 tool categories: Light, Color, Effects, Detail, Optics, Geometry',
            ),
            const _HintLine(
              icon: Icons.swipe_outlined,
              text:
                  'Swipe horizontally on the photo to adjust, vertically to switch parameters',
            ),
            const _HintLine(
              icon: Icons.compare_outlined,
              text: 'Hold the compare button to see the original at any time',
            ),
            const _HintLine(
              icon: Icons.undo_outlined,
              text: 'Undo / Redo every step — your original is never changed',
            ),
          ],
        ),
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// App-bar action that cycles theme mode (dark → light → system → dark)
/// and persists the choice. Icon mirrors the active mode so the user
/// can see at a glance what they're switching from.
class _ThemeToggleAction extends ConsumerWidget {
  const _ThemeToggleAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeControllerProvider);
    final controller = ref.read(themeModeControllerProvider.notifier);
    final (icon, label) = switch (mode) {
      ThemeMode.dark => (Icons.dark_mode, 'Dark'),
      ThemeMode.light => (Icons.light_mode, 'Light'),
      ThemeMode.system => (Icons.brightness_auto, 'System'),
    };
    return IconButton(
      tooltip: 'Theme: $label (tap to change)',
      icon: Icon(icon),
      onPressed: () {
        Haptics.tap();
        controller.cycle();
      },
    );
  }
}
