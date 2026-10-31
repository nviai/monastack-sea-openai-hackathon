import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';
import 'package:monastack/shared/utc_time.dart';

class Meetings extends ConsumerStatefulWidget {
  const Meetings({
    super.key,
    required this.request,
    required this.rooms,
    required this.identity,
  });
  final NodeRequest request;
  final List<Map<String, dynamic>> rooms;
  final String? identity;
  @override
  ConsumerState<Meetings> createState() => _MeetingsState();
}

class _MeetingsState extends ConsumerState<Meetings> {
  List<dynamic> items = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result =
          await widget.request('GET', '/v1/meetings') as List<dynamic>;
      if (mounted) {
        setState(() {
          items = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          items = [];
          error = 'Could not load meetings.';
        });
      }
    }
  }

  Future<void> create() async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _MeetingForm(rooms: widget.rooms),
    );
    if (data == null) return;
    try {
      await widget.request('POST', '/v1/meetings', {
        'id': const Uuid().v4(),
        'op': const Uuid().v4(),
        ...data,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the meeting was saved. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> cancel(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel meeting?'),
        content: Text(item['title'] as String),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm cancellation'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.request(
        'POST',
        '/v1/meetings/${Uri.encodeComponent(item['id'] as String)}/cancel',
        {'expected_version': item['version'], 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm cancellation. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> reschedule(Map<String, dynamic> item) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _MeetingForm(rooms: widget.rooms, existing: item),
    );
    if (data == null) return;
    data.remove('scope');
    try {
      await widget.request(
        'POST',
        '/v1/meetings/${Uri.encodeComponent(item['id'] as String)}',
        {...data, 'expected_version': item['version'], 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the change. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/meetings/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Meeting history'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: events
                  .map((e) => Text('${e['actor']} · ${e['action']}'))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not load meeting history.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 780,
      height: 600,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Meetings',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: load,
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Times are UTC. Room-scoped meetings follow current room access. No invitations or voice are sent.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            TextButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('Schedule meeting'),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('No accessible meetings.'))
                  : ListView(
                      children: items.map((v) {
                        final item = v as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(item['title'] as String),
                            subtitle: Text(
                              '${formatUtc(item['starts'] as int)} – ${formatUtc(item['ends'] as int)}\n${item['scope']} · ${item['state']} · ${item['creator']}',
                            ),
                            isThreeLine: true,
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                if (item['creator'] == widget.identity &&
                                    item['state'] == 'scheduled')
                                  TextButton(
                                    onPressed: () => reschedule(item),
                                    child: const Text('Reschedule'),
                                  ),
                                if (item['creator'] == widget.identity &&
                                    item['state'] == 'scheduled')
                                  TextButton(
                                    onPressed: () => cancel(item),
                                    child: const Text('Cancel meeting'),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MeetingForm extends StatefulWidget {
  const _MeetingForm({required this.rooms, this.existing});
  final List<Map<String, dynamic>> rooms;
  final Map<String, dynamic>? existing;
  @override
  State<_MeetingForm> createState() => _MeetingFormState();
}

class _MeetingFormState extends State<_MeetingForm> {
  final title = TextEditingController(),
      starts = TextEditingController(),
      ends = TextEditingController();
  String scope = 'workspace';
  String? error;
  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    if (item != null) {
      title.text = item['title'] as String;
      starts.text = formatUtc(item['starts'] as int).replaceFirst(' UTC', '');
      ends.text = formatUtc(item['ends'] as int).replaceFirst(' UTC', '');
      scope = item['scope'] as String;
    }
  }

  @override
  void dispose() {
    title.dispose();
    starts.dispose();
    ends.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Schedule meeting' : 'Reschedule meeting',
    ),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: scope,
            decoration: const InputDecoration(labelText: 'Visibility'),
            items: [
              const DropdownMenuItem(
                value: 'workspace',
                child: Text('Workspace'),
              ),
              ...widget.rooms.map(
                (r) => DropdownMenuItem(
                  value: 'room:${r['id']}',
                  child: Text('${r['name']} room'),
                ),
              ),
            ],
            onChanged: widget.existing == null
                ? (value) => setState(() => scope = value ?? 'workspace')
                : null,
          ),
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: starts,
            decoration: const InputDecoration(
              labelText: 'Start UTC (YYYY-MM-DD HH:MM)',
            ),
          ),
          TextField(
            controller: ends,
            decoration: const InputDecoration(
              labelText: 'End UTC (YYYY-MM-DD HH:MM)',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Back'),
      ),
      FilledButton(
        onPressed: () {
          final start = parseUtc(starts.text), end = parseUtc(ends.text);
          if (title.text.trim().isEmpty ||
              start == null ||
              end == null ||
              start < 946684800 ||
              end > 4102444800 ||
              end <= start ||
              end - start > 604800) {
            setState(
              () => error = 'Enter a valid UTC range of up to seven days between 2000 and 2100.',
            );
            return;
          }
          Navigator.pop(context, {
            'scope': scope,
            'title': title.text.trim(),
            'starts': start,
            'ends': end,
          });
        },
        child: Text(widget.existing == null ? 'Schedule' : 'Save changes'),
      ),
    ],
  );
}
