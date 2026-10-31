import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

class CustomerDirectory extends ConsumerStatefulWidget {
  const CustomerDirectory({super.key, required this.request});
  final NodeRequest request;
  @override
  ConsumerState<CustomerDirectory> createState() => _CustomerDirectoryState();
}

class _CustomerDirectoryState extends ConsumerState<CustomerDirectory> {
  List<dynamic> records = [];
  String? error;
  bool refreshing = false, refreshAgain = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    try {
      final list =
          await widget.request('GET', '/v1/customers') as List<dynamic>;
      if (mounted) {
        setState(() {
          records = list;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          records = [];
          error = 'Customer access denied or node unavailable.';
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

  Future<void> edit([Map<String, dynamic>? existing]) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _CustomerEditor(existing: existing),
    );
    if (result == null) return;
    try {
      final uuid = const Uuid();
      if (existing == null) {
        await widget.request('POST', '/v1/customers', {
          'id': uuid.v4(),
          'op': uuid.v4(),
          ...result,
        });
      } else {
        await widget.request(
          'POST',
          '/v1/customers/${Uri.encodeComponent(existing['id'] as String)}',
          {'op': uuid.v4(), 'expected_version': existing['version'], ...result},
        );
      }
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Save denied, offline, or record changed. Refresh before retrying.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 700,
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
                    'Customers',
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
              'Sales, support and admin access · local prototype · no messages are sent',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (error == null)
              TextButton.icon(
                onPressed: () => edit(),
                icon: const Icon(Icons.add),
                label: const Text('Customer'),
              ),
            Expanded(
              child: records.isEmpty
                  ? const Center(child: Text('No accessible customer records.'))
                  : ListView(
                      children: records
                          .map(
                            (c) => Card(
                              child: ListTile(
                                title: Text(c['name'] as String),
                                subtitle: Text(c['email'] as String),
                                trailing: const Icon(Icons.edit_outlined),
                                onTap: () => edit(c as Map<String, dynamic>),
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

class _CustomerEditor extends StatefulWidget {
  const _CustomerEditor({this.existing});
  final Map<String, dynamic>? existing;
  @override
  State<_CustomerEditor> createState() => _CustomerEditorState();
}

class _CustomerEditorState extends State<_CustomerEditor> {
  late final TextEditingController name, email, notes;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.existing?['name'] as String?);
    email = TextEditingController(text: widget.existing?['email'] as String?);
    notes = TextEditingController(text: widget.existing?['notes'] as String?);
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'New customer' : 'Edit customer'),
    content: SizedBox(
      width: 450,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: email,
            maxLength: 320,
            decoration: const InputDecoration(labelText: 'Email (optional)'),
          ),
          TextField(
            controller: notes,
            maxLength: 4000,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notes'),
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
          if (name.text.trim().isNotEmpty) {
            Navigator.pop(context, {
              'name': name.text.trim(),
              'email': email.text.trim(),
              'notes': notes.text,
            });
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
