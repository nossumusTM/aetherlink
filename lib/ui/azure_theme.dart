import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AzureTheme {
  static const Color azure = Color(0xFF1279FF);
  static const Color azureDark = Color(0xFF0A4FC3);
  static const Color sky = Color(0xFF6BD7FF);
  static const Color ink = Color(0xFF081A33);
  static const Color mist = Color(0xFFF2F8FF);
  static const Color backgroundTop = Color(0xFFE6F4FF);
  static const Color backgroundMiddle = Color(0xFFF8FBFF);
  static const Color backgroundBottom = Color(0xFFD7EBFF);
  static const Color panel = Color(0xFFFFFFFF);
  static const Color glass = Color(0xB8FFFFFF);
  static const Color glassStrong = Color(0xD9FFFFFF);
  static const Color glassStroke = Color(0x85FFFFFF);
  static const Color success = Color(0xFF1CBA72);
  static const Color warning = Color(0xFFFFB020);
  static const SystemUiOverlayStyle systemUiOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  static ThemeData theme() {
    const colorScheme = ColorScheme.light(
      primary: azure,
      secondary: sky,
      surface: panel,
      error: Color(0xFFD7263D),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: backgroundMiddle,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: glassStroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: glassStroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x99FFFFFF), width: 1.2),
        ),
        labelStyle: const TextStyle(color: ink),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: glass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: glassStroke),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: glassStrong,
          foregroundColor: ink,
          minimumSize: const Size.fromHeight(56),
          disabledBackgroundColor: glass,
          disabledForegroundColor: ink.withValues(alpha: 0.45),
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: glassStroke),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: glass,
          minimumSize: const Size.fromHeight(56),
          side: const BorderSide(color: glassStroke),
          disabledForegroundColor: ink.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return azure;
          }
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return azure.withValues(alpha: 0.55);
          }
          return const Color(0x5FFFFFFF);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => const Color(0x55FFFFFF),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return Colors.white.withValues(alpha: 0.08);
          }
          return Colors.transparent;
        }),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: azure,
        inactiveTrackColor: Color(0x66FFFFFF),
        thumbColor: azure,
        overlayColor: Color(0x14FFFFFF),
        valueIndicatorColor: Color(0xD9FFFFFF),
        valueIndicatorTextStyle: TextStyle(color: ink),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        selectedColor: glassStrong,
        backgroundColor: glass,
        side: const BorderSide(color: glassStroke),
        labelStyle: const TextStyle(color: ink),
        checkmarkColor: ink,
      ),
    );
  }

  static ThemeData adaptiveTheme(BuildContext context, ThemeData baseTheme) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) {
      return baseTheme;
    }

    final platform = defaultTargetPlatform;
    final isMobilePlatform =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final shortestSide = mediaQuery.size.shortestSide;
    if (!isMobilePlatform || shortestSide >= 700) {
      return baseTheme;
    }

    final isIos = platform == TargetPlatform.iOS;
    final textTheme = _mobileTextTheme(baseTheme.textTheme, isIos: isIos);
    final mobileButtonTextStyle = (isIos
            ? textTheme.titleMedium
            : textTheme.bodyMedium?.copyWith(
                fontSize: 13.5,
                height: 1.18,
                fontWeight: FontWeight.w700,
              ))
        ?.copyWith(fontWeight: FontWeight.w700);
    final mobileButtonPadding = EdgeInsets.symmetric(
      horizontal: isIos ? 18 : 16,
      vertical: isIos ? 14 : 12,
    );
    final mobileButtonHeight = Size.fromHeight(isIos ? 54 : 50);

    return baseTheme.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: ink.withValues(alpha: 0.76),
          fontWeight: FontWeight.w600,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: ink.withValues(alpha: 0.46),
        ),
        helperStyle: textTheme.bodySmall?.copyWith(
          color: ink.withValues(alpha: 0.6),
        ),
        errorStyle: textTheme.bodySmall?.copyWith(
          color: baseTheme.colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: baseTheme.textButtonTheme.style?.copyWith(
          textStyle: WidgetStatePropertyAll(
            mobileButtonTextStyle,
          ),
          padding: WidgetStatePropertyAll(mobileButtonPadding),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: baseTheme.elevatedButtonTheme.style?.copyWith(
          textStyle: WidgetStatePropertyAll(
            mobileButtonTextStyle,
          ),
          minimumSize: WidgetStatePropertyAll(mobileButtonHeight),
          padding: WidgetStatePropertyAll(mobileButtonPadding),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: baseTheme.outlinedButtonTheme.style?.copyWith(
          textStyle: WidgetStatePropertyAll(
            mobileButtonTextStyle,
          ),
          minimumSize: WidgetStatePropertyAll(mobileButtonHeight),
          padding: WidgetStatePropertyAll(mobileButtonPadding),
        ),
      ),
      chipTheme: baseTheme.chipTheme.copyWith(
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: ink,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static TextTheme _mobileTextTheme(TextTheme base, {required bool isIos}) {
    return base.copyWith(
      displaySmall: base.displaySmall?.copyWith(
        fontSize: isIos ? 38 : 36,
        height: 1.02,
        letterSpacing: -1.3,
        fontWeight: FontWeight.w800,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: isIos ? 28 : 27,
        height: 1.08,
        letterSpacing: -0.8,
        fontWeight: FontWeight.w800,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: isIos ? 24 : 23,
        height: 1.1,
        letterSpacing: -0.5,
        fontWeight: FontWeight.w800,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: isIos ? 20 : 19,
        height: 1.18,
        letterSpacing: -0.3,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: isIos ? 16 : 15.5,
        height: 1.24,
        letterSpacing: -0.15,
        fontWeight: FontWeight.w700,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: isIos ? 16 : 15,
        height: 1.42,
        letterSpacing: -0.05,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: isIos ? 14.5 : 14,
        height: 1.42,
        letterSpacing: -0.02,
        fontWeight: FontWeight.w500,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: isIos ? 13 : 12.5,
        height: 1.38,
        letterSpacing: 0,
        fontWeight: FontWeight.w500,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: isIos ? 14.5 : 14,
        height: 1.1,
        letterSpacing: -0.05,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
