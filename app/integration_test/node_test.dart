import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';

Future<List<dynamic>> getJson(String token, String path) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(
          Uri.parse(
            'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT'] ?? '47830'}/v1/$path',
          ),
        )
        .timeout(const Duration(seconds: 5));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw HttpException('status ${response.statusCode}');
    }
    return jsonDecode(
      await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5)),
    ) as List<dynamic>;
  } finally {
    client.close();
  }
}

Future<int> postJson(String token, String path, Object body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT'] ?? '47830'}/v1/$path',
      ),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain();
    return response.statusCode;
  } finally {
    client.close();
  }
}

/// Reads presence from the realtime capability using a ticket issued by the
/// authority for the given credential.
Future<List<dynamic>> realtimePresence(String token) async {
  final client = HttpClient();
  try {
    final port = Platform.environment['MONASTACK_NODE_PORT'] ?? '47830';
    final issue = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/realtime/ticket'),
    );
    issue.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final issued = jsonDecode(
      await utf8.decoder.bind(await issue.close()).join(),
    ) as Map<String, dynamic>;
    final read = await client.getUrl(
      Uri.parse('${issued['realtime_url']}/v1/presence'),
    );
    read.headers.set(
      HttpHeaders.authorizationHeader,
      'Ticket ${issued['ticket']}',
    );
    final response = await read.close();
    if (response.statusCode != 200) {
      throw HttpException('status ${response.statusCode}');
    }
    return jsonDecode(await utf8.decoder.bind(response).join())
        as List<dynamic>;
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final anToken = Platform.environment['MONASTACK_TEST_AN'];
  final vanToken = Platform.environment['MONASTACK_TEST_VAN'];
  testWidgets('app exchanges chat and coordinates with the node', (
    tester,
  ) async {
    // Progress output keeps failures attributable without logging credentials.
    debugPrint('integration: start');
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    for (var i = 0; i < 60 && find.text('Connect').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(find.byType(TextField).first, anToken!);
    await tester.tap(find.text('Connect'));
    for (
      var i = 0;
      i < 80 && find.textContaining('Chat · Connected').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Chat · Connected'), findsOneWidget);
    debugPrint('integration: first connected');
    await tester.enterText(find.byType(TextField).last, 'integration message');
    await tester.tap(find.byTooltip('Send'));
    for (
      var i = 0;
      i < 50 && find.text('an: integration message').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('an: integration message'), findsOneWidget);
    debugPrint('integration: sent message');
    final messages = (await tester.runAsync(
      () => getJson(vanToken!, 'messages/room%3Alobby'),
    ))!;
    expect(messages.any((m) => m['body'] == 'integration message'), isTrue);
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Open task board').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Project'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Integration project');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Workspace'));
    await tester.pump(const Duration(seconds: 1));
    for (
      var i = 0;
      i < 50 && find.text('Choose a project').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('project-picker')));
    await tester.pump(const Duration(milliseconds: 300));
    for (
      var i = 0;
      i < 50 && find.text('Integration project').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Integration project').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Task'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Integration task');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Dev Agent · offline agent'));
    for (
      var i = 0;
      i < 50 && find.text('Integration task').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration task'), findsOneWidget);
    final projectList = (await tester.runAsync(
      () => getJson(vanToken!, 'projects'),
    ))!;
    final project = projectList.singleWhere(
      (p) => p['name'] == 'Integration project',
    );
    final taskList = (await tester.runAsync(
      () => getJson(vanToken!, 'projects/${project['id']}/tasks'),
    ))!;
    expect(taskList.single['assignee'], 'dev-agent');
    await tester.tap(find.text('Start'));
    for (var i = 0; i < 50 && find.text('Reopen').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Reopen'), findsOneWidget);
    final updated = (await tester.runAsync(
      () => getJson(vanToken!, 'projects/${project['id']}/tasks'),
    ))!;
    expect(updated.single['state'], 'in_progress');
    await tester.tap(find.text('History'));
    for (
      var i = 0;
      i < 50 && find.text('Task history').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('transition:todo:in_progress'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Project'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Integration private');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Private'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('project-picker')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Integration private · private').last);
    await tester.pump(const Duration(milliseconds: 300));
    final ownerProjects = (await tester.runAsync(
      () => getJson(anToken, 'projects'),
    ))!;
    final privateProject = ownerProjects.singleWhere(
      (p) => p['name'] == 'Integration private',
    );
    final beforeInvite = (await tester.runAsync(
      () => getJson(vanToken!, 'projects'),
    ))!;
    expect(beforeInvite.any((p) => p['id'] == privateProject['id']), isFalse);
    await tester.tap(find.text('Members'));
    await tester.pump(const Duration(milliseconds: 500));
    final member = find.byKey(const ValueKey('member-van'));
    final scrollable = find
        .descendant(
          of: find.byType(AlertDialog).last,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(member, 150, scrollable: scrollable);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(of: member, matching: find.text('Invite')),
    );
    for (
      var i = 0;
      i < 50 &&
          find
              .descendant(of: member, matching: find.text('Remove'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.descendant(of: member, matching: find.text('Remove')),
      findsOneWidget,
    );
    final afterInvite = (await tester.runAsync(
      () => getJson(vanToken!, 'projects'),
    ))!;
    expect(afterInvite.any((p) => p['id'] == privateProject['id']), isTrue);
    await tester.tap(
      find.descendant(of: member, matching: find.text('Make read-only')),
    );
    for (
      var i = 0;
      i < 50 &&
          find
              .descendant(of: member, matching: find.text('Make editor'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final readerProjects = (await tester.runAsync(
      () => getJson(vanToken!, 'projects'),
    ))!;
    expect(
      readerProjects.singleWhere(
        (p) => p['id'] == privateProject['id'],
      )['can_edit'],
      isFalse,
    );
    await tester.tap(
      find.descendant(of: member, matching: find.text('Remove')),
    );
    for (
      var i = 0;
      i < 50 &&
          find
              .descendant(of: member, matching: find.text('Invite'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final afterRevoke = (await tester.runAsync(
      () => getJson(vanToken!, 'projects'),
    ))!;
    expect(afterRevoke.any((p) => p['id'] == privateProject['id']), isFalse);
    await tester.tap(find.text('Close').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Agent proposals').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Integration proposal');
    await tester.tap(find.text('Propose'));
    for (var i = 0; i < 50 && find.text('Approve').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Approve'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    for (
      var i = 0;
      i < 50 &&
          find.textContaining('Approved, waiting for host').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Approved, waiting for host'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final jobs = (await tester.runAsync(() => getJson(vanToken!, 'jobs')))!;
    expect(jobs.single['state'], 'approved_waiting');

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Documents').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Document'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Integration document',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Text'),
      'Integration content',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('New document').evaluate().isNotEmpty ||
              find.text('Integration document').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration document'), findsOneWidget);
    await tester.tap(find.text('History'));
    for (
      var i = 0;
      i < 50 && find.text('Document history').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('an · created'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final documents = (await tester.runAsync(
      () => getJson(vanToken!, 'documents'),
    ))!;
    expect(documents.single['title'], 'Integration document');

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Customers').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Customer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Integration customer',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('New customer').evaluate().isNotEmpty ||
              find.text('Integration customer').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration customer'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Sales pipeline').last);
    for (
      var i = 0;
      i < 50 && find.text('Opportunity').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Opportunity'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Integration customer').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Opportunity title'),
      'Integration opportunity',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('New opportunity').evaluate().isNotEmpty ||
              find.text('Integration opportunity').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration opportunity'), findsOneWidget);
    await tester.tap(find.text('Move to qualified'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.text('Move to proposal').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Move to proposal'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Customer support').last);
    for (
      var i = 0;
      i < 50 && find.text('Support case').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Support case'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Integration customer').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Case title'),
      'Integration support case',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('New support case').evaluate().isNotEmpty ||
              find.text('Integration support case').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Integration support case'), findsOneWidget);
    await tester.tap(find.text('Move to in progress'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.text('Move to resolved').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Move to resolved'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Meetings').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Schedule meeting'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Integration meeting',
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
    for (
      var i = 0;
      i < 50 &&
          (find.widgetWithText(TextField, 'Title').evaluate().isNotEmpty ||
              find.text('Integration meeting').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Integration meeting'), findsOneWidget);
    final otherMeetings = (await tester.runAsync(
      () => getJson(vanToken!, 'meetings'),
    ))!;
    expect(otherMeetings.single['title'], 'Integration meeting');
    await tester.tap(find.text('Reschedule'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Updated integration meeting',
    );
    await tester.tap(find.text('Save changes'));
    for (
      var i = 0;
      i < 50 && find.text('Reschedule meeting').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (
      var i = 0;
      i < 50 && find.text('Updated integration meeting').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Updated integration meeting'), findsOneWidget);
    await tester.tap(find.text('Cancel meeting'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm cancellation'));
    for (
      var i = 0;
      i < 50 && find.textContaining('cancelled').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('cancelled'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Whiteboard').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Note'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Note text'),
      'Integration note',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('New note').evaluate().isNotEmpty ||
              find.text('Integration note').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Integration note'), findsWidgets);
    final sharedNotes = (await tester.runAsync(
      () => getJson(vanToken!, 'whiteboard/notes?scope=workspace'),
    ))!;
    expect(sharedNotes.single['text'], 'Integration note');
    await tester.tap(find.text('Edit note'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Horizontal position (0–1000)'),
      '700',
    );
    await tester.tap(find.text('Save'));
    for (var i = 0; i < 50 && find.text('700, 100').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('700, 100'), findsOneWidget);
    await tester.tap(find.text('Delete note'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    for (
      var i = 0;
      i < 50 && find.text('Integration note').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration note'), findsNothing);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Expense approvals').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Propose expense'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Integration expense',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount in minor units (integer)'),
      '123',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find.text('Propose expense').evaluate().length > 1 ||
              find.text('Integration expense').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Integration expense'), findsOneWidget);
    await tester.tap(find.text('Withdraw'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.textContaining('withdrawn').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('withdrawn'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final expenses = (await tester.runAsync(
      () => getJson(vanToken!, 'expenses'),
    ))!;
    expect(expenses.single['minor'], 123);
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Journal entries').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Propose journal'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Integration journal',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Debit account code'),
      'cash',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Credit account code'),
      'revenue',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount in minor units (integer)'),
      '100',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 &&
          (find
                  .widgetWithText(TextField, 'Description')
                  .evaluate()
                  .isNotEmpty ||
              find.text('Integration journal').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Integration journal'), findsOneWidget);
    expect(find.text('Post'), findsNothing);
    final createdJournal = await tester.runAsync(
      () => postJson(vanToken!, 'journals', {
        'id': 'integration-van-journal-0001',
        'op': 'integration-van-operation-0001',
        'description': 'Second identity journal',
        'debit': 'cash',
        'credit': 'revenue',
        'minor': 100,
        'currency': 'VND',
      }),
    );
    expect(createdJournal, 201);
    await tester.tap(find.byTooltip('Refresh').last);
    for (var i = 0; i < 50 && find.text('Post').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Post'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm'));
    for (var i = 0; i < 50 && find.text('Reverse').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Reverse'), findsOneWidget);
    await tester.tap(find.text('View net activity'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('cash · VND · 100'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Reverse'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Propose reversal'));
    for (
      var i = 0;
      i < 50 && find.textContaining('Reversal of').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Reversal of'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final journals = (await tester.runAsync(
      () => getJson(vanToken!, 'journals'),
    ))!;
    expect(
      journals.any(
        (j) =>
            j['debit'] == 'cash' &&
            j['credit'] == 'revenue' &&
            j['state'] == 'posted',
      ),
      isTrue,
    );
    final createdExpense = await tester.runAsync(
      () => postJson(vanToken!, 'expenses', {
        'id': 'payment-expense-fixture-0001',
        'op': 'payment-expense-operation-0001',
        'description': 'Payment fixture',
        'minor': 250,
        'currency': 'VND',
      }),
    );
    expect(createdExpense, 201);
    final approvedExpense = await tester.runAsync(
      () =>
          postJson(anToken, 'expenses/payment-expense-fixture-0001/decision', {
            'action': 'approve',
            'expected_version': 1,
            'op': 'payment-expense-approval-0001',
          }),
    );
    expect(approvedExpense, 200);
    final paymentRequest = await tester.runAsync(
      () => postJson(vanToken!, 'payment-authorizations', {
        'id': 'payment-request-fixture-0001',
        'expense': 'payment-expense-fixture-0001',
        'op': 'payment-request-operation-0001',
      }),
    );
    expect(paymentRequest, 201);
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Payment authorizations').last);
    await tester.tap(find.text('Payment authorizations').last);
    for (
      var i = 0;
      i < 50 && find.text('Payment fixture').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Payment fixture'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('No payment is made'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.textContaining('no payment executed').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('no payment executed'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Leave requests').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Request leave'));
    await tester.pump(const Duration(milliseconds: 300));
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
      'Integration leave',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 && find.text('2026-11-02 to 2026-11-03').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('2026-11-02 to 2026-11-03'), findsOneWidget);
    await tester.tap(find.text('Withdraw'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.textContaining('withdrawn').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('withdrawn'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final otherLeave = (await tester.runAsync(
      () => getJson(vanToken!, 'leave'),
    ))!;
    expect(otherLeave, isEmpty);
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Incidents').last);
    await tester.tap(find.text('Incidents').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Report incident'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Integration incident',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Synthetic incident',
    );
    await tester.tap(find.text('Submit'));
    for (
      var i = 0;
      i < 50 && find.widgetWithText(TextField, 'Title').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (
      var i = 0;
      i < 50 && find.text('Integration incident').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Integration incident'), findsOneWidget);
    await tester.tap(find.text('Discussion'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Update'),
      'Synthetic investigation update',
    );
    await tester.tap(find.text('Post update'));
    for (
      var i = 0;
      i < 50 && find.text('Synthetic investigation update').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Synthetic investigation update'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Close').first);
    await tester.pump(const Duration(milliseconds: 300));
    final otherIncidents = (await tester.runAsync(
      () => getJson(vanToken!, 'incidents'),
    ))!;
    expect(otherIncidents, isEmpty);
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    await tester.tap(find.text('Dev & QA').first);
    for (var i = 0; i < 300 && world.current.toString() != '[3, 3]'; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('integration: dev arrival');
    expect(world.current, [3, 3]);
    debugPrint('integration: starting presence read');
    List<dynamic> presence = [];
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      presence = (await tester.runAsync(() => realtimePresence(vanToken!)))!;
      if (presence.any(
        (p) => p['actor'] == 'an' && p['x'] == 3 && p['y'] == 3,
      )) {
        break;
      }
    }
    expect(
      presence.any((p) => p['actor'] == 'an' && p['x'] == 3 && p['y'] == 3),
      isTrue,
    );
    if (Platform.environment['MONASTACK_TEST_REVOCATION'] == '1') {
      debugPrint('integration: first identity complete');
      await tester.tap(find.byTooltip('Disconnect'));
      debugPrint('integration: disconnect tapped');
      for (var i = 0; i < 80 && find.text('Connect').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Connect'), findsOneWidget);
      debugPrint('integration: disconnected');
      await tester.enterText(find.byType(TextField).first, vanToken!);
      await tester.tap(find.text('Connect'));
      for (
        var i = 0;
        i < 80 && find.textContaining('Chat · Connected').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
      debugPrint('integration: second identity connected');
      world.goToRoom('finance');
      for (var i = 0; i < 400 && world.current.toString() != '[25, 23]'; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('integration: finance arrival check');
      expect(world.current, [25, 23]);
      for (var i = 0; i < 300 && world.current.toString() != '[14, 13]'; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(world.current, [14, 13]);
      expect(find.textContaining('Room access changed'), findsOneWidget);
    }
  }, skip: anToken == null || vanToken == null);
}
