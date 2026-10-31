import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

class SalesPipeline extends ConsumerStatefulWidget {
  const SalesPipeline({super.key, required this.request});
  final NodeRequest request;
  @override
  ConsumerState<SalesPipeline> createState() => _SalesPipelineState();
}

class _SalesPipelineState extends ConsumerState<SalesPipeline> {
  List<dynamic> items = [], customers = [];
  String? error;
  bool refreshing = false, refreshAgain = false;
  Timer? timer;
  bool loading = true;
  bool canManage = false;
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
      final result = await Future.wait([
        widget.request('GET', '/v1/opportunities'),
        widget.request('GET', '/v1/customers'),
        widget.request('GET', '/v1/sales/capabilities'),
      ]);
      if (mounted) {
        setState(() {
          items = result[0] as List<dynamic>;
          customers = result[1] as List<dynamic>;
          canManage = (result[2] as Map<String, dynamic>)['can_manage'] == true;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          items = [];
          customers = [];
          canManage = false;
          loading = false;
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

  Future<void> create() async {
    if (customers.isEmpty) {
      setState(() => error = 'Create a customer first.');
      return;
    }
    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _OpportunityForm(customers: customers),
    );
    if (data == null) return;
    try {
      await widget.request('POST', '/v1/opportunities', {
        'id': const Uuid().v4(),
        'op': const Uuid().v4(),
        ...data,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the save. Refresh and check before retrying. Sales access is required to write.',
        );
      }
    }
  }

  Future<void> move(Map<String, dynamic> item, String to) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move to $to?'),
        content: Text('${item['title']} · ${item['customer_name']}'),
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
        '/v1/opportunities/${Uri.encodeComponent(item['id'] as String)}/transition',
        {
          'to': to,
          'expected_version': item['version'],
          'op': const Uuid().v4(),
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the change. Refresh and check before retrying. Sales access is required to write.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/opportunities/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Opportunity history'),
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
        setState(() => error = 'Could not load opportunity history.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 800,
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
                    'Sales pipeline',
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
              'Sales and admins can update; support can view. No messages or contracts are sent.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (!loading && canManage && customers.isNotEmpty)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('Opportunity'),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? const Center(child: Text('No accessible opportunities.'))
                  : ListView(
                      children: items.map((v) {
                        final item = v as Map<String, dynamic>;
                        final stage = item['stage'] as String;
                        final next = switch (stage) {
                          'lead' => 'qualified',
                          'qualified' => 'proposal',
                          'proposal' => 'won',
                          _ => null,
                        };
                        return Card(
                          child: ListTile(
                            title: Text(item['title'] as String),
                            subtitle: Text('${item['customer_name']} · $stage'),
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                if (canManage && next != null)
                                  TextButton(
                                    onPressed: () => move(item, next),
                                    child: Text('Move to $next'),
                                  ),
                                if (canManage && next != null)
                                  TextButton(
                                    onPressed: () => move(item, 'lost'),
                                    child: const Text('Mark lost'),
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

class _OpportunityForm extends StatefulWidget {
  const _OpportunityForm({required this.customers});
  final List<dynamic> customers;
  @override
  State<_OpportunityForm> createState() => _OpportunityFormState();
}

class _OpportunityFormState extends State<_OpportunityForm> {
  final title = TextEditingController();
  String? customer, error;
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New opportunity'),
    content: SizedBox(
      width: 420,
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
                    child: Text(
                      c['name'] as String,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => customer = value),
          ),
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Opportunity title'),
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
          if (customer == null || title.text.trim().isEmpty) {
            setState(() => error = 'Choose a customer and enter a title.');
            return;
          }
          Navigator.pop(context, {
            'customer': customer!,
            'title': title.text.trim(),
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
