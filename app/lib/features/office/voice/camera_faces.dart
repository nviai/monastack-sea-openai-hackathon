import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:monastack/features/office/voice/voice_controller.dart';

/// Camera views by actor for the office view, built from the voice state.
/// Returns `current` unchanged when the same tracks are already shown, so
/// the renderers keep their textures.
Map<String, Widget> cameraFaces(VoiceState state, Map<String, Widget> current) {
  final videos = state.phase == VoicePhase.joined
      ? state.videos
      : const <String, lk.VideoTrack>{};
  final same =
      current.length == videos.length &&
      videos.entries.every((e) => current[e.key]?.key == ValueKey(e.value.sid));
  if (same) return current;
  return {
    for (final e in videos.entries)
      e.key: lk.VideoTrackRenderer(
        e.value,
        key: ValueKey(e.value.sid),
        fit: lk.VideoViewFit.cover,
        // Textures can be clipped to a circle; platform views cannot.
        renderMode: lk.VideoRenderMode.texture,
      ),
  };
}
