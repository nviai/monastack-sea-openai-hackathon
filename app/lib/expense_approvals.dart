import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';
import 'finance_dialog_guard.dart';

class ExpenseApprovals extends ConsumerStatefulWidget {
  const ExpenseApprovals({super.key, required this.request, this.identity});
  final TaskRequest request;
  final String? identity;
  @override
  ConsumerState<ExpenseApprovals> createState() => _ExpenseApprovalsState();
}

class _ExpenseApprovalsState extends ConsumerState<ExpenseApprovals> {
  List<dynamic> expenses = [];
  String? error;
  bool refreshing = false, refreshAgain = false;
  bool canApprove = false;
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
        widget.request('GET', '/v1/expenses'),
        widget.request('GET', '/v1/finance/capabilities'),
      ]);
      if (mounted) {
        final nextCanApprove =
            (result[1] as Map<String, dynamic>)['can_approve'] == true;
        if (canApprove && !nextCanApprove) accessEpoch.value++;
        setState(() {
          expenses = result[0] as List<dynamic>;
          canApprove = nextCanApprove;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        accessEpoch.value++;
        setState(() {
          expenses = [];
          canApprove = false;
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
    final epoch = accessEpoch.value;
    final form = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) =>
          guardFinanceDialog(accessEpoch, epoch, const _ExpenseForm()),
    );
    if (form == null || !mounted || epoch != accessEpoch.value) return;
    try {
      const uuid = Uuid();
      await widget.request('POST', '/v1/expenses', {
        'id': uuid.v4(),
        'op': uuid.v4(),
        ...form,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm whether the expense was saved. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> decide(Map<String, dynamic> expense, String action) async {
    final epoch = accessEpoch.value;
    final confirmed = await showDialog<bool>(
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
                : 'Withdraw'} expense?',
          ),
          content: Text(
            '${expense['description']} · ${expense['minor']} minor units ${expense['currency']}\nThis records a decision only; no payment is made.',
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
      ),
    );
    if (confirmed != true || !mounted || epoch != accessEpoch.value) return;
    try {
      await widget.request(
        'POST',
        '/v1/expenses/${Uri.encodeComponent(expense['id'] as String)}/decision',
        {
          'action': action,
          'expected_version': expense['version'],
          'op': const Uuid().v4(),
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the decision. Refresh and check the expense before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> expense) async {
    final epoch = accessEpoch.value;
    try {
      final events = await widget.request(
        'GET',
        '/v1/expenses/${Uri.encodeComponent(expense['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted || epoch != accessEpoch.value) return;
      await showDialog<void>(
        context: context,
        builder: (context) => guardFinanceDialog(
          accessEpoch,
          epoch,
          AlertDialog(
            title: const Text('Expense history'),
            content: SingleChildScrollView(
              child: Column(
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
        setState(() => error = 'Could not load expense history.');
      }
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
                    'Expense approvals',
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
              'Finance and admin access · approval records only · no payments or ledger',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (error == null)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('Propose expense'),
              ),
            Expanded(
              child: expenses.isEmpty
                  ? const Center(child: Text('No accessible expenses.'))
                  : ListView(
                      children: expenses.map((e) {
                        final expense = e as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(expense['description'] as String),
                            subtitle: Text(
                              '${expense['minor']} minor units · ${expense['currency']} · ${expense['state']} · by ${expense['creator']}',
                            ),
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(expense),
                                  child: const Text('History'),
                                ),
                                if (expense['state'] == 'proposed') ...[
                                  if (expense['creator'] == widget.identity)
                                    TextButton(
                                      onPressed: () =>
                                          decide(expense, 'withdraw'),
                                      child: const Text('Withdraw'),
                                    ),
                                  if (canApprove &&
                                      expense['creator'] !=
                                          widget.identity) ...[
                                    TextButton(
                                      onPressed: () =>
                                          decide(expense, 'approve'),
                                      child: const Text('Approve'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          decide(expense, 'reject'),
                                      child: const Text('Reject'),
                                    ),
                                  ],
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

class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm();
  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  final description = TextEditingController();
  final amount = TextEditingController();
  final currency = TextEditingController(text: 'VND');
  String? error;
  @override
  void dispose() {
    description.dispose();
    amount.dispose();
    currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Propose expense'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: description,
            maxLength: 400,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          TextField(
            controller: amount,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Amount in minor units (integer)',
            ),
          ),
          TextField(
            controller: currency,
            maxLength: 3,
            decoration: const InputDecoration(
              labelText: 'Three-letter currency code',
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
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final minor = int.tryParse(amount.text);
          final code = currency.text.trim().toUpperCase();
          if (description.text.trim().isEmpty ||
              minor == null ||
              minor <= 0 ||
              minor > 1000000000000 ||
              !RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
            setState(
              () => error = 'Enter a description, positive integer amount and three-letter code.',
            );
            return;
          }
          Navigator.pop(context, {
            'description': description.text.trim(),
            'minor': minor,
            'currency': code,
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
