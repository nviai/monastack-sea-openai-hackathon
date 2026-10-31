import 'package:flutter/material.dart';

import '../application/chat_controller.dart';

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
      builder: (context, setState) => AlertDialog(
        title: const Text('New direct message'),
        content: SizedBox(
          width: 400,
          height: 380,
          child: Column(
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Find a person'),
                onChanged: (value) =>
                    setState(() => query = value.toLowerCase()),
              ),
              const Text('Choose 1 to 8 people for a private conversation.'),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: ListView(
                  children: [
                    for (final person in controller.client.people)
                      if (person.id != controller.client.userId &&
                          person.name.toLowerCase().contains(query))
                        CheckboxListTile(
                          value: selected.contains(person.actor),
                          title: Text(person.name),
                          onChanged: busy
                              ? null
                              : (checked) => setState(() {
                                  if (checked == true && selected.length < 8) {
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
      ),
    ),
  );
}
