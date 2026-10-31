# ADR 0007: Camera faces and app icons

Status: accepted for the local topology. Real-webcam capture and the camera permission prompt are pending (manual).

## Context

The earlier Monastack client (the original repository) showed each person's webcam in a round bubble that *was* their character in the office. Stage 1 here had drawn avatars and audio-only voice (ADR 0006). The app also used the default Flutter icon and only had a macOS target.

## Decision

- **Camera rides the voice connection.** The camera is published into the same per-room LiveKit room as the microphone, so the voice control plane governs it. Join tokens allow the `microphone` and `camera` sources and nothing else (no screen share, no data). Only people in the same media room receive the video. Revocation, room rotation, leaving the room and restart behave exactly as for audio.
- **Off on every join.** Like the microphone, the camera is off whenever a voice room is joined, including when voice follows you into another room. Turning it on is an explicit button in the voice panel ("Turn camera on") and triggers the OS permission prompt (`NSCameraUsageDescription`, `com.apple.security.device.camera`). A camera failure turns the camera off and leaves voice running.
- **Face replacement.** For each actor with a live camera track (the local preview included), the drawn head is omitted and a circular video bubble with a white border sits on the avatar's shoulders. The office canvas computes the bubble's screen position each frame (`WorldGame.faceSlots`); a Flutter overlay (`FaceLayer`) places `VideoTrackRenderer` textures there, because platform textures cannot be drawn inside the Flame canvas. The overlay only ticks while a camera is shown. Clicking the bubble opens the profile.
  - The overlay is above the canvas, so walls cannot hide a bubble. When the head would be behind a wall or furniture the bubble is drawn at 35 % opacity instead.
  - Capture is 480×360 at up to 24 fps, enough for a bubble of at most 140 px.
- **Logo.** An original mark: an "M" built from isometric blocks like the office walls, with a person standing in its notch, on the brand blue (#3B6BF6) with yellow (#F7C744). It is drawn in code (`lib/shared/brand/monastack_logo.dart`), shown in the sidebar, and rendered into every platform's icon by `flutter test tool/generate_icons.dart` (macOS, iOS without alpha, Android legacy and adaptive, web and maskable, Windows `.ico`, Linux window icon from the bundled asset).
- **Platform scaffolds.** iOS, Android, web, Windows and Linux runners were added so the icons and names exist on every platform. They are **scaffolds only**: the Rust core is built and bundled for macOS only, the app accepts loopback services only, and none of these targets has been built or run. Camera and microphone usage strings and permissions are declared on iOS and Android.

## Consequences

- Seeing someone's face requires both of you in the same room's voice with their camera on. There is no "video visible to everyone, audio by proximity" mode as in the original client; that would need a separate media policy.
- Camera adds bandwidth on the loopback media server. No measurements with several real cameras exist.

## Verification

- `tools/media-spike/.venv/bin/python backend/office-node/tests/voice_app.py`: a synthetic peer published generated audio and a generated camera video in the lobby. The macOS app (camera and microphone never turned on) received the video, showed it in place of the peer's face, decoded at least 10 frames, and removed it after walking into Dev & QA. A private close-up capture was written to the app container.
- `voice_control.py` (unchanged scenarios) and the Rust grant test cover the token sources.
- Widget and unit tests: face bubbles replace and remove faces and open the profile (`office_view_test.dart`); the camera is off on every join and failures leave voice running (`voice_controller_test.dart`).
- Not verified: a real webcam, the macOS camera permission prompt, two people seeing each other, any non-macOS platform.
