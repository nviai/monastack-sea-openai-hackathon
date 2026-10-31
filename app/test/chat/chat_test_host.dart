import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/presentation/chat_dialog.dart';
import 'package:monastack/features/chat/presentation/chat_message_tile.dart';

import 'fake_chat_client.dart';

Future<ChatController> showChat(
  WidgetTester tester,
  FakeChatClient client, {
  Size size = const Size(1440, 1000),
  String? fontFamily,
  Brightness? brightness,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (brightness != null) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }
  final controller = ChatController(client);
  addTearDown(controller.dispose);
  addTearDown(client.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatClientProvider.overrideWithValue(client),
        chatControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamily == null ? null : ['ChatEmoji'],
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff69766b),
            surface: const Color(0xfff7f5ef),
          ),
        ),
        home: Scaffold(body: ChatDialog(currentRoom: () => 'engineering')),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

/// Hovers the first message so its toolbar shows, then opens "Message actions".
Future<void> openMessageActions(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.byType(ChatMessageTile).first));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Message actions'));
  await mouse.removePointer();
}
