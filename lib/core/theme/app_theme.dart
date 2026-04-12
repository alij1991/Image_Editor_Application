import 'package:flutter/material.dart';

/// Centralized Material 3 theme for the editor.
///
/// The editor runs in a dark chrome with a blue-leaning primary so the
/// user's photo stays the focal point. Sliders get a dedicated theme
/// (thicker track, custom value indicator) and icons get a bigger
/// default size so touch targets sit comfortably above 48 dp.
class AppTheme {
  AppTheme._();

  static const Color _seed = Color(0xFF3E8EDE);

  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      // Typography — inter-like font metrics via the default roboto stack;
      // we only override sizes for legibility during editing.
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        titleSmall: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        labelLarge: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        labelMedium: TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
        labelSmall:
            TextStyle(fontWeight: FontWeight.w500, fontSize: 11, letterSpacing: 0.8),
        bodyMedium: TextStyle(fontSize: 14),
        bodySmall: TextStyle(fontSize: 12),
      ),

      // Slider theme — thicker track + custom value indicator so slider
      // readouts are clearly tied to their thumb during drag.
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.surfaceContainerHighest,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.15),
        valueIndicatorColor: colorScheme.inverseSurface,
        valueIndicatorTextStyle: TextStyle(
          color: colorScheme.onInverseSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        trackHeight: 4,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        showValueIndicator: ShowValueIndicator.onlyForContinuous,
      ),

      // Icon theme — 22 px default hits comfortably without crowding.
      iconTheme: IconThemeData(
        color: colorScheme.onSurface,
        size: 22,
      ),

      // App bar — flat, no shadow, aligns with the editor chrome.
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 18,
        ),
      ),

      // Chip theme — editor uses ChoiceChip for category switching.
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primary,
        disabledColor: colorScheme.surfaceContainerLow,
        labelStyle: TextStyle(color: colorScheme.onSurface),
        side: BorderSide(color: colorScheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      ),

      // Card / dialog theme.
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHigh,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
      ),

      // Buttons — keep Filled as the primary CTA shape.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),

      // Snackbar — floating, rounded, tonal.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        actionTextColor: colorScheme.inversePrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // Progress indicator — a touch thicker than default.
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),

      // Divider tuned down so the editor chrome reads as one surface.
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
      ),
    );
  }
}
