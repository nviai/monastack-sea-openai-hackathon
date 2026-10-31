import 'package:flutter/material.dart';

import 'nexus_metrics.dart';
import 'nexus_tokens.dart';

/// A Material theme built from NEXUS tokens. Everything under it (menus,
/// dialogs, tooltips, snack bars) takes the chat look.
ThemeData nexusThemeData(NexusTokens nx) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: nx.accent,
        brightness: nx.brightness,
      ).copyWith(
        primary: nx.accent,
        onPrimary: nx.onAccent,
        surface: nx.surface,
        onSurface: nx.ink,
        onSurfaceVariant: nx.ink2,
        outline: nx.line2,
        outlineVariant: nx.line,
        error: nx.now,
        onError: nx.onAccent,
        surfaceContainer: nx.surface2,
        surfaceContainerHighest: nx.surface2,
      );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(NexusTokens.rCard),
    side: BorderSide(color: nx.line),
  );
  final body = nx.text(NexusTokens.t14, height: NexusTokens.lhBody);
  return ThemeData(
    useMaterial3: true,
    brightness: nx.brightness,
    fontFamily: NexusTokens.sans,
    fontFamilyFallback: NexusTokens.sansFallback,
    colorScheme: scheme,
    scaffoldBackgroundColor: nx.surface,
    canvasColor: nx.surface,
    dividerColor: nx.line,
    extensions: [nx],
    splashFactory: NoSplash.splashFactory,
    hoverColor: nx.ghostHover(),
    highlightColor: Colors.transparent,
    textTheme: TextTheme(
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: nx.text(NexusTokens.t12, color: nx.ink2),
      labelLarge: nx.text(NexusTokens.t125, weight: NexusTokens.w600),
      labelMedium: nx.text(NexusTokens.t12, weight: NexusTokens.w560),
      labelSmall: nx.text(NexusTokens.t115, color: nx.ink3),
      titleMedium: nx.text(NexusTokens.t14, weight: NexusTokens.w640),
      titleLarge: nx.text(NexusTokens.t15, weight: NexusTokens.w640),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: nx.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: nx.shadow,
      elevation: NxSpace.s12,
      shape: shape,
      titleTextStyle: nx.text(NexusTokens.t15, weight: NexusTokens.w640),
      contentTextStyle: body,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: nx.elevated,
      surfaceTintColor: Colors.transparent,
      shadowColor: nx.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
        side: BorderSide(color: nx.line),
      ),
      textStyle: nx.text(NexusTokens.t135),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: nx.ink,
        borderRadius: BorderRadius.circular(NexusTokens.rSm),
      ),
      textStyle: nx.text(NexusTokens.t12, color: nx.surface),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: nx.ink,
      contentTextStyle: nx.text(NexusTokens.t13, color: nx.surface),
      actionTextColor: nx.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: nx.accent,
      linearTrackColor: nx.surface2,
      circularTrackColor: Colors.transparent,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: nx.accent,
        textStyle: nx.text(NexusTokens.t125, weight: NexusTokens.w600),
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(
          horizontal: NxSpace.s10,
          vertical: NxSpace.s6,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: nx.accent,
        foregroundColor: nx.onAccent,
        disabledBackgroundColor: nx.surface2,
        disabledForegroundColor: nx.ink3,
        textStyle: nx.text(NexusTokens.t125, weight: NexusTokens.w600),
        minimumSize: const Size(0, NxSize.send),
        padding: const EdgeInsets.symmetric(horizontal: NxSize.sendPad),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
        ),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: nx.line2, width: NxSize.checkBorder),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NexusTokens.rKbd),
      ),
    ),
  );
}

/// Applies the NEXUS theme, light or dark from the platform brightness.
class NexusTheme extends StatelessWidget {
  const NexusTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Theme(
    data: nexusThemeData(
      NexusTokens.of(MediaQuery.platformBrightnessOf(context)),
    ),
    child: child,
  );
}
