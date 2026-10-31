import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/customers/contracts.dart';

void main() {
  testWidgets('contract list clears after Sales access is removed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var allowed = true;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (!allowed) throw Exception('revoked');
      if (path == '/v1/customers') return <dynamic>[];
      if (path == '/v1/contracts/capabilities') return {'can_decide': false};
      return [
        {
          'id': '0123456789abcdef',
          'customer': 'abcdef0123456789',
          'customer_name': 'Example',
          'title': 'Private proposal',
          'terms': 'Private terms',
          'creator': 'mai',
          'state': 'proposed',
          'version': 1,
        },
      ];
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Contracts(request: request, identity: 'mai'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private proposal'), findsOneWidget);
    allowed = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('Private proposal'), findsNothing);
    expect(find.textContaining('Sales access denied'), findsOneWidget);
  });
  testWidgets('proposal links customer and freezes terms for internal review', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/customers') {
        return [
          {'id': '0123456789abcdef', 'name': 'Synthetic customer'},
        ];
      }
      if (path == '/v1/contracts/capabilities') return {'can_decide': false};
      if (method == 'GET') return List.of(records);
      records.add({
        ...body as Map<String, dynamic>,
        'customer_name': 'Synthetic customer',
        'creator': 'mai',
        'state': 'proposed',
        'version': 1,
      });
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Contracts(request: request, identity: 'mai'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Propose contract'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic customer').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Example proposal',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Proposed terms'),
      'Synthetic terms',
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(records.single['customer'], '0123456789abcdef');
    expect(find.textContaining('Synthetic terms'), findsOneWidget);
    expect(find.text('Approve internally'), findsNothing);
    expect(find.textContaining('No agreement is signed'), findsOneWidget);
  });
  testWidgets('internal approval requires explicit confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? decision;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/customers') return <dynamic>[];
      if (path == '/v1/contracts/capabilities') return {'can_decide': true};
      if (method == 'GET') {
        return [
          {
            'id': '0123456789abcdef',
            'customer': 'abcdef0123456789',
            'customer_name': 'Example',
            'title': 'Example proposal',
            'terms': 'Example terms',
            'creator': 'mai',
            'state': 'proposed',
            'version': 1,
          },
        ];
      }
      decision = Map<String, dynamic>.from(body as Map);
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Contracts(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve internally'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not a signature'), findsOneWidget);
    expect(decision, isNull);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(decision!['action'], 'approve');
    expect(decision!['expected_version'], 1);
  });
}
