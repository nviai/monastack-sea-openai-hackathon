import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/finance/expense_approvals.dart';
import 'package:monastack/features/finance/journal_entries.dart';
import 'package:monastack/features/finance/payment_authorizations.dart';

void main() {
  testWidgets('journal reversal confirmation clears on access loss', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var allowed = true;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (!allowed) throw StateError('revoked');
      if (path == '/v1/finance/capabilities') return {'can_approve': true};
      return [
        {
          'id': '0123456789abcdef',
          'description': 'Synthetic',
          'minor': 100,
          'currency': 'VND',
          'state': 'posted',
          'creator': 'van',
          'debit': 'cash',
          'credit': 'revenue',
          'version': 2,
        },
      ];
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: JournalEntries(request: request, identity: 'an'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reverse'));
    await tester.pumpAndSettle();
    expect(find.text('Propose a reversal?'), findsOneWidget);
    allowed = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('Finance access changed'), findsOneWidget);
    expect(find.text('Propose reversal'), findsNothing);
  });
  for (final kind in ['expenses', 'journals']) {
    for (final view in ['form', 'history']) {
      testWidgets('$kind $view clears when access is lost', (tester) async {
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
          if (!allowed) throw StateError('revoked');
          if (path == '/v1/finance/capabilities') return {'can_approve': true};
          if (path.endsWith('/history')) {
            return [
              {'actor': 'Private history actor', 'action': 'propose'},
            ];
          }
          return [
            {
              'id': '0123456789abcdef',
              'description': 'Synthetic',
              'minor': 100,
              'currency': 'VND',
              'state': 'proposed',
              'creator': 'van',
              'debit': 'cash',
              'credit': 'revenue',
              'version': 1,
            },
          ];
        }

        final page = kind == 'expenses'
            ? ExpenseApprovals(request: request, identity: 'an')
            : JournalEntries(request: request, identity: 'an');
        await tester.pumpWidget(ProviderScope(child: MaterialApp(home: page)));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            view == 'history'
                ? 'History'
                : kind == 'expenses'
                ? 'Propose expense'
                : 'Propose journal',
          ),
        );
        await tester.pumpAndSettle();
        if (view == 'history') {
          expect(find.textContaining('Private history actor'), findsOneWidget);
        }
        allowed = false;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text('Finance access changed'), findsOneWidget);
        expect(find.textContaining('Private history actor'), findsNothing);
        expect(find.text('Confirm'), findsNothing);
      });
    }
    testWidgets('$kind approval controls follow current authority', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var canApprove = false;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path == '/v1/finance/capabilities') {
          return {'can_approve': canApprove};
        }
        return [
          {
            'id': '0123456789abcdef',
            'description': 'Synthetic',
            'minor': 100,
            'currency': 'VND',
            'state': 'proposed',
            'creator': 'van',
            'debit': 'cash',
            'credit': 'revenue',
            'version': 1,
          },
        ];
      }

      final page = kind == 'expenses'
          ? ExpenseApprovals(request: request, identity: 'an')
          : JournalEntries(request: request, identity: 'an');
      await tester.pumpWidget(ProviderScope(child: MaterialApp(home: page)));
      await tester.pumpAndSettle();
      final action = kind == 'expenses' ? 'Approve' : 'Post';
      expect(find.text('Synthetic'), findsOneWidget);
      expect(find.text(action), findsNothing);
      canApprove = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text(action), findsOneWidget);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('Confirm'), findsOneWidget);
      canApprove = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Finance access changed'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      expect(find.text(action), findsNothing);
      expect(find.text('Synthetic'), findsOneWidget);
    });
  }
  testWidgets(
    'activity balance displays currency totals and excludes opening balances',
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
      ]) async {
        if (!allowed) throw Exception('revoked');
        if (path == '/v1/finance/capabilities') return {'can_approve': false};
        if (path == '/v1/journals/trial-balance') {
          return [
            {
              'currency': 'VND',
              'debit_total_minor': '100',
              'credit_total_minor': '100',
              'accounts': [
                {'account': 'cash', 'debit_minor': '100', 'credit_minor': '0'},
                {'account': 'sales', 'debit_minor': '0', 'credit_minor': '100'},
              ],
            },
          ];
        }
        return <dynamic>[];
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: JournalEntries(request: request, identity: 'van'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('View activity balance'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No opening balances'), findsOneWidget);
      expect(
        find.textContaining('VND · Debit 100 · Credit 100'),
        findsOneWidget,
      );
      expect(
        find.textContaining('cash · Debit 100 · Credit 0'),
        findsOneWidget,
      );
      allowed = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.textContaining('cash · Debit 100 · Credit 0'), findsNothing);
      expect(find.textContaining('Finance access denied'), findsWidgets);
    },
  );
  for (final kind in ['expenses', 'journals', 'payments']) {
    testWidgets('$kind clears finance data after access is revoked', (
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
        if (!allowed) throw Exception('revoked');
        if (path == '/v1/finance/capabilities') return {'can_approve': false};
        if (kind == 'payments' && path == '/v1/expenses') return <dynamic>[];
        return [
          {
            'id': '0123456789abcdef',
            'description': 'Private synthetic finance record',
            'minor': 100,
            'currency': 'VND',
            'state': kind == 'payments' ? 'pending' : 'proposed',
            'creator': 'van',
            'requester': 'van',
            'expense_creator': 'van',
            'expense': 'abcdef0123456789',
            'debit': '100',
            'credit': '200',
            'version': 1,
          },
        ];
      }

      final Widget page = switch (kind) {
        'expenses' => ExpenseApprovals(request: request, identity: 'van'),
        'journals' => JournalEntries(request: request, identity: 'van'),
        _ => PaymentAuthorizations(request: request, identity: 'van'),
      };
      await tester.pumpWidget(ProviderScope(child: MaterialApp(home: page)));
      await tester.pumpAndSettle();
      expect(find.text('Private synthetic finance record'), findsOneWidget);
      allowed = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.text('Private synthetic finance record'), findsNothing);
      expect(find.textContaining('Finance access denied'), findsOneWidget);
    });
  }
}
