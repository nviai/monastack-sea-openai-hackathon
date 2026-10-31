import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/customer_directory.dart';
import 'package:monastack/sales_pipeline.dart';
import 'package:monastack/support_cases.dart';

void main() {
  testWidgets('sales write controls disappear while read access remains', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var canManage = true;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/sales/capabilities') return {'can_manage': canManage};
      if (path == '/v1/customers') {
        return [
          {'id': 'abcdef0123456789', 'name': 'Synthetic'},
        ];
      }
      return [
        {
          'id': '0123456789abcdef',
          'customer': 'abcdef0123456789',
          'customer_name': 'Synthetic',
          'title': 'Visible opportunity',
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
    expect(find.text('Opportunity'), findsOneWidget);
    canManage = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('Opportunity'), findsNothing);
    expect(find.text('Visible opportunity'), findsOneWidget);
  });
  for (final kind in ['customers', 'sales', 'support']) {
    testWidgets('$kind hides records when access is removed', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var allowed = true;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (!allowed) throw Exception('revoked');
        if (path.endsWith('/capabilities')) return {'can_manage': false};
        if (path == '/v1/customers') {
          return [
            {
              'id': '0123456789abcdef',
              'name': 'Private synthetic customer',
              'email': '',
              'notes': '',
              'version': 1,
            },
          ];
        }
        return [
          {
            'id': '0123456789abcdef',
            'customer': '0123456789abcdef',
            'customer_name': 'Synthetic',
            'title': 'Private synthetic case',
            'stage': 'lead',
            'status': 'open',
            'version': 1,
          },
        ];
      }

      final Widget page = switch (kind) {
        'customers' => CustomerDirectory(request: request),
        'sales' => SalesPipeline(request: request),
        _ => SupportCases(request: request),
      };
      await tester.pumpWidget(ProviderScope(child: MaterialApp(home: page)));
      await tester.pumpAndSettle();
      final name = kind == 'customers'
          ? 'Private synthetic customer'
          : 'Private synthetic case';
      expect(find.text(name), findsOneWidget);
      allowed = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.text(name), findsNothing);
      expect(find.textContaining('Customer access denied'), findsOneWidget);
    });
  }
}
