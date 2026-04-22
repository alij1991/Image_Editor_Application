import 'package:uuid/uuid.dart';

import '../../data/ocr_service.dart' show OcrScript;

/// Scan filter preset applied to each page before export.
enum ScanFilter {
  /// Leave the detected image as-is (native pipelines already white-balance).
  auto,

  /// Keep full color, boost contrast slightly.
  color,

  /// Convert to neutral grayscale.
  grayscale,

  /// High-contrast black-and-white (adaptive threshold).
  bw,

  /// "Magic color" — white balance + saturation + local contrast boost
  /// aimed at paper documents.
  magicColor,
}

extension ScanFilterLabel on ScanFilter {
  String get label => switch (this) {
        ScanFilter.auto => 'Auto',
        ScanFilter.color => 'Color',
        ScanFilter.grayscale => 'Grayscale',
        ScanFilter.bw => 'B&W',
        ScanFilter.magicColor => 'Magic Color',
      };
}

/// Detection strategy the user selected (or the app recommended).
enum DetectorStrategy {
  /// Google ML Kit / Apple VisionKit native full-screen scanner.
  /// Best UX, multi-page, auto-capture. Needs Play Services on Android.
  native,

  /// Pure in-app flow: camera/gallery → drag 4 corners → warp.
  /// Works everywhere; user drives detection.
  manual,

  /// In-app flow with classical CV edge guess as a starting point
  /// (Sobel + largest-quad heuristic). Offline; falls back to manual.
  auto,
}

extension DetectorStrategyLabel on DetectorStrategy {
  String get label => switch (this) {
        DetectorStrategy.native => 'Native scanner',
        DetectorStrategy.manual => 'Manual crop',
        DetectorStrategy.auto => 'Auto (experimental)',
      };

  String get description => switch (this) {
        DetectorStrategy.native =>
          'Full-screen scanner with auto-capture and multi-page support. '
              'Uses Google ML Kit on Android and VisionKit on iOS.',
        DetectorStrategy.manual =>
          'Take or pick a photo, then drag the four corners yourself. '
              'Works on every device.',
        DetectorStrategy.auto =>
          'Tries to detect document edges in-app, then lets you fine-tune. '
              'Works offline; no Google Play Services required.',
      };
}

/// Normalised 0..1 corners of a document in the source image, in
/// clockwise order starting from top-left.
class Corners {
  const Corners(this.tl, this.tr, this.br, this.bl);

  final Point2 tl;
  final Point2 tr;
  final Point2 br;
  final Point2 bl;

  /// Default "page at 5% inset" seed for the manual editor.
  factory Corners.inset([double inset = 0.05]) => Corners(
        Point2(inset, inset),
        Point2(1 - inset, inset),
        Point2(1 - inset, 1 - inset),
        Point2(inset, 1 - inset),
      );

  /// Full image rect (used when a native scanner returned an already
  /// cropped image — no further warp needed).
  factory Corners.full() => const Corners(
        Point2(0, 0),
        Point2(1, 0),
        Point2(1, 1),
        Point2(0, 1),
      );

  List<Point2> get list => [tl, tr, br, bl];

  Corners copyWith({Point2? tl, Point2? tr, Point2? br, Point2? bl}) =>
      Corners(tl ?? this.tl, tr ?? this.tr, br ?? this.br, bl ?? this.bl);

  Map<String, dynamic> toJson() => {
        'tl': tl.toJson(),
        'tr': tr.toJson(),
        'br': br.toJson(),
        'bl': bl.toJson(),
      };

  factory Corners.fromJson(Map<String, dynamic> j) => Corners(
        Point2.fromJson(j['tl'] as Map<String, dynamic>),
        Point2.fromJson(j['tr'] as Map<String, dynamic>),
        Point2.fromJson(j['br'] as Map<String, dynamic>),
        Point2.fromJson(j['bl'] as Map<String, dynamic>),
      );
}

class Point2 {
  const Point2(this.x, this.y);
  final double x;
  final double y;

  Point2 copyWith({double? x, double? y}) => Point2(x ?? this.x, y ?? this.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory Point2.fromJson(Map<String, dynamic> j) =>
      Point2((j['x'] as num).toDouble(), (j['y'] as num).toDouble());
}

/// One OCR run for a scan page.
class OcrResult {
  const OcrResult({required this.fullText, required this.blocks});

  final String fullText;
  final List<OcrBlock> blocks;

  Map<String, dynamic> toJson() => {
        'fullText': fullText,
        'blocks': blocks.map((b) => b.toJson()).toList(),
      };

  factory OcrResult.fromJson(Map<String, dynamic> j) => OcrResult(
        fullText: j['fullText'] as String,
        blocks: (j['blocks'] as List<dynamic>)
            .map((b) => OcrBlock.fromJson(b as Map<String, dynamic>))
            .toList(),
      );
}

class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
        't': text,
        'l': left,
        'top': top,
        'w': width,
        'h': height,
      };

  factory OcrBlock.fromJson(Map<String, dynamic> j) => OcrBlock(
        text: j['t'] as String,
        left: (j['l'] as num).toDouble(),
        top: (j['top'] as num).toDouble(),
        width: (j['w'] as num).toDouble(),
        height: (j['h'] as num).toDouble(),
      );
}

/// A single scanned page within a session.
///
/// [brightness], [contrast] and [thresholdOffset] are user-controlled
/// fine-tune values applied AFTER the [filter] pipeline. They give
/// the user a way to fix a B&W result that came out too dark, or
/// warm up a magic-color result that drifted, without leaving the
/// scanner. All three are zero by default — identity, no effect.
class ScanPage {
  ScanPage({
    required this.id,
    required this.rawImagePath,
    this.processedImagePath,
    Corners? corners,
    this.filter = ScanFilter.auto,
    this.rotationDeg = 0,
    this.ocr,
    this.brightness = 0,
    this.contrast = 0,
    this.thresholdOffset = 0,
    this.magicScale = 220,
  }) : corners = corners ?? Corners.inset();

  final String id;

  /// Path to the captured / picked file on disk.
  final String rawImagePath;

  /// Path to the warped+filtered JPEG (null until processed).
  String? processedImagePath;

  Corners corners;
  ScanFilter filter;
  double rotationDeg;
  OcrResult? ocr;

  /// Brightness offset in [-1..+1]. Maps to a per-channel additive
  /// shift inside the isolate filter chain.
  double brightness;

  /// Contrast multiplier in [-1..+1]. 0 = identity, +1 ≈ ×2 contrast,
  /// -1 ≈ ×0.5.
  double contrast;

  /// Adaptive-threshold C-value offset in [-30..+30] for the B&W
  /// filter. Negative makes thin strokes thicker / darker; positive
  /// drops faint marks. Ignored for non-B&W filters.
  double thresholdOffset;

  /// VIII.19 — Multi-Scale Retinex divisor for the magic-color
  /// filter. Range [180..240]; default 220 matches the pre-VIII.19
  /// hard-coded value. Higher = stronger illumination normalisation
  /// (whiter background, more aggressive shadow lift). Ignored for
  /// non-magic-color filters.
  double magicScale;

  ScanPage copyWith({
    String? processedImagePath,
    Corners? corners,
    ScanFilter? filter,
    double? rotationDeg,
    OcrResult? ocr,
    double? brightness,
    double? contrast,
    double? thresholdOffset,
    double? magicScale,
    bool clearProcessed = false,
  }) =>
      ScanPage(
        id: id,
        rawImagePath: rawImagePath,
        processedImagePath:
            clearProcessed ? null : (processedImagePath ?? this.processedImagePath),
        corners: corners ?? this.corners,
        filter: filter ?? this.filter,
        rotationDeg: rotationDeg ?? this.rotationDeg,
        ocr: ocr ?? this.ocr,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        thresholdOffset: thresholdOffset ?? this.thresholdOffset,
        magicScale: magicScale ?? this.magicScale,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'raw': rawImagePath,
        'processed': processedImagePath,
        'corners': corners.toJson(),
        'filter': filter.name,
        'rot': rotationDeg,
        'ocr': ocr?.toJson(),
        if (brightness != 0) 'brightness': brightness,
        if (contrast != 0) 'contrast': contrast,
        if (thresholdOffset != 0) 'thresholdOffset': thresholdOffset,
        if (magicScale != 220) 'magicScale': magicScale,
      };

  factory ScanPage.fromJson(Map<String, dynamic> j) => ScanPage(
        id: j['id'] as String,
        rawImagePath: j['raw'] as String,
        processedImagePath: j['processed'] as String?,
        corners: Corners.fromJson(j['corners'] as Map<String, dynamic>),
        filter: ScanFilter.values.firstWhere(
          (f) => f.name == j['filter'],
          orElse: () => ScanFilter.auto,
        ),
        rotationDeg: (j['rot'] as num?)?.toDouble() ?? 0,
        ocr: j['ocr'] == null
            ? null
            : OcrResult.fromJson(j['ocr'] as Map<String, dynamic>),
        brightness: (j['brightness'] as num?)?.toDouble() ?? 0,
        contrast: (j['contrast'] as num?)?.toDouble() ?? 0,
        thresholdOffset: (j['thresholdOffset'] as num?)?.toDouble() ?? 0,
        magicScale: (j['magicScale'] as num?)?.toDouble() ?? 220,
      );
}

/// A multi-page scan session the user is working on or has finished.
class ScanSession {
  ScanSession({
    String? id,
    DateTime? createdAt,
    this.title,
    List<ScanPage>? pages,
    this.strategy = DetectorStrategy.manual,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        pages = pages ?? <ScanPage>[];

  final String id;
  final DateTime createdAt;
  String? title;
  List<ScanPage> pages;
  DetectorStrategy strategy;

  ScanSession copyWith({
    String? title,
    List<ScanPage>? pages,
    DetectorStrategy? strategy,
  }) =>
      ScanSession(
        id: id,
        createdAt: createdAt,
        title: title ?? this.title,
        pages: pages ?? this.pages,
        strategy: strategy ?? this.strategy,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'title': title,
        'pages': pages.map((p) => p.toJson()).toList(),
        'strategy': strategy.name,
      };

  factory ScanSession.fromJson(Map<String, dynamic> j) => ScanSession(
        id: j['id'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        title: j['title'] as String?,
        pages: (j['pages'] as List<dynamic>)
            .map((p) => ScanPage.fromJson(p as Map<String, dynamic>))
            .toList(),
        strategy: DetectorStrategy.values.firstWhere(
          (s) => s.name == j['strategy'],
          orElse: () => DetectorStrategy.manual,
        ),
      );
}

/// Export configuration chosen on the Export page.
///
/// NOTE: a `password` field lived here until Phase I.8. The `pdf`
/// package's encryption API has shifted between versions and we never
/// wired it up, so the option was a trap — an `ExportOptions(password:
/// 'secret')` call logged a warning at export time but produced an
/// *unencrypted* PDF. The field + the exporter's TODO branch were
/// removed so the only way to add password-protected export is to ship
/// a real implementation first. See `pdf_exporter.dart` for the
/// absence-NOTE and the audit trail.
class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.pdf,
    this.pageSize = PageSize.auto,
    this.jpegQuality = 85,
    this.includeOcr = true,
    this.ocrScript = OcrScript.latin,
  });

  final ExportFormat format;
  final PageSize pageSize;
  final int jpegQuality;
  final bool includeOcr;

  /// VIII.13 — script the OCR pass should target. Defaults to Latin
  /// for backwards-compat; users with non-Latin documents pick a
  /// different value on the export sheet.
  final OcrScript ocrScript;

  ExportOptions copyWith({
    ExportFormat? format,
    PageSize? pageSize,
    int? jpegQuality,
    bool? includeOcr,
    OcrScript? ocrScript,
  }) =>
      ExportOptions(
        format: format ?? this.format,
        pageSize: pageSize ?? this.pageSize,
        jpegQuality: jpegQuality ?? this.jpegQuality,
        includeOcr: includeOcr ?? this.includeOcr,
        ocrScript: ocrScript ?? this.ocrScript,
      );
}

enum ExportFormat { pdf, docx, text, jpegZip }

enum PageSize { auto, a4, letter, legal }

extension PageSizeLabel on PageSize {
  String get label => switch (this) {
        PageSize.auto => 'Auto',
        PageSize.a4 => 'A4',
        PageSize.letter => 'Letter',
        PageSize.legal => 'Legal',
      };
}

extension ExportFormatLabel on ExportFormat {
  String get label => switch (this) {
        ExportFormat.pdf => 'PDF',
        ExportFormat.docx => 'Word (.docx)',
        ExportFormat.text => 'Plain text',
        ExportFormat.jpegZip => 'JPEG (.zip)',
      };
}
