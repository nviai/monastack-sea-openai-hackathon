import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/knowledge/document_library.dart';

void main() {
  testWidgets('creates and opens a scoped document', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final docs = <Map<String, dynamic>>[];
    var denied = false;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET' && denied) throw StateError('revoked');
      if (method == 'GET' && path.endsWith('/history')) {
        return [
          {'actor': 'an', 'action': 'created'},
        ];
      }
      if (method == 'GET' && path.startsWith('/v1/documents')) {
        return List.of(docs);
      }
      if (method == 'POST' && path == '/v1/documents') {
        docs.add({...body as Map<String, dynamic>, 'version': 1});
        return null;
      }
      throw StateError('Unexpected request');
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DocumentLibrary(request: request, rooms: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Notes');
    await tester.enterText(find.widgetWithText(TextField, 'Text'), 'Some text');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(docs.single['scope'], 'workspace');
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('an · created'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Edit document'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    denied = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsNothing);
  });
}
