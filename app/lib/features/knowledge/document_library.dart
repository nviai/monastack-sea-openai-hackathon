import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

class DocumentLibrary extends ConsumerStatefulWidget {
  const DocumentLibrary({
    super.key,
    required this.request,
    required this.rooms,
  });
  final NodeRequest request;
  final List<Map<String, dynamic>> rooms;
  @override
  ConsumerState<DocumentLibrary> createState() => _DocumentLibraryState();
}

class _DocumentLibraryState extends ConsumerState<DocumentLibrary> {
  final search = TextEditingController();
  List<dynamic> docs = [];
  String? error;
  bool refreshing = false;
  Timer? refreshTimer;
  @override
  void initState() {
    super.initState();
    load();
    refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final list = await widget.request(
        'GET',
        '/v1/documents?q=${Uri.encodeQueryComponent(search.text.trim())}',
      ) as List<dynamic>;
      if (mounted) {
        setState(() {
          docs = list;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          docs = [];
          error = 'Could not load documents.';
        });
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> edit([Map<String, dynamic>? existing]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) =>
          _DocumentEditor(rooms: widget.rooms, existing: existing),
    );
    if (result == null) return;
    try {
      final uuid = const Uuid();
      if (existing == null) {
        await widget.request('POST', '/v1/documents', {
          'id': uuid.v4(),
          'op': uuid.v4(),
          ...result,
        });
      } else {
        await widget.request(
          'POST',
          '/v1/documents/${Uri.encodeComponent(existing['id'] as String)}',
          {
            'op': uuid.v4(),
            'title': result['title'],
            'body': result['body'],
            'expected_version': existing['version'],
          },
        );
      }
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm the save. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> document) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/documents/${Uri.encodeComponent(document['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Document history'),
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
        setState(() => error = 'Could not load document history.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 720,
      height: 620,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Documents',
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
              'Server-readable · online only · room access applies',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: search,
                    onSubmitted: (_) => load(),
                    decoration: const InputDecoration(labelText: 'Search'),
                  ),
                ),
                IconButton(
                  onPressed: load,
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                ),
                TextButton.icon(
                  onPressed: () => edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Document'),
                ),
              ],
            ),
            Expanded(
              child: docs.isEmpty
                  ? const Center(child: Text('No documents found.'))
                  : ListView(
                      children: docs
                          .map(
                            (d) => Card(
                              child: ListTile(
                                title: Text(d['title'] as String),
                                subtitle: Text(
                                  '${d['scope']} · version ${d['version']}',
                                ),
                                trailing: TextButton(
                                  onPressed: () =>
                                      history(d as Map<String, dynamic>),
                                  child: const Text('History'),
                                ),
                                onTap: () => edit(d as Map<String, dynamic>),
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DocumentEditor extends StatefulWidget {
  const _DocumentEditor({required this.rooms, this.existing});
  final List<Map<String, dynamic>> rooms;
  final Map<String, dynamic>? existing;
  @override
  State<_DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends State<_DocumentEditor> {
  late final TextEditingController title;
  late final TextEditingController body;
  late String scope;
  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: widget.existing?['title'] as String?);
    body = TextEditingController(text: widget.existing?['body'] as String?);
    scope = widget.existing?['scope'] as String? ?? 'workspace';
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'New document' : 'Edit document'),
    content: SizedBox(
      width: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: scope,
            isExpanded: true,
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
                ? (v) {
                    if (v != null) setState(() => scope = v);
                  }
                : null,
          ),
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: body,
            maxLength: 100000,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'Text'),
          ),
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
          if (title.text.trim().isNotEmpty) {
            Navigator.pop(context, {
              'title': title.text.trim(),
              'body': body.text,
              'scope': scope,
            });
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
