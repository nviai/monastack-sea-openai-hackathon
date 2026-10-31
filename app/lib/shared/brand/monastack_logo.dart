import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Background shape behind the logo glyph.
enum LogoPlate {
  /// Glyph only, transparent around it.
  none,

  /// Rounded square with a margin and drop shadow (macOS, Windows, web,
  /// Android legacy launchers).
  rounded,

  /// Edge-to-edge square; the platform applies its own mask (iOS, web
  /// maskable, Android adaptive background).
  fullBleed,
}

/// Brand colours, from DESIGN.md.
abstract final class BrandColors {
  static const blue = Color(0xff3b6bf6);
  static const blueLight = Color(0xff5b86ff);
  static const blueDeep = Color(0xff2448c9);
  static const yellow = Color(0xfff7c744);
}

/// The Monastack mark: an "M" built from isometric office blocks, with a
/// person standing in its notch. Original artwork drawn in code.
///
/// The M is a 7×5 grid of blocks standing in one plane of the isometric
/// world, like a run of office walls. Top row first.
const _rows = ['XX...XX', 'XXX.XXX', 'X.XXX.X', 'X..X..X', 'X.....X'];
const _columns = 7, _height = 5;

/// Block depth (into the picture) relative to its width: thin like a wall.
const _depth = .55;

/// Paints the logo filling `size` (square). `glyphScale` overrides how much
/// of the square the M occupies, e.g. for Android's adaptive-icon safe zone.
void paintMonastackLogo(
  Canvas canvas,
  Size size, {
  LogoPlate plate = LogoPlate.none,
  double? glyphScale,
}) {
  final s = size.shortestSide;
  canvas.save();
  canvas.translate((size.width - s) / 2, (size.height - s) / 2);
  final double defaultScale;
  switch (plate) {
    case LogoPlate.none:
      defaultScale = 1;
    case LogoPlate.rounded:
      // Apple's grid: an 824 pt body inside a 1024 pt canvas.
      final body = Rect.fromLTWH(s * .1, s * .1, s * .8, s * .8);
      final rrect = RRect.fromRectAndRadius(body, Radius.circular(s * .18));
      canvas.drawRRect(
        rrect.shift(Offset(0, s * .012)),
        Paint()
          ..color = const Color(0x55000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * .02),
      );
      canvas.drawRRect(rrect, _plateFill(body));
      defaultScale = .8;
    case LogoPlate.fullBleed:
      final body = Offset.zero & Size.square(s);
      canvas.drawRect(body, _plateFill(body));
      // Masks and safe zones keep the centre ~66 % visible.
      defaultScale = .86;
  }
  _paintGlyph(
    canvas,
    s,
    glyphScale ?? defaultScale,
    onPlate: plate != LogoPlate.none,
  );
  canvas.restore();
}

Paint _plateFill(Rect body) => Paint()
  ..shader = ui.Gradient.linear(body.topLeft, body.bottomRight, const [
    BrandColors.blueLight,
    BrandColors.blueDeep,
  ]);

void _paintGlyph(
  Canvas canvas,
  double s,
  double scale, {
  required bool onPlate,
}) {
  // Projection: a unit along x or y moves u across and u / 2 down; a unit
  // of height moves e up.
  const heightRatio = 1.0;
  const widthU = _columns + _depth;
  const heightU = (_columns + _depth) / 2 + _height * heightRatio;
  final u = s * scale * .74 / heightU;
  final e = u * heightRatio;
  // Centre the glyph's bounding box; origin is world (0, 0, 0).
  final origin = Offset(
    (s - widthU * u) / 2 + _depth * u,
    (s - heightU * u) / 2 + _height * e,
  );
  Offset p(double x, double y, double z) =>
      origin + Offset((x - y) * u, (x + y) * u / 2 - z * e);

  bool filled(int x, int z) =>
      x >= 0 &&
      x < _columns &&
      z >= 0 &&
      z < _height &&
      _rows[_height - 1 - z][x] == 'X';

  // Contact shadow on the floor.
  canvas.drawPath(
    Path()..addPolygon([
      p(-.2, -.2, 0),
      p(_columns + .4, -.2, 0),
      p(_columns + .4, _depth + 1.1, 0),
      p(-.2, _depth + 1.1, 0),
    ], true),
    Paint()
      ..color = onPlate ? const Color(0x55102a80) : const Color(0x33102a80)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * .45),
  );

  final tops = Path(), rights = Path(), fronts = Path();
  for (var x = 0; x < _columns; x++) {
    for (var z = 0; z < _height; z++) {
      if (!filled(x, z)) continue;
      final fx = x.toDouble(), fz = z.toDouble();
      if (!filled(x, z + 1)) {
        tops.addPolygon([
          p(fx, 0, fz + 1),
          p(fx + 1, 0, fz + 1),
          p(fx + 1, _depth, fz + 1),
          p(fx, _depth, fz + 1),
        ], true);
      }
      if (!filled(x + 1, z)) {
        rights.addPolygon([
          p(fx + 1, 0, fz),
          p(fx + 1, _depth, fz),
          p(fx + 1, _depth, fz + 1),
          p(fx + 1, 0, fz + 1),
        ], true);
      }
      fronts.addPolygon([
        p(fx, _depth, fz),
        p(fx + 1, _depth, fz),
        p(fx + 1, _depth, fz + 1),
        p(fx, _depth, fz + 1),
      ], true);
    }
  }
  // Each face group is one path, so neighbouring blocks show no seams. The
  // letter is one block deep, so every front face lies in the plane nearest
  // the viewer: drawing tops, then right sides, then fronts is a correct
  // painter's order.
  canvas.drawPath(tops, Paint()..color = const Color(0xffd3ddff));
  canvas.drawPath(rights, Paint()..color = const Color(0xff8fa6f2));

  // The person stands on the block at the bottom of the M's notch.
  final feet = p(3.45, _depth / 2, 3);
  canvas.drawOval(
    Rect.fromCenter(center: feet, width: u * .7, height: u * .3),
    Paint()..color = const Color(0x402448c9),
  );
  final body = RRect.fromRectAndRadius(
    Rect.fromCenter(
      center: feet - Offset(0, e * .3),
      width: u * .5,
      height: e * .6,
    ),
    Radius.circular(u * .25),
  );
  canvas.drawRRect(body, Paint()..color = const Color(0xffdc9f1f));
  canvas.save();
  canvas.clipRRect(body);
  canvas.drawRect(
    Rect.fromLTRB(body.left, body.top, feet.dx - u * .04, body.bottom),
    Paint()..color = BrandColors.yellow,
  );
  canvas.restore();
  final head = feet - Offset(0, e * .6 + u * .26);
  canvas.drawCircle(head, u * .27, Paint()..color = BrandColors.yellow);
  canvas.drawCircle(
    head - Offset(u * .09, u * .09),
    u * .08,
    Paint()..color = const Color(0x99ffffff),
  );

  canvas.drawPath(fronts, Paint()..color = const Color(0xffffffff));
}

/// The logo as a widget.
class MonastackLogo extends StatelessWidget {
  const MonastackLogo({
    super.key,
    this.size = 40,
    this.plate = LogoPlate.rounded,
  });

  final double size;
  final LogoPlate plate;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Monastack',
    image: true,
    child: CustomPaint(size: Size.square(size), painter: _LogoPainter(plate)),
  );
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter(this.plate);
  final LogoPlate plate;

  @override
  void paint(Canvas canvas, Size size) =>
      paintMonastackLogo(canvas, size, plate: plate);

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.plate != plate;
}
