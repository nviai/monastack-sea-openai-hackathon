import 'package:monastack/shared/actor_role.dart';
import 'package:flutter/foundation.dart';

import 'package:monastack/features/sync/task_outbox.dart';
import 'package:monastack/features/agents/job_queue.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:monastack/shared/node_request.dart';

/// This board uses the authenticated node; it has no offline queue.
class TaskBoard extends ConsumerStatefulWidget {
  const TaskBoard({
    super.key,
    required this.request,
    required this.actors,
    this.queue,
    this.reviewQueue,
  });
  final NodeRequest request;
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
        selected ??= projects.isEmpty ? null : projects.first['id'] as String;
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
              child: Text(actorDisplayName(a)),
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
              child: Text(actorDisplayName(a)),
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

  String search = '';
  String actorName(dynamic id) {
    for (final actor in widget.actors) {
      if (actor['id'] == id) return actorDisplayName(actor);
    }
    return id?.toString() ?? 'Unassigned';
  }

  Widget projectCard(Map p, int index) {
    final active = selected == p['id'];
    index = {'Meslingo': 0, 'VibeKOL': 1, 'OmitX': 2}[p['name']] ?? index;
    final colors = [
      const Color(0xff46635a),
      const Color(0xff9a6947),
      const Color(0xff527381),
    ];
    final color = colors[index % colors.length];
    final total = (p['task_count'] as num?)?.toInt() ?? 0;
    final done = (p['done_count'] as num?)?.toInt() ?? 0;
    return SizedBox(
      width: 270,
      child: Semantics(
        selected: active,
        child: Card(
          elevation: 0,
          color: active ? const Color(0xffe6edde) : const Color(0xfffcfbf7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: active ? color : const Color(0xffdfe4d8),
              width: active ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('project-${p['id']}'),
            onTap: () {
              setState(() {
                selected = p['id'] as String;
                tasks = [];
              });
              loadTasks();
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          [
                            Icons.school_outlined,
                            Icons.auto_awesome_outlined,
                            Icons.laptop_mac_outlined,
                          ][index % 3],
                          color: color,
                          size: 21,
                        ),
                      ),
                      const Spacer(),
                      if (p['demo'] == true)
                        const Text(
                          'DEMO',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.4,
                            color: Color(0xff62756b),
                          ),
                        ),
                      if (p['private'] == true)
                        const Icon(Icons.lock_outline, size: 15),
                      if (active)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.check_circle,
                            color: color,
                            size: 18,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    p['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff253d38),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (p['description'] as String?)?.isNotEmpty == true
                        ? p['description'] as String
                        : p['private'] == true
                        ? 'Private project'
                        : 'Workspace project',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff62756b),
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Text(
                        '$total tasks',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const Spacer(),
                      Text(
                        '$done completed',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    color: color,
                    backgroundColor: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8),
                    minHeight: 4,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget taskCard(Map<String, dynamic> task, String state) => Card(
    elevation: 0,
    color: const Color(0xfffcfbf7),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Color(0xffe1e5da)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task['title'] as String,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.45,
              color: Color(0xff253d38),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: const Color(0xffe5ecdf),
                child: Text(
                  actorName(task['assignee']).substring(0, 1).toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff46635a),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  actorName(task['assignee']),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff62756b),
                  ),
                ),
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'Assign',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.person_add_alt, size: 17),
                  onPressed: () => changeAssignee(task),
                ),
            ],
          ),
          const Divider(height: 20),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              TextButton(
                onPressed: () => comments(task),
                child: const Text('Comments'),
              ),
              TextButton(
                onPressed: () => history(task),
                child: const Text('History'),
              ),
              if (canEdit)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => JobQueue(
                      request: widget.request,
                      actors: widget.actors,
                      linkedTaskId: task['id'] as String,
                      linkedTaskTitle: task['title'] as String,
                    ),
                  ),
                  child: const Text('Agent proposal'),
                ),
              if (canEdit && state == 'todo')
                TextButton(
                  onPressed: () => transition(task, 'in_progress'),
                  child: const Text('Start'),
                ),
              if (canEdit && state == 'in_progress') ...[
                TextButton(
                  onPressed: () => transition(task, 'todo'),
                  child: const Text('Reopen'),
                ),
                TextButton(
                  onPressed: () => transition(task, 'done'),
                  child: const Text('Done'),
                ),
              ],
              if (canEdit && state == 'done')
                TextButton(
                  onPressed: () => transition(task, 'in_progress'),
                  child: const Text('Reopen'),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget lane(String state) {
    final visible = tasks
        .where(
          (t) =>
              t['state'] == state &&
              ('${t['title']} ${actorName(t['assignee'])}')
                  .toLowerCase()
                  .contains(search.toLowerCase()),
        )
        .toList();
    final color = {
      'todo': const Color(0xff829086),
      'in_progress': const Color(0xffb48041),
      'done': const Color(0xff4d8063),
    }[state]!;
    return Container(
      width: 320,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffedf0e7),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Row(
              children: [
                Icon(Icons.circle, size: 9, color: color),
                const SizedBox(width: 8),
                Text(
                  {
                    'todo': 'To do',
                    'in_progress': 'In progress',
                    'done': 'Done',
                  }[state]!,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '${visible.length}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      search.isEmpty ? 'Nothing here yet' : 'No matching tasks',
                      style: const TextStyle(
                        color: Color(0xff62756b),
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 7),
                    itemBuilder: (_, i) =>
                        taskCard(visible[i] as Map<String, dynamic>, state),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = projects.where((p) => p['id'] == selected).firstOrNull;
    return Dialog(
      backgroundColor: const Color(0xfff7f5ef),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: 1240,
        height: 850,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WORKSPACE / PROJECTS',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.8,
                            color: Color(0xff62756b),
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Make room for great work.',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: Color(0xff253d38),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: createProject,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Project'),
                  ),
                  IconButton(
                    onPressed: loadProjects,
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 186,
                child: projects.isEmpty
                    ? const Center(
                        child: Text('Create a project to get started.'),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: projects.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) =>
                            projectCard(projects[i] as Map, i),
                      ),
              ),
              if (widget.queue != null)
                ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: widget.queue!,
                  builder: (_, entries, _) => entries.isEmpty
                      ? const SizedBox.shrink()
                      : TextButton(
                          onPressed: widget.reviewQueue,
                          child: Text(
                            'Review ${entries.length} pending or rejected task change(s)',
                          ),
                        ),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    project?['name'] as String? ?? 'Select a project',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff253d38),
                    ),
                  ),
                  if (project?['demo'] == true)
                    const Text(
                      'Demo tasks',
                      style: TextStyle(fontSize: 11, color: Color(0xff62756b)),
                    ),
                  if ((project?['url'] as String? ?? '').isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        final uri = Uri.tryParse(project['url'] as String);
                        if (uri == null ||
                            !['https', 'http'].contains(uri.scheme)) {
                          return;
                        }
                        try {
                          if (!await launchUrl(uri) && mounted) {
                            setState(
                              () => error = 'Could not open project website.',
                            );
                          }
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => error = 'Could not open project website.',
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(Uri.parse(project['url'] as String).host),
                    ),
                  if (project?['private'] == true)
                    TextButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ProjectMembers(
                          project: selected!,
                          request: widget.request,
                          actors: widget.actors,
                        ),
                      ),
                      icon: const Icon(Icons.group_outlined, size: 17),
                      label: const Text('Members'),
                    ),
                  if (selected != null && canEdit)
                    FilledButton.icon(
                      onPressed: createTask,
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('Task'),
                    ),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      onChanged: (v) => setState(() => search = v),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Search tasks or people',
                        prefixIcon: Icon(Icons.search, size: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 2,
                child: loading ? const LinearProgressIndicator() : null,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: selected == null
                    ? const Center(
                        child: Text(
                          'Choose a project card to explore its board.',
                        ),
                      )
                    : LayoutBuilder(
                        builder: (_, constraints) {
                          if (constraints.maxWidth < 900) {
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final state in [
                                    'todo',
                                    'in_progress',
                                    'done',
                                  ])
                                    Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: lane(state),
                                    ),
                                ],
                              ),
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final state in [
                                'todo',
                                'in_progress',
                                'done',
                              ])
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      right: state == 'done' ? 0 : 12,
                                    ),
                                    child: lane(state),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  final NodeRequest request;
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
                    title: Text(actorDisplayName(a)),
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
