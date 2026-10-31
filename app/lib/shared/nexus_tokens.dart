import 'package:flutter/material.dart';

/// NEXUS (nexus-fe) design tokens for Flutter: colours, radii and type.
/// Source: nexus-fe src/styles/tokens.css + tokens-scale.css, as approved in
/// monastack-plans/matrix-chat-2026-10/redesign. Light and dark values.
@immutable
class NexusTokens extends ThemeExtension<NexusTokens> {
  const NexusTokens({
    required this.brightness,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.elevated,
    required this.chrome,
    required this.line,
    required this.line2,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentWeak,
    required this.accentInk,
    required this.onAccent,
    required this.now,
    required this.presence,
    required this.badge,
    required this.onBadge,
    required this.fill,
    required this.shadow,
    required this.hues,
  });

  final Brightness brightness;
  final Color surface, surface2, surface3, elevated, chrome;
  final Color line, line2;
  final Color ink, ink2, ink3;

  /// `--gt-accent` and `--gt-accent-solid` share one value in both themes.
  final Color accent, accentWeak, accentInk, onAccent;

  /// `--gt-now` danger ink; failed sends sit on a tint of it.
  final Color now;

  /// `--gt-pass-fill`, used for the presence dot.
  final Color presence;
  final Color badge, onBadge;

  /// Ghost-button hover fill (`--gt-fill`).
  final Color fill;
  final Color shadow;

  /// blue, violet, amber, green, teal, red (`--gt-hue-*`).
  final List<Color> hues;

  static const light = NexusTokens(
    brightness: Brightness.light,
    surface: Color(0xfffcfbf7),
    surface2: Color(0xfff1f1e9),
    surface3: Color(0xffffffff),
    elevated: Color(0xffffffff),
    chrome: Color(0xffe9ede4),
    line: Color(0xffe2e6dc),
    line2: Color(0xffc8d2c6),
    ink: Color(0xff253d38),
    ink2: Color(0xff53685f),
    ink3: Color(0xff526358),
    accent: Color(0xff46635a),
    accentWeak: Color(0xffe0eade),
    accentInk: Color(0xff324e43),
    onAccent: Color(0xffffffff),
    now: Color(0xff76000c),
    presence: Color(0xff16a34a),
    badge: Color(0xffff453a),
    onBadge: Color(0xff253d38),
    fill: Color(0x1a1d1a21),
    shadow: Color(0x2e000000),
    hues: [
      Color(0xff2f5fd0),
      Color(0xff6d4fd8),
      Color(0xff8f6a00),
      Color(0xff13804b),
      Color(0xff0f7f75),
      Color(0xffc62f2f),
    ],
  );

  static const dark = NexusTokens(
    brightness: Brightness.dark,
    surface: Color(0xff202b26),
    surface2: Color(0xff18221e),
    surface3: Color(0xff1c2722),
    elevated: Color(0xff2a3730),
    chrome: Color(0xff121b17),
    line: Color(0x14ffffff),
    line2: Color(0xff405047),
    ink: Color(0xffedf2e8),
    ink2: Color(0xffb5c5b8),
    ink3: Color(0xff9caf9f),
    accent: Color(0xffb4d3b5),
    accentWeak: Color(0x24b4d3b5),
    accentInk: Color(0xffb4d3b5),
    onAccent: Color(0xff183a28),
    now: Color(0xffffc4be),
    presence: Color(0xff16a34a),
    badge: Color(0xffff453a),
    onBadge: Color(0xff253d38),
    fill: Color(0x30f2f1f7),
    shadow: Color(0x2e000000),
    hues: [
      Color(0xff6b9cff),
      Color(0xffa78bfa),
      Color(0xffe0b23a),
      Color(0xff4fc38a),
      Color(0xff3ccfc0),
      Color(0xffff6b6b),
    ],
  );

  static NexusTokens of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// A stable hue for a name, so a person keeps one colour everywhere.
  Color hueFor(String name) =>
      hues[name.runes.fold<int>(0, (a, b) => a + b) % hues.length];

  // Alpha steps from the mockup (`color-mix(... N%, transparent)`).
  static const double alphaHover = .05, alphaMessageHover = .03;
  static const double alphaSelected = .10, alphaRing = .14;
  static const double alphaAvatar = .16, alphaFace = .22, alphaFail = .12;
  static const double alphaReactionBorder = .35, alphaHint = .6;

  Color ghostHover() => ink.withValues(alpha: alphaHover);
  Color messageHover() => ink.withValues(alpha: alphaMessageHover);
  Color selectedRow() => accent.withValues(alpha: alphaSelected);
  Color focusRing() => accent.withValues(alpha: alphaRing);
  Color failTint() => now.withValues(alpha: alphaFail);
  Color avatarBackground(String name, {bool face = false}) =>
      hueFor(name).withValues(alpha: face ? alphaFace : alphaAvatar);

  // Radii: --gt-r-sm / --gt-r-ctrl / --gt-r-card, plus a full pill.
  static const double rSm = 6, rCtrl = 8, rCard = 12, rPill = 999;
  static const double rKbd = 4, rMention = 4;

  // Type scale (tokens-scale.css): sizes in px, weights as variable-font wght.
  static const double t10 = 10, t11 = 11, t115 = 11.5, t12 = 12, t125 = 12.5;
  static const double t13 = 13, t135 = 13.5, t14 = 14, t15 = 15;
  static const double w500 = 500, w560 = 560, w580 = 580, w600 = 600;
  static const double w640 = 640;
  static const double lhUi = 1.4, lhBody = 1.5;
  static const String sans = 'Inter';
  static const String mono = 'Menlo';
  static const List<String> sansFallback = ['Apple Color Emoji'];

  /// One text style at a token size and weight. Inter is a variable font, so
  /// weights between the named steps (560, 580, 640) are real.
  TextStyle text(
    double size, {
    double weight = w500,
    Color? color,
    double height = lhUi,
    bool tabular = false,
    bool italic = false,
  }) => TextStyle(
    fontFamily: sans,
    fontFamilyFallback: sansFallback,
    fontSize: size,
    height: height,
    color: color ?? ink,
    fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
    fontVariations: [FontVariation.weight(weight)],
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
    leadingDistribution: TextLeadingDistribution.even,
  );

  TextStyle monoText(double size, {Color? color, double height = lhBody}) =>
      TextStyle(
        fontFamily: mono,
        fontFamilyFallback: const ['monospace'],
        fontSize: size,
        height: height,
        color: color ?? ink,
      );

  @override
  NexusTokens copyWith() => this;

  @override
  NexusTokens lerp(ThemeExtension<NexusTokens>? other, double t) =>
      t < .5 || other is! NexusTokens ? this : other;
}

extension NexusContext on BuildContext {
  NexusTokens get nx =>
      Theme.of(this).extension<NexusTokens>() ?? NexusTokens.light;
}
