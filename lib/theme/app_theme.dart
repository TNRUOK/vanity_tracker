import 'package:flutter/material.dart';

class AppTheme {
  // Brand Colors - Rose Quartz & Champagne Skincare Luxury
  static const Color primaryRose = Color(0xFFE05780);
  static const Color primaryDark = Color(0xFF9E2A2B);
  static const Color secondaryGold = Color(0xFFD4AF37);
  static const Color accentPeach = Color(0xFFFF9F1C);
  static const Color surfaceLight = Color(0xFFFAF7F5);
  static const Color cardLight = Colors.white;
  static const Color textDark = Color(0xFF1E293B);
  static const Color textMuted = Color(0xFF64748B);

  // Status Colors (Green >30d, Amber 0-30d, Red expired)
  static const Color statusGreen = Color(0xFF10B981);
  static const Color statusGreenBg = Color(0xFFECFDF5);
  static const Color statusAmber = Color(0xFFF59E0B);
  static const Color statusAmberBg = Color(0xFFFFFBEB);
  static const Color statusRed = Color(0xFFEF4444);
  static const Color statusRedBg = Color(0xFFFEF2F2);
  static const Color statusUnopened = Color(0xFF6366F1);
  static const Color statusUnopenedBg = Color(0xFFEEF2FF);
  static const Color statusFinished = Color(0xFF8B5CF6);
  static const Color statusFinishedBg = Color(0xFFF5F3FF);

  static Color getStatusColor(int? daysUntilExpiry, {bool isUnopened = false, bool isFinished = false}) {
    if (isFinished) return statusFinished;
    if (isUnopened || daysUntilExpiry == null) return statusUnopened;
    if (daysUntilExpiry < 0) return statusRed;
    if (daysUntilExpiry <= 30) return statusAmber;
    return statusGreen;
  }

  static Color getStatusBgColor(int? daysUntilExpiry, {bool isUnopened = false, bool isFinished = false}) {
    if (isFinished) return statusFinishedBg;
    if (isUnopened || daysUntilExpiry == null) return statusUnopenedBg;
    if (daysUntilExpiry < 0) return statusRedBg;
    if (daysUntilExpiry <= 30) return statusAmberBg;
    return statusGreenBg;
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: primaryRose,
      scaffoldBackgroundColor: surfaceLight,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryRose,
        primary: primaryRose,
        secondary: secondaryGold,
        surface: surfaceLight,
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textDark,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: textDark),
      ),
      cardTheme: CardThemeData(
        color: cardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFF1ECE8), width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryRose, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryRose,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryRose,
          side: const BorderSide(color: primaryRose),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
