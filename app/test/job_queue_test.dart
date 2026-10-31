import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/agents/job_queue.dart';

void main() {
  testWidgets('host reports are explicitly unverified', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Future<dynamic> request(String method, String path, [Object? body]) async {
      return [
        {
          'id': '0123456789abcdef',
          'agent': 'dev-agent',
          'instruction': 'Synthetic job',
          'created_by': 'an',
          'state': 'host_reported',
          'version': 4,
          'report_outcome': 'success',
          'report_summary': 'Synthetic report',
        },
      ];
    }

    const actors = [
      {'id': 'dev-agent', 'name': 'Dev Agent', 'kind': 'agent'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: JobQueue(request: request, actors: actors),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('not independently verified'), findsOneWidget);
    expect(find.textContaining('Synthetic report'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });
  testWidgets('records a proposal and clearly states there is no host', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final jobs = <Map<String, dynamic>>[];
    var denied = false;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET' && path == '/v1/jobs') {
        if (denied) throw StateError('revoked');
        return List.of(jobs);
      }
      if (method == 'POST' && path == '/v1/jobs') {
        final data = body as Map<String, dynamic>;
        jobs.add({
          ...data,
          'state': 'proposed',
          'created_by': 'an',
          'version': 1,
        });
        return null;
      }
      throw StateError('unexpected operation');
    }

    const actors = [
      {'id': 'dev-agent', 'name': 'Dev Agent', 'kind': 'agent'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: JobQueue(
            request: request,
            actors: actors,
            linkedTaskId: '0123456789abcdef',
            linkedTaskTitle: 'Example task',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('nothing runs'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Investigate issue');
    await tester.tap(find.text('Propose'));
    await tester.pumpAndSettle();
    expect(find.text('Investigate issue'), findsOneWidget);
    expect(jobs.single['state'], 'proposed');
    expect(jobs.single['task'], '0123456789abcdef');
    expect(find.text('Linked task: Example task'), findsOneWidget);
    denied = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Investigate issue'), findsNothing);
  });
}
