import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/whiteboard.dart';

void main() {
  testWidgets('shared note supports accessible edit and deletion', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final notes = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') return List.of(notes);
      final data = body as Map<String, dynamic>;
      if (path == '/v1/whiteboard/notes') {
        notes.add({...data, 'version': 1, 'created_by': 'an'});
      } else if (data['delete'] == true) {
        notes.clear();
      } else {
        notes.single.addAll(data);
        notes.single['version'] = 2;
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Whiteboard(request: request, rooms: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Note text'),
      'Example note',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(notes.single['scope'], 'workspace');
    expect(find.text('Example note'), findsWidgets);
    await tester.tap(find.text('Edit note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Horizontal position (0–1000)'),
      '700',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(notes.single['x'], 700);
    await tester.tap(find.text('Delete note'));
    await tester.pumpAndSettle();
    expect(notes, isNotEmpty);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(notes, isEmpty);
  });
}
