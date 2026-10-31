import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'package:monastack/features/office/presence/remote_motion.dart';
import 'package:monastack/features/office/world/avatars.dart';
import 'package:monastack/features/office/world/iso.dart';
import 'package:monastack/features/office/world/office_map.dart';
import 'package:monastack/features/office/world/office_scene.dart';

/// A figure drawn this frame, kept for hit testing.
class _Figure {
  _Figure(this.actor, this.x, this.y, this.kind);
  final String actor;
  final double x, y;
  final _Kind kind;
  double get depth => x + y + .1;
}

enum _Kind { self, remote, agent }

/// Renders the cached office scene, avatars with occlusion and a
/// constant-size overlay. State changes here never rebuild Flutter widgets.
class WorldGame extends FlameGame {
  WorldGame({required this.onStep});

  final void Function(List<int>) onStep;
  OfficeScene? scene;
  final RemoteMotion remote = RemoteMotion();

  /// Display names by actor ID, room names by room ID.
  Map<String, String> names = const {};
  Map<String, String> roomNames = const {};
  Set<String> restrictedRooms = const {};

  /// Rooms the viewer may enter, or `null` when unknown.
  Set<String>? accessibleRooms;
  String self = '';
  List<({String actor, CellPos seat})> agentSeats = const [];

  /// Actors currently speaking in voice.
  Set<String> speaking = const {};
  bool reducedMotion = false;

  List<List<int>> route = [];
  List<int> position = [0, 0];
  List<int>? _from;
  double _step = 0;
  double _clock = 0;
  static const stepSeconds = .16;

  double zoom = 1;
  Offset pan = Offset.zero;
  Offset? hover;
  bool follow = true;
  final List<_Figure> _figures = [];

  @override
  Color backgroundColor() => const Color(0xffe8ebe3);

  void setScene(OfficeScene value) {
    scene?.dispose();
    scene = value;
  }

  void reset(List<int> spawn) {
    route = [];
    position = List.of(spawn);
    _from = null;
    _step = 0;
  }

  bool get moving => _from != null || route.isNotEmpty;

  // ---------------------------------------------------------------- camera --

  Iso get iso => scene?.iso ?? const Iso(64, 32);
  Rect get _bounds => scene?.bounds ?? const Rect.fromLTWH(-400, 0, 800, 500);
  double get baseScale => math
      .min(size.x / _bounds.width, size.y / _bounds.height)
      .clamp(.15, 2.0)
      .toDouble();
  double get scale => baseScale * zoom;
  Offset get center => Offset(size.x / 2, size.y / 2);
  Offset get origin => center - _bounds.center * scale + pan;

  Offset toScreen(Offset world) => origin + world * scale;

  void zoomAt(double value, Offset focal) {
    final point = (focal - origin) / scale;
    zoom = value.clamp(.6, 4.0);
    pan += focal - (origin + point * scale);
  }

  void resetView() {
    zoom = 1;
    pan = Offset.zero;
  }

  /// Centres the camera on a cell, optionally zooming in first.
  void focusOn(List<int> cell, {double? zoomTo}) {
    if (zoomTo != null) zoom = zoomTo.clamp(.6, 4.0);
    final target = toScreen(
      iso.project(cell[0].toDouble(), cell[1].toDouble()),
    );
    pan += center - target;
  }

  List<int> cellAt(Offset point) {
    final world = iso.unproject((point - origin) / scale);
    return [world.x.round(), world.y.round()];
  }

  /// Actor whose figure is under the point, preferring the nearest figure.
  String? actorAt(Offset point) {
    for (final figure in _figures.reversed) {
      final bounds = avatarBounds(iso, figure.x, figure.y);
      final rect = Rect.fromPoints(
        toScreen(bounds.topLeft),
        toScreen(bounds.bottomRight),
      ).inflate(3);
      if (rect.contains(point)) return figure.actor;
    }
    return null;
  }

  // ---------------------------------------------------------------- update --

  ({double x, double y}) get selfPoint {
    final from = _from;
    if (from == null) {
      return (x: position[0].toDouble(), y: position[1].toDouble());
    }
    final t = Curves.easeInOut.transform(_step.clamp(0, 1));
    return (
      x: from[0] + (position[0] - from[0]) * t,
      y: from[1] + (position[1] - from[1]) * t,
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    remote.advance(dt);
    if (reducedMotion && (route.isNotEmpty || _from != null)) {
      if (route.isNotEmpty) position = route.last;
      route.clear();
      _from = null;
      onStep(position);
      return;
    }
    if (_from != null) {
      _step += dt / stepSeconds;
      if (_step >= 1) {
        _from = null;
        _step = 0;
        onStep(position);
      }
    }
    if (_from == null && route.isNotEmpty) {
      _from = position;
      position = route.removeAt(0);
      _step = 0;
    }
    if (follow && moving && scene != null) {
      final p = selfPoint;
      final screen = toScreen(iso.project(p.x, p.y, 24));
      final inner = Rect.fromLTWH(
        0,
        0,
        size.x,
        size.y,
      ).deflate(math.min(size.x, size.y) * .18);
      if (!inner.contains(screen)) {
        final target = Offset(
          screen.dx.clamp(inner.left, inner.right),
          screen.dy.clamp(inner.top, inner.bottom),
        );
        pan += (target - screen) * math.min(1, dt * 6);
      }
    }
  }

  // ---------------------------------------------------------------- render --

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final scene = this.scene;
    if (scene == null) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    canvas.drawPicture(scene.picture);
    _veils(canvas, scene);
    _hover(canvas, scene);
    _figuresPass(canvas, scene);
    canvas.restore();
    _overlay(canvas, scene);
  }

  /// Dims rooms the viewer cannot enter. The node enforces access; this is
  /// only a visual cue.
  void _veils(Canvas canvas, OfficeScene scene) {
    final allowed = accessibleRooms;
    if (allowed == null) return;
    final veil = Paint()..color = const Color(0x4a3c4a44);
    for (final room in scene.map.rooms) {
      if (allowed.contains(room.id)) continue;
      canvas.drawPath(
        iso.floor(
          Rect.fromLTRB(room.x0 + .5, room.y0 + .5, room.x1 - .5, room.y1 - .5),
        ),
        veil,
      );
    }
  }

  void _hover(Canvas canvas, OfficeScene scene) {
    final point = hover;
    if (point == null || actorAt(point) != null) return;
    final cell = cellAt(point);
    final x = cell[0], y = cell[1];
    if (x < 0 || y < 0 || x >= scene.map.width || y >= scene.map.height) {
      return;
    }
    final room = scene.map.roomContaining(x, y);
    if (room != null && room.isWall(x, y)) return;
    canvas.drawPath(
      iso.floor(Iso.cells(x, y).deflate(.06)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xaa2f7a5f),
    );
  }

  void _figuresPass(Canvas canvas, OfficeScene scene) {
    _figures
      ..clear()
      ..addAll([
        for (final agent in agentSeats)
          _Figure(
            agent.actor,
            agent.seat.x.toDouble(),
            agent.seat.y.toDouble(),
            _Kind.agent,
          ),
        for (final other in remote.avatars)
          _Figure(
            other.actor,
            other.position.dx,
            other.position.dy,
            _Kind.remote,
          ),
        _Figure(self, selfPoint.x, selfPoint.y, _Kind.self),
      ])
      ..sort((a, b) => a.depth.compareTo(b.depth));
    final occluders = scene.occluders;
    for (final figure in _figures) {
      final walking =
          figure.kind == _Kind.self && _from != null && !reducedMotion;
      if (figure.kind != _Kind.agent && speaking.contains(figure.actor)) {
        final feet = iso.project(figure.x, figure.y);
        final pulse = reducedMotion ? 0.0 : (math.sin(_clock * 8) + 1) * 2;
        canvas.drawOval(
          Rect.fromCenter(
            center: feet,
            width: 40 + pulse * 2,
            height: 20 + pulse,
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = const Color(0xcc2f9e6f),
        );
      }
      paintAvatar(
        canvas,
        iso,
        figure.x,
        figure.y,
        AvatarStyle.of(figure.actor),
        self: figure.kind == _Kind.self,
        offlineAgent: figure.kind == _Kind.agent,
        bob: walking ? (math.sin(_clock * 18).abs() * 2.5) : 0,
      );
      final bounds = avatarBounds(iso, figure.x, figure.y);
      for (final occluder in occluders) {
        if (occluder.depth > figure.depth && occluder.bounds.overlaps(bounds)) {
          occluder.paint(canvas);
        }
      }
    }
    // A faint outline keeps the local avatar findable behind tall walls.
    final p = selfPoint;
    final head = iso.project(p.x, p.y, 38);
    canvas.drawCircle(
      head,
      8.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x552f7a5f),
    );
  }

  void _overlay(Canvas canvas, OfficeScene scene) {
    for (final room in scene.map.rooms) {
      final restricted = restrictedRooms.contains(room.id);
      final denied =
          accessibleRooms != null && !accessibleRooms!.contains(room.id);
      final anchor = toScreen(
        iso.project(room.x0 + .5, room.y0 + .5, scene.map.wallHeight + 14),
      );
      _roomSign(
        canvas,
        anchor,
        roomNames[room.id] ?? room.id,
        room.accent,
        restricted: restricted,
        denied: denied,
      );
    }
    for (final figure in _figures) {
      final anchor = toScreen(
        iso.project(figure.x, figure.y, avatarLabelHeight),
      );
      final name = names[figure.actor] ?? figure.actor;
      switch (figure.kind) {
        case _Kind.self:
          paintLabel(
            canvas,
            anchor,
            '$name (you)',
            dot: const Color(0xff2f9e6f),
            emphasis: true,
          );
        case _Kind.remote:
          paintLabel(canvas, anchor, name, dot: const Color(0xff2f9e6f));
        case _Kind.agent:
          // Offline profiles stay unlabelled until hovered to keep rooms
          // readable; a grey status dot marks them as not running.
          final status = toScreen(iso.project(figure.x, figure.y, 47));
          canvas.drawCircle(
            status,
            4,
            Paint()..color = const Color(0xffffffff),
          );
          canvas.drawCircle(
            status,
            2.8,
            Paint()..color = const Color(0xff9aa6ad),
          );
      }
    }
    final point = hover;
    if (point != null) {
      final tip = _tooltip(point, scene);
      if (tip != null) {
        paintLabel(canvas, point + const Offset(0, -14), tip, muted: true);
      }
    }
  }

  String? _tooltip(Offset point, OfficeScene scene) {
    final actor = actorAt(point);
    if (actor != null) {
      final agent = agentSeats.any((a) => a.actor == actor);
      return '${names[actor] ?? actor}${agent ? ' · offline agent profile' : ''} · click for profile';
    }
    final cell = cellAt(point);
    for (final desk in scene.map.desks) {
      if (desk.seat.x == cell[0] && desk.seat.y == cell[1]) {
        final who = desk.assignee;
        return who == null ? 'Open desk' : 'Desk · ${names[who] ?? who}';
      }
    }
    return null;
  }

  void _roomSign(
    Canvas canvas,
    Offset anchor,
    String text,
    Color accent, {
    required bool restricted,
    required bool denied,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.toUpperCase(),
        style: TextStyle(
          color: denied ? const Color(0xff5f6b66) : Colors.white,
          fontSize: 10,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final icon = restricted ? 14.0 : 0.0;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: anchor,
        width: painter.width + 16 + icon,
        height: painter.height + 8,
      ),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      rect.shift(const Offset(0, 1.5)),
      Paint()..color = const Color(0x26000000),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = denied ? const Color(0xffe6e9e4) : shade(accent, -.12),
    );
    if (restricted) {
      final c = Offset(rect.left + 11, rect.center.dy);
      final lock = Paint()
        ..color = denied ? const Color(0xff5f6b66) : Colors.white;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: c + const Offset(0, 1.5),
            width: 8,
            height: 6,
          ),
          const Radius.circular(1.5),
        ),
        lock,
      );
      canvas.drawArc(
        Rect.fromCenter(center: c + const Offset(0, -1.5), width: 6, height: 7),
        math.pi,
        math.pi,
        false,
        lock
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    painter.paint(canvas, Offset(rect.left + 8 + icon, rect.top + 4));
    painter.dispose();
  }

  @override
  void onRemove() {
    scene?.dispose();
    scene = null;
    super.onRemove();
  }
}
