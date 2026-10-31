import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:monastack/features/sync/task_outbox.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:uuid/uuid.dart';
import 'package:monastack/shared/node_request.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final token = Platform.environment['MONASTACK_TEST_AN'];
  testWidgets(
    'node replay after lost responses does not duplicate a queued project',
    (tester) async {
      await tester.runAsync(() async {
        final temporary = await getTemporaryDirectory();
        await temporary.create(recursive: true);
        final dir = await temporary.createTemp('monastack-outbox-integration-');
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        try {
          Future<dynamic> send(
            String method,
            String path, [
            Object? body,
          ]) async {
            final req = await client
                .openUrl(
                  method,
                  Uri.parse(
                    'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT'] ?? '47830'}$path',
                  ),
                )
                .timeout(const Duration(seconds: 5));
            req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
            if (body != null) {
              req.headers.contentType = ContentType.json;
              req.write(jsonEncode(body));
            }
            final res = await req.close().timeout(const Duration(seconds: 5));
            final text = await utf8.decoder
                .bind(res)
                .join()
                .timeout(const Duration(seconds: 5));
            if (res.statusCode >= 400) throw NodeFailure(res.statusCode);
            return text.isEmpty ? null : jsonDecode(text);
          }

          final me = await send('GET', '/v1/me') as Map<String, dynamic>;
          final outbox = TaskOutbox.forPath(
            '${me['authority_id']}_${me['actor']}',
            '${dir.path}/queue.sqlite3',
          );
          const uuid = Uuid();
          final id = uuid.v4();
          final body = {
            'id': id,
            'op': uuid.v4(),
            'name': 'Outbox integration project',
          };
          var lost = 2;
          Future<dynamic> dropping(
            String method,
            String path, [
            Object? data,
          ]) async {
            final result = await send(method, path, data);
            if (lost > 0) {
              lost--;
              throw const SocketException('simulated lost response');
            }
            return result;
          }

          final first = TaskDelivery(
            outbox: outbox,
            network: dropping,
            active: () => true,
            onChanged: (_) {},
          );
          await expectLater(
            first.request('POST', '/v1/projects', body),
            throwsA(isA<TaskChangeQueued>()),
          );
          expect((await outbox.list()).single['state'], 'pending');
          final reopened = TaskDelivery(
            outbox: TaskOutbox.forPath(outbox.actor, outbox.path),
            network: send,
            active: () => true,
            onChanged: (_) {},
          );
          await reopened.drain();
          expect(await reopened.outbox.list(), isEmpty);
          final projects = await send('GET', '/v1/projects') as List<dynamic>;
          expect(projects.where((p) => p['id'] == id).length, 1);
          final conflicting = {
            'id': id,
            'op': uuid.v4(),
            'name': 'Conflicting project',
          };
          await expectLater(
            reopened.request('POST', '/v1/projects', conflicting),
            throwsA(isA<TaskChangeRejected>()),
          );
          expect((await reopened.outbox.list()).single['state'], 'rejected');
          final messageId = uuid.v4();
          final chatBody = {
            'id': messageId,
            'op': messageId,
            'body': 'Synthetic queued message',
          };
          final chatBox = TaskOutbox.forPath(
            outbox.actor,
            '${dir.path}/chat.sqlite3',
          );
          lost = 2;
          final chat = TaskDelivery(
            outbox: chatBox,
            network: dropping,
            active: () => true,
            onChanged: (_) {},
          );
          await expectLater(
            chat.request('POST', '/v1/messages/room%3Alobby', chatBody),
            throwsA(isA<TaskChangeQueued>()),
          );
          expect((await chatBox.list()).single['state'], 'pending');
          final chatAfterRestart = TaskDelivery(
            outbox: TaskOutbox.forPath(chatBox.actor, chatBox.path),
            network: send,
            active: () => true,
            onChanged: (_) {},
          );
          await chatAfterRestart.drain();
          expect(await chatAfterRestart.outbox.list(), isEmpty);
          final messages =
              await send('GET', '/v1/messages/room%3Alobby') as List<dynamic>;
          expect(messages.where((m) => m['id'] == messageId).length, 1);
          final privateId = uuid.v4();
          await expectLater(
            chatAfterRestart.request('POST', '/v1/messages/room%3Afinance', {
              'id': privateId,
              'op': privateId,
              'body': 'Synthetic denied message',
            }),
            throwsA(isA<TaskChangeRejected>()),
          );
          expect(
            (await chatAfterRestart.outbox.list()).single['state'],
            'rejected',
          );
        } finally {
          client.close(force: true);
          await dir.delete(recursive: true);
        }
      });
    },
    skip: token == null,
  );
  testWidgets(
    'disconnect preserves a draft when its pending queue write fails',
    (tester) async {
      Future<void> until(bool Function() condition, String reason) async {
        for (var i = 0; i < 200 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: reason);
      }

      await tester.pumpWidget(const ProviderScope(child: Monastack()));
      await until(
        () => find.text('Connect').evaluate().isNotEmpty,
        'connect UI',
      );
      tester.widget<TextField>(find.byType(TextField).first).controller!.text =
          token!;
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
          .onPressed!();
      await until(
        () => find.text('Chat · Connected').evaluate().isNotEmpty,
        'connected',
      );
      final text = List.filled(4001, 'x').join();
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          text;
      Finder icon(String tooltip) => find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      );
      tester.widget<IconButton>(icon('Send')).onPressed!();
      tester.widget<IconButton>(icon('Disconnect')).onPressed!();
      await until(
        () => find
            .text('Chat · Send failed; message kept in draft')
            .evaluate()
            .isNotEmpty,
        'failed send prevented disconnect',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        text,
      );
      expect(find.byTooltip('Disconnect'), findsOneWidget);
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          'Synthetic corrected draft';
      tester.widget<IconButton>(icon('Send')).onPressed!();
      await until(
        () => find.text('an: Synthetic corrected draft').evaluate().isNotEmpty,
        'corrected draft delivered',
      );
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          'Synthetic pending disconnect';
      tester.widget<IconButton>(icon('Send')).onPressed!();
      tester.widget<IconButton>(icon('Disconnect')).onPressed!();
      await until(
        () => find.text('Connect').evaluate().isNotEmpty,
        'disconnect after durable queue write',
      );
      tester.widget<TextField>(find.byType(TextField).first).controller!.text =
          token;
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
          .onPressed!();
      await until(
        () =>
            find.text('an: Synthetic pending disconnect').evaluate().isNotEmpty,
        'queued message delivered after reconnect',
      );
    },
    skip: token == null,
  );
}
