import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/hr/leave_calendar.dart';
import 'package:monastack/features/hr/leave_requests.dart';

void main() {
  testWidgets('leave requests opens the scoped calendar', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path.startsWith('/v1/leave/calendar?month=')) {
        return {
          'month': path.split('=').last,
          'truncated': false,
          'items': <dynamic>[],
        };
      }
      return <dynamic>[];
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: LeaveRequests(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approved leave calendar'));
    await tester.pumpAndSettle();
    expect(find.byType(LeaveCalendar), findsOneWidget);
    expect(find.textContaining('not a leave balance'), findsOneWidget);
  });
  testWidgets(
    'calendar shows scoped approved days and clears revoked records',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var visible = true;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async => {
        'month': '2026-11',
        'truncated': false,
        'items': visible
            ? [
                {
                  'id': 'synthetic',
                  'requester': 'test-person',
                  'start_date': '2026-10-31',
                  'end_date': '2026-11-02',
                  'state': 'cancellation_pending',
                },
              ]
            : [],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: LeaveCalendar(
            request: request,
            initialMonth: DateTime.utc(2026, 11),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 · 1'), findsOneWidget);
      expect(find.text('2 · 1'), findsOneWidget);
      await tester.tap(find.text('1 · 1'));
      await tester.pump();
      expect(find.text('test-person'), findsOneWidget);
      expect(find.textContaining('cancellation pending'), findsOneWidget);
      visible = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('test-person'), findsNothing);
      expect(find.text('1 · 1'), findsNothing);
    },
  );

  testWidgets('late previous month cannot replace current month', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final old = Completer<dynamic>();
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path.endsWith('2026-11')) return old.future;
      return {'month': '2026-12', 'truncated': true, 'items': <dynamic>[]};
    }

    await tester.pumpWidget(
      MaterialApp(
        home: LeaveCalendar(
          request: request,
          initialMonth: DateTime.utc(2026, 11),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();
    expect(find.text('2026-12'), findsOneWidget);
    expect(find.textContaining('first 500 records'), findsOneWidget);
    old.complete({
      'month': '2026-11',
      'truncated': false,
      'items': [
        {
          'requester': 'old-person',
          'start_date': '2026-11-01',
          'end_date': '2026-11-02',
        },
      ],
    });
    await tester.pump();
    expect(find.text('2026-12'), findsOneWidget);
    expect(find.textContaining('first 500 records'), findsOneWidget);
    expect(find.text('old-person'), findsNothing);
  });
}
