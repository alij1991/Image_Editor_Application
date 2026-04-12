/// Spacing scale used throughout the editor UI.
///
/// All padding/margin/gap sizes should come from this class instead of
/// inline magic numbers so spacing stays consistent as the design
/// evolves. Roughly follows an 8-pt grid with a few 4-pt insertions for
/// tight UI regions (slider labels, chip rows).
class Spacing {
  Spacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
}
