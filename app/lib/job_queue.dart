import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'task_board.dart';

/// Stores proposals only. No job execution is implemented.
class JobQueue extends ConsumerStatefulWidget {
  const JobQueue({
    super.key,
    required this.request,
    required this.actors,
    this.linkedTaskId,
    this.linkedTaskTitle,
  });
  final TaskRequest request;
  final List<Map<String, dynamic>> actors;
  final String? linkedTaskId;
  final String? linkedTaskTitle;
  @override
  ConsumerState<JobQueue> createState() => _JobQueueState();
}

class _JobQueueState extends ConsumerState<JobQueue> {
  final instruction = TextEditingController();
  final uuid = const Uuid();
  List<dynamic> jobs = [];
  String agent = 'dev-agent';
  String? error;
  bool busy = false;
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
    instruction.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final list = await widget.request('GET', '/v1/jobs') as List<dynamic>;
      if (mounted) {
        setState(() {
          jobs = list;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          jobs = [];
          error = 'Could not load proposals.';
        });
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> propose() async {
    if (busy || instruction.text.trim().isEmpty) return;
    final text = instruction.text.trim();
    setState(() => busy = true);
    try {
      await widget.request('POST', '/v1/jobs', {
        'id': uuid.v4(),
        'op': uuid.v4(),
        'agent': agent,
        'task': widget.linkedTaskId,
        'instruction': text,
        'budget': 5,
      });
      if (mounted) instruction.clear();
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the proposal was saved. Refresh and check before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> decide(Map<String, dynamic> job, String action) async {
    try {
      await widget.request(
        'POST',
        '/v1/jobs/${Uri.encodeComponent(job['id'] as String)}/decision',
        {'action': action, 'expected_version': job['version'], 'op': uuid.v4()},
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

  Future<void> history(Map<String, dynamic> job) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/jobs/${Uri.encodeComponent(job['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Proposal history'),
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
      if (mounted) setState(() => error = 'Could not load proposal history.');
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 700,
      height: 650,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Agent proposals',
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
              'Approval records a decision; nothing runs until an explicitly configured host acts. Unlinked proposals are workspace-visible; linked proposals follow project access.',
              style: TextStyle(color: Colors.black54),
            ),
            if (widget.linkedTaskId != null)
              Text(
                'Linked task: ${widget.linkedTaskTitle ?? widget.linkedTaskId}',
              ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            DropdownButton<String>(
              value: agent,
              items: widget.actors
                  .where((a) => a['kind'] == 'agent')
                  .map(
                    (a) => DropdownMenuItem(
                      value: a['id'] as String,
                      child: Text('${a['name']} · offline'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => agent = v);
              },
            ),
            TextField(
              controller: instruction,
              maxLength: 4000,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Proposed instruction',
              ),
            ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Requested budget: 5 units (not enforced by the host)',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                FilledButton(
                  onPressed: busy ? null : propose,
                  child: const Text('Propose'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: jobs.map((j) {
                  final job = j as Map<String, dynamic>;
                  final state = job['state'] as String;
                  return Card(
                    child: ListTile(
                      title: Text(job['instruction'] as String),
                      subtitle: Text(
                        '${job['agent']} · ${state == 'approved_waiting'
                            ? 'Approved, waiting for host'
                            : state == 'host_claimed'
                            ? 'Claimed by host; execution not verified'
                            : state == 'host_reported'
                            ? 'Host reported ${job['report_outcome']}; not independently verified'
                            : state} · by ${job['created_by']}${job['report_summary'] == null ? '' : '\n${job['report_summary']}'}',
                      ),
                      trailing: Wrap(
                        children: [
                          TextButton(
                            onPressed: () => history(job),
                            child: const Text('History'),
                          ),
                          if (state == 'proposed')
                            TextButton(
                              onPressed: () => decide(job, 'approve'),
                              child: const Text('Approve'),
                            ),
                          if (state == 'proposed' ||
                              state == 'approved_waiting' ||
                              state == 'host_claimed')
                            TextButton(
                              onPressed: () => decide(job, 'cancel'),
                              child: const Text('Cancel'),
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
