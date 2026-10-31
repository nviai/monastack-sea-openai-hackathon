import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/incidents.dart';

void main() {
  testWidgets('discussion retries the same operation and clears revoked data', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final comments = <Map<String, dynamic>>[];
    final sent = <Map<String, dynamic>>[];
    var revoked = false;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/incidents') {
        if (revoked) return <dynamic>[];
        return [
          {
            'id': '0123456789abcdef',
            'reporter': 'an',
            'title': 'Example',
            'description': 'Details',
            'severity': 'low',
            'state': 'open',
            'version': 1,
          },
        ];
      }
      if (revoked) throw Exception('revoked');
      if (method == 'GET') return List.of(comments);
      final command = Map<String, dynamic>.from(body as Map);
      sent.add(command);
      if (sent.length == 1) {
        comments.add({'author': 'an', 'body': command['body']});
        throw Exception('response lost');
      }
      return null;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Incidents(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discussion'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Update'),
      'Synthetic update',
    );
    await tester.tap(find.text('Post update'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not confirm'), findsOneWidget);
    await tester.tap(find.text('Post update'));
    await tester.pumpAndSettle();
    expect(sent.length, 2);
    expect(sent[0], sent[1]);
    expect(find.text('Synthetic update'), findsOneWidget);
    revoked = true;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic update'), findsNothing);
    expect(find.textContaining('access removed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('Example'), findsNothing);
  });
}
