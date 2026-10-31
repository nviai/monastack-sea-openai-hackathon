import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/leave_requests.dart';

void main() {
  testWidgets(
    'HR list removes another person’s leave after access is revoked',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var allowed = true;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async => allowed
          ? [
              {
                'id': '0123456789abcdef',
                'requester': 'van',
                'start_date': '2026-11-02',
                'end_date': '2026-11-03',
                'reason': 'Private test reason',
                'state': 'proposed',
                'version': 1,
              },
            ]
          : <dynamic>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: LeaveRequests(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Private test reason'), findsOneWidget);
      allowed = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.textContaining('Private test reason'), findsNothing);
    },
  );
  for (final scenario in [
    (
      'van',
      'approved',
      'Request cancellation',
      'request_cancel',
      'Request cancellation of approved leave?',
    ),
    (
      'an',
      'cancellation_pending',
      'Approve cancellation',
      'cancel_approve',
      'Approve leave cancellation?',
    ),
  ]) {
    testWidgets('leave cancellation: ${scenario.$4} needs confirmation', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? submitted;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (method == 'GET') {
          return [
            {
              'id': '0123456789abcdef',
              'requester': 'van',
              'start_date': '2026-11-02',
              'end_date': '2026-11-03',
              'reason': 'Example',
              'state': scenario.$2,
              'version': 4,
            },
          ];
        }
        submitted = Map<String, dynamic>.from(body as Map);
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: LeaveRequests(request: request, identity: scenario.$1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(scenario.$3));
      await tester.pumpAndSettle();
      expect(find.text(scenario.$5), findsOneWidget);
      expect(submitted, isNull);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(submitted!['action'], scenario.$4);
      expect(submitted!['expected_version'], 4);
    });
  }
}
