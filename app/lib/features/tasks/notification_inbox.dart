import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:monastack/shared/node_request.dart';
import 'package:uuid/uuid.dart';

class NotificationInbox extends StatefulWidget {
  const NotificationInbox({
    super.key,
    required this.request,
    this.admin = false,
  });
  final NodeRequest request;
  final bool admin;
  @override
  State<NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<NotificationInbox> {
  List<dynamic> items = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.request('GET', '/v1/notifications') as List;
      if (mounted) {
        setState(() {
          items = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not load notifications.');
    }
  }

  Future<void> reply(Map item) async {
    var draft = '';
    final attachments = <Map<String, String>>[];
    String? attachmentError;
    final body = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(item['title'] as String),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (value) => draft = value,
                maxLines: 5,
                maxLength: 4000,
                decoration: const InputDecoration(labelText: 'Reply to ticket'),
              ),
              if (item['question'] != null)
                TextButton.icon(
                  icon: const Icon(Icons.attach_file),
                  label: Text(
                    'Attach file (${attachments.length}/4 · max 256 KiB each)',
                  ),
                  onPressed: attachments.length >= 4
                      ? null
                      : () async {
                          try {
                            final file = await openFile();
                            if (file == null) return;
                            if (await file.length() > 262144) {
                              update(
                                () => attachmentError = 'File exceeds 256 KiB.',
                              );
                              return;
                            }
                            final data = base64Encode(await file.readAsBytes());
                            update(() {
                              attachments.add({
                                'name': file.name,
                                'data': data,
                              });
                              attachmentError = null;
                            });
                          } catch (_) {
                            update(
                              () => attachmentError = 'Could not read file.',
                            );
                          }
                        },
                ),
              for (final file in attachments) Text(file['name']!),
              if (attachmentError != null) Text(attachmentError!),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, draft.trim()),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    if (body == null || body.isEmpty) return;
    try {
      if (item['question'] != null) {
        await widget.request(
          'POST',
          '/v1/workflow/questions/${Uri.encodeComponent(item['question'] as String)}/answer',
          {'body': body, 'attachments': attachments},
        );
      } else {
        await widget.request(
          'POST',
          '/v1/tasks/${Uri.encodeComponent(item['task'] as String)}/comments',
          {'id': const Uuid().v4(), 'op': const Uuid().v4(), 'body': body},
        );
      }
      await widget.request('POST', '/v1/notifications/${item['id']}/read', {});
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Reply could not be confirmed. Check the ticket before retrying.',
        );
      }
    }
  }

  Future<void> settings() async {
    try {
      final config =
          await widget.request('GET', '/v1/workflow/settings') as Map;
      if (!mounted) return;
      final channel = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('Delivery · ${config['channel']}'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'notification'),
              child: const Text('Ticket + notifications'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'voice'),
              child: const Text(
                'Voice in current room + notification fallback',
              ),
            ),
          ],
        ),
      );
      if (channel == null) return;
      await widget.request('POST', '/v1/workflow/settings', {
        'channel': channel,
      });
      await load();
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save delivery settings.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Notifications'),
    content: SizedBox(
      width: 520,
      height: 480,
      child: Column(
        children: [
          if (error != null) Text(error!),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No notifications yet'))
                : ListView(
                    children: items
                        .map(
                          (item) => Card(
                            child: ListTile(
                              leading: Icon(
                                item['read'] == true
                                    ? Icons.mark_email_read_outlined
                                    : Icons.notifications_active_outlined,
                              ),
                              title: Text(item['title'] as String),
                              subtitle: Text(item['body'] as String),
                              onTap: () => reply(item as Map),
                              trailing: IconButton(
                                tooltip: 'Mark read',
                                icon: const Icon(Icons.done),
                                onPressed: () async {
                                  try {
                                    await widget.request(
                                      'POST',
                                      '/v1/notifications/${item['id']}/read',
                                      {},
                                    );
                                    await load();
                                  } catch (_) {
                                    if (mounted) {
                                      setState(
                                        () => error =
                                            'Could not mark notification read.',
                                      );
                                    }
                                  }
                                },
                              ),
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
      if (widget.admin)
        TextButton(onPressed: settings, child: const Text('Delivery settings')),
      TextButton(onPressed: load, child: const Text('Refresh')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
