import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import 'chat_atoms.dart';

Future<void> showPersonPicker(
  BuildContext context,
  ChatController controller,
) async {
  final selected = <String>{};
  var query = '', busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final nx = context.nx;
        return AlertDialog(
          title: const Text('New direct message'),
          content: SizedBox(
            width: NxSize.personPickerW,
            height: NxSize.personPickerH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: NxSize.search,
                  child: FocusFrame(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NxSpace.s10,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, size: NxSize.icon, color: nx.ink3),
                          const SizedBox(width: NxSpace.s8),
                          Expanded(
                            child: TextField(
                              maxLines: 1,
                              style: nx.text(NexusTokens.t135),
                              cursorColor: nx.accent,
                              decoration: InputDecoration.collapsed(
                                hintText: 'Find a person',
                                hintStyle: nx.text(
                                  NexusTokens.t135,
                                  color: nx.ink3,
                                ),
                              ),
                              onChanged: (value) =>
                                  setState(() => query = value.toLowerCase()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: NxSpace.s8),
                  child: Text(
                    'Choose 1 to ${NxSize.maxPeople} people for a private conversation.',
                    style: nx.text(NexusTokens.t125, color: nx.ink2),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NxSpace.s8),
                    child: Text(
                      error!,
                      style: nx.text(
                        NexusTokens.t125,
                        weight: NexusTokens.w560,
                        color: nx.now,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final person in controller.client.people)
                        if (person.id != controller.client.userId &&
                            person.name.toLowerCase().contains(query))
                          CheckboxListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: NxSpace.s8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                NexusTokens.rSm,
                              ),
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: nx.accent,
                            checkColor: nx.onAccent,
                            value: selected.contains(person.actor),
                            secondary: NexusAvatar(
                              name: person.name,
                              size: NxSize.avatarSm,
                              radius: NxSize.avatarSmRadius,
                              fontSize: NexusTokens.t10,
                            ),
                            title: Text(
                              person.name,
                              style: nx.text(NexusTokens.t13),
                            ),
                            onChanged: busy
                                ? null
                                : (checked) => setState(() {
                                    if (checked == true &&
                                        selected.length < NxSize.maxPeople) {
                                      selected.add(person.actor);
                                    } else {
                                      selected.remove(person.actor);
                                    }
                                  }),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy || selected.isEmpty
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final room = await controller.client.directMessage(
                          selected.toList(),
                        );
                        await controller.select(room);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (context.mounted) {
                          setState(() {
                            busy = false;
                            error = 'Conversation could not be opened. Retry.';
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Opening…' : 'Open conversation'),
            ),
          ],
        );
      },
    ),
  );
}
