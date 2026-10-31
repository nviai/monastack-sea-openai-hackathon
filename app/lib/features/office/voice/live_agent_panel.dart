import 'package:flutter/material.dart';

import 'voice_controller.dart';

/// Room-scoped, ephemeral captions and authenticated command confirmations.
class LiveAgentPanel extends StatefulWidget {
  const LiveAgentPanel({
    super.key,
    required this.data,
    required this.controller,
    required this.request,
    required this.onChanged,
  });
  final Map<String, dynamic> data;
  final VoiceController controller;
  final Future<dynamic> Function(String, String, [Object?]) request;
  final Future<void> Function() onChanged;
  @override
  State<LiveAgentPanel> createState() => _LiveAgentPanelState();
}

class _LiveAgentPanelState extends State<LiveAgentPanel> {
  bool busy = false;
  String? error;
  Future<void> act(String path, Map<String, dynamic> body) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.request('POST', path, body);
      await widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Action failed. Check your current room and permissions.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final agents = (data['agents'] as List?) ?? [];
    if (agents.isEmpty || data['enabled'] != true) {
      return const SizedBox.shrink();
    }
    final operations = (data['operations'] as List?) ?? [];
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${data['display_name'] ?? data['selected']} · ${data['state']}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  data['activation_mode'] == 'automatic'
                      ? 'Starts automatically on room entry · waits ${data['idle_seconds'] ?? 60}s without speech.'
                      : 'Enable your mic and speak · waits ${data['idle_seconds'] ?? 60}s without speech.',
                  style: TextStyle(fontSize: 11),
                ),
                if (data['message'] is String &&
                    (data['message'] as String).isNotEmpty)
                  Text(data['message'] as String),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (agents.length > 1)
                      DropdownButton<String>(
                        value: data['selected'] as String,
                        items: [
                          for (final agent in agents)
                            DropdownMenuItem(
                              value: agent as String,
                              child: Text(agent),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (agent) => act(
                                '/v1/live-agents/rooms/${data['room']}',
                                {'action': 'select', 'agent': agent},
                              ),
                      ),
                    ValueListenableBuilder<VoiceState>(
                      valueListenable: widget.controller,
                      builder: (context, _, child) {
                        final muted = widget.controller.agentMuted;
                        return Semantics(
                          toggled: !muted,
                          label: muted
                              ? 'Agent audio muted'
                              : 'Agent audio enabled',
                          child: Tooltip(
                            message: 'Only changes what you hear; other people are unaffected',
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              decoration: BoxDecoration(
                                color: muted
                                    ? const Color(0xfffff2ed)
                                    : const Color(0xffe4f3eb),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: muted
                                      ? const Color(0xffe7bba9)
                                      : const Color(0xffa8ceb9),
                                ),
                              ),
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: muted
                                      ? const Color(0xff974a32)
                                      : const Color(0xff246544),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () =>
                                    widget.controller.setAgentMuted(!muted),
                                icon: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: Icon(
                                    muted
                                        ? Icons.volume_off_rounded
                                        : Icons.volume_up_rounded,
                                    key: ValueKey(muted),
                                    size: 20,
                                  ),
                                ),
                                label: Text(
                                  muted ? 'Unmute agent' : 'Mute agent',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    if (data['can_control'] == true)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () =>
                                  act('/v1/live-agents/rooms/${data['room']}', {
                                    'action': data['state'] == 'paused'
                                        ? 'resume'
                                        : 'pause',
                                  }),
                        child: Text(
                          data['state'] == 'paused'
                              ? 'Resume agent'
                              : 'Pause agent',
                        ),
                      ),
                  ],
                ),
                for (final op in operations)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Create task: ${op['title']}'),
                      Wrap(
                        children: [
                          for (final action in ['approve', 'reject'])
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => act(
                                      '/v1/live-agents/operations/${op['id']}',
                                      {'action': action},
                                    ),
                              child: Text(
                                action == 'approve' ? 'Approve task' : 'Reject',
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
