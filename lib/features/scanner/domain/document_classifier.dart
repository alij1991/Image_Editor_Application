import 'models/scan_models.dart';

/// What kind of document the heuristic classifier guessed. Drives the
/// default filter selection on the review page so the user lands on a
/// sensible look without tapping through every option.
///
/// Five buckets are enough to cover ~95 % of consumer scans without
/// pretending to be a real ML classifier (that lands in S5 v2 with a
/// MobileNetV3-Small head trained on RVL-CDIP-mobile).
enum DocumentType {
  receipt,
  invoiceOrLetter,
  idCard,
  handwritten,
  photo,
  unknown,
}

extension DocumentTypeLabel on DocumentType {
  String get label {
    switch (this) {
      case DocumentType.receipt:
        return 'Receipt';
      case DocumentType.invoiceOrLetter:
        return 'Document';
      case DocumentType.idCard:
        return 'ID card';
      case DocumentType.handwritten:
        return 'Handwritten';
      case DocumentType.photo:
        return 'Photo';
      case DocumentType.unknown:
        return 'Unknown';
    }
  }

  /// Filter that pairs best with this document type — used as the
  /// default selection on the review page when the classifier has
  /// been run.
  ScanFilter get suggestedFilter {
    switch (this) {
      case DocumentType.receipt:
        return ScanFilter.bw;
      case DocumentType.invoiceOrLetter:
        return ScanFilter.magicColor;
      case DocumentType.idCard:
        return ScanFilter.color;
      case DocumentType.handwritten:
        return ScanFilter.grayscale;
      case DocumentType.photo:
        return ScanFilter.color;
      case DocumentType.unknown:
        return ScanFilter.auto;
    }
  }
}

/// VIII.11 — Below this normalised Laplacian-variance value, the
/// frame counts as "blurry" for classifier purposes. 0.30 is the
/// empirical knee of the (sharpness vs subjective-quality) curve on
/// a 256-px grayscale: clean document scans land 0.45-0.95, motion
/// blurred / OOF scans drop below 0.20.
const double kBlurredSharpnessThreshold = 0.30;

/// Pure-Dart heuristic classifier. Lives in `domain/` because it
/// depends only on already-extracted facts ([ImageStats] from the
/// processor, [OcrResult] from ML Kit) — no native deps, easy to unit
/// test, and a clean swap point for a future ML model.
class DocumentClassifier {
  const DocumentClassifier();

  DocumentType classify({
    required ImageStats stats,
    OcrResult? ocr,
  }) {
    final aspect = stats.aspectRatio;
    final density = ocr == null ? 0.0 : _textDensity(ocr, stats);
    final text = ocr?.fullText.toLowerCase() ?? '';

    // Receipts: tall and narrow, lots of short numeric lines, often
    // contain "total", "subtotal", or a currency symbol.
    if (aspect < 0.55 && (density > 0.05 || _hasMoneyMarker(text))) {
      return DocumentType.receipt;
    }
    // Photos: very high colour variance and almost no recognised
    // text. Checked before ID card so a saturated landscape doesn't
    // get mistaken for a laminated card. VIII.11 — also gated on
    // sharpness; a blurry colour-rich frame is more likely a bad
    // document capture than a real photo, so route those to unknown
    // and let the user pick a filter.
    if (stats.colorRichness > 0.5 && density < 0.01) {
      if (stats.sharpness < kBlurredSharpnessThreshold) {
        return DocumentType.unknown;
      }
      return DocumentType.photo;
    }
    // ID cards: roughly credit-card shape with moderate (but not
    // wild) colour saturation. The upper bound on richness keeps a
    // saturated photo from sliding into this bucket.
    if (aspect > 1.4 &&
        aspect < 1.95 &&
        stats.colorRichness > 0.25 &&
        stats.colorRichness < 0.5) {
      return DocumentType.idCard;
    }
    // Handwritten: ML Kit's confidence drops sharply on cursive — we
    // don't have per-block confidence here, so use the fact that
    // handwritten OCR usually returns very few well-formed blocks
    // relative to the page area.
    if (ocr != null && ocr.blocks.isNotEmpty && density < 0.02 &&
        text.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 30) {
      return DocumentType.handwritten;
    }
    // Letter / invoice / printed form: standard page aspect, plenty
    // of text.
    if (aspect > 0.65 && aspect < 0.85 && density > 0.02) {
      return DocumentType.invoiceOrLetter;
    }
    return DocumentType.unknown;
  }

  /// Ratio of OCR-block coverage to total page area — proxy for "how
  /// much of this page is recognised text".
  double _textDensity(OcrResult ocr, ImageStats stats) {
    final pageArea = (stats.width * stats.height).toDouble();
    if (pageArea <= 0) return 0;
    var blockArea = 0.0;
    for (final b in ocr.blocks) {
      blockArea += b.width.abs() * b.height.abs();
    }
    return (blockArea / pageArea).clamp(0.0, 1.0);
  }

  bool _hasMoneyMarker(String text) {
    if (text.isEmpty) return false;
    if (text.contains(r'$') || text.contains('€') ||
        text.contains('£') || text.contains('¥')) {
      return true;
    }
    return text.contains('total') ||
        text.contains('subtotal') ||
        text.contains('change due');
  }
}

/// Lightweight image statistics used by the classifier. Cheap to
/// compute (one pass over a downscaled grayscale + RGB), passed in
/// rather than computed inside the classifier so the call site can
/// share a single decode for filter / OCR / classify.
class ImageStats {
  const ImageStats({
    required this.width,
    required this.height,
    required this.colorRichness,
    this.sharpness = 1.0,
  });

  final int width;
  final int height;

  /// Standard deviation of the per-pixel hue distribution, normalised
  /// to [0..1]. Documents print on a near-white background and skew
  /// toward 0; photos with rich subjects skew toward 1.
  final double colorRichness;

  /// VIII.11 — Laplacian-variance sharpness in [0..1]. 1.0 = sharp,
  /// 0.0 = severely blurred (motion blur, out-of-focus). The
  /// classifier uses this to demote low-sharpness high-chroma inputs
  /// from `photo` to `unknown` (otherwise blurry document scans get
  /// mis-tagged as photos and routed to the wrong default filter).
  /// Defaults to 1.0 so callers that don't compute it (or older
  /// fixtures) keep their pre-VIII.11 classifier behaviour.
  final double sharpness;

  double get aspectRatio => width == 0 ? 0 : width / height;
}
