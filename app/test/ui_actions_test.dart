import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/agents/ui_actions.dart';

void main() {
  testWidgets(
    'controls fill fields and click, excluding passwords and disabled buttons',
    (tester) async {
      late BuildContext root;
      var clicks = 0;
      var text = '';
      var active = true;
      final navigation = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              root = context;
              return Scaffold(
                body: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(labelText: 'Title'),
                      onChanged: (v) => text = v,
                    ),
                    const TextField(
                      obscureText: true,
                      decoration: InputDecoration(labelText: 'Password'),
                    ),
                    TextButton(
                      onPressed: () => clicks++,
                      child: const Text('Save'),
                    ),
                    const TextButton(onPressed: null, child: Text('Disabled')),
                  ],
                ),
              );
            },
          ),
        ),
      );
      final ui = UiActions(
        root: () => root,
        active: () => active,
        navigate: navigation.add,
      );
      var controls = ui.snapshot();
      expect(controls.where((c) => c['label'] == 'Password'), isEmpty);
      expect(controls.where((c) => c['label'] == 'Disabled'), isEmpty);
      final fill = controls.singleWhere((c) => c['label'] == 'Title');
      var action = ui.execute({'id': fill['id'], 'value': 'New task'});
      await tester.pump(const Duration(milliseconds: 350));
      await action;
      expect(text, 'New task');
      controls = ui.snapshot();
      action = ui.execute({
        'id': controls.singleWhere((c) => c['label'] == 'Save')['id'],
        'value': '',
      });
      await tester.pump(const Duration(milliseconds: 350));
      await action;
      expect(clicks, 1);
      action = ui.execute({'id': 'open:tasks', 'value': ''});
      await tester.pump(const Duration(milliseconds: 350));
      await action;
      expect(navigation, ['tasks']);
      active = false;
      expect(ui.snapshot(), isEmpty);
      await expectLater(ui.execute({'id': 'open:chat'}), throwsStateError);
    },
  );

  testWidgets('stale controls and controls behind a modal cannot execute', (
    tester,
  ) async {
    late BuildContext root;
    var clicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            root = context;
            return Scaffold(
              body: TextButton(
                onPressed: () => clicks++,
                child: const Text('Behind'),
              ),
            );
          },
        ),
      ),
    );
    final ui = UiActions(
      root: () => root,
      active: () => true,
      navigate: (_) {},
    );
    final old = ui.snapshot().singleWhere((c) => c['label'] == 'Behind')['id'];
    showDialog<void>(
      context: root,
      builder: (_) => const AlertDialog(
        title: Text('Modal'),
        actions: [TextButton(onPressed: null, child: Text('Wait'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(ui.snapshot().where((c) => c['label'] == 'Behind'), isEmpty);
    await expectLater(ui.execute({'id': old}), throwsStateError);
    expect(clicks, 0);
  });
}
