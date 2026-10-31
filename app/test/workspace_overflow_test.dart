import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/shared/workspace_theme.dart';
import 'package:monastack/features/agents/agent_configuration.dart';
import 'package:monastack/features/agents/job_queue.dart';
import 'package:monastack/features/agents/agent_chat.dart';
import 'package:monastack/features/knowledge/document_library.dart';
import 'package:monastack/features/knowledge/whiteboard.dart';
import 'package:monastack/features/knowledge/meetings.dart';
import 'package:monastack/features/customers/customer_directory.dart';
import 'package:monastack/features/customers/support_cases.dart';
import 'package:monastack/features/customers/sales_pipeline.dart';
import 'package:monastack/features/finance/expense_approvals.dart';
import 'package:monastack/features/office/rooms/room_membership.dart';
import 'package:monastack/features/office/communication/workspace_tools.dart';
import 'package:monastack/features/tasks/task_board.dart';

import 'agent_configuration_test.dart' show fixture;
import 'chat/chat_nexus_support.dart' show loadNexusFonts;

void main() {
  setUpAll(loadNexusFonts);
  const actors = [
    {
      'id': 'dev-agent',
      'name': 'Atlas with a very long customized name',
      'kind': 'agent',
      'role': 'agent',
    },
  ];
  const rooms = [
    {
      'id': 'dev',
      'name': 'Development and Quality Assurance Department',
      'restricted': true,
    },
  ];
  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (path == '/v1/agent-configuration') {
      final data = fixture(true);
      data['agents'][0]['config']['display_name'] =
          'Mona with a very long customized display name';
      return data;
    }
    if (path.endsWith('/capabilities')) {
      return {'configured': true, 'can_manage': true, 'can_approve': true};
    }
    if (path.contains('room-admin/rooms/') && !path.endsWith('history')) {
      return {'version': 1, 'members': []};
    }
    if (path == '/v1/jobs') {
      return [
        {
          'id': '0123456789abcdef',
          'agent': 'dev-agent',
          'instruction': 'Review the onboarding experience with a deliberately long task description and detailed acceptance criteria.',
          'state': 'host_reported',
          'report_outcome': 'success',
          'report_summary': 'Waiting for human review',
          'created_by': 'pha.le',
          'version': 1,
        },
      ];
    }
    return [];
  }

  final screens = <String, Widget Function()>{
    'agent settings': () => AgentConfiguration(request: request),
    'proposals': () => JobQueue(request: request, actors: actors),
    'agent chat': () => AgentChat(request: request, actors: actors),
    'documents': () => DocumentLibrary(request: request, rooms: rooms),
    'whiteboard': () => Whiteboard(request: request, rooms: rooms),
    'meetings': () =>
        Meetings(request: request, rooms: rooms, identity: 'le-pha'),
    'customers': () => CustomerDirectory(request: request),
    'support': () => SupportCases(request: request),
    'sales': () => SalesPipeline(request: request),
    'expenses': () => ExpenseApprovals(request: request),
    'rooms': () =>
        RoomMembership(request: request, actors: actors, rooms: rooms),
    'tools': () =>
        const WorkspaceTools(account: true, admin: true, chatUnread: 99),
    'tasks': () => TaskBoard(request: request, actors: actors),
  };
  for (final scale in [1.0, 1.5, 2.0]) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} fits minimum desktop at $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1100, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: workspaceTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: screen.value()),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
