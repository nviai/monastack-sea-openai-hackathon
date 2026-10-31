import 'package:flutter/material.dart';

/// Presence is filtered by the node; absence does not prove someone is offline.
class PeopleProfiles extends StatelessWidget {
  const PeopleProfiles({
    super.key,
    required this.actors,
    required this.remote,
    required this.connectedActor,
  });
  final List<Map<String, dynamic>> actors;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final String? connectedActor;

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
            ? 'Agent · offline'
            : connectedActor == null
            ? '${actor['role']} · status unavailable'
            : actor['id'] == connectedActor
            ? '${actor['role']} · this session'
            : visible
            ? '${actor['role']} · visible in office'
            : '${actor['role']} · not currently visible';
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
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(actor['name'] as String),
                content: Text(
                  '${actor['kind']} · ${actor['role']}\n${isAgent ? 'No runtime connected.' : 'Presence is filtered by room access; absence does not imply offline.'}',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    ),
  );
}
