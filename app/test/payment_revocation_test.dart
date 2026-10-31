import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/payment_authorizations.dart';

void main() {
  for (final loss in ['access', 'approval role']) {
    testWidgets('open payment confirmation clears on loss of $loss', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var allowed = true;
      var canApprove = true;
      var writes = 0;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (!allowed) throw StateError('access revoked');
        if (method == 'POST') {
          writes++;
          return null;
        }
        if (path == '/v1/finance/capabilities') {
          return {'can_approve': canApprove};
        }
        if (path == '/v1/expenses') return <dynamic>[];
        return [
          {
            'id': '0123456789abcdef',
            'expense': 'abcdef0123456789',
            'description': 'Private synthetic description',
            'minor': 100,
            'currency': 'VND',
            'expense_creator': 'van',
            'requester': 'van',
            'state': 'approved_waiting',
            'version': 2,
          },
        ];
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PaymentAuthorizations(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Private synthetic description'),
        findsWidgets,
      );
      if (loss == 'access') {
        allowed = false;
      } else {
        canApprove = false;
      }
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Finance access changed'), findsOneWidget);
      expect(
        find.textContaining('Private synthetic description · 100 minor units'),
        findsNothing,
      );
      expect(find.text('Confirm'), findsNothing);
      allowed = true;
      canApprove = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Finance access changed'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
  for (final outcome in ['success', 'failure']) {
    testWidgets('late payment history $outcome is ignored after access loss', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var allowed = true;
      final history = Completer<dynamic>();
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path.endsWith('/history')) return history.future;
        if (!allowed) throw StateError('access revoked');
        if (path == '/v1/finance/capabilities') return {'can_approve': true};
        if (path == '/v1/expenses') return <dynamic>[];
        return [
          {
            'id': '0123456789abcdef',
            'expense': 'abcdef0123456789',
            'description': 'Synthetic',
            'minor': 100,
            'currency': 'VND',
            'expense_creator': 'van',
            'requester': 'van',
            'state': 'approved_waiting',
            'version': 2,
          },
        ];
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PaymentAuthorizations(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pump();
      allowed = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      if (outcome == 'success') {
        history.complete([
          {'actor': 'private actor', 'action': 'approve'},
        ]);
      } else {
        history.completeError(StateError('late failure'));
      }
      await tester.pump();
      expect(find.textContaining('private actor'), findsNothing);
      expect(find.text('Authorization history'), findsNothing);
      expect(
        find.text('Finance access denied or node unavailable.'),
        findsOneWidget,
      );
    });
  }
  for (final view in ['history', 'request']) {
    testWidgets('open payment $view hides its contents after access loss', (
      tester,
    ) async {
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
        if (!allowed) throw StateError('access revoked');
        if (path.endsWith('/history')) {
          return [
            {'actor': 'private history actor', 'action': 'approve'},
          ];
        }
        if (path == '/v1/finance/capabilities') return {'can_approve': true};
        if (path == '/v1/expenses') {
          return [
            {
              'id': '1234567890abcdef',
              'description': 'Private expense',
              'minor': 100,
              'currency': 'VND',
              'state': 'approved',
            },
          ];
        }
        return [
          {
            'id': '0123456789abcdef',
            'expense': 'abcdef0123456789',
            'description': 'Synthetic',
            'minor': 100,
            'currency': 'VND',
            'expense_creator': 'van',
            'requester': 'van',
            'state': 'approved_waiting',
            'version': 2,
          },
        ];
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PaymentAuthorizations(request: request, identity: 'an'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(view == 'history' ? 'History' : 'Request authorization'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          view == 'history'
              ? 'Authorization history'
              : 'Request payment authorization',
        ),
        findsOneWidget,
      );
      allowed = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Finance access changed'), findsOneWidget);
      expect(find.textContaining('private history actor'), findsNothing);
      expect(find.text('Request payment authorization'), findsNothing);
    });
  }
  testWidgets('approved authorization requires confirmation to revoke', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? decision;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/finance/capabilities') return {'can_approve': true};
      if (path == '/v1/expenses') return <dynamic>[];
      if (method == 'GET') {
        return [
          {
            'id': '0123456789abcdef',
            'expense': 'abcdef0123456789',
            'description': 'Synthetic',
            'minor': 100,
            'currency': 'VND',
            'expense_creator': 'van',
            'requester': 'van',
            'state': 'approved_waiting',
            'version': 2,
          },
        ];
      }
      decision = Map<String, dynamic>.from(body as Map);
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PaymentAuthorizations(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke authorization?'), findsOneWidget);
    expect(find.textContaining('No payment is made'), findsOneWidget);
    expect(decision, isNull);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(decision!['action'], 'revoke');
    expect(decision!['expected_version'], 2);
  });
}
