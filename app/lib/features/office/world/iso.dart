import 'package:flutter/painting.dart';

/// Orthographic 2:1 isometric projection. A cell `(x, y)` covers the world
/// square `[x - 0.5, x + 0.5] × [y - 0.5, y + 0.5]`; larger `x + y` is nearer
/// the viewer. `z` is height in screen units at zoom 1.
class Iso {
  const Iso(this.tileWidth, this.tileHeight);
  final double tileWidth;
  final double tileHeight;

  Offset project(double x, double y, [double z = 0]) =>
      Offset((x - y) * tileWidth / 2, (x + y) * tileHeight / 2 - z);

  /// Ground-plane world coordinates for a point in projected space.
  ({double x, double y}) unproject(Offset p) {
    final a = p.dx / (tileWidth / 2);
    final b = p.dy / (tileHeight / 2);
    return (x: (a + b) / 2, y: (b - a) / 2);
  }

  Path quad(Offset a, Offset b, Offset c, Offset d) => Path()
    ..moveTo(a.dx, a.dy)
    ..lineTo(b.dx, b.dy)
    ..lineTo(c.dx, c.dy)
    ..lineTo(d.dx, d.dy)
    ..close();

  /// Floor diamond for a world rectangle at height `z`.
  Path floor(Rect r, [double z = 0]) => quad(
    project(r.left, r.top, z),
    project(r.right, r.top, z),
    project(r.right, r.bottom, z),
    project(r.left, r.bottom, z),
  );

  /// World rectangle covered by a run of cells.
  static Rect cells(int x, int y, [int w = 1, int h = 1]) =>
      Rect.fromLTRB(x - .5, y - .5, x + w - .5, y + h - .5);

  /// Screen-space bounds of a box, used for occlusion tests.
  Rect boxBounds(Rect r, double z0, double z1) {
    final points = [
      project(r.left, r.top, z1),
      project(r.right, r.top, z1),
      project(r.left, r.bottom, z1),
      project(r.right, r.bottom, z0),
      project(r.left, r.bottom, z0),
      project(r.right, r.top, z0),
    ];
    var bounds = Rect.fromPoints(points[0], points[1]);
    for (final p in points.skip(2)) {
      bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
    }
    return bounds;
  }

  /// Draws the three faces of an axis-aligned box that face the camera.
  void box(
    Canvas canvas,
    Rect r,
    double z0,
    double z1,
    Color color, {
    Color? top,
    double outline = 0,
  }) {
    final left = quad(
      project(r.left, r.bottom, z0),
      project(r.right, r.bottom, z0),
      project(r.right, r.bottom, z1),
      project(r.left, r.bottom, z1),
    );
    final right = quad(
      project(r.right, r.bottom, z0),
      project(r.right, r.top, z0),
      project(r.right, r.top, z1),
      project(r.right, r.bottom, z1),
    );
    canvas.drawPath(left, Paint()..color = shade(color, -.04));
    canvas.drawPath(right, Paint()..color = shade(color, -.16));
    canvas.drawPath(floor(r, z1), Paint()..color = top ?? shade(color, .1));
    if (outline > 0) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outline
        ..color = shade(color, -.3).withValues(alpha: .35);
      canvas.drawPath(floor(r, z1), stroke);
    }
  }

  /// Soft contact shadow under a footprint.
  void shadow(Canvas canvas, Rect r, {double opacity = .12}) {
    final c = project(r.center.dx, r.center.dy);
    canvas.drawOval(
      Rect.fromCenter(
        center: c + Offset(0, tileHeight * .08),
        width: (r.width + r.height) * tileWidth / 2 * .95,
        height: (r.width + r.height) * tileHeight / 2 * .8,
      ),
      Paint()
        ..color = Color.fromRGBO(40, 50, 40, opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }
}

/// Lightens (positive) or darkens (negative) a colour in HSL space.
Color shade(Color color, double amount) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0)).toColor();
}
