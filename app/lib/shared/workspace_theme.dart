import 'package:flutter/material.dart';

import 'nexus_theme.dart';
import 'nexus_tokens.dart';

abstract final class WorkspaceColors {
  static const background = Color(0xfff7f5ef);
  static const paper = Color(0xfffcfbf7);
  static const sage = Color(0xff46635a);
  static const ink = Color(0xff253d38);
  static const muted = Color(0xff526358);
  static const border = Color(0xffdfe5d9);
}

ThemeData workspaceTheme() {
  final base = nexusThemeData(NexusTokens.light);
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
  );
  OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );
  return base.copyWith(
    scaffoldBackgroundColor: WorkspaceColors.background,
    visualDensity: VisualDensity.standard,
    textTheme: base.textTheme.copyWith(
      headlineSmall: const TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: WorkspaceColors.ink,
        letterSpacing: -.5,
      ),
      titleLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: WorkspaceColors.ink,
      ),
      titleMedium: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: WorkspaceColors.ink,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: WorkspaceColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: WorkspaceColors.border),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: WorkspaceColors.ink,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        height: 1.5,
        color: WorkspaceColors.muted,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
    ),
    cardTheme: CardThemeData(
      color: WorkspaceColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: WorkspaceColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: WorkspaceColors.paper,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      labelStyle: const TextStyle(fontSize: 13, color: WorkspaceColors.muted),
      hintStyle: const TextStyle(fontSize: 13, color: WorkspaceColors.muted),
      border: inputBorder(WorkspaceColors.border),
      enabledBorder: inputBorder(WorkspaceColors.border),
      focusedBorder: inputBorder(WorkspaceColors.sage, 1.5),
      errorBorder: inputBorder(base.colorScheme.error),
      focusedErrorBorder: inputBorder(base.colorScheme.error, 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WorkspaceColors.sage,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        minimumSize: const Size(0, 40),
        shape: rounded,
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WorkspaceColors.sage,
        backgroundColor: WorkspaceColors.paper,
        side: const BorderSide(color: WorkspaceColors.border),
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: WorkspaceColors.sage,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: WorkspaceColors.sage,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded,
      iconColor: WorkspaceColors.sage,
      textColor: WorkspaceColors.ink,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      selectedTileColor: const Color(0xffe6edde),
    ),
    dividerTheme: const DividerThemeData(
      color: WorkspaceColors.border,
      thickness: 1,
      space: 24,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xffe9eee2),
      side: BorderSide.none,
      labelStyle: const TextStyle(fontSize: 12, color: WorkspaceColors.sage),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStateProperty.all(const Color(0xffe9eee2)),
      headingTextStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: WorkspaceColors.ink,
      ),
      dataTextStyle: const TextStyle(fontSize: 13, color: WorkspaceColors.ink),
      dividerThickness: .5,
    ),
  );
}

/// Shared surface for workspace feature panels; forms inherit the same theme.
class WorkspaceDialog extends StatelessWidget {
  const WorkspaceDialog({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Dialog(
    clipBehavior: Clip.antiAlias,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xffc3d4bc), width: 4)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xfff0f3e9), WorkspaceColors.background],
          stops: [0, .3],
        ),
      ),
      child: child,
    ),
  );
}
