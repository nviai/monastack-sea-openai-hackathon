import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/remote_motion.dart';

Map<String, dynamic> snapshot({
  int seq = 1,
  double x = 2,
  double y = 2,
  String room = 'lobby',
}) => {
  'session': 'synthetic-session',
  'actor': 'synthetic',
  'room': room,
  'x': x,
  'y': y,
  'seq': seq,
};

void main() {
  test(
    'one-cell presence moves interpolate without rewinding on heartbeats',
    () {
      final motion = RemoteMotion()..updateSnapshot([snapshot()]);
      expect(motion.avatars.single.position, const Offset(2, 2));
      motion.updateSnapshot([snapshot(seq: 2, x: 3)]);
      motion.advance(.125);
      expect(motion.avatars.single.position, const Offset(2.5, 2));
      motion.updateSnapshot([snapshot(seq: 3, x: 3)]);
      expect(motion.avatars.single.position, const Offset(2.5, 2));
      motion.updateSnapshot([snapshot(seq: 2, x: 2)]);
      motion.advance(.125);
      expect(motion.avatars.single.position, const Offset(3, 2));
    },
  );

  test('room changes, long moves, removal and reduced motion snap safely', () {
    final motion = RemoteMotion()..updateSnapshot([snapshot()]);
    motion.updateSnapshot([snapshot(seq: 2, x: 8)]);
    expect(motion.avatars.single.position, const Offset(8, 2));
    motion.updateSnapshot([snapshot(seq: 3, x: 9, room: 'dev')]);
    expect(motion.avatars.single.position, const Offset(9, 2));
    motion.updateSnapshot([snapshot(seq: 4, x: 10, room: 'dev')]);
    motion.advance(.1);
    motion.reducedMotion = true;
    expect(motion.avatars.single.position, const Offset(10, 2));
    motion.updateSnapshot([snapshot(seq: 5, x: 11, room: 'dev')]);
    expect(motion.avatars.single.position, const Offset(11, 2));
    motion.updateSnapshot([]);
    expect(motion.avatars, isEmpty);
  });

  test('new movement before interpolation finishes snaps rather than cutting a corner', () {
    final motion = RemoteMotion()..updateSnapshot([snapshot()]);
    motion.updateSnapshot([snapshot(seq: 2, x: 3)]);
    motion.advance(.05);
    motion.updateSnapshot([snapshot(seq: 3, x: 3, y: 3)]);
    expect(motion.avatars.single.position, const Offset(3, 3));
  });
}
