/// XVI.97 (B3) — `/dev/ai-test-lab` screen scaffold.
///
/// This is the framework the runners (B4) and persistence (B5) bolt
/// onto. The shipped scaffold:
///
/// - Loads the test corpus from `assets/test_images/manifest.json`.
/// - Renders a horizontal carousel of bundled test images.
/// - Renders the op-picker list driven by [kLabOps].
/// - Wires three run-mode buttons — selected-op-on-selected-image,
///   selected-op-on-all-images, full-matrix.
/// - Shows a result placeholder until B4 lands the per-op runners.
///
/// The page is debug-only — the home-page link is gated behind
/// `kDebugMode`, and the route exists in release builds purely to
/// keep the URL stable for integration_test.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../ai/lab/corpus/corpus.dart';
import '../lab_op_catalogue.dart';

class AiLabPage extends StatefulWidget {
  const AiLabPage({super.key});

  @override
  State<AiLabPage> createState() => _AiLabPageState();
}

enum _RunScope { single, opAcrossImages, fullMatrix }

class _AiLabPageState extends State<AiLabPage> {
  TestCorpus? _corpus;
  Object? _loadError;
  TestImage? _selectedImage;
  LabOp _selectedOp = kLabOps.first;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadCorpus();
  }

  Future<void> _loadCorpus() async {
    try {
      final corpus = await TestCorpus.load();
      if (!mounted) return;
      setState(() {
        _corpus = corpus;
        _selectedImage = corpus.images.isEmpty ? null : corpus.images.first;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  void _runScope(_RunScope scope) {
    // B4 wires the per-op runners. For now we surface a status banner
    // so the UI is exercisable end-to-end and integration_test can
    // assert the button bound the right callback.
    final imageDesc = switch (scope) {
      _RunScope.single => _selectedImage?.id ?? 'no image',
      _RunScope.opAcrossImages =>
        '${_corpus?.imagesFor(_selectedOp.id).length ?? 0} images',
      _RunScope.fullMatrix =>
        '${kLabOps.length} ops × ${_corpus?.images.length ?? 0} images',
    };
    setState(() {
      _status =
          'TODO (B4): run "${_selectedOp.label}" on $imageDesc — '
          'runners not yet wired.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI Test Lab')),
        body: Center(child: Text('Failed to load corpus: $_loadError')),
      );
    }
    if (_corpus == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI Test Lab')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final corpus = _corpus!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Test Lab'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload corpus',
            onPressed: _loadCorpus,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _CorpusHeader(corpus: corpus),
          const SizedBox(height: 12),
          SizedBox(
            height: 132,
            child: _ImageCarousel(
              images: corpus.images,
              selected: _selectedImage,
              onSelect: (img) => setState(() => _selectedImage = img),
            ),
          ),
          const SizedBox(height: 12),
          _SelectedImageDetails(image: _selectedImage),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Op picker',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ...kLabOps.map(
            (op) => _OpListTile(
              op: op,
              selected: op.id == _selectedOp.id,
              onTap: () => setState(() => _selectedOp = op),
              imagesAvailable: corpus.imagesFor(op.id).length,
            ),
          ),
          const Divider(height: 32),
          _RunControls(
            disabled: _selectedImage == null,
            onSingle: () => _runScope(_RunScope.single),
            onOp: () => _runScope(_RunScope.opAcrossImages),
            onMatrix: () => _runScope(_RunScope.fullMatrix),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_status!),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CorpusHeader extends StatelessWidget {
  const _CorpusHeader({required this.corpus});

  final TestCorpus corpus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Corpus v${corpus.version} • ${corpus.images.length} images',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (corpus.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                corpus.notes,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageCarousel extends StatelessWidget {
  const _ImageCarousel({
    required this.images,
    required this.selected,
    required this.onSelect,
  });

  final List<TestImage> images;
  final TestImage? selected;
  final ValueChanged<TestImage> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const PageStorageKey('ai_lab_carousel'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: images.length,
      itemBuilder: (context, i) {
        final img = images[i];
        final isSel = img.id == selected?.id;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _CarouselTile(
            image: img,
            selected: isSel,
            onTap: () => onSelect(img),
          ),
        );
      },
    );
  }
}

class _CarouselTile extends StatelessWidget {
  const _CarouselTile({
    required this.image,
    required this.selected,
    required this.onTap,
  });

  final TestImage image;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final aspect = image.width / image.height;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 110,
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 3,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            SizedBox(
              height: 80,
              width: 110,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: 110,
                  height: 110 / aspect,
                  child: _ThumbnailImage(path: image.path),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Center(
                  child: Text(
                    image.id,
                    style: Theme.of(context).textTheme.labelSmall,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Async asset image loader that caches the decoded bytes once per
/// asset path. Keeps the carousel snappy when the user scrolls.
class _ThumbnailImage extends StatefulWidget {
  const _ThumbnailImage({required this.path});

  final String path;

  @override
  State<_ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<_ThumbnailImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bd = await rootBundle.load(widget.path);
    if (!mounted) return;
    setState(() => _bytes = bd.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const ColoredBox(color: Color(0x33000000));
    }
    return Image.memory(bytes, fit: BoxFit.cover);
  }
}

class _SelectedImageDetails extends StatelessWidget {
  const _SelectedImageDetails({required this.image});

  final TestImage? image;

  @override
  Widget build(BuildContext context) {
    final img = image;
    if (img == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('No image selected.'),
      );
    }
    final ops = img.expectedOps.join(', ');
    final gt = img.groundTruth.keys.join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            img.id,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text('${img.width} × ${img.height} • ${img.category}'),
          Text('expected ops: $ops'),
          if (gt.isNotEmpty) Text('ground truth: $gt'),
          if (img.notes != null && img.notes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                img.notes!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _OpListTile extends StatelessWidget {
  const _OpListTile({
    required this.op,
    required this.selected,
    required this.onTap,
    required this.imagesAvailable,
  });

  final LabOp op;
  final bool selected;
  final VoidCallback onTap;
  final int imagesAvailable;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      onTap: onTap,
      title: Text(op.label),
      subtitle: Text(op.description),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
          op.primaryMetric.length > 3
              ? op.primaryMetric.substring(0, 3)
              : op.primaryMetric,
          style: TextStyle(
            color: selected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
            fontSize: 10,
          ),
        ),
      ),
      trailing: Text('$imagesAvailable img'),
    );
  }
}

class _RunControls extends StatelessWidget {
  const _RunControls({
    required this.disabled,
    required this.onSingle,
    required this.onOp,
    required this.onMatrix,
  });

  final bool disabled;
  final VoidCallback onSingle;
  final VoidCallback onOp;
  final VoidCallback onMatrix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run this op on this image'),
            onPressed: disabled ? null : onSingle,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.layers),
            label: const Text('Run this op on every image'),
            onPressed: disabled ? null : onOp,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.grid_on),
            label: const Text('Run full matrix'),
            onPressed: disabled ? null : onMatrix,
          ),
          if (kDebugMode)
            Chip(
              avatar: const Icon(Icons.bug_report, size: 16),
              label: const Text('debug build'),
              backgroundColor:
                  Theme.of(context).colorScheme.tertiaryContainer,
            ),
        ],
      ),
    );
  }
}
