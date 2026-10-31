import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';
import 'leave_calendar.dart';

class LeaveRequests extends ConsumerStatefulWidget {
  const LeaveRequests({super.key, required this.request, this.identity});
  final TaskRequest request;
  final String? identity;
  @override
  ConsumerState<LeaveRequests> createState() => _LeaveRequestsState();
}

class _LeaveRequestsState extends ConsumerState<LeaveRequests> {
  List<dynamic> requests = [];
  String? error;
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
      final result = await widget.request('GET', '/v1/leave') as List<dynamic>;
      if (mounted) {
        setState(() {
          requests = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          requests = [];
          error = 'Could not load leave requests.';
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
    final form = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _LeaveForm(),
    );
    if (form == null) return;
    try {
      const uuid = Uuid();
      await widget.request('POST', '/v1/leave', {
        'id': uuid.v4(),
        'op': uuid.v4(),
        ...form,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm whether the request was saved. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> decide(Map<String, dynamic> item, String action) async {
    final question = switch (action) {
      'approve' => 'Approve leave?',
      'reject' => 'Reject leave?',
      'withdraw' => 'Withdraw leave?',
      'request_cancel' => 'Request cancellation of approved leave?',
      'cancel_withdraw' => 'Withdraw cancellation request?',
      'cancel_approve' => 'Approve leave cancellation?',
      'cancel_reject' => 'Reject leave cancellation?',
      _ => 'Confirm change?',
    };
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question),
        content: Text(
          '${item['requester']} · ${item['start_date']} to ${item['end_date']}',
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
        '/v1/leave/${Uri.encodeComponent(item['id'] as String)}/decision',
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
          () => error = 'Could not confirm the decision. Refresh and check the request before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/leave/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Leave history'),
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
      );
    } catch (_) {
      if (mounted) setState(() => error = 'Could not load leave history.');
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
                    'Leave requests',
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
              'Your requests are private; only an explicitly authorized HR member can review others. No HR member is seeded.',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            TextButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('Request leave'),
            ),
            TextButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => LeaveCalendar(request: widget.request),
              ),
              icon: const Icon(Icons.calendar_month),
              label: const Text('Approved leave calendar'),
            ),
            Expanded(
              child: requests.isEmpty
                  ? const Center(child: Text('No accessible leave requests.'))
                  : ListView(
                      children: requests.map((r) {
                        final item = r as Map<String, dynamic>;
                        return Card(
                          child: ListTile(
                            title: Text(
                              '${item['start_date']} to ${item['end_date']}',
                            ),
                            subtitle: Text(
                              '${item['requester']} · ${item['state']}\n${item['reason']}',
                            ),
                            trailing: Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => history(item),
                                  child: const Text('History'),
                                ),
                                if (item['state'] == 'proposed') ...[
                                  if (item['requester'] == widget.identity)
                                    TextButton(
                                      onPressed: () => decide(item, 'withdraw'),
                                      child: const Text('Withdraw'),
                                    ),
                                  if (item['requester'] != widget.identity) ...[
                                    TextButton(
                                      onPressed: () => decide(item, 'approve'),
                                      child: const Text('Approve'),
                                    ),
                                    TextButton(
                                      onPressed: () => decide(item, 'reject'),
                                      child: const Text('Reject'),
                                    ),
                                  ],
                                ],
                                if (item['requester'] == widget.identity &&
                                    item['state'] == 'approved')
                                  TextButton(
                                    onPressed: () =>
                                        decide(item, 'request_cancel'),
                                    child: const Text('Request cancellation'),
                                  ),
                                if (item['state'] ==
                                    'cancellation_pending') ...[
                                  if (item['requester'] == widget.identity)
                                    TextButton(
                                      onPressed: () =>
                                          decide(item, 'cancel_withdraw'),
                                      child: const Text(
                                        'Withdraw cancellation',
                                      ),
                                    )
                                  else ...[
                                    TextButton(
                                      onPressed: () =>
                                          decide(item, 'cancel_approve'),
                                      child: const Text('Approve cancellation'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          decide(item, 'cancel_reject'),
                                      child: const Text('Reject cancellation'),
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

class _LeaveForm extends StatefulWidget {
  const _LeaveForm();
  @override
  State<_LeaveForm> createState() => _LeaveFormState();
}

class _LeaveFormState extends State<_LeaveForm> {
  final start = TextEditingController();
  final end = TextEditingController();
  final reason = TextEditingController();
  String? error;
  @override
  void dispose() {
    start.dispose();
    end.dispose();
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Request leave'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: start,
            decoration: const InputDecoration(
              labelText: 'Start date (YYYY-MM-DD)',
            ),
          ),
          TextField(
            controller: end,
            decoration: const InputDecoration(
              labelText: 'End date (YYYY-MM-DD)',
            ),
          ),
          TextField(
            controller: reason,
            maxLength: 1000,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Reason'),
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
          if (start.text.trim().isEmpty ||
              end.text.trim().isEmpty ||
              reason.text.trim().isEmpty) {
            setState(() => error = 'Complete all fields.');
            return;
          }
          Navigator.pop(context, {
            'start_date': start.text.trim(),
            'end_date': end.text.trim(),
            'reason': reason.text.trim(),
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
