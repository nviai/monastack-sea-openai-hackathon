import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';
import 'finance_dialog_guard.dart';

class PaymentAuthorizations extends ConsumerStatefulWidget {
  const PaymentAuthorizations({
    super.key,
    required this.request,
    required this.identity,
  });
  final TaskRequest request;
  final String? identity;
  @override
  ConsumerState<PaymentAuthorizations> createState() =>
      _PaymentAuthorizationsState();
}

class _PaymentAuthorizationsState extends ConsumerState<PaymentAuthorizations> {
  List<dynamic> payments = [], expenses = [];
  String? error;
  bool loading = true;
  bool canApprove = false;
  bool refreshing = false, refreshAgain = false;
  final accessEpoch = ValueNotifier<int>(0);
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
      final result = await Future.wait([
        widget.request('GET', '/v1/payment-authorizations'),
        widget.request('GET', '/v1/expenses'),
        widget.request('GET', '/v1/finance/capabilities'),
      ]);
      if (mounted) {
        final nextCanApprove =
            (result[2] as Map<String, dynamic>)['can_approve'] == true;
        if (canApprove && !nextCanApprove) accessEpoch.value++;
        setState(() {
          payments = result[0] as List<dynamic>;
          canApprove = nextCanApprove;
          final active = payments
              .where(
                (p) =>
                    p['state'] == 'pending' || p['state'] == 'approved_waiting',
              )
              .map((p) => p['expense'])
              .toSet();
          expenses = (result[1] as List<dynamic>)
              .where(
                (e) => e['state'] == 'approved' && !active.contains(e['id']),
              )
              .toList();
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        accessEpoch.value++;
        setState(() {
          payments = [];
          expenses = [];
          canApprove = false;
          loading = false;
          error = 'Finance access denied or node unavailable.';
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
    accessEpoch.value++;
    accessEpoch.dispose();
    super.dispose();
  }

  Future<void> create() async {
    if (expenses.isEmpty) {
      setState(
        () => error =
            'An approved expense without an active authorization is required.',
      );
      return;
    }
    final epoch = accessEpoch.value;
    final id = await showDialog<String>(
      context: context,
      builder: (_) => guardFinanceDialog(
        accessEpoch,
        epoch,
        _PaymentForm(expenses: expenses),
      ),
    );
    if (id == null || !mounted || epoch != accessEpoch.value) return;
    try {
      await widget.request('POST', '/v1/payment-authorizations', {
        'id': const Uuid().v4(),
        'expense': id,
        'op': const Uuid().v4(),
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the request. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> decide(Map<String, dynamic> item, String action) async {
    final epoch = accessEpoch.value;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => guardFinanceDialog(
        accessEpoch,
        epoch,
        AlertDialog(
          title: Text(
            '${action == 'approve'
                ? 'Approve'
                : action == 'reject'
                ? 'Reject'
                : action == 'revoke'
                ? 'Revoke'
                : 'Withdraw'} authorization?',
          ),
          content: Text(
            '${item['description']} · ${item['minor']} minor units ${item['currency']}\nThis records an internal decision only. No payment is made.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
    if (yes != true || !mounted || epoch != accessEpoch.value) return;
    try {
      await widget.request(
        'POST',
        '/v1/payment-authorizations/${Uri.encodeComponent(item['id'] as String)}/decision',
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
          () => error = 'Could not confirm the decision. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    final epoch = accessEpoch.value;
    try {
      final events = await widget.request(
        'GET',
        '/v1/payment-authorizations/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted || epoch != accessEpoch.value) return;
      await showDialog<void>(
        context: context,
        builder: (context) => guardFinanceDialog(
          accessEpoch,
          epoch,
          AlertDialog(
            title: const Text('Authorization history'),
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
        ),
      );
    } catch (_) {
      if (mounted && accessEpoch.value == epoch) {
        setState(() => error = 'Could not load history.');
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
                    'Payment authorizations',
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
              'Internal approvals only. No bank connection, beneficiary, payment execution or transfer is configured.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (!loading && error == null)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('Request authorization'),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : payments.isEmpty
                  ? const Center(child: Text('No accessible authorizations.'))
                  : ListView(
                      children: payments.map((v) {
                        final item = v as Map<String, dynamic>;
                        final state = item['state'] as String;
                        final canDecide =
                            canApprove &&
                            widget.identity != item['requester'] &&
                            widget.identity != item['expense_creator'];
                        return Card(
                          child: ListTile(
                            title: Text(item['description'] as String),
                            subtitle: Text(
                              '${item['minor']} minor units · ${item['currency']} · ${state == 'approved_waiting' ? 'Approved, no payment executed' : state}\nRequested by ${item['requester']}',
                            ),
                            isThreeLine: true,
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                if (state == 'pending' &&
                                    item['requester'] == widget.identity)
                                  TextButton(
                                    onPressed: () => decide(item, 'withdraw'),
                                    child: const Text('Withdraw'),
                                  ),
                                if (state == 'pending' && canDecide) ...[
                                  TextButton(
                                    onPressed: () => decide(item, 'approve'),
                                    child: const Text('Approve'),
                                  ),
                                  TextButton(
                                    onPressed: () => decide(item, 'reject'),
                                    child: const Text('Reject'),
                                  ),
                                ],
                                if (state == 'approved_waiting' && canDecide)
                                  TextButton(
                                    onPressed: () => decide(item, 'revoke'),
                                    child: const Text('Revoke'),
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

class _PaymentForm extends StatefulWidget {
  const _PaymentForm({required this.expenses});
  final List<dynamic> expenses;
  @override
  State<_PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<_PaymentForm> {
  String? selected;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Request payment authorization'),
    content: SizedBox(
      width: 440,
      child: DropdownButtonFormField<String>(
        initialValue: selected,
        decoration: const InputDecoration(labelText: 'Approved expense'),
        items: widget.expenses
            .map(
              (e) => DropdownMenuItem<String>(
                value: e['id'] as String,
                child: Text(
                  '${e['description']} · ${e['minor']} ${e['currency']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: (v) => setState(() => selected = v),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Back'),
      ),
      FilledButton(
        onPressed: selected == null
            ? null
            : () => Navigator.pop(context, selected),
        child: const Text('Request'),
      ),
    ],
  );
}
