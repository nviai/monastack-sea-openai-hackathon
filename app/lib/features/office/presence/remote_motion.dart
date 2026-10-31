import 'package:flutter/material.dart';

/// Visual interpolation of trusted presence snapshots, keyed by session.
/// Only one-cell moves within the same room are interpolated. Other changes
/// snap, so the client never guesses a path across walls or room boundaries.
class RemoteMotion {
  final Map<String, RemoteAvatar> _avatars = {};
  bool _reducedMotion = false;
  static const duration = .25;

  Iterable<RemoteAvatar> get avatars => _avatars.values;

  set reducedMotion(bool value) {
    _reducedMotion = value;
    if (value) {
      for (final avatar in _avatars.values) {
        avatar._snap();
      }
    }
  }

  void updateSnapshot(List<Map<String, dynamic>> snapshot) {
    final seen = <String>{};
    for (final item in snapshot) {
      final session = item['session'],
          actor = item['actor'],
          room = item['room'];
      final x = item['x'], y = item['y'], seq = item['seq'];
      if (session is! String ||
          actor is! String ||
          room is! String ||
          x is! num ||
          y is! num ||
          !x.isFinite ||
          !y.isFinite ||
          seq is! int) {
        continue;
      }
      seen.add(session);
      final point = Offset(x.toDouble(), y.toDouble());
      final old = _avatars[session];
      if (old == null || old.actor != actor) {
        _avatars[session] = RemoteAvatar(session, actor, room, seq, point);
      } else if (seq > old.sequence) {
        final previous = old.target;
        final adjacent =
            (previous.dx - point.dx).abs() + (previous.dy - point.dy).abs() ==
            1;
        final unchanged = previous == point && old.room == room;
        final canAnimate =
            !_reducedMotion &&
            old.room == room &&
            adjacent &&
            old.progress >= 1;
        old.sequence = seq;
        old.room = room;
        if (!unchanged) {
          old.start = canAnimate ? old.position : point;
          old.target = point;
          old.progress = canAnimate ? 0 : 1;
        }
      }
    }
    _avatars.removeWhere((session, _) => !seen.contains(session));
  }

  void advance(double dt) {
    if (dt <= 0 || !dt.isFinite) return;
    for (final avatar in _avatars.values) {
      avatar.progress = (avatar.progress + dt / duration).clamp(0, 1);
    }
  }
}

class RemoteAvatar {
  RemoteAvatar(this.session, this.actor, this.room, this.sequence, Offset point)
    : start = point,
      target = point;
  final String session;
  final String actor;
  String room;
  int sequence;
  Offset start;
  Offset target;
  double progress = 1;
  Offset get position => Offset.lerp(start, target, progress)!;
  void _snap() {
    start = target;
    progress = 1;
  }
}
