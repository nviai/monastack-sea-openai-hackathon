import 'package:flutter/foundation.dart';

import 'task_outbox.dart';
import 'job_queue.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

typedef TaskRequest = Future<dynamic> Function(
  String method,
  String path, [
  Object? body,
]);

/// This board uses the authenticated node; it has no offline queue.
class TaskBoard extends ConsumerStatefulWidget {
  const TaskBoard({
    super.key,
    required this.request,
    required this.actors,
    this.queue,
    this.reviewQueue,
  });
  final TaskRequest request;
  final List<Map<String, dynamic>> actors;
  final ValueListenable<List<Map<String, dynamic>>>? queue;
  final VoidCallback? reviewQueue;
  @override
  ConsumerState<TaskBoard> createState() => _TaskBoardState();
}

class _TaskBoardState extends ConsumerState<TaskBoard> {
  List<dynamic> projects = [];
  List<dynamic> tasks = [];
  String? selected;
  String? error;
  bool loading = false;
  bool get canEdit =>
      projects.any((p) => p['id'] == selected && p['can_edit'] != false);
  final uuid = const Uuid();
  Timer? refreshTimer;
  @override
  void initState() {
    super.initState();
    loadProjects();
    refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => loadProjects(),
    );
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> loadProjects() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result =
          await widget.request('GET', '/v1/projects') as List<dynamic>;
      if (!mounted) return;
      setState(() {
        projects = result;
        if (selected != null && !projects.any((p) => p['id'] == selected)) {
          selected = null;
          tasks = [];
        }
      });
      if (selected != null) await loadTasks();
    } catch (_) {
      if (mounted) {
        setState(() {
          projects = [];
          tasks = [];
          selected = null;
          error = 'Could not load projects. Check the local connection.';
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadTasks() async {
    final project = selected;
    if (project == null) return;
    try {
      final result = await widget.request(
        'GET',
        '/v1/projects/${Uri.encodeComponent(project)}/tasks',
      ) as List<dynamic>;
      if (mounted && selected == project) {
        setState(() {
          tasks = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted && selected == project) {
        setState(() {
          tasks = [];
          error = 'Could not load tasks.';
        });
      }
    }
  }

  Future<String?> textPrompt(String title, {bool multiline = false}) =>
      showDialog<String>(
        context: context,
        builder: (context) => _TextPrompt(title: title, multiline: multiline),
      );

  String changeError(Object error, String fallback) {
    if (error is TaskChangeQueued) {
      return 'Saved on this device and waiting for the node. Do not recreate the change.';
    }
    if (error is TaskChangeRejected) {
      return 'The node rejected this change. Review the task queue and refresh before recreating it.';
    }
    if (error is OutboxFailure) {
      return 'The local task queue is unavailable. Refresh before retrying.';
    }
    return fallback;
  }

  Future<void> createProject() async {
    final name = await textPrompt('New project');
    if (name == null || name.isEmpty || !mounted) return;
    final private = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Project access'),
        content: const Text(
          'Workspace projects are visible to everyone. Private projects are visible only to their owner and invited members.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Workspace'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Private'),
          ),
        ],
      ),
    );
    if (private == null) return;
    try {
      await widget.request('POST', '/v1/projects', {
        'id': uuid.v4(),
        'op': uuid.v4(),
        'name': name,
        if (private) 'private': true,
      });
      await loadProjects();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = changeError(
            failure,
            'Project change failed. Refresh before retrying.',
          ),
        );
      }
    }
  }

  Future<void> createTask() async {
    final project = selected;
    if (project == null) return;
    final title = await textPrompt('New task');
    if (title == null || title.isEmpty) return;
    if (!mounted) return;
    String? assignee;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Assign to'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Unassigned'),
          ),
          ...widget.actors.map(
            (a) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, a['id'] as String),
              child: Text(
                '${a['name']}${a['kind'] == 'agent' ? ' · offline agent' : ''}',
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice.isNotEmpty) assignee = choice;
    try {
      await widget.request(
        'POST',
        '/v1/projects/${Uri.encodeComponent(project)}/tasks',
        {
          'id': uuid.v4(),
          'op': uuid.v4(),
          'title': title,
          'assignee': assignee,
        },
      );
      await loadTasks();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = changeError(
            failure,
            'Task change failed. Refresh before retrying.',
          ),
        );
      }
    }
  }

  Future<void> changeAssignee(Map<String, dynamic> task) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Assign to'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Unassigned'),
          ),
          ...widget.actors.map(
            (a) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, a['id'] as String),
              child: Text(
                '${a['name']}${a['kind'] == 'agent' ? ' · offline agent' : ''}',
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    try {
      await widget.request(
        'POST',
        '/v1/tasks/${Uri.encodeComponent(task['id'] as String)}/assign',
        {
          'assignee': choice.isEmpty ? null : choice,
          'expected_version': task['version'],
          'op': uuid.v4(),
        },
      );
      await loadTasks();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = changeError(
            failure,
            'Assignment failed. Refresh before retrying.',
          ),
        );
      }
    }
  }

  Future<void> transition(Map<String, dynamic> task, String target) async {
    try {
      await widget.request(
        'POST',
        '/v1/tasks/${Uri.encodeComponent(task['id'] as String)}/transition',
        {'to': target, 'expected_version': task['version'], 'op': uuid.v4()},
      );
      await loadTasks();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = changeError(
            failure,
            'Transition failed. Refresh before retrying.',
          ),
        );
      }
    }
  }

  Future<void> comments(Map<String, dynamic> task) async {
    final id = task['id'] as String;
    try {
      final list = await widget.request(
        'GET',
        '/v1/tasks/${Uri.encodeComponent(id)}/comments',
      ) as List<dynamic>;
      if (!mounted) return;
      final add = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(task['title'] as String),
          content: SizedBox(
            width: 380,
            child: list.isEmpty
                ? const Text('No comments yet.')
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: list
                          .map(
                            (c) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text('${c['author']}: ${c['body']}'),
                            ),
                          )
                          .toList(),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Close'),
            ),
            if (canEdit)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add comment'),
              ),
          ],
        ),
      );
      if (add != true || !mounted) return;
      final body = await textPrompt('Comment', multiline: true);
      if (body == null || body.isEmpty) return;
      await widget.request(
        'POST',
        '/v1/tasks/${Uri.encodeComponent(id)}/comments',
        {'id': uuid.v4(), 'op': uuid.v4(), 'body': body},
      );
      if (mounted) await comments(task);
    } catch (failure) {
      if (mounted) {
        setState(
          () =>
              error = changeError(failure, 'Could not load or save comments.'),
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> task) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/tasks/${Uri.encodeComponent(task['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Task history'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: events
                    .map(
                      (event) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('${event['actor']} · ${event['action']}'),
                      ),
                    )
                    .toList(),
              ),
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
      if (mounted) setState(() => error = 'Could not load task history.');
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 950,
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
                    'Tasks',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: loadProjects,
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
              'Workspace-wide prototype · online only · assigning an agent does not start it',
              style: TextStyle(color: Colors.black54),
            ),
            if (widget.queue != null)
              ValueListenableBuilder<List<Map<String, dynamic>>>(
                valueListenable: widget.queue!,
                builder: (context, entries, _) => entries.isEmpty
                    ? const SizedBox.shrink()
                    : TextButton(
                        onPressed: widget.reviewQueue,
                        child: Text(
                          'Review ${entries.length} pending or rejected task change(s)',
                        ),
                      ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    key: const ValueKey('project-picker'),
                    isExpanded: true,
                    value: selected,
                    hint: const Text('Choose a project'),
                    items: projects
                        .map(
                          (p) => DropdownMenuItem(
                            value: p['id'] as String,
                            child: Text(
                              '${p['name']}${p['private'] == true ? ' · private' : ''}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (id) {
                      setState(() {
                        selected = id;
                        tasks = [];
                      });
                      loadTasks();
                    },
                  ),
                ),
                TextButton.icon(
                  onPressed: createProject,
                  icon: const Icon(Icons.add),
                  label: const Text('Project'),
                ),
                if (selected != null &&
                    projects.any(
                      (p) => p['id'] == selected && p['private'] == true,
                    ))
                  TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => _ProjectMembers(
                        project: selected!,
                        request: widget.request,
                        actors: widget.actors,
                      ),
                    ),
                    icon: const Icon(Icons.group_outlined),
                    label: const Text('Members'),
                  ),
                if (selected != null && canEdit)
                  TextButton.icon(
                    onPressed: createTask,
                    icon: const Icon(Icons.add),
                    label: const Text('Task'),
                  ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            Expanded(
              child: selected == null
                  ? const Center(child: Text('Create or choose a project.'))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final state in ['todo', 'in_progress', 'done'])
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.all(5),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xfff0f2ed),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    {
                                      'todo': 'To do',
                                      'in_progress': 'In progress',
                                      'done': 'Done',
                                    }[state]!,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: ListView(
                                      children: tasks.where((t) => t['state'] == state).map((
                                        t,
                                      ) {
                                        final task = t as Map<String, dynamic>;
                                        return Card(
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  task['title'] as String,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  task['assignee'] == null
                                                      ? 'Unassigned'
                                                      : 'Assigned: ${task['assignee']}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                Wrap(
                                                  children: [
                                                    if (canEdit)
                                                      TextButton(
                                                        onPressed: () =>
                                                            changeAssignee(
                                                              task,
                                                            ),
                                                        child: const Text(
                                                          'Assign',
                                                        ),
                                                      ),
                                                    if (canEdit)
                                                      TextButton(
                                                        onPressed: () =>
                                                            showDialog<void>(
                                                              context: context,
                                                              builder: (_) => JobQueue(
                                                                request: widget
                                                                    .request,
                                                                actors: widget
                                                                    .actors,
                                                                linkedTaskId:
                                                                    task['id']
                                                                        as String,
                                                                linkedTaskTitle:
                                                                    task['title']
                                                                        as String,
                                                              ),
                                                            ),
                                                        child: const Text(
                                                          'Agent proposal',
                                                        ),
                                                      ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          comments(task),
                                                      child: const Text(
                                                        'Comments',
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          history(task),
                                                      child: const Text(
                                                        'History',
                                                      ),
                                                    ),
                                                    if (canEdit &&
                                                        state == 'todo')
                                                      TextButton(
                                                        onPressed: () =>
                                                            transition(
                                                              task,
                                                              'in_progress',
                                                            ),
                                                        child: const Text(
                                                          'Start',
                                                        ),
                                                      ),
                                                    if (canEdit &&
                                                        state ==
                                                            'in_progress') ...[
                                                      TextButton(
                                                        onPressed: () =>
                                                            transition(
                                                              task,
                                                              'todo',
                                                            ),
                                                        child: const Text(
                                                          'Reopen',
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () =>
                                                            transition(
                                                              task,
                                                              'done',
                                                            ),
                                                        child: const Text(
                                                          'Done',
                                                        ),
                                                      ),
                                                    ],
                                                    if (canEdit &&
                                                        state == 'done')
                                                      TextButton(
                                                        onPressed: () =>
                                                            transition(
                                                              task,
                                                              'in_progress',
                                                            ),
                                                        child: const Text(
                                                          'Reopen',
                                                        ),
                                                      ),
                                                  ],
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
                      ],
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({required this.title, required this.multiline});
  final String title;
  final bool multiline;
  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: widget.multiline ? 4000 : 120,
      maxLines: widget.multiline ? 3 : 1,
      onSubmitted: (_) => Navigator.pop(context, controller.text.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

class _ProjectMembers extends StatefulWidget {
  const _ProjectMembers({
    required this.project,
    required this.request,
    required this.actors,
  });
  final String project;
  final TaskRequest request;
  final List<Map<String, dynamic>> actors;
  @override
  State<_ProjectMembers> createState() => _ProjectMembersState();
}

class _ProjectMembersState extends State<_ProjectMembers> {
  Map<String, dynamic>? data;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.request(
        'GET',
        '/v1/projects/${Uri.encodeComponent(widget.project)}/members',
      ) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          data = null;
          error = 'Could not load project membership.';
        });
      }
    }
  }

  Future<void> change(String actor, String action) async {
    try {
      await widget.request(
        'POST',
        '/v1/projects/${Uri.encodeComponent(widget.project)}/members',
        {'actor': actor, 'action': action, 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Membership change denied or could not be saved.',
        );
      }
    }
  }

  Future<void> history() async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/projects/${Uri.encodeComponent(widget.project)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Project history'),
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
      if (mounted) setState(() => error = 'Could not load project history.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = data;
    final members = (info?['members'] as List? ?? []).cast<String>();
    final readers = (info?['readers'] as List? ?? []).cast<String>();
    return AlertDialog(
      title: const Text('Project members'),
      content: SizedBox(
        width: 420,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Only the owner can change membership. Organization admins have no automatic override.',
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: ListView(
                children: widget.actors.where((a) => a['kind'] == 'human').map((
                  a,
                ) {
                  final id = a['id'] as String;
                  final owner = id == info?['owner'];
                  final active = members.contains(id);
                  return ListTile(
                    key: ValueKey('member-$id'),
                    title: Text(a['name'] as String),
                    subtitle: Text(
                      owner
                          ? 'Owner'
                          : active
                          ? (readers.contains(id)
                                ? 'Read-only member'
                                : 'Editor')
                          : 'Not a member',
                    ),
                    trailing: info?['can_manage'] == true && !owner
                        ? Wrap(
                            children: [
                              TextButton(
                                onPressed: () =>
                                    change(id, active ? 'revoke' : 'grant'),
                                child: Text(active ? 'Remove' : 'Invite'),
                              ),
                              TextButton(
                                onPressed: () => change(
                                  id,
                                  active
                                      ? (readers.contains(id)
                                            ? 'set_writer'
                                            : 'set_reader')
                                      : 'grant_reader',
                                ),
                                child: Text(
                                  active
                                      ? (readers.contains(id)
                                            ? 'Make editor'
                                            : 'Make read-only')
                                      : 'Invite read-only',
                                ),
                              ),
                            ],
                          )
                        : null,
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: history, child: const Text('History')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
