import 'package:flutter/material.dart';

class AppTheme {
  // Brand color palette - Warm Minimalist Theme based on #FAF9F5
  static const Color primary = Color(0xFF0066FF);
  static const Color primaryDark = Color(0xFF0052CC);

  // Background exact color matching user uploaded image: #FAF9F5
  static const Color background = Color(0xFFFAF9F5);
  static const Color surface = Color(0xFFFAF9F5);
  static const Color card = Color(0xFFFAF9F5);
  static const Color cardBorder = Color(0xFFE2DDD1);

  // Status colors
  static const Color statusConnected = Color(0xFF10B981);
  static const Color statusConnecting = Color(0xFFF59E0B);
  static const Color statusDisconnected = Color(0xFFEF4444);

  // Text colors (warm high contrast on #FAF9F5)
  static const Color textPrimary = Color(0xFF1C1917);
  static const Color textSecondary = Color(0xFF57534E);
  static const Color textMuted = Color(0xFFA8A29E);

  static ThemeData get theme {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      colorScheme: const ColorScheme.light(
        primary: primary,
        secondary: primaryDark,
        surface: surface,
        surfaceTint: Colors.transparent,
        error: statusDisconnected,
      ),
      fontFamily: 'Microsoft YaHei UI',
      // Microsoft YaHei ships only Regular (400) and Bold (700). Requesting
      // any other weight makes Flutter synthesize a fake bold, which renders
      // as uneven stroke thickness (and visually shortened, muddy strokes)
      // for the same glyph across the UI. Snap every Material style to the
      // two real weights so all text resolves to real outlines.
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontWeight: FontWeight.w700),
        displayMedium: TextStyle(fontWeight: FontWeight.w700),
        displaySmall: TextStyle(fontWeight: FontWeight.w700),
        headlineLarge: TextStyle(fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontWeight: FontWeight.w700),
        titleSmall: TextStyle(fontWeight: FontWeight.w400),
        bodyLarge: TextStyle(fontWeight: FontWeight.w400),
        bodyMedium: TextStyle(fontWeight: FontWeight.w400),
        bodySmall: TextStyle(fontWeight: FontWeight.w400),
        labelLarge: TextStyle(fontWeight: FontWeight.w700),
        labelMedium: TextStyle(fontWeight: FontWeight.w400),
        labelSmall: TextStyle(fontWeight: FontWeight.w400),
      ),
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'PingFang SC',
        'Segoe UI',
        'sans-serif',
      ],
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorder, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: textMuted, fontSize: 14),
        labelStyle: const TextStyle(color: textSecondary, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        color: cardBorder,
        thickness: 1,
      ),
    );
  }

  // Alias for backward compatibility
  static ThemeData get darkTheme => theme;
  static ThemeData get lightTheme => theme;
}
