import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/chat_history.dart';

void main() {
  testWidgets(
    'empty older page stays disabled after refreshing the same page',
    (tester) async {
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path.contains('?before=')) return <dynamic>[];
        return List.generate(
          200,
          (index) => {
            'id': 'synthetic-message-${index.toString().padLeft(4, '0')}',
            'sender': 'synthetic',
            'body': 'message $index',
          },
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: ChatHistory(request: request, scope: 'room:lobby'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Older'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Older'))
            .onPressed,
        isNull,
      );
      expect(find.text('synthetic: message 0'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Older'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('history pages older and newer, then clears on access loss', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var allowed = true;
    final paths = <String>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      paths.add(path);
      if (!allowed) throw StateError('revoked');
      if (path.contains('?before=')) {
        return [
          {
            'id': 'synthetic-old-00001',
            'sender': 'synthetic',
            'body': 'oldest synthetic',
          },
        ];
      }
      return List.generate(
        200,
        (index) => {
          'id': index == 0
              ? 'synthetic+cursor-0000'
              : 'synthetic-message-${index.toString().padLeft(4, '0')}',
          'sender': 'synthetic',
          'body': 'latest synthetic $index',
        },
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ChatHistory(request: request, scope: 'dm:person'),
      ),
    );
    await tester.pumpAndSettle();
    expect(paths.first, '/v1/messages/dm%3Aperson');
    await tester.tap(find.text('Older'));
    await tester.pumpAndSettle();
    expect(
      paths.last,
      '/v1/messages/dm%3Aperson?before=synthetic%2Bcursor-0000',
    );
    expect(find.text('synthetic: oldest synthetic'), findsOneWidget);
    await tester.tap(find.text('Newer'));
    await tester.pumpAndSettle();
    expect(find.text('synthetic: latest synthetic 0'), findsOneWidget);
    allowed = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('History unavailable or access denied.'), findsOneWidget);
    expect(find.text('synthetic: latest synthetic 0'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Older'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Newer'))
          .onPressed,
      isNull,
    );
  });
}
