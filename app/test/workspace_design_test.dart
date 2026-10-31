import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/identity/sign_in_shell.dart';
import 'package:monastack/features/office/communication/workspace_tools.dart';
import 'package:monastack/shared/workspace_theme.dart';

import 'chat/chat_nexus_support.dart' show loadNexusFonts;

void main() {
  setUpAll(loadNexusFonts);
  for (final size in [const Size(360, 740), const Size(1440, 900)]) {
    for (final screen in ['login', 'workspace']) {
      testWidgets('$screen fits ${size.width} with workspace theme', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: workspaceTheme(),
              home: Scaffold(
                body: screen == 'login'
                    ? SignInShell(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const TextField(
                              decoration: InputDecoration(
                                labelText: 'Username',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const TextField(
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: Icon(Icons.lock_outline),
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () {},
                              child: const Text('Sign in'),
                            ),
                          ],
                        ),
                      )
                    : const WorkspaceTools(
                        account: true,
                        admin: true,
                        chatUnread: 3,
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (Platform.environment['MONASTACK_CAPTURE_PREVIEW'] == '1' &&
            size.width > 1000) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('../runtime/previews/$screen-refresh.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
