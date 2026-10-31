import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';

import 'chat_test_host.dart';
import 'fake_chat_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!File('/System/Library/Fonts/SFNS.ttf').existsSync()) return;
    final mono = FontLoader('monospace')
      ..addFont(
        File('/System/Library/Fonts/Menlo.ttc')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    final emoji = FontLoader('ChatEmoji')
      ..addFont(
        File('/System/Library/Fonts/Apple Color Emoji.ttc')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await mono.load();
    await emoji.load();
    final text = FontLoader('ChatVerification')
      ..addFont(
        File('/System/Library/Fonts/SFNS.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['HOME']}/fvm/versions/3.47.7/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await text.load();
    await icons.load();
  });
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1366, 768),
    const Size(1920, 1080),
  ]) {
    testWidgets('chat panes fit ${size.width}x${size.height}', (tester) async {
      final client = FakeChatClient()
        ..events['lobby'] = [
          message(
            'hello',
            body: 'Hello team. **Today’s plan** is ready.\n\n```dart\nfinal ready = true;\n```',
            reactions: {'👍': 2},
            readers: ['An'],
          ),
          message('deleted', deleted: true),
          message(
            'edited',
            body: 'Updated plan',
            edited: true,
            own: true,
            canDelete: true,
          ),
        ];
      final controller = await showChat(
        tester,
        client,
        size: size,
        fontFamily: 'ChatVerification',
      );
      await controller.select('lobby');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
      await screenshot(tester, 'main-${size.width.toInt()}');
      controller.side(SidePane.details);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'details-${size.width.toInt()}');
      controller.side(SidePane.members);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await controller.openThread(message('hello'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'thread-${size.width.toInt()}');
      if (size.width < 850) {
        await tester.tap(find.byTooltip('Conversations'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(tester, 'sidebar-${size.width.toInt()}');
      }
    });
  }
}

Future<void> screenshot(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/chat-layout');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
