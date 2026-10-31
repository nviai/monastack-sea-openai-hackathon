import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/customers/customer_directory.dart';
import 'package:monastack/features/finance/expense_approvals.dart';
import 'package:monastack/features/hr/leave_requests.dart';
import 'package:monastack/features/operations/incidents.dart';
import 'package:monastack/features/customers/sales_pipeline.dart';
import 'package:monastack/features/knowledge/meetings.dart';
import 'package:monastack/features/customers/support_cases.dart';
import 'package:monastack/features/finance/journal_entries.dart';
import 'package:monastack/features/finance/payment_authorizations.dart';
import 'package:monastack/shared/utc_time.dart';

void main() {
  testWidgets(
    'payment approval records no transfer and requires confirmation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      Map<String, dynamic>? decision;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path == '/v1/finance/capabilities') return {'can_approve': true};
        if (path == '/v1/expenses') return <dynamic>[];
        if (method == 'GET') {
          return [
            {
              'id': '0123456789abcdef',
              'expense': 'abcdef0123456789',
              'description': 'Example expense',
              'minor': 100,
              'currency': 'VND',
              'expense_creator': 'van',
              'requester': 'van',
              'state': decision == null ? 'pending' : 'approved_waiting',
              'version': 1,
            },
          ];
        }
        decision = body as Map<String, dynamic>;
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PaymentAuthorizations(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No payment is made'), findsOneWidget);
      expect(decision, isNull);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(decision!['action'], 'approve');
      expect(find.textContaining('no payment executed'), findsOneWidget);
    },
  );
  testWidgets(
    'posted journal reversal requires confirmation and shows net activity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      Map<String, dynamic>? reversal;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path == '/v1/finance/capabilities') return {'can_approve': true};
        if (path == '/v1/journals/balances') {
          return [
            {'account': 'cash', 'currency': 'VND', 'net_debit_minor': '100'},
          ];
        }
        if (method == 'GET') {
          return [
            {
              'id': '0123456789abcdef',
              'description': 'Posted journal',
              'debit': 'cash',
              'credit': 'revenue',
              'minor': 100,
              'currency': 'VND',
              'creator': 'van',
              'state': 'posted',
              'version': 2,
              'reverses': null,
              'reversed': false,
            },
          ];
        }
        reversal = body as Map<String, dynamic>;
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: JournalEntries(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('View net activity'));
      await tester.pumpAndSettle();
      expect(find.textContaining('cash · VND · 100'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reverse'));
      await tester.pumpAndSettle();
      expect(reversal, isNull);
      expect(find.textContaining('No payment occurs'), findsOneWidget);
      await tester.tap(find.text('Propose reversal'));
      await tester.pumpAndSettle();
      expect(reversal!['id'], isNotEmpty);
      expect(reversal!['op'], isNotEmpty);
    },
  );
  testWidgets('journal proposal has distinct balanced accounts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final entries = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/finance/capabilities') return {'can_approve': true};
      if (method == 'GET') return List.of(entries);
      entries.add({
        ...body as Map<String, dynamic>,
        'creator': 'an',
        'state': 'proposed',
        'version': 1,
      });
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: JournalEntries(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Propose journal'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Example journal',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Debit account code'),
      'cash',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Credit account code'),
      'cash',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount in minor units (integer)'),
      '100',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(entries, isEmpty);
    await tester.enterText(
      find.widgetWithText(TextField, 'Credit account code'),
      'revenue',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(entries.single['debit'], 'cash');
    expect(entries.single['credit'], 'revenue');
    expect(find.text('Post'), findsNothing);
  });
  testWidgets('support creates a case linked to the selected customer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final cases = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/support/capabilities') return {'can_manage': true};
      if (path == '/v1/customers') {
        return [
          {'id': '0123456789abcdef', 'name': 'Example customer'},
        ];
      }
      if (method == 'GET') return List.of(cases);
      cases.add({
        ...body as Map<String, dynamic>,
        'customer_name': 'Example customer',
        'status': 'open',
        'version': 1,
      });
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SupportCases(request: request)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Support case'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example customer').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Case title'),
      'Example case',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(cases.single['customer'], '0123456789abcdef');
    expect(find.text('Example case'), findsOneWidget);
  });
  testWidgets('expense creator can withdraw a pending expense', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Map<String, dynamic>? decision;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/finance/capabilities') return {'can_approve': true};
      if (method == 'GET') {
        return [
          {
            'id': '0123456789abcdef',
            'description': 'Example',
            'minor': 100,
            'currency': 'VND',
            'creator': 'an',
            'state': decision == null ? 'proposed' : 'withdrawn',
            'version': 1,
          },
        ];
      }
      decision = body as Map<String, dynamic>;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ExpenseApprovals(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    await tester.tap(find.text('Withdraw'));
    await tester.pumpAndSettle();
    expect(decision, isNull);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(decision!['action'], 'withdraw');
    expect(decision!['expected_version'], 1);
  });
  test('meeting times reject normalized invalid dates', () {
    expect(parseUtc('2026-02-30 10:00'), isNull);
    expect(parseUtc('2026-11-02 10:00'), isNotNull);
    expect(parseUtc('2026-11-02 25:00'), isNull);
  });
  testWidgets('meeting form schedules in UTC and confirms cancellation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final meetings = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') return List.of(meetings);
      if (path == '/v1/meetings') {
        meetings.add({
          ...body as Map<String, dynamic>,
          'creator': 'an',
          'state': 'scheduled',
          'version': 1,
        });
      } else if (path.endsWith('/cancel')) {
        meetings.single['state'] = 'cancelled';
      } else {
        final update = body as Map<String, dynamic>;
        expect(update['expected_version'], 1);
        meetings.single.addAll(update);
        meetings.single['version'] = 2;
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Meetings(request: request, rooms: const [], identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Schedule meeting'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Synthetic meeting',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC (YYYY-MM-DD HH:MM)'),
      '2026-11-02 10:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End UTC (YYYY-MM-DD HH:MM)'),
      '2026-11-02 11:00',
    );
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic meeting'), findsOneWidget);
    await tester.tap(find.text('Reschedule'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Updated meeting',
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('Updated meeting'), findsOneWidget);
    await tester.tap(find.text('Cancel meeting'));
    await tester.pumpAndSettle();
    expect(meetings.single['state'], 'scheduled');
    await tester.tap(find.text('Confirm cancellation'));
    await tester.pumpAndSettle();
    expect(meetings.single['state'], 'cancelled');
  });
  testWidgets('support sees pipeline without sales controls', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/sales/capabilities') return {'can_manage': false};
      if (path == '/v1/customers') {
        return [
          {'id': '0123456789abcdef', 'name': 'Example'},
        ];
      }
      return [
        {
          'id': '0123456789abcdef',
          'title': 'Example deal',
          'customer_name': 'Example',
          'stage': 'lead',
          'version': 1,
        },
      ];
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SalesPipeline(request: request)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Example deal'), findsOneWidget);
    expect(find.text('Opportunity'), findsNothing);
    expect(find.text('Move to qualified'), findsNothing);
  });
  testWidgets('sales pipeline links an opportunity to an existing customer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final opportunities = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/sales/capabilities') return {'can_manage': true};
      if (path == '/v1/customers') {
        return [
          {'id': '0123456789abcdef', 'name': 'Example customer'},
        ];
      }
      if (method == 'GET') return List.of(opportunities);
      opportunities.add({
        ...body as Map<String, dynamic>,
        'customer_name': 'Example customer',
        'stage': 'lead',
        'version': 1,
      });
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SalesPipeline(request: request)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opportunity'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example customer').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Opportunity title'),
      'Example deal',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(opportunities.single['customer'], '0123456789abcdef');
    expect(find.text('Example deal'), findsOneWidget);
  });
  testWidgets('incident reporting keeps responder actions off own report', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final reports = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') return List.of(reports);
      reports.add({
        ...body as Map<String, dynamic>,
        'reporter': 'an',
        'state': 'open',
        'version': 1,
      });
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Incidents(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report incident'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Synthetic incident',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Test description',
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(reports.single['severity'], 'medium');
    expect(find.text('Synthetic incident'), findsOneWidget);
    expect(find.text('Investigate'), findsNothing);
  });
  testWidgets('denied customer access displays no records', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Future<dynamic> denied(String method, String path, [Object? body]) async =>
        throw StateError('denied');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: CustomerDirectory(request: denied)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Customer access denied or node unavailable.'),
      findsOneWidget,
    );
    expect(find.text('Customer'), findsNothing);
  });
  testWidgets(
    'expense decision asks for confirmation and does not imply payment',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      var sent = false;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path == '/v1/finance/capabilities') return {'can_approve': true};
        if (method == 'GET') {
          return [
            {
              'id': '0123456789abcdef',
              'description': 'Travel',
              'minor': 123,
              'currency': 'VND',
              'creator': 'van',
              'state': 'proposed',
              'version': 1,
            },
          ];
        }
        sent = true;
        return null;
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: ExpenseApprovals(request: request)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no payment is made'), findsOneWidget);
      expect(sent, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isFalse);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(sent, isTrue);
    },
  );
  testWidgets(
    'leave form submits an own request without an invented HR member',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      final requests = <Map<String, dynamic>>[];
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (method == 'GET') return List.of(requests);
        final data = body as Map<String, dynamic>;
        requests.add({
          ...data,
          'requester': 'an',
          'state': 'proposed',
          'version': 1,
        });
        return null;
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: LeaveRequests(request: request)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No HR member is seeded'), findsOneWidget);
      await tester.tap(find.text('Request leave'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Start date (YYYY-MM-DD)'),
        '2026-11-02',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'End date (YYYY-MM-DD)'),
        '2026-11-03',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason'),
        'Personal',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(requests.single['requester'], 'an');
      expect(find.text('2026-11-02 to 2026-11-03'), findsOneWidget);
    },
  );
  testWidgets('requester confirms withdrawal with the current version', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Map<String, dynamic>? decision;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') {
        return [
          {
            'id': '0123456789abcdef',
            'requester': 'an',
            'start_date': '2026-11-02',
            'end_date': '2026-11-03',
            'reason': 'Personal',
            'state': decision == null ? 'proposed' : 'withdrawn',
            'version': 1,
          },
        ];
      }
      decision = body as Map<String, dynamic>;
      return null;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: LeaveRequests(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    await tester.tap(find.text('Withdraw'));
    await tester.pumpAndSettle();
    expect(decision, isNull);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(decision!['action'], 'withdraw');
    expect(decision!['expected_version'], 1);
    expect(find.textContaining('withdrawn'), findsOneWidget);
  });
}
