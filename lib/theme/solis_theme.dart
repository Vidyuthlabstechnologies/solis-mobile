import 'package:flutter/material.dart';

/// SOLIS design system.
///
/// Principles (from clinician research on ambient scribes and alert fatigue):
/// - One accent color: SOLIS Orchid (see docs/BRAND.md). Red and amber are
///   reserved for meaning: recording, abnormal values, STAT/urgent,
///   destructive actions. Green, teal and blue are status colors only.
/// - Body text never below 14sp; labels never below 12sp. The note is read
///   at arm's length under exam-room lighting.
/// - Touch targets at least 48dp. Physicians operate the phone mid-visit.
/// - Surfaces come from the color scheme so light and dark stay consistent.
class SolisTheme {
  // Brand: SOLIS Orchid. OKLCH hue 335; tones 70 to 90 lean to hue 325 so the
  // dark-mode accent stays clear of the salmon danger color. Ramp 10 (darkest) to 99.
  // Contrast figures are in docs/BRAND.md; all pairs used below pass WCAG AA.
  static const Color orchid10 = Color(0xFF2F0029);
  static const Color orchid20 = Color(0xFF4E0044);
  static const Color orchid30 = Color(0xFF6F0061);
  static const Color orchid40 = Color(0xFF980F86);
  static const Color orchid50 = Color(0xFFB435A0);
  static const Color orchid60 = Color(0xFFCA58B5);
  static const Color orchid70 = Color(0xFFD180D6);
  static const Color orchid80 = Color(0xFFE5A3E8);
  static const Color orchid90 = Color(0xFFF1CAF3);
  static const Color orchid95 = Color(0xFFFDE2F6);
  static const Color orchid99 = Color(0xFFFFF8FD);

  /// The brand color. Text on white 7.6:1, white on it 7.6:1. Also the logo tile.
  static const Color brand = orchid40;

  /// Brand accent for dark surfaces. 9.2:1 on [darkSurface]; [brandDeep] on it 7.6:1.
  static const Color brandDark = orchid80;

  /// Deepest brand tone: text on [brandContainer], onPrimary in dark mode.
  static const Color brandDeep = orchid20;

  /// Light-mode container (selected rows, chips). [brandDeep] on it 12.3:1.
  static const Color brandContainer = orchid95;

  /// Dark-mode container. [brandContainerText] on it 7.8:1.
  static const Color brandContainerDark = orchid30;
  static const Color brandContainerText = orchid90;

  /// Kept for older call sites; now the brand color, not a blue.
  static const Color primaryBlue = brand;
  static const Color navy = Color(0xFF0F172A);
  static const Color slate = Color(0xFF64748B);
  static const Color clinicalBg = Color(0xFFF8FAFC);
  static const Color slateBorder = Color(0xFFE2E8F0);

  // Semantic colors. Use through [onTint]/[tint] so dark mode stays legible.
  static const Color danger = Color(0xFFC62828);
  static const Color warning = Color(0xFFB45309);
  static const Color success = Color(0xFF1B7F3B);
  static const Color info = Color(0xFF1D4ED8);
  static const Color teal = Color(0xFF0F766E);

  // Dark surfaces
  static const Color darkBg = Color(0xFF0B0E14);
  static const Color darkSurface = Color(0xFF12161F);
  static const Color darkSurfaceHigh = Color(0xFF1A1F2B);
  static const Color darkLine = Color(0x24FFFFFF);
  static const Color darkTextSub = Color(0xFFA3AAB8);

  // Legacy names still referenced by older code paths.
  static const Color txt = Color(0xFF334155);
  static const Color sub = slate;

  // Shape scale
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;

  // Spacing scale (4dp grid)
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;

  /// Tinted container background for a semantic color.
  static Color tint(Color color, {required bool isDark}) => color.withAlpha(isDark ? 51 : 23);

  /// Hairline border for a semantic container.
  static Color tintBorder(Color color, {required bool isDark}) => color.withAlpha(isDark ? 102 : 64);

  /// Foreground on a tinted container. Dark mode lifts the hue toward white so
  /// saturated clinical colors keep at least 4.5:1 contrast.
  static Color onTint(Color color, {required bool isDark}) =>
      isDark ? Color.lerp(color, Colors.white, 0.5)! : color;

  static ThemeData lightTheme() => _build(Brightness.light);
  static ThemeData darkTheme() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: brand, brightness: brightness);
    final scheme = base.copyWith(
      primary: isDark ? brandDark : brand,
      onPrimary: isDark ? brandDeep : Colors.white,
      primaryContainer: isDark ? brandContainerDark : brandContainer,
      onPrimaryContainer: isDark ? brandContainerText : brandDeep,
      inversePrimary: isDark ? brand : brandDark,
      // The seed would derive an orange tertiary, which reads as a warning.
      // Keep every accent role on the brand hue.
      tertiary: isDark ? brandDark : brand,
      onTertiary: isDark ? brandDeep : Colors.white,
      tertiaryContainer: isDark ? brandContainerDark : brandContainer,
      onTertiaryContainer: isDark ? brandContainerText : brandDeep,
      surfaceTint: isDark ? brandDark : brand,
      error: isDark ? const Color(0xFFFF8A80) : danger,
      surface: isDark ? darkSurface : Colors.white,
      onSurface: isDark ? const Color(0xFFE6E9EF) : navy,
      onSurfaceVariant: isDark ? darkTextSub : const Color(0xFF475569),
      outline: isDark ? const Color(0xFF4A5263) : const Color(0xFF94A3B8),
      outlineVariant: isDark ? darkLine : slateBorder,
      surfaceContainerLowest: isDark ? darkBg : Colors.white,
      surfaceContainerLow: isDark ? const Color(0xFF151A24) : const Color(0xFFF8FAFC),
      surfaceContainer: isDark ? darkSurfaceHigh : const Color(0xFFF1F5F9),
      surfaceContainerHigh: isDark ? const Color(0xFF212736) : const Color(0xFFE9EEF4),
      surfaceContainerHighest: isDark ? const Color(0xFF2A3142) : const Color(0xFFE2E8F0),
    );

    final text = Typography.material2021(platform: TargetPlatform.android)
        .englishLike
        .merge(isDark ? Typography.material2021().white : Typography.material2021().black)
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
    final textTheme = text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(height: 1.5),
      bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );

    final outline = scheme.outlineVariant;
    final pillShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd));

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: isDark ? darkBg : clinicalBg,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? darkBg : clinicalBg,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: BorderSide(color: outline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXl))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFFE6E9EF) : navy,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: isDark ? navy : Colors.white),
        actionTextColor: isDark ? brand : brandDark,
        shape: pillShape,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: textTheme.labelLarge,
          shape: pillShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outline),
          shape: pillShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: textTheme.labelLarge,
          shape: pillShape,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(0, 44),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outline),
          selectedBackgroundColor: scheme.primary.withAlpha(isDark ? 64 : 28),
          selectedForegroundColor: isDark ? scheme.primary : brand,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurfaceHigh : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: BorderSide(color: scheme.outline)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: BorderSide(color: scheme.outline)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: BorderSide(color: scheme.primary, width: 2)),
      ),
      chipTheme: ChipThemeData(
        labelStyle: textTheme.labelLarge,
        side: BorderSide(color: scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? const Icon(Icons.check, size: 14) : null,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: isDark ? const Color(0xFFE6E9EF) : navy, borderRadius: BorderRadius.circular(radiusSm)),
        textStyle: textTheme.bodySmall?.copyWith(color: isDark ? navy : Colors.white),
      ),
    );
  }
}
