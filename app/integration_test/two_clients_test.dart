import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final actor = Platform.environment['MONASTACK_TEST_ACTOR']!;
  final credential = Platform.environment['MONASTACK_TEST_CREDENTIAL']!;
  testWidgets('two independent macOS clients exchange and reconnect', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String label, {
      int attempts = 150,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (!condition()) {
        final texts = find
            .byType(Text, skipOffstage: false)
            .evaluate()
            .map((element) => (element.widget as Text).data ?? '')
            .where((text) => text.contains('two-client'));
        debugPrint(
          'two-client $actor visible test messages: ${texts.join(' | ')}',
        );
      }
      expect(condition(), isTrue, reason: label);
    }

    bool message(String text) =>
        find.textContaining(text).evaluate().isNotEmpty;
    void setText(Finder field, String value) {
      tester.widget<TextField>(field).controller!.text = value;
    }

    void connect() => tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    void icon(String tooltip) => tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == tooltip,
          ),
        )
        .onPressed!();
    void directMessage(String peer) => tester
        .widget<DropdownButton<String>>(
          find.byWidgetPredicate(
            (w) =>
                w is DropdownButton<String> &&
                (w.items?.any((item) => item.value == '') ?? false),
          ),
        )
        .onChanged!(peer);
    Future<void> send(String text) async {
      setText(find.byType(TextField).last, text);
      icon('Send');
      await until(() => message('$actor: $text'), 'message $text');
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    setText(find.byType(TextField).first, credential);
    connect();
    await until(() => message('Chat · Connected'), 'connected');
    debugPrint('two-client $actor connected');
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    bool sees(String who, [List<int>? position]) =>
        world.widget.remote.value.any(
          (p) =>
              p['actor'] == who &&
              (position == null ||
                  (p['x'] == position[0] && p['y'] == position[1])),
        );
    // Flutter serializes macOS builds; wait for both clients to connect.
    await until(
      () => sees(actor == 'an' ? 'van' : 'an'),
      'both clients connected',
      attempts: 1200,
    );
    if (actor == 'an') {
      await send('two-client hello');
      debugPrint('two-client an sent hello');
      await until(
        () => message('van: two-client ready'),
        'ready received',
        attempts: 300,
      );
      debugPrint('two-client an received ready');
      await until(() => sees('van'), 'other app present', attempts: 300);
      debugPrint('two-client an sees van');
      await send('two-client move');
      await until(
        () => sees('van', [8, 2]),
        'other app movement',
        attempts: 200,
      );
      await send('two-client observed');
      await until(
        () => message('van: two-client disconnecting'),
        'other app disconnecting',
        attempts: 200,
      );
      await until(() => !sees('van'), 'other app disconnected', attempts: 150);
      await send('two-client absent');
      await until(
        () => sees('van') && message('van: two-client rejoined'),
        'other app reconnected',
        attempts: 250,
      );
      directMessage('van');
      await tester.pump();
      await send('two-client private hello');
      await until(
        () => message('van: two-client private reply'),
        'direct reply',
        attempts: 250,
      );
      await send('two-client restart preparation');
      await until(
        () => message('van: two-client restart prepared'),
        'restart preparation',
        attempts: 250,
      );
      await send('two-client restart request');
      await until(
        () => message('Chat · Offline or access denied'),
        'node outage',
        attempts: 250,
      );
      setText(find.byType(TextField).last, 'two-client queued during outage');
      icon('Send');
      await until(
        () => message('Messages pending/rejected: 1'),
        'message queued during outage',
        attempts: 200,
      );
      await until(
        () => message('Chat · Message queued'),
        'queue write completed',
        attempts: 100,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        try {
          var online = false;
          for (var i = 0; i < 150 && !online; i++) {
            try {
              final request = await client.getUrl(
                Uri.parse(
                  'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT']}/v1/me',
                ),
              );
              request.headers.set(
                HttpHeaders.authorizationHeader,
                'Bearer $credential',
              );
              final response = await request.close().timeout(
                const Duration(seconds: 1),
              );
              await response.drain();
              online = response.statusCode == 200;
            } catch (_) {}
            if (!online) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
          }
          expect(online, isTrue, reason: 'node restarted');
        } finally {
          client.close(force: true);
        }
      });
      await tester.pumpWidget(const ProviderScope(child: Monastack()));
      await until(
        () => find.text('Connect').evaluate().isNotEmpty,
        'reopened app',
      );
      setText(find.byType(TextField).first, credential);
      connect();
      await until(
        () => message('Chat · Connected'),
        'node recovery',
        attempts: 350,
      );
      directMessage('van');
      await tester.pump();
      await until(
        () => message('an: two-client queued during outage'),
        'queued message delivered after restart',
        attempts: 250,
      );
      await until(
        () => message('van: two-client restart reply'),
        'direct reply after restart',
        attempts: 250,
      );
    } else {
      await until(
        () => message('an: two-client hello'),
        'hello received',
        attempts: 1200,
      );
      debugPrint('two-client van received hello');
      await until(() => sees('an'), 'other app present', attempts: 250);
      debugPrint('two-client van sees an');
      await send('two-client ready');
      await until(
        () => message('an: two-client move'),
        'movement request',
        attempts: 300,
      );
      world.goToRoom('dev');
      await until(
        () => world.current.toString() == '[8, 2]',
        'local movement',
        attempts: 100,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)),
      );
      world.goToRoom('lobby');
      await until(
        () => world.current.toString() == '[2, 2]',
        'return to lobby',
        attempts: 100,
      );
      await until(
        () => message('an: two-client observed'),
        'movement observed',
        attempts: 150,
      );
      await send('two-client disconnecting');
      icon('Disconnect');
      await until(
        () => find.text('Connect').evaluate().isNotEmpty,
        'disconnected',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 9)),
      );
      setText(find.byType(TextField).first, credential);
      connect();
      await until(() => message('Chat · Connected'), 'reconnected');
      await until(
        () => message('an: two-client absent'),
        'absence observed',
        attempts: 150,
      );
      await send('two-client rejoined');
      directMessage('an');
      await tester.pump();
      await until(
        () => message('an: two-client private hello'),
        'direct message',
        attempts: 250,
      );
      await send('two-client private reply');
      await until(
        () => message('an: two-client restart preparation'),
        'restart preparation',
        attempts: 250,
      );
      await send('two-client restart prepared');
      await until(
        () => message('Chat · Offline or access denied'),
        'node outage',
        attempts: 250,
      );
      await until(
        () => message('Chat · Connected'),
        'node recovery',
        attempts: 350,
      );
      await until(
        () => message('an: two-client queued during outage'),
        'queued direct message after restart',
        attempts: 250,
      );
      await send('two-client restart reply');
    }
  });
}
