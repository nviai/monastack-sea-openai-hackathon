# Agent presentation and administration

Open **Workspace tools → Agent configuration**. Signed-in members can inspect agent names, gender/persona, voice and enabled state. Users with `org-admin` or `agent-admin` may edit the complete configuration; the seeded `triet.le`, CEO `pha.le` and CTO `hao.hua` accounts have organization administration permission.

Choose **Female** or **Male** in **Gender & voice** to preview the avatar and filter the voice list. Female defaults to Marin; Male defaults to Cedar. Saving applies both the voice and the Office avatar. Female uses a bob hairstyle and ear details; Male uses short hair. Both retain the animated Rive mouth. The server rejects a Female/Male preset paired with a voice from the other presentation group. Mona can change gender alone through her management tool; the tool selects a matching voice when necessary.

Startup persists complete agent presets, including role-specific system prompts, tools/actions, activation mode, timeouts and voice:

| Agent | Gender | Voice |
| --- | --- | --- |
| Mona | Female | Marin |
| Atlas (Dev Agent) | Male | Cedar |
| Iris (QA Agent) | Female | Sage |
| Nova (PM Agent) | Female | Coral |
| Leo (Sales Agent) | Male | Ash |
| Luna (Customer Support Agent) | Female | Shimmer |

All presets wait for voice, use a 60-second no-speech timeout, a 5-second muted timeout and a 600-second session cap. Mona has agent-management and room-control actions; other agents can read public workspace data and propose tasks for approval.

The one-time `seed-agent-presets-v1` migration inserts missing configurations and fills gender/voice for legacy `unspecified` agents, retaining their other settings. Explicitly configured genders remain intact. Changes are versioned and audited. Later restarts preserve edits. Legacy nonbinary configurations remain readable.

Each of the six resident agents has persistent settings for display name, gender, voice, system prompt, enabled state, greeting, activation mode, conversation language, allowed tool groups/actions, no-speech timeout, all-microphones-muted timeout and session duration cap. Global server limits still apply. Voice choices are filtered by persona gender using voice-presentation labels; gender and voice remain separate fields. Presentation for standard voices is an app catalog label, not an identity claim. Additional Live voice presentation labels follow the [official voice catalog](https://developers.openai.com/api/docs/guides/live-conversations). Test pronunciation in the language you intend to use.

**Save configuration** uses a version check, persists settings and writes before/after audit records attributed to the administrator. **Restore defaults** is also versioned and audited. A stale editor must reload rather than overwrite another user's changes. Updates invalidate the target's existing voice lease; the supervisor restarts it with the new voice/prompt/permissions. Disabling an agent also stops its live session and rejects text chat. Prompts are not exposed in non-administrator configuration responses.


## Activation mode and waiting time

In **Voice activation**:

- **Wait for voice · mic on + speech**: no GPT-Live session until local speech detection sees an authorized unmuted mic. This remains the default for existing settings.
- **Automatic on room entry**: start GPT-Live when an authorized human connects to room media, even with the microphone off. The configured greeting can play immediately. This mode uses billable Live duration while waiting.
- **No speech timeout (seconds)**: configurable per agent from 5 to 600, default 60. A value such as 180 now works; it is no longer silently capped by the old 60-second global default.
- **All microphones muted timeout (seconds)**: configurable from 1 to 600, default 5. The current reply and delegated work finish before the model closes.

After automatic mode times out, it stays closed until new speech or a new authorized media arrival. A repeated presence heartbeat does not reopen a paid session. The safety ceiling is `LIVE_AGENT_MAX_IDLE_TIMEOUT_SECONDS` (default 600); `LIVE_AGENT_IDLE_TIMEOUT_SECONDS` is only the fallback default when agent settings are absent. Session/daily spending caps continue to apply. Modes and timeouts can also be configured by authorized Mona administration tools.

## Avatar visibility and design

Agents are drawn at full opacity and are not faded or repainted behind desks/furniture. Human camera occlusion stays unchanged. GPT-6 Astra assisted the new original shaded face design: swept hair and highlights, brows, detailed eyes, subtle nose/cheeks, and size-aware freckles. The Rive mouth still follows received audio levels; the surrounding portrait is drawn in Flutter. This is an improved composite avatar, not a new prerecorded talking clip or phoneme-aligned voice model.

A real native-rendered contact sheet is saved in `runtime/previews/agent-avatar.png`. The mouth size/position was adjusted after inspecting it at 32, 64 and 100 pixels.

## Current executable capabilities

| Tool group | Allowed actions | Requirements |
| --- | --- | --- |
| workspace | `workspace.read` | Read workspace-visible projects/tasks only |
| tasks | `tasks.propose` | Current verified speaker; requesting user must approve task creation in the app |
| agent_management | `agents.read`, `agents.configure`, `agents.reset` | System Mona plus an initiating user with agent-administration permission |
| room_control | `rooms.select`, `rooms.pause`, `rooms.resume` | System Mona plus an initiating administrator with access to the target room |

Both the action and its tool group must be enabled. The server checks the saved settings before execution; hiding a checkbox or changing a prompt is not the permission boundary. Management actions cannot be assigned to ordinary resident agents. Mona cannot change its own authority through a delegated tool; administrators can edit/reset Mona directly in the configuration dialog.

The catalog also displays additional areas (task updates, project creation, documents, customer/sales/support records, meetings, whiteboards, leave, finance, account management, additional agent creation/deletion, external messaging, shell/code, web search and integrations). These entries are explicitly disabled while no live-agent adapter is installed. Unsupported action IDs are rejected by the server; a configuration entry does not implement a business action.

## Ask Mona to configure an agent

With an administrator account, speak to Mona in Lobby or use **Workspace tools → Chat with agents → Mona**. For example:

> Set QA Agent to the cedar voice and male gender. Keep its other settings unchanged.

Mona inspects current configuration, calls the management tool with the current target version, and reports the verified outcome. Text Mona supports inspecting/updating/resetting existing agents; voice Mona also supports the configured room controls. This applies the requested configuration directly and records the initiating administrator in the audit log. Non-administrators, unverified overlapping speakers and users who leave the voice room cannot acquire these permissions by asking Mona.

Configuration changes can restart the target's audio. Existing business task proposals retain their separate explicit approval flow. No arbitrary shell execution, additional identity creation or external messaging is enabled by this feature.

## Office presentation and camera

After authenticated presence establishes room access, the client joins shared media automatically. **The camera now defaults on; the microphone stays off.** Camera publication still depends on OS permission and an available device. A manually disabled camera stays off across room changes in that login session. Explicitly leaving voice prevents automatic rejoining until the user joins again or changes rooms. Nothing is captured on the sign-in screen.

Agent names are always drawn in the same screen-space label style as users, with real online/offline status. Output transcript fragments appear in a bubble above the selected agent's head, follow pan/zoom and expire after 12 seconds without an update. Room changes and sign-out clear the presentation buffer. Transcripts are approximate and may precede audio; they do not mark work complete.

The avatar head uses a bundled Rive mouth artboard controlled by LiveKit's received audio level: silence closes the mouth, quiet speech opens it slightly, and louder speech opens it further. This is amplitude-driven articulation, not phoneme-accurate lip sync. The prerecorded demo artboards and audio timeline are never instantiated. Reduced-motion mode keeps the mouth still. Transcript text is shown only in the bubble above the avatar; the right-side live-agent card has audio controls and task approvals without repeating the transcript. The Rive asset is bundled for offline loading and includes its MIT license in `app/assets/animations/`.

## Verification

```sh
cargo test --locked --manifest-path backend/office-node/Cargo.toml
(cd app && flutter analyze && flutter test test/agent_configuration_test.dart test/agent_speech_layer_test.dart test/voice_controller_test.dart test/live_agent_panel_test.dart test/agent_chat_test.dart test/auth_session_test.dart)
```

Run paid integration checks sequentially against the local server:

```sh
runtime/live-agent/.venv/bin/python backend/live-agent/check_agent_configuration.py
runtime/live-agent/.venv/bin/python backend/live-agent/smoke.py --mona-setup
```

The configuration smoke checks real administrator/member APIs and real OpenAI Responses management calls, then restores the original QA configuration. The voice smoke uses synthetic administrator speech through real LiveKit/GPT-Live and restores QA settings afterward; it never opens host capture devices. Unit tests cover version conflicts, capability denial, private prompt visibility, admin/speaker validation, revision fencing, camera defaults/preferences, voice filtering, bubble expiry and actual native Rive asset loading.

Latest verified result: 33 Rust tests, 6 Python routing tests and 24 selected Flutter tests pass; Flutter Analyze and the macOS build pass. Real text Mona and real synthetic-voice Mona both changed QA Agent to Cedar/male through their management tool, with administrator attribution and successful restoration of the original configuration. Two RTC clients received the shared voice response (573 non-silent frames each in the management smoke). The bundled Rive file loaded successfully in the native-runtime widget test. Physical camera capture was not opened by automated tests; the app applies the default on actual authenticated media joins and surfaces device/OS permission failures.

In **Wait for voice** mode (the default), camera, presence and a silent/muted microphone do not open GPT-Live. The worker waits for three voiced 20 ms frames from an authorized unmuted microphone, keeps 300 ms of pre-roll and up to five seconds of startup audio, and only then starts the model. Turning off every mic allows the current response/work to finish and closes the model after the configured all-microphones-muted timeout (default five seconds). With an enabled but silent mic, the configured idle timeout still applies. A ready LiveKit bot is not a running OpenAI session. The greeting option applies when the conversation starts: on room entry in automatic mode, or on the first spoken interaction in voice mode.

Speech-gating update verification: 34 Rust tests, 11 Python routing/activation tests and 25 selected Flutter tests pass, along with Analyze and the macOS build. The real two-peer smoke verified zero Live duration before speech (including silent and muted microphone tracks), shared spoken output after activation, successful session closure after all mics muted, and unchanged usage while waiting afterward. Rive tests verify the isolated Mouth artboard and changes to its actual numViseme input at different audio levels.

Activation/visibility update verification: 36 Rust tests, 16 worker tests and 26 selected Flutter tests pass. The real automatic-mode test opened a paid Live session with no host capture devices, closed it using a per-agent short timeout, verified no heartbeat reopening, and restored the original Mona configuration. Existing saved configurations load with voice activation and the five-second muted timeout.

Office avatars load for all six agents immediately after sign-in through authenticated `/v1/agents/appearances`, regardless of the current room. This endpoint returns only identity/appearance metadata. The app refreshes it every five seconds and preserves appearances across room changes and transient room-status failures; speech captions remain room-scoped.

Agent names Atlas (Dev), Iris (QA), Nova (PM), Leo (Sales) and Luna (Support) are seeded in both the Office map and configuration. The one-time `seed-agent-names-v1` migration replaces original generic labels, preserving custom display names and other settings. Mona retains her name.
