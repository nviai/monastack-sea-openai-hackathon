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
  });
  final String? initialAgent;
  final UiActions? uiActions;
  final NodeRequest request;
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
    });
    try {
      var response = await widget.request(
        'POST',
        '/v1/agents/${Uri.encodeComponent(target)}/chat',
        {
          'messages': messages,
          if (widget.uiActions != null)
            'ui_controls': widget.uiActions!.snapshot(),
        },
      );
      for (var step = 0; response['ui_action'] != null && step < 10; step++) {
        if (!mounted || widget.uiActions == null) return;
        String outcome;
        try {
          outcome = await widget.uiActions!.execute(
            Map<String, dynamic>.from(response['ui_action'] as Map),
          );
        } catch (_) {
          outcome = 'The control could not be invoked. Inspect the current screen and do not assume success.';
        }
        if (!mounted) return;
        response = await widget.request(
          'POST',
          '/v1/agents/${Uri.encodeComponent(target)}/chat',
          {
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
          },
        );
      }
      if (response['ui_action'] != null) {
        response = {
          'text': 'UI step limit reached. Ask me to continue.',
          'incomplete': true,
        };
      }
      if (!mounted) return;
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
        if (response['incomplete'] == true) {
          error =
              'Response reached the output limit. Ask the agent to continue.';
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    } on NodeFailure catch (e) {
      if (mounted) {
        setState(
          () => error = switch (e.status) {
            401 || 403 => 'Your session is unavailable. Sign in again.',
            429 =>
              'Agent is busy or OpenAI quota was reached. Try again shortly.',
            503 => 'OpenAI is not configured or rejected the key. Check the backend .env and restart it.',
            _ =>
              'Could not get a response. Your message is kept below for retry.',
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Connection failed. Your message is kept below for retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
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
        const Text(
          'Chat with agents',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
              : history.isEmpty
              ? const Center(
                  child: Text('Ask this agent for help with your work.'),
                )
              : ListView.builder(
                  controller: scroll,
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final message = history[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              message['role'] == 'user' ? 'You' : 'Agent',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            SelectableText(message['content']!),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (busy) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: composer,
                enabled: !busy && configured && agent != null,
                minLines: 1,
                maxLines: 4,
                maxLength: 4000,
                decoration: const InputDecoration(
                  hintText: 'Message this agent…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Send',
              onPressed: !busy && configured && agent != null ? send : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ],
    ),
  );
}
