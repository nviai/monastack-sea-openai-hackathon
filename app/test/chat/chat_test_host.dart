import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/presentation/chat_dialog.dart';

import 'fake_chat_client.dart';

Future<ChatController> showChat(
  WidgetTester tester,
  FakeChatClient client, {
  Size size = const Size(1440, 1000),
  String? fontFamily,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
