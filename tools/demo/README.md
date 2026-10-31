# Automated AI Office demo

The opt-in Flutter integration target performs real UI actions against the local
workspace. It signs in as `pha.le`, visits Lobby and Dev & QA for actual live-agent
greetings, tours the three sample projects, proposes a clearly labeled demo task
to Atlas, then shows notifications and connected room chat. The LLM chat segment
is omitted from this shortened walkthrough.
The proposal is left pending; the demo does not claim code execution or completion.

The recorder uses macOS ScreenCaptureKit to capture only the app window and its
playback audio, then encodes video and muxes audio with FFmpeg. It does not record
the microphone. Audio is the actual live agent,
not a prerecorded replacement. No Accessibility permission is required.

Requirements: macOS 15+, Xcode/Swift, Flutter, running local office services,
configured live voice and text agents, and Screen Recording permission for the
terminal running the recorder. Close other app sessions using the same account.

From the repository root:

```sh
python3 tools/local_office.py start
cd app
flutter build macos --debug -t integration_test/automated_demo.dart
cd ..
# Read the password without storing it in shell history.
read -s MONASTACK_DEMO_PASSWORD
export MONASTACK_DEMO_PASSWORD
python3 tools/demo/run.py
unset MONASTACK_DEMO_PASSWORD
```

Outputs are timestamped under `runtime/demo/`: `demo-raw.mp4`, chapter timestamps,
and diagnostic logs. Failed runs remain for diagnosis and are not finished demos.
Flutter's sandbox uses a separate temporary control directory under the app's
macOS container. The runner closes the current app but keeps backend services up.

After recording, restore the standard app build:

```sh
cd app
flutter build macos --debug
cd ..
python3 tools/local_office.py start
```

This creates one real pending demo proposal per successful run. Keep or cancel it
through Agent proposals. Do not present the proposal as an approved/executed job.

To add local English narration (Samantha), chapter labels and action highlights:

```sh
python3 tools/demo/edit.py runtime/demo/RECORDING_TIMESTAMP
```

This exports a 1080p `monastack-demo-narrated.mp4` plus `narration.wav` and editable
scripts. It preserves actual app audio and ducks it during narration. Lobby/room
voice chapters contain no narration so the live agents remain audible. Highlights
are timed to the scripted UI layout; review them after changing window dimensions.
