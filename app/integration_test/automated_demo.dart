import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';
import 'package:monastack/features/office/communication/collaboration.dart';
import 'package:monastack/features/office/world/office_world.dart';

/// Explicit opt-in demo target. Uses real UI callbacks and real backend services.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('record the AI office walkthrough', (tester) async {
    final dir = Directory(Platform.environment['MONASTACK_DEMO_DIR']!);
    final password = Platform.environment['MONASTACK_DEMO_PASSWORD']!;
    final start = DateTime.now();
    void mark(String chapter) {
      File('${dir.path}/chapters.jsonl').writeAsStringSync(
        '${jsonEncode({'time': DateTime.now().toIso8601String(), 'chapter': chapter})}\n',
        mode: FileMode.append,
      );
      debugPrint('DEMO: $chapter');
    }

    Future<void> wait(double seconds) async {
      final until = DateTime.now().add(
        Duration(milliseconds: (seconds * 1000).round()),
      );
      while (DateTime.now().isBefore(until)) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> until(
      bool Function() ready,
      String label, {
      int seconds = 40,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await wait(.2);
      }
      if (!ready()) throw StateError('Demo timed out: $label');
    }

    Future<void> tap(Finder finder) async {
      await Scrollable.ensureVisible(
        tester.element(finder.last),
        alignment: .5,
      );
      await wait(.35);
      if (finder.hitTestable().evaluate().isEmpty) {
        throw StateError('Demo control is not visible: $finder');
      }
      await tester.tap(finder.hitTestable().last);
      await wait(1);
    }

    Finder field(String label) => find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.labelText == label || w.decoration?.hintText == label),
    );
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => field('Username').evaluate().isNotEmpty, 'login');
    File('${dir.path}/ready').writeAsStringSync('$pid');
    await until(
      () => File('${dir.path}/go').existsSync(),
      'recorder',
      seconds: 90,
    );
    mark('Welcome to Your AI Office');
    await wait(4);
    await tester.enterText(field('Username'), 'pha.le');
    await wait(1);
    await tester.enterText(field('Password'), password);
    await wait(1);
    await tap(find.text('Sign in'));
    await until(() => find.byType(OfficeWorld).evaluate().isNotEmpty, 'office');
    final collaboration = tester.state<CollaborationState>(
      find.byType(Collaboration),
    );
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    await collaboration.voice?.setCamera(false);
    await until(
      () => collaboration.chatClient?.phase == ChatPhase.ready,
      'Matrix room chat connected',
      seconds: 45,
    );
    mark('Lobby — live agent greeting');
    await wait(23);
    mark('Walk into Dev & QA — live voice');
    unawaited(world.goToRoom('dev'));
    await wait(28);
    mark('Projects and task board');
    unawaited(collaboration.openTool('tasks'));
    await until(
      () => find.text('Meslingo').evaluate().isNotEmpty,
      'project cards',
    );
    await wait(5);
    await tap(find.byKey(const ValueKey('project-demo-meslingo-v1')));
    await wait(8);
    await tap(find.byKey(const ValueKey('project-demo-vibekol-v1')));
    await wait(6);
    await tap(find.byKey(const ValueKey('project-demo-omitx-v1')));
    await wait(6);
    if (!Navigator.of(collaboration.context).canPop()) {
      throw StateError('Expected an open demo panel');
    }
    Navigator.of(collaboration.context).pop();
    await wait(1);
    mark('Assign a task to Atlas');
    unawaited(collaboration.openTool('agents'));
    await until(
      () => field('Proposed instruction').evaluate().isNotEmpty,
      'assignment form',
    );
    final dropdown = find.byType(DropdownButton<String>);
    await tap(dropdown);
    await tap(find.text('Atlas · Software Engineer'));
    await tester.enterText(
      field('Proposed instruction'),
      'Demo: review the Meslingo English-learning onboarding and propose three improvements. Ask me before making code changes.',
    );
    await wait(4);
    await tap(find.text('Propose'));
    await wait(5);
    if (!Navigator.of(collaboration.context).canPop()) {
      throw StateError('Expected an open demo panel');
    }
    Navigator.of(collaboration.context).pop();
    await wait(1);
    mark('Ask an agent to open the task board');
    collaboration.openAgentChat('dev-agent');
    await until(
      () => field('Message this agent…').evaluate().isNotEmpty,
      'agent chat',
    );
    await wait(3);
    await tester.enterText(
      field('Message this agent…'),
      'Open the task board for me, please.',
    );
    await wait(3);
    await tap(find.byTooltip('Send'));
    await until(
      () => find.text('Meslingo').evaluate().isNotEmpty,
      'agent opens board',
      seconds: 65,
    );
    await wait(8);
    if (!Navigator.of(collaboration.context).canPop()) {
      throw StateError('Expected an open demo panel');
    }
    Navigator.of(collaboration.context).pop();
    await wait(1);
    // Close the originating agent chat after viewing the opened board.
    await wait(2);
    if (find.byTooltip('Close').evaluate().isNotEmpty) {
      if (!Navigator.of(collaboration.context).canPop()) {
        throw StateError('Expected an open demo panel');
      }
      Navigator.of(collaboration.context).pop();
      await wait(1);
    }
    mark('Notifications');
    unawaited(collaboration.openTool('notifications'));
    await wait(6);
    if (find.byTooltip('Close').evaluate().isNotEmpty) {
      if (!Navigator.of(collaboration.context).canPop()) {
        throw StateError('Expected an open demo panel');
      }
      Navigator.of(collaboration.context).pop();
      await wait(1);
    } else if (find.text('Close').evaluate().isNotEmpty) {
      await tap(find.text('Close'));
    }
    mark('Workspace chat');
    await until(
      () => collaboration.chatClient?.phase == ChatPhase.ready,
      'room chat ready',
    );
    collaboration.openChat(currentRoom: true);
    await until(
      () =>
          collaboration.chatController?.room?.officeRoom ==
              collaboration.widget.room &&
          collaboration.chatController?.error == null,
      'current room conversation',
    );
    await wait(12);
    if (collaboration.chatClient?.phase != ChatPhase.ready ||
        collaboration.chatController?.error != null) {
      throw StateError('Room chat lost connection');
    }
    mark('Demo complete');
    File('${dir.path}/done')
        .writeAsStringSync('${DateTime.now().difference(start).inSeconds}');
    await wait(8);
  }, timeout: const Timeout(Duration(minutes: 7)));
}
