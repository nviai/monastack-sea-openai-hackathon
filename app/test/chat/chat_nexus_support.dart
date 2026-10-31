import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';

import 'chat_test_host.dart';
import 'fake_chat_client.dart';

const chatSizes = [
  Size(320, 568),
  Size(390, 844),
  Size(768, 1024),
  Size(1366, 768),
  Size(1920, 1080),
];

String sizeName(Size s) => '${s.width.toInt()}x${s.height.toInt()}';

/// Loads the bundled Inter plus system fonts the chat dialog names, so tests
/// measure the real glyphs. Skips quietly where the system fonts are absent.
Future<void> loadNexusFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final inter = FontLoader('Inter')
    ..addFont(bytes('assets/fonts/inter-4.1/InterVariable.ttf'));
  await inter.load();
  final home = Platform.environment['HOME'];
  final loaders = <String, String>{
    'Menlo': '/System/Library/Fonts/Menlo.ttc',
    'Apple Color Emoji': '/System/Library/Fonts/Apple Color Emoji.ttc',
    'MaterialIcons':
        '$home/fvm/versions/3.47.7/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  };
  for (final entry in loaders.entries) {
    if (!File(entry.value).existsSync()) continue;
    final loader = FontLoader(entry.key)..addFont(bytes(entry.value));
    await loader.load();
  }
}

/// A conversation that exercises every message state in one screen.
FakeChatClient nexusClient() {
  final base = DateTime.now().subtract(const Duration(minutes: 30));
  ChatMessage at(ChatMessage m, int minutes, {String? sender}) => ChatMessage(
    id: m.id,
    roomId: m.roomId,
    sender: sender ?? m.sender,
    body: m.body,
    time: base.add(Duration(minutes: minutes)),
    own: m.own,
    canDelete: m.canDelete,
    deleted: m.deleted,
    edited: m.edited,
    thread: m.thread,
    attachment: m.attachment,
    reactions: m.reactions,
    readers: m.readers,
    replyTo: m.replyTo,
  );
  return FakeChatClient()
    ..events['lobby'] = [
      at(
        message(
          'last',
          body: 'Looks good, shipping after lunch',
          own: true,
          canDelete: true,
          readers: ['An', 'Linh', 'Triet', 'Hung'],
        ),
        20,
      ),
      at(
        message(
          'file',
          body: 'deploy-log-2026-10-31.txt',
          attachment: 'mxc://x',
        ),
        12,
        sender: 'Linh',
      ),
      at(
        message(
          'r2',
          body: 'Checked on HR, history hides right away.',
          thread: 'hello',
        ),
        11,
        sender: 'Linh',
      ),
      at(
        message('r1', body: 'Revoke kicks in about 0.4 s.', thread: 'hello'),
        10,
        sender: 'Triet',
      ),
      at(
        message(
          'edited',
          body: 'Updated plan. @An please review',
          edited: true,
        ),
        9,
        sender: 'Triet',
      ),
      at(message('gone', deleted: true), 6),
      at(message('follow', body: 'And a second line from the same person'), 5),
      at(
        message(
          'hello',
          body: 'Hello team. **Today’s plan** is ready.\n\n```dart\nfinal ready = true;\n```',
          reactions: {'👍': 2, '🎉': 1},
        ),
        4,
      ),
    ]
    ..typers = ['Linh'];
}

Future<ChatController> pumpNexusChat(
  WidgetTester tester,
  Size size,
  Brightness brightness, {
  FakeChatClient? client,
}) async {
  final controller = await showChat(
    tester,
    client ?? nexusClient(),
    size: size,
    brightness: brightness,
  );
  await controller.select('lobby');
  await tester.pumpAndSettle();
  return controller;
}

Future<void> screenshot(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/chat-layout-nexus');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
