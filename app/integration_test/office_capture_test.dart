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

/// Writes overview and close-up captures for visual review. The images show
/// seeded names; keep them out of version control.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('capture office views', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(key: boundary, child: const Monastack()),
      ),
    );
    for (
      var i = 0;
      i < 40 && find.byType(OfficeWorld).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
    final directory = await tester.runAsync(
      () async => (await getTemporaryDirectory()).createTemp('office-capture-'),
    );
    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('${directory!.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      });
    }

    await capture('overview');
    await tester.tap(find.byTooltip('Center on me'));
    await capture('lobby');
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    tester.widget<ListTile>(find.widgetWithText(ListTile, 'Dev & QA')).onTap!();
    for (var i = 0; i < 300 && world.current.toString() != '[3, 3]'; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byTooltip('Center on me'));
    await capture('dev');
    debugPrint('CAPTURES ${directory!.path}');
  });
}
