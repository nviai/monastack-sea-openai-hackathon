import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:monastack/features/office/world/iso.dart';
import 'package:monastack/features/office/world/office_map.dart';

/// A static object with height. Avatars are drawn over the cached scene and
/// then any occluder that is nearer the viewer and overlaps them is repainted.
class SceneOccluder {
  SceneOccluder(this.depth, this.bounds, this.paint);
  final double depth;
  final Rect bounds;
  final void Function(Canvas canvas) paint;
}

/// Programmatic, original artwork for the office. Everything static is
/// recorded once into [picture]; nothing here runs per frame.
class OfficeScene {
  OfficeScene(this.map) : iso = Iso(map.tileWidth, map.tileHeight) {
    _build();
  }

  final OfficeMap map;
  final Iso iso;
  late final ui.Picture picture;
  final List<SceneOccluder> occluders = [];
  late final Rect bounds;

  static const wallFace = Color(0xffefe9df);
  static const wallCap = Color(0xff7d9a8a);

  /// Wall slabs hug the interior side of their perimeter cell.
  static const wallThickness = .36;
  static const platform = Color(0xffc5cdbd);
  static const ink = Color(0xff30483f);

  void dispose() => picture.dispose();

  void _build() {
    final statics = <SceneOccluder>[];
    for (final room in map.rooms) {
      for (var x = room.x0; x <= room.x1; x++) {
        for (var y = room.y0; y <= room.y1; y++) {
          if (!room.perimeter(x, y)) continue;
          if (room.isWall(x, y)) {
            statics.add(_wall(room, x, y));
          } else if (room.isBackEdge(x, y)) {
            statics.add(_doorHeader(room, x, y));
          }
        }
      }
    }
    for (final prop in map.props) {
      if (prop.type == 'rug') continue;
      statics.add(_prop(prop));
    }
    for (final desk in map.desks) {
      statics.add(_chair(desk));
    }
    statics.sort((a, b) => a.depth.compareTo(b.depth));
    occluders.addAll(statics);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _floor(canvas);
    for (final item in statics) {
      item.paint(canvas);
    }
    picture = recorder.endRecording();

    final w = map.width.toDouble(), h = map.height.toDouble();
    bounds = Rect.fromLTRB(
      iso.project(-.5, h - .5).dx,
      iso.project(-.5, -.5, map.wallHeight).dy,
      iso.project(w - .5, -.5).dx,
      iso.project(w - .5, h - .5).dy + 18,
    );
  }

  // ---------------------------------------------------------------- floor --

  void _floor(Canvas canvas) {
    final all = Iso.cells(0, 0, map.width, map.height);
    iso.box(canvas, all, -16, 0, platform, top: map.corridorFloor);
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .6
      ..color = shade(map.corridorFloor, -.08);
    for (var x = 0; x < map.width; x++) {
      for (var y = 0; y < map.height; y++) {
        if (map.roomContaining(x, y) == null) {
          canvas.drawPath(iso.floor(Iso.cells(x, y)), grid);
        }
      }
    }
    for (final room in map.rooms) {
      _roomFloor(canvas, room);
    }
    for (final prop in map.props.where((p) => p.type == 'rug')) {
      _rug(canvas, prop);
    }
    for (final prop in map.props.where((p) => p.solid)) {
      iso.shadow(canvas, Iso.cells(prop.x, prop.y, prop.w, prop.h));
    }
  }

  void _roomFloor(Canvas canvas, MapRoom room) {
    final interior = Rect.fromLTRB(
      room.x0 + .5,
      room.y0 + .5,
      room.x1 - .5,
      room.y1 - .5,
    );
    canvas.drawPath(iso.floor(interior), Paint()..color = room.floor);
    final line = Paint()
      ..strokeWidth = .7
      ..color = shade(room.floor, -.06);
    switch (room.pattern) {
      case 'wood':
        for (var y = room.y0 + 1; y < room.y1; y++) {
          for (var k = 0; k < 3; k++) {
            final wy = y - .5 + k / 3;
            canvas.drawLine(
              iso.project(interior.left, wy),
              iso.project(interior.right, wy),
              line,
            );
          }
          for (var x = room.x0 + 1 + (y % 2); x < room.x1; x += 2) {
            canvas.drawLine(
              iso.project(x - .5, y - .5),
              iso.project(x - .5, y + .5),
              line,
            );
          }
        }
      case 'tile':
        final light = Paint()..color = shade(room.floor, .025);
        for (var x = room.x0 + 1; x < room.x1; x++) {
          for (var y = room.y0 + 1; y < room.y1; y++) {
            if ((x + y).isEven) {
              canvas.drawPath(iso.floor(Iso.cells(x, y)), light);
            }
          }
        }
      default:
        canvas.drawPath(
          iso.floor(interior.deflate(.25)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = shade(room.floor, -.05),
        );
    }
    // Ambient occlusion along the two far walls.
    final ao = Paint()..color = const Color(0x14000000);
    canvas.drawPath(
      iso.floor(
        Rect.fromLTRB(
          interior.left,
          interior.top,
          interior.right,
          interior.top + .35,
        ),
      ),
      ao,
    );
    canvas.drawPath(
      iso.floor(
        Rect.fromLTRB(
          interior.left,
          interior.top,
          interior.left + .35,
          interior.bottom,
        ),
      ),
      ao,
    );
    for (final door in room.doors) {
      canvas.drawPath(
        iso.floor(Iso.cells(door.x, door.y)),
        Paint()..color = shade(room.floor, -.03),
      );
      canvas.drawPath(
        iso.floor(Iso.cells(door.x, door.y).deflate(.3)),
        Paint()..color = room.accent.withValues(alpha: .28),
      );
    }
  }

  void _rug(Canvas canvas, MapProp prop) {
    final room = map.roomContaining(prop.x, prop.y);
    final base = room?.accent ?? const Color(0xff8fa8a0);
    final r = Iso.cells(prop.x, prop.y, prop.w, prop.h).deflate(.1);
    canvas.drawPath(iso.floor(r), Paint()..color = shade(base, .28));
    canvas.drawPath(
      iso.floor(r.deflate(.22)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = shade(base, .12),
    );
    canvas.drawPath(
      iso.floor(r.deflate(.5)),
      Paint()..color = shade(base, .34),
    );
  }

  // ----------------------------------------------------------------- walls --

  SceneOccluder _wall(MapRoom room, int x, int y) {
    final back = room.isBackEdge(x, y);
    final height = back ? map.wallHeight : map.lowWallHeight;
    final r = _slab(room, x, y);
    return SceneOccluder(
      r.center.dx + r.center.dy,
      iso.boxBounds(r, 0, height),
      (canvas) {
        iso.box(canvas, r, 0, height, wallFace, top: wallCap);
        if (!back) return;
        // Baseboard on the interior face in the room colour.
        final board = Paint()..color = room.accent.withValues(alpha: .75);
        if (y == room.y0 && x != room.x0) {
          canvas.drawPath(
            iso.quad(
              iso.project(r.left, r.bottom),
              iso.project(r.right, r.bottom),
              iso.project(r.right, r.bottom, 5),
              iso.project(r.left, r.bottom, 5),
            ),
            board,
          );
        }
        if (x == room.x0 && y != room.y0) {
          canvas.drawPath(
            iso.quad(
              iso.project(r.right, r.bottom),
              iso.project(r.right, r.top),
              iso.project(r.right, r.top, 5),
              iso.project(r.right, r.bottom, 5),
            ),
            board,
          );
        }
      },
    );
  }

  /// Lintel over a doorway in a full-height wall, so the gap reads as a door.
  /// The part of a perimeter cell occupied by wall, adjacent to the interior.
  Rect _slab(MapRoom room, int x, int y) {
    var left = x - .5, right = x + .5, top = y - .5, bottom = y + .5;
    if (x == room.x0) left = x + .5 - wallThickness;
    if (x == room.x1) right = x - .5 + wallThickness;
    if (y == room.y0) top = y + .5 - wallThickness;
    if (y == room.y1) bottom = y - .5 + wallThickness;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  SceneOccluder _doorHeader(MapRoom room, int x, int y) {
    final r = _slab(room, x, y);
    final z0 = map.wallHeight * .72;
    return SceneOccluder(
      r.center.dx + r.center.dy,
      iso.boxBounds(r, z0, map.wallHeight),
      (canvas) {
        iso.box(canvas, r, z0, map.wallHeight, wallFace, top: wallCap);
        iso.box(canvas, r, z0 - 2, z0, shade(room.accent, -.05));
      },
    );
  }

  // ----------------------------------------------------------------- props --

  SceneOccluder _prop(MapProp prop) {
    final r = Iso.cells(prop.x, prop.y, prop.w, prop.h);
    if (prop.wallMounted) {
      final depth = (prop.x + prop.w - 1 + prop.y + prop.h - 1) + .05;
      return SceneOccluder(
        depth,
        iso.boxBounds(r, 0, map.wallHeight),
        (canvas) => _decor(canvas, prop),
      );
    }
    final room = map.roomContaining(prop.x, prop.y);
    final accent = room?.accent ?? const Color(0xff4c7468);
    final (top, paint) = switch (prop.type) {
      'desk' => (40.0, (Canvas c) => _desk(c, prop, r)),
      'counter' => (34.0, (Canvas c) => _counter(c, prop, r, accent)),
      'coffee_bar' => (40.0, (Canvas c) => _coffeeBar(c, r)),
      'sofa' => (24.0, (Canvas c) => _sofa(c, prop, r, accent)),
      'table' || 'side_table' => (18.0, (Canvas c) => _table(c, r)),
      'meeting_table' => (22.0, (Canvas c) => _meetingTable(c, r, accent)),
      'plant' => (40.0, (Canvas c) => _plant(c, r)),
      'cabinet' => (36.0, (Canvas c) => _cabinet(c, r)),
      'safe' => (24.0, (Canvas c) => _safe(c, r)),
      _ => (
        16.0,
        (Canvas c) => iso.box(c, r.deflate(.1), 0, 16, const Color(0xffcbbfae)),
      ),
    };
    return SceneOccluder(prop.depth, iso.boxBounds(r, 0, top), paint);
  }

  SceneOccluder _chair(MapDesk desk) {
    final r = Iso.cells(desk.seat.x, desk.seat.y).deflate(.27);
    final room = map.roomById(desk.room);
    final color = shade(room?.accent ?? const Color(0xff4c7468), -.05);
    return SceneOccluder(
      desk.seat.x + desk.seat.y - .2,
      iso.boxBounds(r, 0, 12),
      (canvas) {
        iso.box(canvas, r.deflate(.16), 0, 7, const Color(0xff5d6461));
        iso.box(canvas, r, 7, 11, color);
      },
    );
  }

  static const _wood = Color(0xffc9a07a);
  static const _woodTop = Color(0xffe2c4a0);

  void _desk(Canvas c, MapProp prop, Rect r) {
    final top = r.deflate(.06);
    for (final (lx, ly) in [
      (top.left + .05, top.top + .05),
      (top.right - .11, top.top + .05),
      (top.left + .05, top.bottom - .11),
      (top.right - .11, top.bottom - .11),
    ]) {
      iso.box(
        c,
        Rect.fromLTWH(lx, ly, .06, .06),
        0,
        16,
        const Color(0xff8a7766),
      );
    }
    iso.box(c, top, 16, 20, _wood, top: _woodTop);
    // One monitor per seat, on the side away from the seat.
    final along = prop.facing == 's' || prop.facing == 'n';
    final count = along ? prop.w : prop.h;
    for (var i = 0; i < count; i++) {
      final cx = along ? prop.x + i.toDouble() : prop.x.toDouble();
      final cy = along ? prop.y.toDouble() : prop.y + i.toDouble();
      final Rect screen = switch (prop.facing) {
        's' => Rect.fromLTWH(cx - .28, cy - .34, .56, .07),
        'n' => Rect.fromLTWH(cx - .28, cy + .27, .56, .07),
        'e' => Rect.fromLTWH(cx - .34, cy - .28, .07, .56),
        _ => Rect.fromLTWH(cx + .27, cy - .28, .07, .56),
      };
      iso.box(
        c,
        Rect.fromCenter(center: screen.center, width: .08, height: .08),
        20,
        25,
        const Color(0xff4b5458),
      );
      iso.box(c, screen, 25, 40, const Color(0xff3b4a52));
      // Lit screen face when it faces the camera.
      if (prop.facing == 's') {
        c.drawPath(
          iso.quad(
            iso.project(screen.left + .03, screen.bottom, 27),
            iso.project(screen.right - .03, screen.bottom, 27),
            iso.project(screen.right - .03, screen.bottom, 38),
            iso.project(screen.left + .03, screen.bottom, 38),
          ),
          Paint()..color = const Color(0xff9cc3d4),
        );
      } else if (prop.facing == 'e') {
        c.drawPath(
          iso.quad(
            iso.project(screen.right, screen.bottom - .03, 27),
            iso.project(screen.right, screen.top + .03, 27),
            iso.project(screen.right, screen.top + .03, 38),
            iso.project(screen.right, screen.bottom - .03, 38),
          ),
          Paint()..color = const Color(0xff9cc3d4),
        );
      }
      final keyboard = switch (prop.facing) {
        's' => Rect.fromLTWH(cx - .2, cy + .08, .4, .14),
        'n' => Rect.fromLTWH(cx - .2, cy - .22, .4, .14),
        'e' => Rect.fromLTWH(cx + .08, cy - .2, .14, .4),
        _ => Rect.fromLTWH(cx - .22, cy - .2, .14, .4),
      };
      iso.box(c, keyboard, 20, 21.5, const Color(0xfff4f1ea));
    }
  }

  void _counter(Canvas c, MapProp prop, Rect r, Color accent) {
    final body = r.deflate(.05);
    iso.box(
      c,
      body,
      0,
      30,
      const Color(0xffe0cdb2),
      top: const Color(0xfff3e7d4),
    );
    iso.box(
      c,
      Rect.fromLTRB(
        body.left - .04,
        body.top - .04,
        body.right + .04,
        body.bottom + .04,
      ),
      30,
      34,
      _wood,
      top: _woodTop,
    );
    c.drawPath(
      iso.quad(
        iso.project(body.left, body.bottom, 10),
        iso.project(body.right, body.bottom, 10),
        iso.project(body.right, body.bottom, 18),
        iso.project(body.left, body.bottom, 18),
      ),
      Paint()..color = accent,
    );
  }

  void _coffeeBar(Canvas c, Rect r) {
    final body = r.deflate(.05);
    iso.box(
      c,
      body,
      0,
      26,
      const Color(0xffb98d6b),
      top: const Color(0xffe8d8c4),
    );
    iso.box(
      c,
      Rect.fromLTWH(body.left + .15, body.top + .1, .4, .35),
      26,
      42,
      const Color(0xff4a4f52),
    );
    iso.box(
      c,
      Rect.fromLTWH(body.left + .25, body.top + .45, .2, .12),
      26,
      30,
      const Color(0xff4a4f52),
    );
    for (var i = 0; i < 3; i++) {
      final p = iso.project(body.right - .25 - i * .22, body.center.dy, 29);
      c.drawCircle(p, 3, Paint()..color = const Color(0xfffaf6ef));
      c.drawCircle(
        p.translate(0, -1),
        2,
        Paint()..color = const Color(0xff8b5e3c),
      );
    }
  }

  void _sofa(Canvas c, MapProp prop, Rect r, Color accent) {
    final fabric = Color.lerp(const Color(0xffd29a88), accent, .25)!;
    final base = r.deflate(.06);
    iso.box(c, base, 0, 10, shade(fabric, -.08), top: fabric);
    const d = .24;
    final back = switch (prop.facing) {
      'n' => Rect.fromLTRB(base.left, base.bottom - d, base.right, base.bottom),
      's' => Rect.fromLTRB(base.left, base.top, base.right, base.top + d),
      'e' => Rect.fromLTRB(base.left, base.top, base.left + d, base.bottom),
      _ => Rect.fromLTRB(base.right - d, base.top, base.right, base.bottom),
    };
    final along = prop.facing == 'n' || prop.facing == 's';
    final arms = along
        ? [
            Rect.fromLTRB(base.left, base.top, base.left + .16, base.bottom),
            Rect.fromLTRB(base.right - .16, base.top, base.right, base.bottom),
          ]
        : [
            Rect.fromLTRB(base.left, base.top, base.right, base.top + .16),
            Rect.fromLTRB(
              base.left,
              base.bottom - .16,
              base.right,
              base.bottom,
            ),
          ];
    // Paint far pieces first.
    final pieces = [(back, 10.0, 24.0), for (final a in arms) (a, 10.0, 16.0)]
      ..sort(
        (a, b) => (a.$1.center.dx + a.$1.center.dy).compareTo(
          b.$1.center.dx + b.$1.center.dy,
        ),
      );
    for (final (rect, z0, z1) in pieces) {
      iso.box(c, rect, z0, z1, shade(fabric, -.04), top: shade(fabric, .06));
    }
  }

  void _table(Canvas c, Rect r) {
    final top = r.deflate(.12);
    iso.box(
      c,
      Rect.fromCenter(center: top.center, width: .14, height: .14),
      0,
      14,
      const Color(0xff8a7766),
    );
    iso.box(c, top, 14, 18, _wood, top: _woodTop);
  }

  void _meetingTable(Canvas c, Rect r, Color accent) {
    final top = r.deflate(.1);
    final chair = shade(accent, -.05);
    for (var x = r.left + .5; x < r.right; x += 1) {
      final rect = Rect.fromCenter(
        center: Offset(x, r.top - .28),
        width: .42,
        height: .36,
      );
      iso.box(c, rect, 0, 10, chair);
      iso.box(
        c,
        Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + .08),
        10,
        22,
        chair,
      );
    }
    for (final dx in [top.left + .4, top.right - .4]) {
      iso.box(
        c,
        Rect.fromCenter(
          center: Offset(dx, top.center.dy),
          width: .2,
          height: .5,
        ),
        0,
        16,
        const Color(0xff8a7766),
      );
    }
    iso.box(
      c,
      top,
      16,
      20,
      const Color(0xffd8b892),
      top: const Color(0xffead3b4),
    );
    for (var x = r.left + .5; x < r.right; x += 1) {
      iso.box(
        c,
        Rect.fromCenter(
          center: Offset(x, r.bottom + .28),
          width: .42,
          height: .36,
        ),
        0,
        10,
        chair,
      );
    }
  }

  void _plant(Canvas c, Rect r) {
    final pot = Rect.fromCenter(center: r.center, width: .4, height: .4);
    iso.box(
      c,
      pot,
      0,
      13,
      const Color(0xffc98a6e),
      top: const Color(0xff7a5a44),
    );
    final base = iso.project(r.center.dx, r.center.dy, 13);
    final leaves = [
      (const Offset(-7, -6), 8.0, const Color(0xff5f8f6c)),
      (const Offset(6, -8), 8.0, const Color(0xff6c9a74)),
      (const Offset(0, -15), 9.0, const Color(0xff7eaa82)),
      (const Offset(-4, -22), 7.0, const Color(0xff8fb98f)),
      (const Offset(5, -19), 6.0, const Color(0xff9cc39a)),
    ];
    for (final (offset, radius, color) in leaves) {
      c.drawCircle(base + offset, radius, Paint()..color = color);
    }
  }

  void _cabinet(Canvas c, Rect r) {
    final body = r.deflate(.06);
    iso.box(c, body, 0, 34, const Color(0xffcfd5d9));
    final line = Paint()
      ..color = const Color(0xff9aa3a8)
      ..strokeWidth = 1;
    for (final z in [11.0, 22.0]) {
      c.drawLine(
        iso.project(body.left, body.bottom, z),
        iso.project(body.right, body.bottom, z),
        line,
      );
    }
    for (var x = body.left + .5; x < body.right; x += 1) {
      for (final z in [6.0, 17.0, 28.0]) {
        c.drawLine(
          iso.project(x - .1, body.bottom, z),
          iso.project(x + .1, body.bottom, z),
          line..strokeWidth = 2,
        );
      }
    }
  }

  void _safe(Canvas c, Rect r) {
    final body = r.deflate(.1);
    iso.box(c, body, 0, 22, const Color(0xff5f6b73));
    final dial = iso.project(body.center.dx, body.bottom, 12);
    c.drawCircle(dial, 3.5, Paint()..color = const Color(0xffc9d1d6));
  }

  // ----------------------------------------------------------- wall decor --

  /// Paints in a face-local frame: `u` runs left→right along the wall's
  /// interior face (32 units per cell), `v` runs down from `top`.
  void _onFace(
    Canvas c,
    MapProp prop,
    double top,
    void Function(Canvas c, double length) draw,
  ) {
    final room = map.roomContaining(prop.x, prop.y);
    if (room == null) return;
    final Offset origin;
    final Offset along;
    final double length;
    if (prop.y == room.y0) {
      origin = iso.project(prop.x - .5, prop.y + .5, top);
      along = const Offset(1, .5);
      length = prop.w * map.tileWidth / 2;
    } else if (prop.x == room.x0) {
      origin = iso.project(prop.x + .5, prop.y + prop.h - .5, top);
      along = const Offset(1, -.5);
      length = prop.h * map.tileWidth / 2;
    } else {
      return;
    }
    c.save();
    c.transform(
      Float64List.fromList([
        along.dx, along.dy, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        origin.dx, origin.dy, 0, 1,
      ]),
    );
    draw(c, length);
    c.restore();
  }

  void _decor(Canvas canvas, MapProp prop) {
    final room = map.roomContaining(prop.x, prop.y);
    final accent = room?.accent ?? const Color(0xff4c7468);
    final top = map.wallHeight - 6;
    switch (prop.type) {
      case 'sign':
        _onFace(canvas, prop, map.wallHeight - 3, (c, length) {
          final panel = RRect.fromRectAndRadius(
            Rect.fromLTWH(6, 2, length - 12, 22),
            const Radius.circular(4),
          );
          c.drawRRect(panel, Paint()..color = const Color(0xff2f4f46));
          _text(
            c,
            prop.text ?? '',
            Rect.fromLTWH(6, 2, length - 12, 22),
            16,
            const Color(0xffffffff),
            FontWeight.w800,
            spacing: 4,
          );
        });
      case 'screen':
        _onFace(canvas, prop, top + 2, (c, length) {
          final frame = Rect.fromLTWH(5, 2, length - 10, 24);
          c.drawRRect(
            RRect.fromRectAndRadius(frame, const Radius.circular(2)),
            Paint()..color = const Color(0xff2d3539),
          );
          c.drawRect(
            frame.deflate(2),
            Paint()..color = Color.lerp(const Color(0xff3e6f86), accent, .3)!,
          );
          if (prop.text != null) {
            _text(
              c,
              prop.text!,
              frame.deflate(2),
              6,
              const Color(0xffffffff),
              FontWeight.w600,
              maxLines: 2,
            );
          } else {
            for (var i = 0; i < 3; i++) {
              c.drawRect(
                Rect.fromLTWH(
                  frame.left + 6 + i * 12,
                  frame.bottom - 6 - i * 4.0,
                  8,
                  4 + i * 4.0,
                ),
                Paint()..color = const Color(0xffcde6ee),
              );
            }
          }
        });
      case 'whiteboard':
        _onFace(canvas, prop, top + 2, (c, length) {
          final board = Rect.fromLTWH(4, 2, length - 8, 22);
          c.drawRect(board, Paint()..color = const Color(0xfff9fbfb));
          c.drawRect(
            board,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = const Color(0xffb9c2c6),
          );
          final pen = Paint()
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke;
          c.drawPath(
            Path()
              ..moveTo(10, 10)
              ..lineTo(22, 7)
              ..lineTo(30, 14)
              ..lineTo(40, 9),
            pen..color = const Color(0xff4f7fb5),
          );
          c.drawRect(
            Rect.fromLTWH(length - 26, 7, 12, 9),
            pen..color = const Color(0xffd0735f),
          );
        });
      case 'board':
        _onFace(canvas, prop, top + 2, (c, length) {
          final board = Rect.fromLTWH(4, 2, length - 8, 22);
          c.drawRect(board, Paint()..color = const Color(0xfff3efe6));
          const notes = [
            Color(0xfff6d06f),
            Color(0xff9fd0b5),
            Color(0xfff2a7a0),
            Color(0xffa9c6ea),
          ];
          final columns = (length - 8) ~/ 16;
          for (var col = 0; col < columns; col++) {
            for (var row = 0; row < 2 + col % 2; row++) {
              c.drawRect(
                Rect.fromLTWH(8 + col * 16.0, 5 + row * 6.5, 10, 5),
                Paint()..color = notes[(col + row) % notes.length],
              );
            }
          }
        });
      case 'shelf':
        _onFace(canvas, prop, top - 2, (c, length) {
          final wood = Paint()..color = const Color(0xffb88d68);
          for (final y in [12.0, 26.0]) {
            c.drawRect(Rect.fromLTWH(3, y, length - 6, 3), wood);
            var x = 6.0;
            var i = 0;
            while (x < length - 10) {
              final h = 7.0 + (i * 7 % 4);
              c.drawRect(
                Rect.fromLTWH(x, y - h, 3.5, h),
                Paint()
                  ..color = [
                    const Color(0xff6f8fb0),
                    const Color(0xffd58f7c),
                    const Color(0xff79a88a),
                    const Color(0xffe0c27a),
                  ][i % 4],
              );
              x += 4.5;
              i++;
            }
          }
        });
      case 'art':
        _onFace(canvas, prop, top + 2, (c, length) {
          final frame = Rect.fromLTWH(10, 2, length - 20, 20);
          c.drawRect(frame, Paint()..color = const Color(0xff8a6a50));
          c.drawRect(
            frame.deflate(2),
            Paint()..color = const Color(0xfffaf3e8),
          );
          c.drawCircle(
            frame.center.translate(-6, 0),
            5,
            Paint()..color = accent,
          );
          c.drawRect(
            Rect.fromCenter(
              center: frame.center.translate(7, 2),
              width: 12,
              height: 8,
            ),
            Paint()..color = const Color(0xfff0c36d),
          );
        });
    }
  }

  void _text(
    Canvas c,
    String text,
    Rect box,
    double size,
    Color color,
    FontWeight weight, {
    double spacing = 0,
    int maxLines = 1,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: spacing,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1, box.width));
    painter.paint(
      c,
      Offset(
        box.left + (box.width - painter.width) / 2,
        box.top + (box.height - painter.height) / 2,
      ),
    );
    painter.dispose();
  }
}
