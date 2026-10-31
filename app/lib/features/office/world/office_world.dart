import 'dart:convert';
import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:monastack/features/office/presence/remote_motion.dart';

typedef RouteFinder = List<List<int>>? Function(
  List<int> start,
  List<int> goal,
);

class OfficeWorld extends StatefulWidget {
  const OfficeWorld({
    super.key,
    required this.seed,
    required this.remote,
    required this.actor,
    required this.findPath,
    required this.onPosition,
    required this.onError,
  });
  final Map<String, dynamic> seed;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final String actor;
  final RouteFinder findPath;
  final void Function(List<int>, String) onPosition;
  final void Function(String) onError;
  @override
  State<OfficeWorld> createState() => OfficeWorldState();
}

class OfficeWorldState extends State<OfficeWorld> {
  final focus = FocusNode();
  Map<String, dynamic>? map;
  late final _WorldGame _game = _WorldGame(onStep: onStep);
  List<int> current = [2, 2];
  double gestureZoom = 1;
  Offset? lastFocal;
  bool reduceMotion = false;
  bool systemReduceMotion = false;
  @override
  void initState() {
    super.initState();
    widget.remote.addListener(updateRemote);
    updateRemote();
    load();
  }

  void updateRemote() {
    _game.remote.updateSnapshot(widget.remote.value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    systemReduceMotion = MediaQuery.disableAnimationsOf(context);
    updateMotionPreference();
  }

  void updateMotionPreference() {
    final reduced = reduceMotion || systemReduceMotion;
    _game.reducedMotion = reduced;
    _game.remote.reducedMotion = reduced;
  }

  Future<void> load() async {
    final decoded = jsonDecode(
      await rootBundle.loadString('assets/map.v1.json'),
    ) as Map<String, dynamic>;
    if (!mounted) return;
    setState(() {
      map = decoded;
      _game.map = decoded;
      _game.labels = {
        for (final r in widget.seed['rooms'] as List)
          r['id'] as String: r['name'] as String,
      };
    });
  }

  void onStep(List<int> point) {
    current = point;
    final rooms = (map?['rooms'] as List? ?? []).cast<Map<String, dynamic>>();
    String room = 'lobby';
    for (final r in rooms) {
      final b = (r['bounds'] as List).cast<int>();
      if (point[0] >= b[0] &&
          point[0] <= b[2] &&
          point[1] >= b[1] &&
          point[1] <= b[3]) {
        room = r['id'] as String;
        break;
      }
    }
    widget.onPosition(List.of(point), room);
  }

  void moveTo(List<int> destination) {
    try {
      final route = widget.findPath(current, destination);
      if (route == null) {
        widget.onError('That destination is blocked or requires membership.');
        return;
      }
      _game.route = route.skip(1).toList();
      focus.requestFocus();
    } catch (_) {
      widget.onError('The Rust map service is unavailable.');
    }
  }

  void policyChanged({required bool reset}) {
    _game.route = [];
    if (reset) {
      _game.reset();
      current = [2, 2];
      widget.onPosition([2, 2], 'lobby');
    }
  }

  void goToRoom(String room) {
    if (map == null) return;
    final r = (map!['rooms'] as List).cast<Map<String, dynamic>>().firstWhere(
      (r) => r['id'] == room,
    );
    moveTo((r['spawn'] as List).cast<int>());
  }

  @override
  void didUpdateWidget(covariant OfficeWorld oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remote != widget.remote) {
      oldWidget.remote.removeListener(updateRemote);
      widget.remote.addListener(updateRemote);
      updateRemote();
    }
    if (oldWidget.actor != widget.actor) {
      _game.reset();
      current = [2, 2];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPosition([2, 2], 'lobby');
      });
    }
  }

  @override
  void dispose() {
    widget.remote.removeListener(updateRemote);
    focus.dispose();
    super.dispose();
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final p = current;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      moveTo([p[0], p[1] - 1]);
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.keyS) {
      moveTo([p[0], p[1] + 1]);
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.keyA) {
      moveTo([p[0] - 1, p[1]]);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.keyD) {
      moveTo([p[0] + 1, p[1]]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: Stack(
      children: [
        GestureDetector(
          onTapUp: (d) => moveTo(_game.cellAt(d.localPosition)),
          onScaleStart: (d) {
            gestureZoom = _game.zoom;
            lastFocal = d.localFocalPoint;
          },
          onScaleUpdate: (d) {
            final previous = lastFocal ?? d.localFocalPoint;
            _game.zoomAt(gestureZoom * d.scale, previous);
            _game.pan += d.localFocalPoint - previous;
            lastFocal = d.localFocalPoint;
          },
          onScaleEnd: (_) => lastFocal = null,
          child: GameWidget(game: _game),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                tooltip: systemReduceMotion
                    ? 'Motion reduced by system'
                    : (reduceMotion ? 'Enable motion' : 'Reduce motion'),
                onPressed: systemReduceMotion
                    ? null
                    : () {
                        setState(() => reduceMotion = !reduceMotion);
                        updateMotionPreference();
                      },
                icon: Icon(
                  reduceMotion || systemReduceMotion
                      ? Icons.motion_photos_on
                      : Icons.motion_photos_off,
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Zoom out',
                onPressed: () => _game.zoomAt(_game.zoom / 1.25, _game.center),
                icon: const Icon(Icons.remove),
              ),
              IconButton.filledTonal(
                tooltip: 'Reset view',
                onPressed: _game.resetView,
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton.filledTonal(
                tooltip: 'Zoom in',
                onPressed: () => _game.zoomAt(_game.zoom * 1.25, _game.center),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _WorldGame extends FlameGame {
  _WorldGame({required this.onStep});
  final void Function(List<int>) onStep;
  Map<String, dynamic>? map;
  Map<String, String> labels = {};
  final RemoteMotion remote = RemoteMotion();
  bool reducedMotion = false;
  List<List<int>> route = [];
  List<int> position = [2, 2];
  double elapsed = 0;
  void reset() {
    route = [];
    position = [2, 2];
    elapsed = 0;
  }

  @override
  Color backgroundColor() => const Color(0xffe6e8dd);
  double zoom = 1;
  Offset pan = Offset.zero;
  double get baseScale => math.min(size.x / 850, size.y / 500).clamp(.3, 1.5);
  double get scale => baseScale * zoom;
  Offset project(double x, double y) => Offset((x - y) * 22, (x + y) * 11);
  Offset get center => Offset(size.x / 2, size.y / 2);
  Offset get origin => Offset(size.x / 2, size.y / 2 - 187 * baseScale) + pan;
  void zoomAt(double value, Offset focal) {
    final point = (focal - origin) / scale;
    zoom = value.clamp(.5, 2.5);
    pan += focal - (origin + point * scale);
  }

  void resetView() {
    zoom = 1;
    pan = Offset.zero;
  }

  void drawFurnishing(Canvas canvas, Offset p, String kind) {
    canvas.drawOval(
      Rect.fromCenter(center: p + const Offset(0, 4), width: 26, height: 8),
      Paint()..color = const Color(0x22000000),
    );
    if (kind == 'plant') {
      final pot = Path()
        ..moveTo(p.dx - 6, p.dy - 6)
        ..lineTo(p.dx + 6, p.dy - 6)
        ..lineTo(p.dx + 4, p.dy + 2)
        ..lineTo(p.dx - 4, p.dy + 2)
        ..close();
      canvas.drawPath(pot, Paint()..color = const Color(0xffb67c64));
      canvas.drawLine(
        p + const Offset(0, -7),
        p + const Offset(0, -19),
        Paint()
          ..color = const Color(0xff547963)
          ..strokeWidth = 2,
      );
      canvas.drawOval(
        Rect.fromCenter(center: p + const Offset(-4, -17), width: 9, height: 6),
        Paint()..color = const Color(0xff6c9678),
      );
      canvas.drawOval(
        Rect.fromCenter(center: p + const Offset(4, -21), width: 9, height: 6),
        Paint()..color = const Color(0xff84a889),
      );
      canvas.drawOval(
        Rect.fromCenter(center: p + const Offset(-1, -25), width: 7, height: 9),
        Paint()..color = const Color(0xff739e7d),
      );
    } else if (kind == 'sofa') {
      final seat = Path()
        ..moveTo(p.dx - 13, p.dy - 7)
        ..lineTo(p.dx, p.dy - 13)
        ..lineTo(p.dx + 13, p.dy - 7)
        ..lineTo(p.dx, p.dy - 1)
        ..close();
      final front = Path()
        ..moveTo(p.dx - 13, p.dy - 7)
        ..lineTo(p.dx, p.dy - 1)
        ..lineTo(p.dx + 13, p.dy - 7)
        ..lineTo(p.dx + 13, p.dy)
        ..lineTo(p.dx, p.dy + 6)
        ..lineTo(p.dx - 13, p.dy)
        ..close();
      canvas.drawPath(front, Paint()..color = const Color(0xffa7786c));
      canvas.drawPath(seat, Paint()..color = const Color(0xffd9a798));
      canvas.drawLine(
        p + const Offset(-12, -10),
        p + const Offset(0, -16),
        Paint()
          ..color = const Color(0xffbd8e80)
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    } else if (kind == 'table') {
      canvas.drawLine(
        p + const Offset(0, -3),
        p + const Offset(0, 3),
        Paint()
          ..color = const Color(0xff94755d)
          ..strokeWidth = 3,
      );
      canvas.drawOval(
        Rect.fromCenter(center: p + const Offset(0, -7), width: 25, height: 12),
        Paint()..color = const Color(0xffc69f7f),
      );
      canvas.drawOval(
        Rect.fromCenter(center: p + const Offset(0, -9), width: 25, height: 12),
        Paint()..color = const Color(0xffe2c6a6),
      );
      canvas.drawCircle(
        p + const Offset(3, -10),
        2,
        Paint()..color = const Color(0xff9ab3a6),
      );
    }
  }

  List<int> cellAt(Offset point) {
    final o = (point - origin) / scale;
    final x = (o.dx / 22 + o.dy / 11) / 2;
    final y = (o.dy / 11 - o.dx / 22) / 2;
    return [x.round(), y.round()];
  }

  @override
  void update(double dt) {
    super.update(dt);
    remote.advance(dt);
    if (route.isEmpty) return;
    if (reducedMotion) {
      position = route.last;
      route.clear();
      elapsed = 0;
      onStep(position);
      return;
    }
    elapsed += dt;
    if (elapsed >= .13) {
      elapsed = 0;
      position = route.removeAt(0);
      onStep(position);
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final m = map;
    if (m == null) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    final rooms = (m['rooms'] as List).cast<Map<String, dynamic>>();
    final props = (m['props'] as List? ?? []).cast<Map<String, dynamic>>();
    for (int sum = 0; sum < 35; sum++) {
      for (int x = 0; x < 18; x++) {
        final y = sum - x;
        if (y < 0 || y >= 18) continue;
        final p = project(x.toDouble(), y.toDouble());
        Map<String, dynamic>? room;
        for (final r in rooms) {
          final b = (r['bounds'] as List).cast<int>();
          if (x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3]) {
            room = r;
            break;
          }
        }
        bool wall = false;
        if (room != null) {
          final b = (room['bounds'] as List).cast<int>();
          final d = (room['door'] as List).cast<int>();
          wall =
              (x == b[0] || x == b[2] || y == b[1] || y == b[3]) &&
              !(x == d[0] && y == d[1]);
        }
        final tile = Path()
          ..moveTo(p.dx, p.dy - 10)
          ..lineTo(p.dx + 21, p.dy)
          ..lineTo(p.dx, p.dy + 10)
          ..lineTo(p.dx - 21, p.dy)
          ..close();
        canvas.drawPath(
          tile,
          Paint()
            ..color = wall
                ? const Color(0xff94aa99)
                : room == null
                ? const Color(0xffd6dcd1)
                : const Color(0xfff5e9d9),
        );
        canvas.drawPath(
          tile,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .5
            ..color = const Color(0xffd4d6c9),
        );
        if (wall) {
          final top = tile.shift(const Offset(0, -8));
          canvas.drawPath(
            tile.shift(const Offset(0, -3)),
            Paint()..color = const Color(0xff89a38f),
          );
          canvas.drawPath(top, Paint()..color = const Color(0xffb7c9b6));
        }
        for (final prop in props) {
          final anchor = (prop['position'] as List).cast<int>();
          if (anchor[0] != x || anchor[1] != y) {
            continue;
          }
          if (const {'plant', 'sofa', 'table'}.contains(prop['type'])) {
            drawFurnishing(canvas, p, prop['type'] as String);
            continue;
          }
          if (prop['type'] != 'desk') continue;
          canvas.drawOval(
            Rect.fromCenter(
              center: p + const Offset(0, 3),
              width: 25,
              height: 8,
            ),
            Paint()..color = const Color(0x22000000),
          );
          final face = Path()
            ..moveTo(p.dx - 12, p.dy - 5)
            ..lineTo(p.dx, p.dy + 1)
            ..lineTo(p.dx + 12, p.dy - 5)
            ..lineTo(p.dx + 12, p.dy + 1)
            ..lineTo(p.dx, p.dy + 7)
            ..lineTo(p.dx - 12, p.dy + 1)
            ..close();
          final top = Path()
            ..moveTo(p.dx, p.dy - 11)
            ..lineTo(p.dx + 12, p.dy - 5)
            ..lineTo(p.dx, p.dy + 1)
            ..lineTo(p.dx - 12, p.dy - 5)
            ..close();
          canvas.drawPath(face, Paint()..color = const Color(0xffa77c5c));
          canvas.drawPath(top, Paint()..color = const Color(0xffdcb894));
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: p + const Offset(0, -10),
                width: 8,
                height: 7,
              ),
              const Radius.circular(1),
            ),
            Paint()..color = const Color(0xff536e67),
          );
        }
        for (final other in remote.avatars) {
          final coordinate = other.position;
          if (coordinate.dx.round() == x && coordinate.dy.round() == y) {
            final avatarPoint = project(coordinate.dx, coordinate.dy);
            canvas.drawCircle(
              avatarPoint + const Offset(0, -13),
              8,
              Paint()..color = const Color(0xffb88166),
            );
            canvas.drawCircle(
              avatarPoint + const Offset(0, -22),
              6,
              Paint()..color = const Color(0xffedbf9d),
            );
            final label = TextPainter(
              text: TextSpan(
                text: other.actor,
                style: TextStyle(
                  color: const Color(0xff30483f),
                  fontSize: math.max(10, 10 / scale),
                  fontWeight: FontWeight.bold,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: math.max(80, 80 / scale));
            label.paint(
              canvas,
              Offset(
                avatarPoint.dx - label.width / 2,
                avatarPoint.dy - 28 - label.height,
              ),
            );
          }
        }
        if (position[0] == x && position[1] == y) {
          canvas.drawOval(
            Rect.fromCenter(
              center: p + const Offset(0, 4),
              width: 22,
              height: 8,
            ),
            Paint()..color = const Color(0x33000000),
          );
          canvas.drawCircle(
            p + const Offset(0, -13),
            8,
            Paint()..color = const Color(0xff4c7468),
          );
          canvas.drawCircle(
            p + const Offset(0, -22),
            6,
            Paint()..color = const Color(0xffedbf9d),
          );
        }
      }
    }
    for (final room in rooms) {
      final spawn = (room['spawn'] as List).cast<int>();
      final p = project(spawn[0].toDouble(), spawn[1].toDouble());
      final t = TextPainter(
        text: TextSpan(
          text: labels[room['id']] ?? room['id'],
          style: TextStyle(
            color: const Color(0xff30483f),
            fontSize: math.max(10, 10 / scale),
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(100, 100 / scale));
      t.paint(canvas, Offset(p.dx - t.width / 2, p.dy - 28 - t.height));
    }
    canvas.restore();
  }
}
