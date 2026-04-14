import 'package:flutter/material.dart';

/// Shared radii, elevation, and spacing for a consistent, calm UI.
abstract final class AppRadii {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
}

abstract final class AppInsets {
  static const EdgeInsets screen = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
  static const EdgeInsets card = EdgeInsets.all(14);
}

/// Semantic data colors — use these for all financial values.
/// Never use cs.primary for data; cs.primary is reserved for UI chrome.
abstract final class AppColors {
  /// Balances, funds available, neutral financial amounts
  static const Color amount = Color(0xFF1A56DB);

  /// Credits, income, positive flows
  static const Color gain = Color(0xFF057A55);

  /// Debits, spent, losses, negative flows
  static const Color loss = Color(0xFFE02424);

  /// Primary numeric values (estimated, neutral labels)
  static const Color number = Color(0xFF111827);

  /// Subtle card border
  static const Color cardBorder = Color(0xFFE5E7EB);

  /// Page background (light gray, like Coin)
  static const Color pageBg = Color(0xFFF3F4F6);
}

ThemeData buildFinappTheme() {
  const seed = Color(0xFF1A56DB);
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    surface: Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.pageBg,
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: const BorderSide(color: AppColors.cardBorder, width: 1),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        borderSide: const BorderSide(color: AppColors.cardBorder),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: AppColors.pageBg,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.cardBorder),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
    ),
  );
}
