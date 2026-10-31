import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('capture the app and measure debug frame timings', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(key: boundary, child: const Monastack()),
      ),
    );
    for (var i = 0; i < 40 && find.text('Connect').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Connect'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    final timings = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> frames) => timings.addAll(frames);
    WidgetsBinding.instance.addTimingsCallback(collect);
    final stopwatch = Stopwatch()..start();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(seconds: 5)),
    );
    stopwatch.stop();
    await tester.pump();
    WidgetsBinding.instance.removeTimingsCallback(collect);
    final image = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final captured = await render.toImage(pixelRatio: 1);
      final bytes = await captured.toByteData(format: ui.ImageByteFormat.png);
      captured.dispose();
      final root = await getTemporaryDirectory();
      final directory = await root.createTemp('office-measurement-');
      final file = File('${directory.path}/monastack-office-capture.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      return file.path;
    });
    expect(image, isNotNull);
    final build = timings.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final raster = timings.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    int p95(List<int> samples) =>
        samples.isEmpty ? 0 : samples[((samples.length - 1) * 0.95).ceil()];
    debugPrint(
      'MEASUREMENT screenshot=$image frames=${timings.length} elapsed_ms=${stopwatch.elapsedMilliseconds} build_p95_us=${p95(build)} raster_p95_us=${p95(raster)} rss_bytes=${ProcessInfo.currentRss} mode=debug harness=fully-live',
    );
  });
}
