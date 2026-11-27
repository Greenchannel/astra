import 'package:flutter/material.dart';

class AstraPalette {
  const AstraPalette({
    required this.canvas,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.accentSoft,
    required this.userBubble,
    required this.danger,
    required this.warning,
    required this.tool,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color ink;
  final Color muted;
  final Color accent;
  final Color accentSoft;
  final Color userBubble;
  final Color danger;
  final Color warning;
  final Color tool;

  static const light = AstraPalette(
    canvas: Color(0xFFF6F5F1),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF0F1EC),
    border: Color(0xFFE2E5DE),
    ink: Color(0xFF1C2522),
    muted: Color(0xFF6C7A73),
    accent: Color(0xFF2D6A5B),
    accentSoft: Color(0xFFDFECE7),
    userBubble: Color(0xFFE5F0EB),
    danger: Color(0xFFB23A48),
    warning: Color(0xFFA76A1E),
    tool: Color(0xFFF3F1EA),
  );

  static const dark = AstraPalette(
    canvas: Color(0xFF0E1312),
    surface: Color(0xFF151B19),
    surfaceAlt: Color(0xFF1B2320),
    border: Color(0xFF26312D),
    ink: Color(0xFFE7EEEA),
    muted: Color(0xFF8B9A93),
    accent: Color(0xFF78B9A6),
    accentSoft: Color(0xFF1C2B26),
    userBubble: Color(0xFF1B2B26),
    danger: Color(0xFFE06C75),
    warning: Color(0xFFE0AF68),
    tool: Color(0xFF171E1B),
  );

  static AstraPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildAstraTheme(Brightness brightness) {
  final palette =
      brightness == Brightness.dark ? AstraPalette.dark : AstraPalette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.accent,
    brightness: brightness,
  ).copyWith(
    primary: palette.accent,
    onPrimary: brightness == Brightness.dark
        ? const Color(0xFF081410)
        : Colors.white,
    surface: palette.surface,
    onSurface: palette.ink,
    error: palette.danger,
    outline: palette.border,
    outlineVariant: palette.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );
  final textTheme = base.textTheme.copyWith(
    displaySmall: base.textTheme.displaySmall?.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      color: palette.ink,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: palette.ink,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: palette.ink,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: 15.5,
      height: 1.55,
      color: palette.ink,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.5,
      color: palette.ink,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: palette.muted,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: palette.canvas,
    canvasColor: palette.canvas,
    dividerColor: palette.border,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: palette.ink,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.accent, width: 1.4),
      ),
      hintStyle: TextStyle(color: palette.muted, fontSize: 14),
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF22302B)
          : const Color(0xFF24332E),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: palette.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: palette.border),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      showDragHandle: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      indicatorColor: palette.accentSoft,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 68,
    ),
  );
}
