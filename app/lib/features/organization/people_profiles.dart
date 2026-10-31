import 'package:flutter/material.dart';
import 'package:monastack/shared/actor_role.dart';

/// Presence is filtered by the node; absence does not prove someone is offline.
class PeopleProfiles extends StatelessWidget {
  const PeopleProfiles({
    super.key,
    required this.actors,
    required this.remote,
    required this.connectedActor,
    this.onChatAgent,
  });
  final List<Map<String, dynamic>> actors;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final String? connectedActor;
  final void Function(String)? onChatAgent;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<Map<String, dynamic>>>(
    valueListenable: remote,
    builder: (context, presence, _) => ListView(
      children: actors.map((actor) {
        final isAgent = actor['kind'] == 'agent';
        final visible = presence.any((entry) => entry['actor'] == actor['id']);
        final status = isAgent
            ? 'Agent · click to chat'
            : connectedActor == null
            ? '${actorRoleLabel(actor['role'])} · status unavailable'
            : actor['id'] == connectedActor
            ? '${actorRoleLabel(actor['role'])} · this session'
            : visible
            ? '${actorRoleLabel(actor['role'])} · visible in office'
            : '${actorRoleLabel(actor['role'])} · not currently visible';
        return Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: isAgent
                  ? const Color(0xffe5d8c9)
                  : const Color(0xffd9e7da),
              child: Text((actor['name'] as String).substring(0, 1)),
            ),
            title: Text(
              actor['name'] as String,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(status, style: const TextStyle(fontSize: 11)),
            onTap: () =>
                showActorProfile(context, actor, onChatAgent: onChatAgent),
          ),
        );
      }).toList(),
    ),
  );
}

/// Profile dialog shared by the people list and the office canvas.
Future<void> showActorProfile(
  BuildContext context,
  Map<String, dynamic> actor, {
  void Function(String)? onChatAgent,
}) {
  final isAgent = actor['kind'] == 'agent';
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(actor['name'] as String),
      content: Text(
        '${actor['kind']} · ${actorRoleLabel(actor['role'])}\n${isAgent ? 'Chat with this agent through OpenAI.' : 'Presence is filtered by room access; absence does not imply offline.'}',
      ),
      actions: [
        if (isAgent && onChatAgent != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onChatAgent(actor['id'] as String);
            },
            child: const Text('Chat with agent'),
          ),

        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
