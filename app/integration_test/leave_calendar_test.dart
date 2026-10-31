import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/features/hr/leave_calendar.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('approved leave appears in the scoped monthly calendar', (
    tester,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    addTearDown(() => client.close(force: true));
    Future<dynamic> request(String method, String path, [Object? body]) async {
      final req = await client.openUrl(
        method,
        Uri.parse(
          'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT']}$path',
        ),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${Platform.environment['MONASTACK_TEST_TOKEN']}',
      );
      final response = await req.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) throw StateError('node denied request');
      return jsonDecode(text);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: LeaveCalendar(
          request: request,
          initialMonth: DateTime.utc(2026, 11),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('1 · 1').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('1 · 1'), findsOneWidget);
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, '1 · 1'))
        .onPressed!();
    await tester.pump();
    expect(find.text('van'), findsOneWidget);
    expect(find.textContaining('2026-10-31 to 2026-11-02'), findsOneWidget);
    expect(find.textContaining('Synthetic private reason'), findsNothing);
  });
}
