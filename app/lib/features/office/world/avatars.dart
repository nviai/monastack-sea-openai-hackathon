import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'package:monastack/features/office/world/iso.dart';

/// Deterministic, original avatar palette derived from the actor ID.
class AvatarStyle {
  const AvatarStyle(this.shirt, this.skin, this.hair);
  final Color shirt;
  final Color skin;
  final Color hair;

  static const _shirts = [
    Color(0xff5f8fb0),
    Color(0xffd58f7c),
    Color(0xff79a88a),
    Color(0xffb48fbf),
    Color(0xffe0b062),
    Color(0xff6f9f9a),
    Color(0xffc77d93),
    Color(0xff8c9cc9),
  ];
  static const _skins = [
    Color(0xfff1c9a5),
    Color(0xffe3b38f),
    Color(0xffcf9b76),
    Color(0xfff5d6bd),
  ];
  static const _hair = [
    Color(0xff2f2a28),
    Color(0xff5a3f30),
    Color(0xff3b3b45),
    Color(0xff7a5a3c),
  ];

  factory AvatarStyle.of(String actor) {
    var h = 0;
    for (final unit in actor.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return AvatarStyle(
      _shirts[h % _shirts.length],
      _skins[(h ~/ 8) % _skins.length],
      _hair[(h ~/ 32) % _hair.length],
    );
  }
}

/// Height above the floor at which a name label is anchored.
const avatarLabelHeight = 52.0;

/// Height of the top of the torso: a camera face sits on it.
const avatarShoulderHeight = 30.0;

/// Height of the drawn head's centre.
const avatarHeadHeight = 38.0;

/// Screen-space bounds (in projected world units) of an avatar at a cell.
Rect avatarBounds(Iso iso, double x, double y) {
  final feet = iso.project(x, y);
  return Rect.fromLTRB(feet.dx - 11, feet.dy - 48, feet.dx + 11, feet.dy + 6);
}

/// Paints a low-poly figure standing on world point `(x, y)`.
/// Offline agents are drawn translucent and grey with an antenna so they
/// are never mistaken for an online person. With `face: false` the head is
/// left out because a live camera bubble is drawn in its place.
void paintAvatar(
  Canvas canvas,
  Iso iso,
  double x,
  double y,
  AvatarStyle style, {
  bool self = false,
  bool offlineAgent = false,
  double bob = 0,
  Color ring = const Color(0xff2f7a5f),
  bool face = true,
}) {
  final feet = iso.project(x, y);
  final opacity = offlineAgent ? .55 : 1.0;
  Color tone(Color c) => c.withValues(alpha: c.a * opacity);
  if (self) {
    canvas.drawOval(
      Rect.fromCenter(center: feet, width: 34, height: 17),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = ring.withValues(alpha: .85),
    );
  }
  canvas.drawOval(
    Rect.fromCenter(center: feet + const Offset(0, 1), width: 22, height: 10),
    Paint()..color = Color.fromRGBO(30, 40, 35, .22 * opacity),
  );
  final lift = -bob;
  final shirt = offlineAgent ? const Color(0xffa9b4bb) : style.shirt;
  final legs = Paint()..color = tone(const Color(0xff47515a));
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(feet.dx - 6, feet.dy - 11 + lift, 5, 11),
      const Radius.circular(2),
    ),
    legs,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(feet.dx + 1, feet.dy - 11 + lift, 5, 11),
      const Radius.circular(2),
    ),
    legs,
  );
  final torso = RRect.fromRectAndRadius(
    Rect.fromLTWH(feet.dx - 9, feet.dy - 30 + lift, 18, 21),
    const Radius.circular(8),
  );
  canvas.drawRRect(torso, Paint()..color = tone(shirt));
  // Right-hand shading gives the figure a lit and a shadow side.
  canvas.save();
  canvas.clipRRect(torso);
  canvas.drawRect(
    Rect.fromLTWH(feet.dx + 2, feet.dy - 30 + lift, 8, 21),
    Paint()..color = tone(shade(shirt, -.08)),
  );
  canvas.restore();
  if (!face && !offlineAgent) return;
  final head = feet + Offset(0, -avatarHeadHeight + lift);
  if (offlineAgent) {
    final face = RRect.fromRectAndRadius(
      Rect.fromCenter(center: head, width: 16, height: 14),
      const Radius.circular(4),
    );
    canvas.drawRRect(face, Paint()..color = tone(const Color(0xffd7dee2)));
    canvas.drawLine(
      head + const Offset(0, -7),
      head + const Offset(0, -12),
      Paint()
        ..color = tone(const Color(0xff7d8a92))
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      head + const Offset(0, -13),
      2.2,
      Paint()..color = tone(const Color(0xff9aa6ad)),
    );
    final eye = Paint()..color = tone(const Color(0xff5c6870));
    canvas.drawCircle(head + const Offset(-3, 0), 1.4, eye);
    canvas.drawCircle(head + const Offset(3, 0), 1.4, eye);
    return;
  }
  canvas.drawCircle(head, 7.5, Paint()..color = style.skin);
  canvas.drawArc(
    Rect.fromCircle(center: head + const Offset(0, -1), radius: 7.8),
    math.pi,
    math.pi,
    true,
    Paint()..color = style.hair,
  );
  canvas.drawCircle(
    head + const Offset(-2.5, -3),
    1.6,
    Paint()..color = const Color(0x55ffffff),
  );
}

/// Constant-size label pill drawn in screen space above an avatar.
void paintLabel(
  Canvas canvas,
  Offset anchor,
  String text, {
  Color? dot,
  bool muted = false,
  bool emphasis = false,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: muted ? const Color(0xff66736d) : const Color(0xff22352e),
        fontSize: 11,
        fontWeight: emphasis ? FontWeight.w800 : FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 160);
  final dotSpace = dot == null ? 0.0 : 10.0;
  final width = painter.width + 14 + dotSpace;
  final rect = RRect.fromRectAndRadius(
    Rect.fromCenter(
      center: anchor + const Offset(0, -10),
      width: width,
      height: painter.height + 6,
    ),
    const Radius.circular(10),
  );
  canvas.drawRRect(
    rect.shift(const Offset(0, 1)),
    Paint()..color = const Color(0x22000000),
  );
  canvas.drawRRect(
    rect,
    Paint()..color = muted ? const Color(0xd9eef0ec) : const Color(0xf2ffffff),
  );
  if (dot != null) {
    canvas.drawCircle(
      Offset(rect.left + 9, rect.center.dy),
      3.2,
      Paint()..color = dot,
    );
  }
  painter.paint(canvas, Offset(rect.left + 7 + dotSpace, rect.top + 3));
  painter.dispose();
}
