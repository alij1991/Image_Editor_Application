import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/spacing.dart';
import '../../../../engine/layers/content_layer.dart';

final _log = AppLogger('TextEditorSheet');

/// Modal bottom sheet to create or edit a [TextLayer].
///
/// Shows a live preview above the controls so the user sees the styled
/// text before committing. Returns a [TextLayer] on save, or null if
/// cancelled. When editing, pass [initial] to pre-fill the fields.
class TextEditorSheet extends StatefulWidget {
  const TextEditorSheet({required this.id, this.initial, super.key});

  /// The id to assign to the layer. For new layers, generate a UUID
  /// in the caller; for edits, pass the existing layer id.
  final String id;
  final TextLayer? initial;

  static Future<TextLayer?> show(
    BuildContext context, {
    required String id,
    TextLayer? initial,
  }) {
    return showModalBottomSheet<TextLayer>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TextEditorSheet(id: id, initial: initial),
    );
  }

  @override
  State<TextEditorSheet> createState() => _TextEditorSheetState();
}

class _TextEditorSheetState extends State<TextEditorSheet> {
  late final TextEditingController _controller;
  late String _text;
  late double _fontSize;
  late int _colorArgb;
  late String? _fontFamily;
  late bool _bold;
  late bool _italic;

  /// A small, safe subset of google_fonts families so users have
  /// variety without loading every typeface on first tap.
  static const List<String> _fontFamilies = [
    'Roboto',
    'Inter',
    'Playfair Display',
    'Montserrat',
    'Lora',
    'Oswald',
    'Dancing Script',
    'Pacifico',
    'Bebas Neue',
    'Merriweather',
    'Fira Sans',
    'Caveat',
  ];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _text = initial?.text ?? '';
    _fontSize = initial?.fontSize ?? 64.0;
    _colorArgb = initial?.colorArgb ?? 0xFFFFFFFF;
    _fontFamily = initial?.fontFamily ?? 'Roboto';
    _bold = initial?.bold ?? false;
    _italic = initial?.italic ?? false;
    _controller = TextEditingController(text: _text);
    _log.i('opened', {'edit': initial != null});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pickColor() async {
    _log.i('color dialog open');
    Color current = Color(_colorArgb);
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Pick text color'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: current,
              onColorChanged: (c) => current = c,
              enableAlpha: false,
              labelTypes: const [],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _log.i('color dialog cancelled');
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                _log.i('color picked', {'argb': current.toARGB32()});
                Navigator.of(context).pop(current);
              },
              child: const Text('Pick'),
            ),
          ],
        );
      },
    );
    if (picked != null) {
      setState(() {
        _colorArgb = picked.toARGB32();
      });
    }
  }

  void _save() {
    if (_text.trim().isEmpty) {
      _log.d('save ignored — empty text');
      Navigator.of(context).pop();
      return;
    }
    final layer = TextLayer(
      id: widget.id,
      text: _text,
      fontSize: _fontSize,
      colorArgb: _colorArgb,
      fontFamily: _fontFamily,
      bold: _bold,
      italic: _italic,
      // Inherit position / rotation / scale from initial if editing.
      x: widget.initial?.x ?? 0.5,
      y: widget.initial?.y ?? 0.5,
      rotation: widget.initial?.rotation ?? 0.0,
      scale: widget.initial?.scale ?? 1.0,
    );
    _log.i('save', {'text': _text, 'font': _fontFamily, 'size': _fontSize});
    Navigator.of(context).pop(layer);
  }

  TextStyle _previewStyle() {
    final base = TextStyle(
      color: Color(_colorArgb),
      fontSize: 28,
      fontWeight: _bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
    );
    if (_fontFamily != null) {
      try {
        return GoogleFonts.getFont(_fontFamily!, textStyle: base);
      } catch (_) {}
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.initial == null ? 'Add text' : 'Edit text',
                    style: theme.textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),

              // Live preview
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Spacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Center(
                  child: Text(
                    _text.isEmpty ? 'Preview' : _text,
                    style: _previewStyle(),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.md),

              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(
                  labelText: 'Text',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _text = v),
              ),
              const SizedBox(height: Spacing.md),

              // Font family picker
              Text('Font', style: theme.textTheme.labelMedium),
              const SizedBox(height: Spacing.xs),
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _fontFamilies.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: Spacing.sm),
                  itemBuilder: (context, i) {
                    final family = _fontFamilies[i];
                    final selected = family == _fontFamily;
                    return ChoiceChip(
                      label: Text(
                        family,
                        style: GoogleFonts.getFont(family),
                      ),
                      selected: selected,
                      onSelected: (_) => setState(() => _fontFamily = family),
                    );
                  },
                ),
              ),
              const SizedBox(height: Spacing.md),

              // Size + color row
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Size: ${_fontSize.round()}',
                          style: theme.textTheme.labelMedium,
                        ),
                        Slider(
                          value: _fontSize,
                          min: 16,
                          max: 200,
                          onChanged: (v) => setState(() => _fontSize = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Color', style: theme.textTheme.labelMedium),
                      const SizedBox(height: Spacing.xs),
                      InkWell(
                        onTap: _pickColor,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 52,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Color(_colorArgb),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),

              // Bold / italic toggles
              Row(
                children: [
                  FilterChip(
                    label: const Text('Bold'),
                    avatar: const Icon(Icons.format_bold, size: 16),
                    selected: _bold,
                    onSelected: (v) => setState(() => _bold = v),
                  ),
                  const SizedBox(width: Spacing.sm),
                  FilterChip(
                    label: const Text('Italic'),
                    avatar: const Icon(Icons.format_italic, size: 16),
                    selected: _italic,
                    onSelected: (v) => setState(() => _italic = v),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: Spacing.sm),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text(widget.initial == null ? 'Add' : 'Save'),
                    onPressed: _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
