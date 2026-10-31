import 'package:monastack/shared/workspace_theme.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

class Incidents extends ConsumerStatefulWidget {
  const Incidents({super.key, required this.request, required this.identity});
  final NodeRequest request;
  final String? identity;
  @override
  ConsumerState<Incidents> createState() => _IncidentsState();
}

class _IncidentsState extends ConsumerState<Incidents> {
  List<dynamic> items = [];
  String? error;
  bool loading = true;
  bool refreshing = false;
  bool refreshAgain = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  Future<void> load() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    try {
      final result =
          await widget.request('GET', '/v1/incidents') as List<dynamic>;
      if (mounted) {
        setState(() {
          items = result;
          error = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          items = [];
          error = 'Could not load incidents.';
          loading = false;
        });
      }
    } finally {
      refreshing = false;
      if (mounted && refreshAgain) {
        refreshAgain = false;
        unawaited(load());
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> create() async {
    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _ReportForm(),
    );
    if (data == null) return;
    try {
      await widget.request('POST', '/v1/incidents', {
        'id': const Uuid().v4(),
        'op': const Uuid().v4(),
        ...data,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the report was saved. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> transition(Map<String, dynamic> item, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          action == 'investigate'
              ? 'Start investigation?'
              : 'Resolve incident?',
        ),
        content: Text(item['title'] as String),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.request(
        'POST',
        '/v1/incidents/${Uri.encodeComponent(item['id'] as String)}/transition',
        {
          'action': action,
          'expected_version': item['version'],
          'op': const Uuid().v4(),
        },
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
        '/v1/incidents/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Incident history'),
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
      if (mounted) setState(() => error = 'Could not load incident history.');
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    child: SizedBox(
      width: 760,
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
                    'Incidents',
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
              'Reports are visible to their reporter and explicitly authorized operations responders.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            TextButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('Report incident'),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? const Center(child: Text('No accessible incidents.'))
                  : ListView(
                      children: items.map((value) {
                        final item = value as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(item['title'] as String),
                            subtitle: Text(
                              '${item['severity']} · ${item['state']} · ${item['reporter']}\n${item['description']}',
                            ),
                            isThreeLine: true,
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                TextButton(
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (_) => _IncidentComments(
                                      request: widget.request,
                                      incident: item['id'] as String,
                                    ),
                                  ),
                                  child: const Text('Discussion'),
                                ),
                                if (item['reporter'] != widget.identity &&
                                    item['state'] == 'open')
                                  TextButton(
                                    onPressed: () =>
                                        transition(item, 'investigate'),
                                    child: const Text('Investigate'),
                                  ),
                                if (item['reporter'] != widget.identity &&
                                    item['state'] == 'investigating')
                                  TextButton(
                                    onPressed: () =>
                                        transition(item, 'resolve'),
                                    child: const Text('Resolve'),
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

class _IncidentComments extends StatefulWidget {
  const _IncidentComments({required this.request, required this.incident});
  final NodeRequest request;
  final String incident;
  @override
  State<_IncidentComments> createState() => _IncidentCommentsState();
}

class _IncidentCommentsState extends State<_IncidentComments> {
  final body = TextEditingController();
  List<dynamic> comments = [];
  Timer? timer;
  bool loading = true,
      refreshing = false,
      refreshAgain = false,
      sending = false;
  String? error, pendingBody, pendingId, pendingOp;
  String get path =>
      '/v1/incidents/${Uri.encodeComponent(widget.incident)}/comments';

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  Future<void> load() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    try {
      final result = await widget.request('GET', path) as List<dynamic>;
      if (mounted) {
        setState(() {
          comments = result;
          error = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          comments = [];
          error = 'Discussion unavailable or access removed.';
          loading = false;
        });
      }
    } finally {
      refreshing = false;
      if (mounted && refreshAgain) {
        refreshAgain = false;
        unawaited(load());
      }
    }
  }

  Future<void> send() async {
    final content = body.text.trim();
    if (sending || content.isEmpty) return;
    if (pendingBody != content) {
      pendingBody = content;
      pendingId = const Uuid().v4();
      pendingOp = const Uuid().v4();
    }
    setState(() => sending = true);
    try {
      await widget.request('POST', path, {
        'id': pendingId,
        'op': pendingOp,
        'body': content,
      });
      if (!mounted) return;
      if (body.text.trim() == content) body.clear();
      pendingBody = pendingId = pendingOp = null;
      await load();
    } catch (_) {
      if (mounted) {
        setState(() {
          comments = [];
          error = 'Could not confirm the comment. Retry unchanged or refresh.';
        });
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Incident discussion'),
    content: SizedBox(
      width: 500,
      height: 350,
      child: Column(
        children: [
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: comments
                        .map(
                          (c) => ListTile(
                            title: Text(c['author'] as String),
                            subtitle: Text(c['body'] as String),
                          ),
                        )
                        .toList(),
                  ),
          ),
          TextField(
            controller: body,
            maxLength: 2000,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Update'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: load, child: const Text('Refresh')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: sending ? null : send,
        child: const Text('Post update'),
      ),
    ],
  );
}

class _ReportForm extends StatefulWidget {
  const _ReportForm();
  @override
  State<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<_ReportForm> {
  final title = TextEditingController();
  final description = TextEditingController();
  String severity = 'medium';
  String? error;
  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Report incident'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: description,
            maxLength: 4000,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: severity,
            decoration: const InputDecoration(labelText: 'Severity'),
            items: ['low', 'medium', 'high', 'critical']
                .map(
                  (s) => DropdownMenuItem(
                    value: s,
                    child: Text(
                      s,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (s) => setState(() => severity = s ?? 'medium'),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (title.text.trim().isEmpty || description.text.trim().isEmpty) {
            setState(() => error = 'Enter a title and description.');
            return;
          }
          Navigator.pop(context, {
            'title': title.text.trim(),
            'description': description.text.trim(),
            'severity': severity,
          });
        },
        child: const Text('Submit'),
      ),
    ],
  );
}
