import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/customers/bookings.dart';

void main() {
  testWidgets('support can read bookings without sales controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/bookings/capabilities') return {'can_manage': false};
      if (path == '/v1/customers') return <dynamic>[];
      return [
        {
          'id': '0123456789abcdef',
          'customer': 'abcdef0123456789',
          'customer_name': 'Example',
          'title': 'Read-only booking',
          'starts': 1800000000,
          'ends': 1800003600,
          'state': 'scheduled',
          'version': 1,
        },
      ];
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Bookings(request: request)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Read-only booking'), findsOneWidget);
    expect(find.text('Book customer'), findsNothing);
    expect(find.text('Reschedule'), findsNothing);
    expect(find.text('Cancel booking'), findsNothing);
  });
  testWidgets('booking accepts UTC, links customer and confirms cancellation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = <Map<String, dynamic>>[];
    Map<String, dynamic>? cancellation;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/customers') {
        return [
          {'id': '0123456789abcdef', 'name': 'Synthetic customer'},
        ];
      }
      if (path == '/v1/bookings/capabilities') return {'can_manage': true};
      if (method == 'GET') return List.of(items);
      if (path == '/v1/bookings') {
        items.add({
          ...body as Map<String, dynamic>,
          'customer_name': 'Synthetic customer',
          'creator': 'mai',
          'state': 'scheduled',
          'version': 1,
        });
      } else if (path.endsWith('/cancel')) {
        cancellation = Map<String, dynamic>.from(body as Map);
        items.single['state'] = 'cancelled';
      } else {
        final update = Map<String, dynamic>.from(body as Map);
        expect(update['expected_version'], 1);
        items.single.addAll(update);
        items.single['version'] = 2;
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Bookings(request: request)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book customer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic customer').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Synthetic appointment',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC'),
      '2026-02-30 12:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End UTC'),
      '2026-03-01 13:00',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('valid UTC interval'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC'),
      '2026-03-01 12:00',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(items.single['customer'], '0123456789abcdef');
    expect(find.text('Synthetic appointment'), findsOneWidget);
    await tester.tap(find.text('Reschedule'));
    await tester.pumpAndSettle();
    expect(find.text('Customer: Synthetic customer'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC'),
      '2026-03-01 14:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End UTC'),
      '2026-03-01 15:00',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(items.single['version'], 2);
    await tester.tap(find.text('Cancel booking'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No customer notification'), findsOneWidget);
    expect(cancellation, isNull);
    await tester.tap(find.text('Confirm cancellation'));
    await tester.pumpAndSettle();
    expect(cancellation!['expected_version'], 2);
    expect(find.textContaining('cancelled'), findsOneWidget);
  });
}
