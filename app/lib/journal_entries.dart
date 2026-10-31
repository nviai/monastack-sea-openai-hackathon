import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';
import 'finance_dialog_guard.dart';

class JournalEntries extends ConsumerStatefulWidget {
  const JournalEntries({super.key, required this.request, this.identity});
  final TaskRequest request;
  final String? identity;
  @override
  ConsumerState<JournalEntries> createState() => _JournalEntriesState();
}

class _JournalEntriesState extends ConsumerState<JournalEntries> {
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
        widget.request('GET', '/v1/journals'),
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
          guardFinanceDialog(accessEpoch, epoch, const _JournalForm()),
    );
    if (form == null || !mounted || epoch != accessEpoch.value) return;
    try {
      const uuid = Uuid();
      await widget.request('POST', '/v1/journals', {
        'id': uuid.v4(),
        'op': uuid.v4(),
        ...form,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm whether the journal was saved. Refresh and check before retrying.',
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
            '${action == 'post'
                ? 'Post'
                : action == 'reject'
                ? 'Reject'
                : 'Withdraw'} journal?',
          ),
          content: Text(
            '${expense['description']} · ${expense['minor']} minor units ${expense['currency']}\nDebit ${expense['debit']} · credit ${expense['credit']}\nThis records a journal only; no payment is made.',
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
        '/v1/journals/${Uri.encodeComponent(expense['id'] as String)}/decision',
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
          () => error = 'Could not confirm the decision. Refresh and check the journal before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> expense) async {
    final epoch = accessEpoch.value;
    try {
      final events = await widget.request(
        'GET',
        '/v1/journals/${Uri.encodeComponent(expense['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted || epoch != accessEpoch.value) return;
      await showDialog<void>(
        context: context,
        builder: (context) => guardFinanceDialog(
          accessEpoch,
          epoch,
          AlertDialog(
            title: const Text('Journal history'),
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
        setState(() => error = 'Could not load journal history.');
      }
    }
  }

  Future<void> reverse(Map<String, dynamic> entry) async {
    final epoch = accessEpoch.value;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => guardFinanceDialog(
        accessEpoch,
        epoch,
        AlertDialog(
          title: const Text('Propose a reversal?'),
          content: Text(
            'A new proposal will debit ${entry['credit']} and credit ${entry['debit']} for ${entry['minor']} minor units ${entry['currency']}. Another administrator must post it. No payment occurs.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Propose reversal'),
            ),
          ],
        ),
      ),
    );
    if (yes != true || !mounted || epoch != accessEpoch.value) return;
    try {
      await widget.request(
        'POST',
        '/v1/journals/${Uri.encodeComponent(entry['id'] as String)}/reverse',
        {'id': const Uuid().v4(), 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the reversal. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> balances() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _BalanceReport(request: widget.request, trial: false),
    );
  }

  Future<void> trialBalance() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _BalanceReport(request: widget.request, trial: true),
    );
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
                    'Journal entries',
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
              'Finance and admin access · two-line journals · no payments',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (error == null)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('Propose journal'),
              ),
            if (error == null)
              TextButton(
                onPressed: balances,
                child: const Text('View net activity'),
              ),
            if (error == null)
              TextButton(
                onPressed: trialBalance,
                child: const Text('View activity balance'),
              ),
            Expanded(
              child: expenses.isEmpty
                  ? const Center(child: Text('No accessible journal entries.'))
                  : ListView(
                      children: expenses.map((e) {
                        final expense = e as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(expense['description'] as String),
                            subtitle: Text(
                              'Debit ${expense['debit']} · credit ${expense['credit']}\n${expense['minor']} minor units · ${expense['currency']} · ${expense['state']} · by ${expense['creator']}',
                            ),
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(expense),
                                  child: const Text('History'),
                                ),
                                if (expense['state'] == 'posted' &&
                                    expense['reverses'] == null &&
                                    expense['reversed'] != true)
                                  TextButton(
                                    onPressed: () => reverse(expense),
                                    child: const Text('Reverse'),
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
                                      onPressed: () => decide(expense, 'post'),
                                      child: const Text('Post'),
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

class _BalanceReport extends StatefulWidget {
  const _BalanceReport({required this.request, required this.trial});
  final TaskRequest request;
  final bool trial;
  @override
  State<_BalanceReport> createState() => _BalanceReportState();
}

class _BalanceReportState extends State<_BalanceReport> {
  List<dynamic> rows = [];
  String? error;
  bool loading = true, busy = false;
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
    if (busy) return;
    busy = true;
    try {
      final result = await widget.request(
        'GET',
        widget.trial ? '/v1/journals/trial-balance' : '/v1/journals/balances',
      ) as List<dynamic>;
      if (mounted) {
        setState(() {
          rows = result;
          error = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          rows = [];
          error = 'Finance access denied or node unavailable.';
          loading = false;
        });
      }
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.trial ? 'Posted activity balance' : 'Net debit by account',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.trial
                ? 'Net posted activity only, grouped by currency. No opening balances or account classification; this is not a financial statement.'
                : 'Posted journal activity only; no opening balances or account classification.',
          ),
          if (loading) const CircularProgressIndicator(),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          if (!loading && error == null && rows.isEmpty)
            const Text('No posted journal activity.'),
          if (!widget.trial)
            ...rows.map(
              (r) => Text(
                "${r['account']} · ${r['currency']} · ${r['net_debit_minor']} minor units",
              ),
            ),
          if (widget.trial)
            ...rows.map(
              (group) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    "${group['currency']} · Debit ${group['debit_total_minor']} · Credit ${group['credit_total_minor']} minor units",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  ...(group['accounts'] as List<dynamic>).map(
                    (account) => Text(
                      "${account['account']} · Debit ${account['debit_minor']} · Credit ${account['credit_minor']}",
                    ),
                  ),
                ],
              ),
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
    ],
  );
}

class _JournalForm extends StatefulWidget {
  const _JournalForm();
  @override
  State<_JournalForm> createState() => _JournalFormState();
}

class _JournalFormState extends State<_JournalForm> {
  final description = TextEditingController();
  final debit = TextEditingController();
  final credit = TextEditingController();
  final amount = TextEditingController();
  final currency = TextEditingController(text: 'VND');
  String? error;
  @override
  void dispose() {
    description.dispose();
    debit.dispose();
    credit.dispose();
    amount.dispose();
    currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Propose journal'),
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
            controller: debit,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Debit account code'),
          ),
          TextField(
            controller: credit,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Credit account code'),
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
          final debitCode = debit.text.trim();
          final creditCode = credit.text.trim();
          if (description.text.trim().isEmpty ||
              !RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(debitCode) ||
              !RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(creditCode) ||
              debitCode == creditCode ||
              minor == null ||
              minor <= 0 ||
              minor > 1000000000000 ||
              !RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
            setState(
              () => error = 'Enter a description, distinct account codes, positive integer amount and three-letter currency code.',
            );
            return;
          }
          Navigator.pop(context, {
            'description': description.text.trim(),
            'debit': debitCode,
            'credit': creditCode,
            'minor': minor,
            'currency': code,
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
