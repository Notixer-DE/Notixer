import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

/// Shared visual language for PDF, Markdown and all supporting screens.
abstract final class NoterTheme {
  static const accent = Color(0xFF238B7E);
  static const accentStrong = Color(0xFF176B61);
  static const ink = Color(0xFF293139);
  static const secondary = Color(0xFF869197);
  // Small, informative text needs more contrast than decorative muted icons.
  static const muted = Color(0xFF647178);
  static const background = Colors.white;
  static const workspace = Color(0xFFF5F7F7);
  static const active = Color(0xFFEAF5F1);
  static const border = Color(0xFFE7EBE9);
  static const markupYellow = Color(0xFFFFE481);
  static const markupBlue = Color(0xFFB3E1F4);
  static const markupPink = Color(0xFFF4BBD0);
  static const markupGreen = Color(0xFFBCE9C9);

  static bool mobileLayout(double width) =>
      width < 600 ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool desktopControls(BuildContext context) =>
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows) &&
      MediaQuery.sizeOf(context).width >= 1000 &&
      MediaQuery.sizeOf(context).height >= 600 &&
      MediaQuery.textScalerOf(context).scale(14) <= 21;

  static double controlExtent(BuildContext context) =>
      desktopControls(context) ? 36 : 48;

  static double headerHeight(BuildContext context) =>
      desktopControls(context) ? 48 : 56;

  static ThemeData forWindow(BuildContext context) {
    final theme = Theme.of(context);
    if (!desktopControls(context)) return theme;
    const size = WidgetStatePropertyAll(Size(0, 36));
    const padding = WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    );
    ButtonStyle compact(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: size,
          padding: padding,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
    return theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(toolbarHeight: 48),
      filledButtonTheme: FilledButtonThemeData(
        style: compact(theme.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: compact(theme.outlinedButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: compact(theme.textButtonTheme.style),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: theme.iconButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(Size.square(36)),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      listTileTheme: theme.listTileTheme.copyWith(dense: true),
    );
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: active,
      onPrimaryContainer: accentStrong,
      secondary: accent,
      secondaryContainer: active,
      onSecondaryContainer: accentStrong,
      surface: Colors.white,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerHighest: workspace,
      outline: secondary,
      outlineVariant: border,
    );
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['Inter', 'Noto Sans', 'Arial'],
    );
    final text = base.textTheme
        .apply(bodyColor: ink, displayColor: ink)
        .copyWith(
          headlineMedium: const TextStyle(
            fontSize: 28,
            height: 1.3,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          headlineSmall: const TextStyle(
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          titleLarge: const TextStyle(
            fontSize: 18,
            height: 1.3,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          titleMedium: const TextStyle(
            fontSize: 14,
            height: 1.4,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          titleSmall: const TextStyle(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          bodyLarge: const TextStyle(fontSize: 15, height: 1.5, color: ink),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.45, color: ink),
          bodySmall: const TextStyle(fontSize: 12, height: 1.45, color: muted),
          labelLarge: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          labelSmall: const TextStyle(fontSize: 11, height: 1.4, color: muted),
        );
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: background,
      iconTheme: const IconThemeData(size: 20, color: muted),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: border)),
        centerTitle: false,
        titleTextStyle: text.titleMedium,
        iconTheme: const IconThemeData(size: 20, color: muted),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: rounded,
          backgroundColor: active,
          foregroundColor: accentStrong,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: rounded,
          side: const BorderSide(color: border),
          backgroundColor: Colors.white,
          foregroundColor: ink,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: accentStrong,
          textStyle: text.labelLarge,
          shape: rounded,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: ink,
          highlightColor: active,
          iconSize: 20,
          shape: rounded,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        isDense: true,
        hintStyle: text.bodyMedium?.copyWith(color: muted),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: accent),
        ),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(5),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => secondary.withValues(
            alpha: states.contains(WidgetState.hovered) ? .6 : .3,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        selectedColor: accentStrong,
        selectedTileColor: active,
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.bodySmall,
        minLeadingWidth: 20,
        horizontalTitleGap: 10,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: active,
        side: const BorderSide(color: border),
        shape: rounded,
        labelStyle: text.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        showCheckmark: false,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: border),
        ),
        textStyle: text.bodyMedium,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        shape: RoundedRectangleBorder(),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: active,
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(text.labelSmall),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          shape: WidgetStatePropertyAll(rounded),
          side: const WidgetStatePropertyAll(BorderSide(color: border)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? active : Colors.white,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? accentStrong : muted,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: .16),
        selectionHandleColor: accent,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _QuietPageTransition(),
          TargetPlatform.linux: _QuietPageTransition(),
          TargetPlatform.windows: _QuietPageTransition(),
          TargetPlatform.macOS: _QuietPageTransition(),
          TargetPlatform.iOS: _QuietPageTransition(),
        },
      ),
    );
  }
}

class _QuietPageTransition extends PageTransitionsBuilder {
  const _QuietPageTransition();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      return child;
    }
    return FadeTransition(
      opacity: animation.drive(
        CurveTween(curve: const Interval(0, .45, curve: Curves.easeOut)),
      ),
      child: child,
    );
  }
}
