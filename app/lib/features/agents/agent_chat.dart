import 'package:url_launcher/url_launcher.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:monastack/shared/agent_stream.dart';

import 'dart:convert';

import 'ui_actions.dart';

import 'package:flutter/material.dart';
import 'package:monastack/shared/actor_role.dart';
import 'package:monastack/shared/node_request.dart';

/// Each agent's conversation stays in this view's memory, scoped to this session.
class AgentChat extends StatefulWidget {
  const AgentChat({
    super.key,
    required this.request,
    required this.actors,
    this.initialAgent,
    this.uiActions,
    this.streamRequest,
  });
  final String? initialAgent;
  final UiActions? uiActions;
  final NodeRequest request;
  final AgentStreamFactory? streamRequest;
  final List<Map<String, dynamic>> actors;
  @override
  State<AgentChat> createState() => _AgentChatState();
}

class _AgentChatState extends State<AgentChat> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  final histories = <String, List<Map<String, String>>>{};
  String? agent;
  String? error;
  String? model;
  bool configured = false;
  bool checking = true;
  bool busy = false;
  AgentStream? activeStream;
  int generation = 0;
  String pending = '';
  String partial = '';
  String activity = 'Thinking…';
  bool operated = false;
  Timer? renderTimer;

  void followTail() {
    final follow = !scroll.hasClients || scroll.position.extentAfter < 100;
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  void stop() {
    generation++;
    activeStream?.cancel();
    activeStream = null;
    renderTimer?.cancel();
    renderTimer = null;
    if (operated) composer.clear();
    setState(() {
      busy = false;
      error = operated
          ? 'Stopped. Actions already performed are kept. Check the screen before sending another request.'
          : 'Stopped. You can edit your message and send it again.';
    });
  }

  Future<dynamic> respond(
    String target,
    Map<String, dynamic> body,
    int run,
  ) async {
    if (widget.streamRequest == null) {
      return widget.request(
        'POST',
        '/v1/agents/${Uri.encodeComponent(target)}/chat',
        body,
      );
    }
    activeStream = widget.streamRequest!(
      '/v1/agents/${Uri.encodeComponent(target)}/chat',
      {...body, 'stream': true},
    );
    partial = '';
    final result = Completer<Map<String, dynamic>>();
    final subscription = activeStream!.events.listen(
      (event) {
        if (!mounted || run != generation || result.isCompleted) return;
        if (event['event'] == 'done') {
          result.complete(event);
        } else if (event['event'] == 'delta') {
          partial += event['text'] as String? ?? '';
          activity = 'Responding…';
          renderTimer ??= Timer(const Duration(milliseconds: 40), () {
            renderTimer = null;
            if (mounted && run == generation) {
              followTail();
              setState(() {});
            }
          });
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(const FormatException('Interrupted response'));
        }
      },
    );
    try {
      return await result.future;
    } finally {
      unawaited(subscription.cancel());
    }
  }

  List<Map<String, String>> get history =>
      histories.putIfAbsent(agent!, () => []);

  @override
  void initState() {
    super.initState();
    agent =
        widget.initialAgent ??
        (widget.actors.where((a) => a['kind'] == 'agent').firstOrNull?['id']
            as String?);
    check();
  }

  Future<void> check() async {
    setState(() {
      checking = true;
      error = null;
    });
    try {
      final result = await widget.request('GET', '/v1/agents/capabilities');
      if (!mounted) return;
      setState(() {
        configured = result['configured'] == true;
        model = result['model'] as String?;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not check agent connection. Sign in and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> send() async {
    final text = composer.text.trim();
    if (busy || text.isEmpty || agent == null || !configured) return;
    if (text.length > 4000) {
      setState(() => error = 'Please keep messages under 4,000 characters.');
      return;
    }
    final target = agent!;
    final run = ++generation;
    // Ten previous turns plus this message; no other agents' chats are sent.
    final previous = history.length > 20
        ? history.sublist(history.length - 20)
        : List<Map<String, String>>.of(history);
    while (previous.isNotEmpty &&
        (previous.any((m) => utf8.encode(m['content']!).length > 16000) ||
            previous.fold<int>(
                  utf8.encode(text).length,
                  (sum, m) => sum + utf8.encode(m['content']!).length,
                ) >
                64000)) {
      previous.removeRange(0, 2);
    }
    final messages = [
      ...previous,
      {'role': 'user', 'content': text},
    ];
    setState(() {
      busy = true;
      error = null;
      pending = text;
      partial = "";
      operated = false;
      activity = "Thinking…";
    });
    try {
      var response = await respond(target, {
        'messages': messages,
        if (widget.uiActions != null)
          'ui_controls': widget.uiActions!.snapshot(),
      }, run);
      for (var step = 0; response['ui_action'] != null && step < 10; step++) {
        if (!mounted || run != generation || widget.uiActions == null) return;
        operated = true;
        setState(() => activity = 'Working in your app…');
        String outcome;
        try {
          outcome = await widget.uiActions!.execute(
            Map<String, dynamic>.from(response['ui_action'] as Map),
          );
        } catch (_) {
          outcome = 'The control could not be invoked. Inspect the current screen and do not assume success.';
        }
        if (!mounted || run != generation) return;
        response = await respond(target, {
          'messages': messages,
          'ui_controls': widget.uiActions!.snapshot(),
          'ui_history': [
            ...?response['ui_history'] as List?,
            {
              'type': 'function_call_output',
              'call_id': response['ui_call_id'],
              'output': outcome,
            },
          ],
        }, run);
      }
      if (response['ui_action'] != null) {
        response = {
          'text': 'UI step limit reached. Ask me to continue.',
          'incomplete': true,
        };
      }
      if (!mounted || run != generation) return;
      setState(() {
        histories[target]!.addAll([
          {'role': 'user', 'content': text},
          {
            'role': 'assistant',
            'content':
                response['text'] as String? ??
                'UI step limit reached. Ask me to continue.',
          },
        ]);
        composer.clear();
        pending = "";
        partial = "";
        if (response['incomplete'] == true) {
          error =
              'Response reached the output limit. Ask the agent to continue.';
        }
      });
      followTail();
    } on NodeFailure catch (e) {
      if (mounted && run == generation) {
        setState(
          () => error = switch (e.status) {
            401 || 403 => 'Your session is unavailable. Sign in again.',
            429 =>
              'Agent is busy or OpenAI quota was reached. Try again shortly.',
            503 => 'Agent connection is unavailable. Ask your workspace admin to check it.',
            _ =>
              'Could not get a response. Your message is kept below for retry.',
          },
        );
      }
    } catch (_) {
      if (mounted && run == generation) {
        setState(
          () => error = operated
              ? 'Connection interrupted after a UI action. Check the screen before sending again.'
              : 'Connection interrupted. Your message is kept below for retry.',
        );
      }
    } finally {
      if (mounted && run == generation) {
        if (operated && error != null) {
          composer.clear();
          error =
              '$error Actions may already have run. Check the screen before sending another request.';
        }
        renderTimer?.cancel();
        renderTimer = null;
        activeStream?.cancel();
        activeStream = null;
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() {
    generation++;
    activeStream?.cancel();
    renderTimer?.cancel();
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 640,
    height: 580,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: const Icon(Icons.auto_awesome_outlined),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Chat with agents',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'New conversation',
              onPressed: busy || agent == null
                  ? null
                  : () {
                      setState(() {
                        histories[agent!] = [];
                        pending = '';
                        partial = '';
                        error = null;
                        composer.clear();
                      });
                    },
              icon: const Icon(Icons.edit_square),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: agent,
          decoration: const InputDecoration(
            labelText: 'Agent',
            border: OutlineInputBorder(),
          ),
          items: widget.actors
              .where((a) => a['kind'] == 'agent')
              .map(
                (a) => DropdownMenuItem(
                  value: a['id'] as String,
                  child: Text(
                    actorDisplayName(a),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: busy
              ? null
              : (value) => setState(() {
                  agent = value;
                  error = null;
                  composer.clear();
                  pending = "";
                  partial = "";
                }),
        ),
        const SizedBox(height: 8),
        Text(
          checking
              ? 'Checking connection…'
              : configured
              ? 'OpenAI · $model'
              : 'OpenAI is not configured on this office node.',
        ),
        const Text(
          'Messages are sent to OpenAI. Chat history lasts while this window is open.',
          style: TextStyle(fontSize: 11),
        ),
        if (!configured && !checking)
          TextButton(
            onPressed: check,
            child: const Text('Check connection again'),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: agent == null
              ? const Center(child: Text('No agents available.'))
              : history.isEmpty && pending.isEmpty
              ? const Center(
                  child: Text('Ask this agent for help with your work.'),
                )
              : ListView.builder(
                  controller: scroll,
                  itemCount: history.length + (pending.isEmpty ? 0 : 2),
                  itemBuilder: (context, index) {
                    final message = index < history.length
                        ? history[index]
                        : index == history.length
                        ? {'role': 'user', 'content': pending}
                        : {
                            'role': 'assistant',
                            'content': partial.isEmpty
                                ? (busy ? activity : 'No response received.')
                                : partial,
                          };
                    return Card(
                      elevation: 0,
                      color: message['role'] == 'user'
                          ? Theme.of(context).colorScheme.primaryContainer
                                .withValues(alpha: .45)
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                      margin: EdgeInsets.only(
                        top: 8,
                        bottom: 8,
                        left: message['role'] == 'user' ? 28 : 0,
                        right: message['role'] == 'user' ? 0 : 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              message['role'] == 'user'
                                  ? 'You'
                                  : actorDisplayName(
                                      widget.actors.firstWhere(
                                        (a) => a['id'] == agent,
                                      ),
                                    ),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (message['role'] == 'user')
                              SelectableText(message['content']!)
                            else
                              MarkdownBody(
                                data: message['content']!,
                                selectable: true,
                                softLineBreak: true,
                                onTapLink: (text, href, title) async {
                                  final uri = Uri.tryParse(href ?? '');
                                  if (uri != null &&
                                      {'https', 'http'}.contains(uri.scheme)) {
                                    await launchUrl(
                                      uri,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  }
                                },
                                imageBuilder: (uri, title, alt) =>
                                    Text(alt ?? 'Image attachment'),
                              ),
                            if (message['role'] == 'assistant' &&
                                index < history.length)
                              Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  tooltip: 'Copy response',
                                  icon: const Icon(
                                    Icons.copy_outlined,
                                    size: 16,
                                  ),
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(text: message['content']!),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (busy)
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(activity)),
                TextButton.icon(
                  onPressed: stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      composer.value.composing.isCollapsed) {
                    send();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: composer,
                  onChanged: (_) => setState(() {}),
                  enabled: !busy && configured && agent != null,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 4000,
                  decoration: const InputDecoration(
                    hintText: 'Message this agent…',
                    border: OutlineInputBorder(),
                    helperText: 'Enter to send · Shift+Enter for a new line',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: error != null && pending.isNotEmpty && !operated
                  ? 'Retry'
                  : 'Send',
              onPressed:
                  !busy &&
                      configured &&
                      agent != null &&
                      composer.text.trim().isNotEmpty
                  ? send
                  : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ],
    ),
  );
}
