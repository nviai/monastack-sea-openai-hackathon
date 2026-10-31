import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:path_provider/path_provider.dart';

/// Frame timing and memory for the office, idle and while the local avatar
/// walks across the map with the camera following. Debug build, one run.
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
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    for (var i = 0; i < 40 && world.map == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<String> measure(String label, Future<void> Function() during) async {
      final timings = <ui.FrameTiming>[];
      void collect(List<ui.FrameTiming> frames) => timings.addAll(frames);
      WidgetsBinding.instance.addTimingsCallback(collect);
      final stopwatch = Stopwatch()..start();
      await during();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(seconds: 5)),
      );
      stopwatch.stop();
      await tester.pump();
      WidgetsBinding.instance.removeTimingsCallback(collect);
      final build = timings.map((f) => f.buildDuration.inMicroseconds).toList()
        ..sort();
      final raster =
          timings.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
      int p95(List<int> samples) =>
          samples.isEmpty ? 0 : samples[((samples.length - 1) * 0.95).ceil()];
      final fps = timings.length * 1000 / stopwatch.elapsedMilliseconds;
      return '$label frames=${timings.length} elapsed_ms=${stopwatch.elapsedMilliseconds} '
          'fps=${fps.toStringAsFixed(1)} build_p95_us=${p95(build)} raster_p95_us=${p95(raster)} '
          'rss_bytes=${ProcessInfo.currentRss}';
    }

    final idle = await measure('idle', () async {});
    // Zoomed in, walking from the lobby to the far corner of Dev & QA.
    await tester.tap(find.byTooltip('Center on me'));
    final walking = await measure('walking', () async {
      await tester.runAsync(() => world.moveTo([6, 2]));
    });
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
    debugPrint('MEASUREMENT $idle mode=debug harness=fully-live');
    debugPrint('MEASUREMENT $walking mode=debug harness=fully-live');
    debugPrint('MEASUREMENT screenshot=$image');
  });
}
