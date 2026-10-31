import 'package:flutter/material.dart';

import 'task_outbox.dart';

class OutboxReview extends StatefulWidget {
  const OutboxReview({super.key, required this.delivery, this.chat = false});
  final TaskDelivery delivery;
  final bool chat;
  @override
  State<OutboxReview> createState() => _OutboxReviewState();
}

class _OutboxReviewState extends State<OutboxReview> {
  List<Map<String, dynamic>> entries = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.delivery.outbox.list();
      if (mounted) {
        setState(() {
          entries = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not read the local queue.');
    }
  }

  Future<void> discard(Map<String, dynamic> entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.chat
              ? 'Discard this queued message?'
              : 'Discard this task change?',
        ),
        content: const Text(
          'It will not be retried. It may already have reached the node; refresh before retrying. A local history record remains on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.delivery.outbox.mark(entry['op'] as String, 'discarded');
      await widget.delivery.updateView();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = 'Could not discard the change.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.chat ? 'Queued messages' : 'Task changes'),
    content: SizedBox(
      width: 520,
      height: 350,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.chat
                ? 'Messages are stored unencrypted on this device and retry in order. A rejection pauses later messages until discarded.'
                : 'Pending changes retry in order when connected. A rejection pauses later changes until it is discarded; refresh before recreating it.',
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('No pending changes.'))
                : ListView(
                    children: entries
                        .map(
                          (entry) => ListTile(
                            title: Text(
                              '${entry['state']} · ${entry['route']}',
                            ),
                            subtitle: Text(
                              '${((entry['body'] as Map<String, dynamic>)['title'] ?? (entry['body'] as Map<String, dynamic>)['name'] ?? (entry['body'] as Map<String, dynamic>)['to'] ?? (entry['body'] as Map<String, dynamic>)['body'] ?? 'Task change')}\n${entry['reason'] ?? 'Waiting for the node'}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: TextButton(
                              onPressed: () => discard(entry),
                              child: const Text('Discard'),
                            ),
                          ),
                        )
                        .toList(),
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
