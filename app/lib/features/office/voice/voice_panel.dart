import 'package:flutter/material.dart';

import 'package:monastack/features/office/voice/voice_controller.dart';

/// Mic/camera buttons are always visible after sign-in and connect on demand.
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
      final connecting = state.phase == VoicePhase.joining;
      final joined = state.phase == VoicePhase.joined;
      final others = state.participants.map((a) => names[a] ?? a).toList()
        ..sort();
      final speaking = state.speaking.map((a) => names[a] ?? a).toList()
        ..sort();
      final status = connecting
          ? 'Connecting media…'
          : joined
          ? [
              state.microphone ? 'Microphone on' : 'Muted',
              if (state.camera) 'camera on',
              others.isEmpty
                  ? 'nobody else here'
                  : '${others.length} here, hearing ${state.hearing.length}',
              if (speaking.isNotEmpty) 'speaking: ${speaking.join(', ')}',
            ].join(' · ')
          : 'Turn on your mic or camera in $roomName';
      return Semantics(
        container: true,
        label: 'Microphone and camera',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: state.microphone
                        ? 'Mute microphone'
                        : 'Unmute microphone',
                    onPressed: connecting
                        ? null
                        : () => controller.toggleMicrophone(room),
                    icon: Icon(state.microphone ? Icons.mic : Icons.mic_off),
                    color: state.microphone ? const Color(0xff2f7a5f) : null,
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: state.camera
                        ? 'Turn camera off'
                        : 'Turn camera on',
                    onPressed: connecting
                        ? null
                        : () => controller.toggleCamera(room),
                    icon: Icon(
                      state.camera ? Icons.videocam : Icons.videocam_off,
                    ),
                    color: state.camera ? const Color(0xff2f7a5f) : null,
                  ),
                  if (connecting)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (joined)
                    IconButton(
                      tooltip: 'Leave voice',
                      onPressed: controller.leave,
                      icon: const Icon(Icons.call_end, size: 18),
                    ),
                ],
              ),
              Text(
                status,
                style: const TextStyle(fontSize: 11),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (state.message != null)
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
