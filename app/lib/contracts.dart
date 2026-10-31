import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';

class Contracts extends ConsumerStatefulWidget {
  const Contracts({super.key, required this.request, required this.identity});
  final TaskRequest request;
  final String? identity;
  @override
  ConsumerState<Contracts> createState() => _ContractsState();
}

class _ContractsState extends ConsumerState<Contracts> {
  List<dynamic> items = [], customers = [];
  bool canDecide = false, busy = false, again = false, loading = true;
  String? error;
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
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    try {
      final result = await Future.wait([
        widget.request('GET', '/v1/contracts'),
        widget.request('GET', '/v1/customers'),
        widget.request('GET', '/v1/contracts/capabilities'),
      ]);
      if (mounted) {
        setState(() {
          items = result[0] as List<dynamic>;
          customers = result[1] as List<dynamic>;
          canDecide = (result[2] as Map<String, dynamic>)['can_decide'] == true;
          error = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          items = [];
          customers = [];
          canDecide = false;
          error = 'Sales access denied or node unavailable.';
          loading = false;
        });
      }
    } finally {
      busy = false;
      if (mounted && again) {
        again = false;
        unawaited(load());
      }
    }
  }

  Future<void> create() async {
    if (customers.isEmpty) {
      setState(() => error = 'Create a customer first.');
      return;
    }
    final proposal = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ProposalForm(customers: customers),
    );
    if (proposal == null) return;
    try {
      await widget.request('POST', '/v1/contracts', {
        'id': const Uuid().v4(),
        'op': const Uuid().v4(),
        ...proposal,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm save. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> decide(Map<String, dynamic> item, String action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${action == 'withdraw'
              ? 'Withdraw'
              : action == 'approve'
              ? 'Approve internally'
              : 'Reject'} proposal?',
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Text(
              '${item['title']} · ${item['customer_name']}\n\n${item['terms']}\n\nThis is an internal record, not a signature or binding agreement.',
            ),
          ),
        ),
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
    if (yes != true) return;
    try {
      await widget.request(
        'POST',
        '/v1/contracts/${Uri.encodeComponent(item['id'] as String)}/decision',
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
          () => error =
              'Could not confirm decision. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/contracts/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Proposal history'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
      if (mounted) setState(() => error = 'Could not load proposal history.');
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
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
                    'Contract proposals',
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
              'Internal review only. No agreement is signed or sent.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            TextButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('Propose contract'),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? const Center(child: Text('No contract proposals.'))
                  : ListView(
                      children: items.map((value) {
                        final item = value as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(item['title'] as String),
                            subtitle: Text(
                              '${item['customer_name']} · ${item['state']} · by ${item['creator']}\n${item['terms']}',
                            ),
                            isThreeLine: true,
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                if (item['state'] == 'proposed' &&
                                    item['creator'] == widget.identity)
                                  TextButton(
                                    onPressed: () => decide(item, 'withdraw'),
                                    child: const Text('Withdraw'),
                                  ),
                                if (item['state'] == 'proposed' &&
                                    item['creator'] != widget.identity &&
                                    canDecide) ...[
                                  TextButton(
                                    onPressed: () => decide(item, 'approve'),
                                    child: const Text('Approve internally'),
                                  ),
                                  TextButton(
                                    onPressed: () => decide(item, 'reject'),
                                    child: const Text('Reject'),
                                  ),
                                ],
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

class _ProposalForm extends StatefulWidget {
  const _ProposalForm({required this.customers});
  final List<dynamic> customers;
  @override
  State<_ProposalForm> createState() => _ProposalFormState();
}

class _ProposalFormState extends State<_ProposalForm> {
  final title = TextEditingController(), terms = TextEditingController();
  String? customer, error;
  @override
  void dispose() {
    title.dispose();
    terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Propose contract'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: customer,
            decoration: const InputDecoration(labelText: 'Customer'),
            items: widget.customers
                .map(
                  (c) => DropdownMenuItem<String>(
                    value: c['id'] as String,
                    child: Text(c['name'] as String),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => customer = value),
          ),
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: terms,
            maxLength: 4000,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Proposed terms'),
          ),
          const Text(
            'Terms are frozen when submitted; create a new proposal to change them.',
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
          if (customer == null ||
              title.text.trim().isEmpty ||
              terms.text.trim().isEmpty) {
            setState(
              () => error = 'Choose a customer and enter a title and terms.',
            );
            return;
          }
          Navigator.pop(context, {
            'customer': customer!,
            'title': title.text.trim(),
            'terms': terms.text.trim(),
          });
        },
        child: const Text('Submit'),
      ),
    ],
  );
}
