import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/world/avatars.dart';

void main() {
  test('nearby agent labels stay separate and inside the viewport', () {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final occupied = <Rect>[];
    const viewport = Rect.fromLTWH(0, 0, 500, 400);
    for (final anchor in [
      const Offset(250, 180),
      const Offset(250, 182),
      const Offset(20, 5),
      const Offset(20, 5),
    ]) {
      paintLabel(
        canvas,
        anchor,
        'Atlas · Software Engineer',
        occupied: occupied,
        viewport: viewport,
      );
    }
    for (var i = 0; i < occupied.length; i++) {
      expect(viewport.contains(occupied[i].topLeft), true);
      expect(viewport.contains(occupied[i].bottomRight), true);
      for (var j = 0; j < i; j++) {
        expect(occupied[i].overlaps(occupied[j]), false);
      }
    }
    recorder.endRecording().dispose();
  });
}
