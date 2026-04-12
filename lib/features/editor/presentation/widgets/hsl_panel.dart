import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../engine/history/history_state.dart';
import '../../../../engine/pipeline/edit_op_type.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/pipeline_extensions.dart';
import '../notifiers/editor_session.dart';
import 'slider_row.dart';

final _log = AppLogger('HslPanel');

/// 8-band HSL panel: one tab per axis (Hue / Sat / Lum), each showing 8
/// color-coded sliders for red/orange/yellow/green/aqua/blue/purple/magenta.
class HslPanel extends StatefulWidget {
  const HslPanel({
    required this.session,
    required this.state,
    super.key,
  });

  final EditorSession session;
  final HistoryState state;

  @override
  State<HslPanel> createState() => _HslPanelState();
}

class _HslPanelState extends State<HslPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  static const List<String> _bandNames = [
    'Red',
    'Orange',
    'Yellow',
    'Green',
    'Aqua',
    'Blue',
    'Purple',
    'Magenta',
  ];

  static const List<Color> _bandColors = [
    Color(0xFFEF5350),
    Color(0xFFFF9800),
    Color(0xFFFFEB3B),
    Color(0xFF66BB6A),
    Color(0xFF26C6DA),
    Color(0xFF42A5F5),
    Color(0xFF7E57C2),
    Color(0xFFEC407A),
  ];

  static const List<String> _axisKeys = ['hue', 'sat', 'lum'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (_tab.indexIsChanging) return;
        _log.d('tab switched', {'axis': _axisKeys[_tab.index]});
      });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  List<double> _readList(EditPipeline pipeline, String key) {
    final op = pipeline.findOp(EditOpType.hsl);
    if (op == null) return List.filled(8, 0.0);
    final raw = op.parameters[key];
    if (raw is List) {
      final out = List.filled(8, 0.0);
      for (int i = 0; i < 8 && i < raw.length; i++) {
        final v = raw[i];
        if (v is num) out[i] = v.toDouble();
      }
      return out;
    }
    return List.filled(8, 0.0);
  }

  void _updateBand(String axisKey, int bandIndex, double value) {
    _log.d('update band', {
      'axis': axisKey,
      'band': _bandNames[bandIndex],
      'value': value,
    });
    final pipeline = widget.state.pipeline;
    // Read current values (or zero-filled defaults)
    final hue = _readList(pipeline, 'hue');
    final sat = _readList(pipeline, 'sat');
    final lum = _readList(pipeline, 'lum');
    switch (axisKey) {
      case 'hue':
        hue[bandIndex] = value;
        break;
      case 'sat':
        sat[bandIndex] = value;
        break;
      case 'lum':
        lum[bandIndex] = value;
        break;
    }
    // All identity? Remove the HSL op entirely.
    final allZero =
        hue.every((v) => v == 0) && sat.every((v) => v == 0) && lum.every((v) => v == 0);
    widget.session.setMapParams(
      EditOpType.hsl,
      {'hue': hue, 'sat': sat, 'lum': lum},
      removeIfIdentity: allZero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pipeline = widget.state.pipeline;
    // Height is computed: one slider row is ~56 px, 8 bands ~= 450 px.
    // On short screens we bound it to 60% of the screen height.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
    const targetHeight = 56.0 * 8;
    final clampedHeight = targetHeight < maxHeight ? targetHeight : maxHeight;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Hue'),
            Tab(text: 'Sat'),
            Tab(text: 'Lum'),
          ],
        ),
        SizedBox(
          height: clampedHeight,
          child: TabBarView(
            controller: _tab,
            children: [
              _axisColumn(pipeline, 'hue'),
              _axisColumn(pipeline, 'sat'),
              _axisColumn(pipeline, 'lum'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _axisColumn(EditPipeline pipeline, String axisKey) {
    final values = _readList(pipeline, axisKey);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < 8; i++)
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _bandColors[i],
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: SliderRow(
                    key: ValueKey(
                        '$axisKey-$i-${values[i].toStringAsFixed(3)}'),
                    label: _bandNames[i],
                    initialValue: values[i],
                    min: -1,
                    max: 1,
                    formatValue: (v) => v.toStringAsFixed(2),
                    onChanged: (v) => _updateBand(axisKey, i, v),
                    onChangeEnd: (_) =>
                        widget.session.flushPendingCommit(),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
