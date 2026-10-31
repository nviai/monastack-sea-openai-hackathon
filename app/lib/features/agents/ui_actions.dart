import 'package:flutter/material.dart';

/// Session-local capabilities backed by the visible Flutter controls.
class UiActions {
  UiActions({
    required this.root,
    required this.active,
    required this.navigate,
    this.extraActions,
  });
  final BuildContext Function() root;
  final bool Function() active;
  final void Function(String) navigate;
  final Map<String, VoidCallback> Function()? extraActions;
  final Map<String, void Function(String)> _actions = {};
  static const screens = [
    'tasks',
    'chat',
    'agent-chat',
    'agent-configuration',
    'agents',
    'notifications',
    'documents',
    'customers',
    'sales',
    'contracts',
    'bookings',
    'support',
    'meetings',
    'whiteboard',
    'expenses',
    'journals',
    'payments',
    'incidents',
    'leave',
    'account',
    'people',
    'company',
    'room-admin',
    'inference',
    'agent:mona',
    'agent:dev-agent',
    'agent:qa-agent',
    'agent:pm-agent',
    'agent:sales-agent',
    'agent:cskh-agent',
  ];

  String label(Element element) {
    final parts = <String>[];
    void visit(Element e) {
      if (parts.length >= 6) return;
      if (e.widget is Text) {
        final w = e.widget as Text;
        final value = w.data ?? w.textSpan?.toPlainText() ?? '';
        if (value.trim().isNotEmpty) parts.add(value.trim());
      }
      e.visitChildren(visit);
    }

    visit(element);
    return parts.join(' ').substring(0, parts.join(' ').length.clamp(0, 160));
  }

  List<Map<String, String>> snapshot() {
    _actions.clear();
    if (!active()) return [];
    final result = <Map<String, String>>[];
    for (final screen in screens) {
      final id = 'open:$screen';
      _actions[id] = (_) => navigate(screen);
      result.add({'id': id, 'label': 'Open $screen', 'kind': 'navigate'});
    }
    for (final entry
        in (extraActions?.call() ?? <String, VoidCallback>{}).entries) {
      final id = 'extra:${entry.key}';
      _actions[id] = (_) => entry.value();
      result.add({'id': id, 'label': entry.key, 'kind': 'navigate'});
    }
    void add(
      Element e,
      String name,
      String kind,
      void Function(String) run, [
      String suffix = '',
    ]) {
      if (name.isEmpty || result.length >= 150) return;
      final route = ModalRoute.of(e);
      if (route != null && !route.isCurrent) return;
      var scope = '';
      e.visitAncestorElements((ancestor) {
        if (ancestor.widget is Card) {
          scope = label(ancestor);
          return false;
        }
        return true;
      });
      if (scope.isNotEmpty && scope != name) name = '$name · $scope';
      final id = '${identityHashCode(e)}:${name.hashCode}:$kind:$suffix';
      _actions[id] = run;
      result.add({'id': id, 'label': name, 'kind': kind});
    }

    void visit(Element e) {
      if (!e.mounted || e.widget.runtimeType.toString() == 'AgentChat') return;
      if (e.widget is Offstage && (e.widget as Offstage).offstage) return;
      final render = e.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        final origin = render.localToGlobal(Offset.zero);
        final viewport = Offset.zero & MediaQuery.sizeOf(root());
        if (!(origin & render.size).overlaps(viewport)) return;
      }
      final w = e.widget;
      if (w is ButtonStyleButton && w.onPressed != null) {
        add(e, label(e), 'click', (_) => w.onPressed!());
        return;
      }
      if (w is IconButton && w.onPressed != null) {
        add(e, w.tooltip ?? label(e), 'click', (_) => w.onPressed!());
        return;
      }
      if (w is TextField &&
          !w.obscureText &&
          w.enabled != false &&
          !w.readOnly) {
        EditableTextState? editable;
        void locate(Element child) {
          if (child is StatefulElement && child.state is EditableTextState) {
            editable = child.state as EditableTextState;
          }
          child.visitChildren(locate);
        }

        e.visitChildren(locate);
        if (editable != null) {
          add(
            e,
            w.decoration?.labelText ?? w.decoration?.hintText ?? 'Text input',
            'fill',
            (value) {
              if (w.maxLength != null &&
                  value.characters.length > w.maxLength!) {
                throw StateError('Input too long');
              }
              editable!.userUpdateTextEditingValue(
                TextEditingValue(
                  text: value,
                  selection: TextSelection.collapsed(offset: value.length),
                ),
                SelectionChangedCause.keyboard,
              );
            },
          );
        }
        return;
      }
      if (w is DropdownButton<dynamic> && w.onChanged != null) {
        for (final item in w.items ?? <DropdownMenuItem<dynamic>>[]) {
          if (!item.enabled) continue;
          final text = item.child is Text
              ? (item.child as Text).data ?? ''
              : item.value.toString();
          add(
            e,
            'Select $text',
            'click',
            (_) => w.onChanged!(item.value),
            item.value.toString(),
          );
        }
        return;
      }
      if (w is Switch && w.onChanged != null) {
        add(
          e,
          'Switch ${w.value ? "off" : "on"}',
          'click',
          (_) => w.onChanged!(!w.value),
        );
      }
      if (w is Checkbox && w.onChanged != null) {
        add(
          e,
          'Checkbox ${w.value == true ? "off" : "on"}',
          'click',
          (_) => w.onChanged!(w.value != true),
        );
      }
      if (w is ListTile && w.onTap != null) {
        add(e, label(e), 'click', (_) => w.onTap!());
        return;
      }
      if (w is InkWell && w.onTap != null) {
        add(e, label(e), 'click', (_) => w.onTap!());
        return;
      }
      if (e is StatefulElement && e.state is ScrollableState) {
        final position = (e.state as ScrollableState).position;
        if (position.hasContentDimensions && position.maxScrollExtent > 0) {
          for (final direction in [-1, 1]) {
            add(
              e,
              'Scroll ${position.axis == Axis.vertical ? (direction < 0 ? "up" : "down") : (direction < 0 ? "left" : "right")}',
              'click',
              (_) => position.jumpTo(
                (position.pixels + direction * position.viewportDimension * .75)
                    .clamp(position.minScrollExtent, position.maxScrollExtent),
              ),
              '$direction',
            );
          }
        }
      }
      e.visitChildren(visit);
    }

    (Navigator.of(root(), rootNavigator: true).context as Element)
        .visitChildren(visit);
    return result;
  }

  Future<String> execute(Map<String, dynamic> command) async {
    if (!active()) throw StateError('Session ended');
    snapshot(); // Resolve against current controls, not captured callbacks from an old screen.
    final run = _actions[command['id']];
    if (run == null) throw StateError('Control is unavailable; refresh the UI');
    final value = command['value'] as String? ?? '';
    if (value.length > 16000) throw StateError('Input too long');
    run(value);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return 'Control invoked. Inspect the next screen to verify the outcome.';
  }
}
