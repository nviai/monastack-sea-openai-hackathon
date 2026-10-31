import 'package:flutter/material.dart';

import 'package:monastack/features/office/voice/voice_controller.dart';

/// Voice controls for the current room. Joining is explicit, the microphone
/// and camera start off, and failures point back to room chat.
class VoicePanel extends StatelessWidget {
  const VoicePanel({
    super.key,
    required this.controller,
    required this.room,
    required this.roomName,
    required this.names,
  });

  final VoiceController controller;
  final String room;
  final String roomName;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VoiceState>(
    valueListenable: controller,
    builder: (context, state, _) {
      final muted = !state.microphone;
      final camera = state.camera;
      final others = state.participants.map((a) => names[a] ?? a).toList()
        ..sort();
      final speaking = state.speaking.map((a) => names[a] ?? a).toList()
        ..sort();
      final Widget body = switch (state.phase) {
        VoicePhase.joined => Row(
          children: [
            IconButton.filledTonal(
              tooltip: muted ? 'Unmute microphone' : 'Mute microphone',
              onPressed: () => controller.setMicrophone(muted),
              icon: Icon(muted ? Icons.mic_off : Icons.mic),
              color: muted ? null : const Color(0xff2f7a5f),
            ),
            const SizedBox(width: 4),
            IconButton.filledTonal(
              tooltip: camera ? 'Turn camera off' : 'Turn camera on',
              onPressed: () => controller.setCamera(!camera),
              icon: Icon(camera ? Icons.videocam : Icons.videocam_off),
              color: camera ? const Color(0xff2f7a5f) : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [
                  muted ? 'Muted' : 'Microphone on',
                  if (camera) 'camera on',
                  others.isEmpty
                      ? 'nobody else here'
                      : '${others.length} here, hearing ${state.hearing.length}',
                  if (speaking.isNotEmpty) 'speaking: ${speaking.join(', ')}',
                ].join(' · '),
                style: const TextStyle(fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Leave voice',
              onPressed: controller.leave,
              icon: const Icon(Icons.call_end, size: 18),
            ),
          ],
        ),
        VoicePhase.joining => const Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Connecting to voice…', style: TextStyle(fontSize: 11)),
          ],
        ),
        VoicePhase.idle => Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => controller.join(room),
            icon: const Icon(Icons.headset_mic_outlined, size: 18),
            label: Text('Join voice in $roomName'),
          ),
        ),
        _ => Text(
          state.message ?? 'Voice unavailable · use room chat',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
      };
      return Semantics(
        container: true,
        label: 'Voice',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              body,
              if (state.phase == VoicePhase.joined && state.message != null)
                Text(
                  state.message!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
            ],
          ),
        ),
      );
    },
  );
}
