import 'package:flutter/material.dart';

import '../domain/chat_client.dart';

class LegacyHistory extends StatefulWidget {
  const LegacyHistory({
    super.key,
    required this.client,
    required this.scope,
    this.room,
  });
  final ChatClient client;
  final String scope;
  final String? room;
  @override
  State<LegacyHistory> createState() => _LegacyHistoryState();
}

class _LegacyHistoryState extends State<LegacyHistory> {
  List<Map<String, dynamic>> messages = [];
  bool loading = true, older = true;
  String? error, before;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    widget.client.addListener(changed);
    load();
  }

  void changed() {
    final office = widget.scope.startsWith('room:')
        ? widget.scope.substring(5)
        : null;
    if ((widget.room != null &&
            !widget.client.rooms.any((r) => r.id == widget.room)) ||
        (office != null &&
            !widget.client.rooms.any((r) => r.officeRoom == office))) {
      generation++;
      setState(() {
        messages = [];
        error = 'History unavailable or access denied.';
        loading = false;
        older = false;
      });
    }
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.client.legacy(widget.scope, before: before);
      if (!mounted || request != generation) return;
      setState(() {
        messages.addAll(page);
        older = page.length == 50;
        if (page.isNotEmpty) before = page.last['created'].toString();
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          messages = [];
          error = 'History unavailable or access denied.';
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    widget.client.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Earlier messages (before Matrix)'),
    content: SizedBox(
      width: 600,
      height: 460,
      child: Column(
        children: [
          const Text('Read-only history. New messages are sent in Chat.'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (loading) const LinearProgressIndicator(),
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('No earlier messages.'))
                : ListView(
                    children: [
                      for (final message in messages)
                        ListTile(
                          title: SelectableText(message['body'] as String),
                          subtitle: Text(
                            '${message['sender_name']} · ${message['created']}',
                          ),
                        ),
                    ],
                  ),
          ),
          if (older || error != null)
            TextButton(
              onPressed: loading ? null : load,
              child: Text(
                error == null ? 'Load older messages' : 'Retry history',
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
