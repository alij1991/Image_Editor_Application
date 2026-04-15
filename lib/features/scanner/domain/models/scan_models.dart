import 'package:uuid/uuid.dart';

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
class ScanPage {
  ScanPage({
    required this.id,
    required this.rawImagePath,
    this.processedImagePath,
    Corners? corners,
    this.filter = ScanFilter.auto,
    this.rotationDeg = 0,
    this.ocr,
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

  ScanPage copyWith({
    String? processedImagePath,
    Corners? corners,
    ScanFilter? filter,
    double? rotationDeg,
    OcrResult? ocr,
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
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'raw': rawImagePath,
        'processed': processedImagePath,
        'corners': corners.toJson(),
        'filter': filter.name,
        'rot': rotationDeg,
        'ocr': ocr?.toJson(),
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
class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.pdf,
    this.pageSize = PageSize.auto,
    this.jpegQuality = 85,
    this.includeOcr = true,
    this.password,
  });

  final ExportFormat format;
  final PageSize pageSize;
  final int jpegQuality;
  final bool includeOcr;
  final String? password;

  ExportOptions copyWith({
    ExportFormat? format,
    PageSize? pageSize,
    int? jpegQuality,
    bool? includeOcr,
    String? password,
    bool clearPassword = false,
  }) =>
      ExportOptions(
        format: format ?? this.format,
        pageSize: pageSize ?? this.pageSize,
        jpegQuality: jpegQuality ?? this.jpegQuality,
        includeOcr: includeOcr ?? this.includeOcr,
        password: clearPassword ? null : (password ?? this.password),
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
