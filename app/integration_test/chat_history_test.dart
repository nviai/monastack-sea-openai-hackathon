import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';
import 'package:monastack/office_world.dart';
import 'package:uuid/uuid.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('private history pages and clears after room access is revoked', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String reason, {
      int attempts = 350,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    Future<void> marker(String body) async {
      await tester.runAsync(() async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        try {
          final req = await client
              .postUrl(
                Uri.parse(
                  'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT']}/v1/messages/room%3Alobby',
                ),
              )
              .timeout(const Duration(seconds: 3));
          req.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${Platform.environment['MONASTACK_TEST_TOKEN']}',
          );
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'id': const Uuid().v4(), 'body': body}));
          final response = await req.close().timeout(
            const Duration(seconds: 3),
          );
          expect(response.statusCode, 201);
          await response.drain().timeout(const Duration(seconds: 3));
        } finally {
          client.close(force: true);
        }
      });
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        Platform.environment['MONASTACK_TEST_TOKEN']!;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(
      () => find.text('Chat · Connected').evaluate().isNotEmpty,
      'connected',
    );
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    world.goToRoom('finance');
    await until(() => world.current.toString() == '[2, 14]', 'finance reached');
    // The UI reports position asynchronously; allow its scope refresh to complete.
    await until(
      () => find.textContaining('van: synthetic history').evaluate().isNotEmpty,
      'finance chat loaded',
    );
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Conversation history',
          ),
        )
        .onPressed!();
    await until(
      () => find.text('van: synthetic history 5').evaluate().isNotEmpty,
      'latest page',
    );
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Older'))
        .onPressed!();
    await until(
      () => find.text('van: synthetic history 0').evaluate().isNotEmpty,
      'older page',
    );
    await marker('synthetic history revoke');
    await until(
      () => find
          .text('History unavailable or access denied.')
          .evaluate()
          .isNotEmpty,
      'history cleared after revocation',
    );
    expect(find.text('van: synthetic history 0'), findsNothing);
    await marker('synthetic history verified');
  });
}
