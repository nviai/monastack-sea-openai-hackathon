"""One server-owned GPT-Live conversation per occupied LiveKit office room."""
import asyncio
import base64
from collections import deque
import contextlib
import json
import logging
import os
from pathlib import Path
import signal
import time
import uuid

import httpx2 as httpx
import numpy as np
from dotenv import load_dotenv
from livekit import rtc
from openai import AsyncOpenAI

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / 'runtime/.env', override=False)
LOG = logging.getLogger('office.voice')
RATE = 24000
SAMPLES = 480
SILENCE = bytes(SAMPLES * 2)
AGENTS = {'mona': 'Mona, office assistant', 'dev-agent': 'Dev Agent, software engineer',
          'qa-agent': 'QA Agent, quality engineer', 'pm-agent': 'PM Agent, product manager',
          'sales-agent': 'Sales Agent', 'cskh-agent': 'Customer Support Agent'}


class AudioRouter:
    """Bounded per-track frames; conservative ownership across overlapping speech."""
    def __init__(self):
        self.frames = {}
        self.allowed = {}
        self.history = deque(maxlen=3000)
        self.samples = 0
        self.open_mics = None

    def microphones(self, identities):
        self.open_mics = set(identities) & self.allowed.keys()
        self.frames = {k:v for k,v in self.frames.items() if k in self.open_mics}

    def record(self, actors):
        self.history.append((self.samples / RATE * 1000, actors))
        self.samples += SAMPLES

    def roster(self, users):
        self.allowed = {f"{u['actor']}.{u['session'][:12]}": u['actor'] for u in users}
        self.frames = {k: v for k, v in self.frames.items() if k in self.allowed}

    def push(self, identity, pcm):
        if identity not in self.allowed or (self.open_mics is not None and identity not in self.open_mics):
            return
        queue = self.frames.setdefault(identity, deque(maxlen=10))
        queue.append(pcm)

    def tick(self, record=True):
        active = []
        audio_frames = []
        for identity, frames in list(self.frames.items()):
            if identity not in self.allowed or (self.open_mics is not None and identity not in self.open_mics) or not frames:
                continue
            pcm = frames.popleft()
            a = np.frombuffer(pcm, dtype='<i2')
            if len(a) != SAMPLES:
                continue
            audio_frames.append(a)
            if np.sqrt(np.mean(a.astype(np.float64) ** 2)) > 350:
                active.append((self.allowed[identity], a))
        actors = frozenset(actor for actor, _ in active)
        if record:
            self.record(actors)
        if not audio_frames:
            return SILENCE, actors
        mixed = np.sum([a.astype(np.int32) for a in audio_frames], axis=0)
        return np.clip(mixed, -32768, 32767).astype('<i2').tobytes(), actors

    def owner(self, start_ms, end_ms):
        owners = set()
        for at, actors in self.history:
            if start_ms - 100 <= at <= end_ms + 100:
                if len(actors) > 1:
                    return None
                owners.update(actors)
        return next(iter(owners)) if len(owners) == 1 else None


class Authority:
    def __init__(self):
        token = (ROOT / 'runtime/live-agent/worker.token').read_text().strip()
        self.client = httpx.AsyncClient(base_url=os.getenv('LIVE_AGENT_AUTHORITY', 'http://127.0.0.1:47830'),
            headers={'Authorization': f'Bearer {token}'}, timeout=10)

    async def call(self, path, data=None):
        response = await self.client.request('GET' if data is None else 'POST', '/v1/voice-worker/' + path, json=data)
        response.raise_for_status()
        return response.json()


class Bridge:
    def __init__(self, authority, plan, settings):
        self.authority, self.plan, self.settings = authority, plan, settings
        self.room_id, self.agent = plan['room'], plan['agent']
        self.config = plan.get('config', {})
        self.actions = set(self.config.get('actions', ['workspace.read', 'tasks.propose']))
        self.tools = set(self.config.get('tools', ['workspace', 'tasks']))
        self.language_rule = {'vi': 'Always answer in Vietnamese.', 'en': 'Always answer in English.'}.get(self.config.get('language'), 'Answer in the speaker language, including Vietnamese.')
        self.room = rtc.Room()
        self.router = AudioRouter()
        self.router.roster(plan['users'])
        self.source = rtc.AudioSource(RATE, 1, queue_size_ms=200)
        self.output = asyncio.Queue(maxsize=25)
        self.tasks = set()
        self.transcripts = deque(maxlen=100)
        self.state = 'starting'
        self.started = time.monotonic()
        self.last_activity = self.started
        self.connection = None
        self.usage = 0.
        self.model_started = None
        self.greeted = False
        self.closed = False
        self.claim = None
        self.last_output = 0.
        self.delegations = set()
        self.reported_operations = set()
        self.had_input = False
        self.wake = asyncio.Event()
        self.collecting = False
        self.pre_roll = deque(maxlen=15)
        self.input_frames = asyncio.Queue(maxsize=250)
        self.speech_frames = 0
        self.work_count = 0
        self.connected_users = set()
        self.wake_reason = "voice"
        self.openai = AsyncOpenAI()

    def spawn(self, coro):
        task = asyncio.create_task(coro)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    def payload(self, **extra):
        return dict(room=self.room_id, lease=self.claim['lease'], **extra)

    async def report(self, **extra):
        result = await self.authority.call('report', self.payload(state=self.state, seconds=self.usage + (time.monotonic()-self.model_started if self.model_started is not None else 0), **extra))
        self.router.roster(result['users'])
        self.sync_subscriptions()
        if not result['active']:
            raise RuntimeError('lease ended')
        return result

    def idle_timeout(self):
        return min(self.settings.get('max_idle_seconds', 600), self.config.get('idle_seconds', self.settings.get('idle_seconds', 60)))

    def muted_timeout(self):
        return min(self.settings.get('max_idle_seconds', 600), self.config.get('muted_idle_seconds', 5))

    def can_start(self):
        return bool(self.router.open_mics) or (self.wake_reason == 'automatic' and self.config.get('activation_mode', 'voice') == 'automatic' and bool(self.connected_users))

    def on_connected_users(self, connected):
        new_users = set(connected) - self.connected_users
        self.connected_users = set(connected)
        # Entry is an event, not a repeating heartbeat. Idle closure must stay closed.
        if new_users and self.config.get('activation_mode', 'voice') == 'automatic' and not self.collecting and self.connection is None:
            self.collecting = True
            self.wake_reason = 'automatic'
            for frame in self.pre_roll:
                if not self.input_frames.full():
                    self.input_frames.put_nowait(frame)
            self.pre_roll.clear()
            self.wake.set()

    def sync_subscriptions(self):
        open_mics = set()
        for participant in self.room.remote_participants.values():
            for publication in participant.track_publications.values():
                allowed = participant.identity in self.router.allowed and publication.source == rtc.TrackSource.SOURCE_MICROPHONE
                publication.set_subscribed(allowed)
                if allowed and not publication.muted:
                    open_mics.add(participant.identity)
        self.router.microphones(open_mics)
        self.on_connected_users(set(self.room.remote_participants) & self.router.allowed.keys())

    async def run(self):
        try:
            self.claim = await self.authority.call(f'rooms/{self.room_id}/claim', {'agent': self.agent})
        except BaseException:
            await self.source.aclose()
            await self.openai.close()
            raise
        @self.room.on('track_subscribed')
        def subscribed(track, publication, participant):
            if publication.source == rtc.TrackSource.SOURCE_MICROPHONE and participant.identity in self.router.allowed:
                self.spawn(self.read_track(track, participant.identity))
        @self.room.on('track_published')
        def published(publication, participant):
            self.sync_subscriptions()
        @self.room.on('track_muted')
        def muted(publication, participant):
            self.sync_subscriptions()
        @self.room.on('track_unmuted')
        def unmuted(publication, participant):
            self.sync_subscriptions()
        @self.room.on('track_unpublished')
        def unpublished(publication, participant):
            self.sync_subscriptions()
        @self.room.on('participant_connected')
        def connected(participant):
            self.sync_subscriptions()
        @self.room.on('participant_disconnected')
        def disconnected(participant):
            self.sync_subscriptions()
        try:
            await self.room.connect(self.claim['url'], self.claim['token'], rtc.RoomOptions(auto_subscribe=False))
            self.sync_subscriptions()
            track = rtc.LocalAudioTrack.create_audio_track(self.agent, self.source)
            await self.room.local_participant.publish_track(track,
                rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
            self.state = 'ready'
            self.spawn(self.playback())
            self.spawn(self.heartbeat())
            self.spawn(self.pump_input())
            while not self.closed and not any(p.identity in self.router.allowed for p in self.room.remote_participants.values()):
                await asyncio.sleep(.1)
            await self.converse()
        except Exception as error:
            self.state = 'error'
            with contextlib.suppress(Exception):
                await self.report(message='Voice connection failed; retrying. Check server configuration, quota or network.')
            LOG.warning('voice failed room=%s type=%s', self.room_id, type(error).__name__)
            raise
        finally:
            self.closed = True
            for task in list(self.tasks):
                task.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)
            with contextlib.suppress(Exception):
                await self.authority.call('report', self.payload(state='closed', seconds=self.usage))
            await self.room.disconnect()
            await self.source.aclose()
            await self.openai.close()

    async def read_track(self, track, identity):
        stream = rtc.AudioStream(track, sample_rate=RATE, num_channels=1, frame_size_ms=20, capacity=10)
        try:
            async for event in stream:
                self.router.push(identity, bytes(event.frame.data))
        finally:
            await stream.aclose()

    async def heartbeat(self):
        while True:
            try:
                if self.state == 'speaking' and time.monotonic() - self.last_output > .8:
                    self.state = 'listening' if self.connection else 'ready'
                result = await self.report()
                for operation in result.get('operations', []):
                    if operation['id'] not in self.reported_operations and self.connection:
                        self.reported_operations.add(operation['id'])
                        await self.connection.session.commentary.append(content='A task proposal was ' + ('approved and the task was created successfully.' if operation['state'] == 'completed' else 'rejected; no task was created.'), delegation_id=None)
            except Exception:
                self.closed = True
                self.wake.set()
                if self.connection:
                    with contextlib.suppress(Exception):
                        await self.connection.session.close()
                return
            await asyncio.sleep(2)

    async def playback(self):
        while True:
            pcm = await self.output.get()
            await self.source.capture_frame(rtc.AudioFrame(pcm, RATE, 1, len(pcm) // 2))

    async def pump_input(self):
        """Local VAD only; no provider connection is needed to observe an enabled mic."""
        deadline = time.monotonic()
        while not self.closed:
            frame = self.router.tick(record=False)
            pcm, actors = frame
            if actors and self.collecting:
                self.last_activity = time.monotonic()
            if not self.collecting:
                if not self.router.open_mics:
                    self.pre_roll.clear()
                else:
                    self.pre_roll.append(frame)
                self.speech_frames = self.speech_frames + 1 if actors and self.router.open_mics else 0
                # 60 ms rejects isolated clicks; 300 ms pre-roll preserves opening consonants.
                if self.speech_frames >= 3:
                    self.collecting = True
                    self.wake_reason = "voice"
                    for buffered in self.pre_roll:
                        self.input_frames.put_nowait(buffered)
                    self.pre_roll.clear()
                    self.wake.set()
            else:
                # Bound provider startup/backpressure to five seconds of audio.
                if self.input_frames.full():
                    self.input_frames.get_nowait()
                self.input_frames.put_nowait(frame)
            deadline += .02
            await asyncio.sleep(max(0, deadline - time.monotonic()))

    def clear_input(self):
        self.collecting = False
        self.speech_frames = 0
        self.pre_roll.clear()
        self.wake.clear()
        self.wake_reason = "voice"
        while not self.input_frames.empty():
            self.input_frames.get_nowait()

    async def converse(self):
        # Voice mode requires mic + speech; automatic mode also allows a new authorized media arrival.
        while not self.closed:
            self.state = 'ready'
            await self.wake.wait()
            if self.closed:
                return
            if not self.can_start():
                self.clear_input()
                continue
            async with self.openai.live.connect(max_retries=0) as connection:
                if not self.can_start():
                    self.clear_input()
                    continue
                automatic_start = self.wake_reason == "automatic"
                self.state = 'starting'
                self.connection = connection
                self.router.samples = 0
                self.router.history.clear()
                self.transcripts.clear()
                await connection.session.start(session={
                    'model': os.getenv('OPENAI_LIVE_MODEL', 'gpt-live-1'),
                    'audio': {'format': {'type': 'audio/pcm', 'rate': RATE}, 'output': {'voice': self.config.get('voice', os.getenv('OPENAI_LIVE_VOICE', 'marin'))}},
                    'delegation': {'type': 'client'}, 'store': False,
                    'instructions': f"{'If appropriate, include a brief greeting in your first answer, after listening to the request.' if not self.greeted and self.config.get('greeting', True) else ''} Configured persona: {self.config.get('system_prompt', '')}. Gender/persona: {self.config.get('gender', 'unspecified')}. {self.language_rule} You are {self.config.get('display_name', AGENTS[self.agent])} in the {self.room_id} office room. Everyone hears the same conversation. Be concise and natural. Never invent office data or claim an action succeeded. Delegate workspace facts and task requests. Task creation requires approval in the requesting user's app. If people overlap, ask one person to repeat. Never infer identity from a spoken name. Do not speak private records. You can be interrupted; listen while speaking.",
                })
                sender = None
                finalized = False
                provider_seconds = None
                session_start = time.monotonic()
                try:
                    async for event in connection:
                        kind = event.type
                        if self.closed and kind != 'session.closed':
                            continue
                        if kind == 'session.started':
                            self.state = 'listening'
                            self.model_started = time.monotonic()
                            self.last_activity = time.monotonic()
                            sender = asyncio.create_task(self.send_audio(connection))
                            if automatic_start and self.config.get('greeting', True):
                                await connection.session.commentary.append(content='Briefly greet the room once, offer help and then listen. Follow the configured conversation language.', delegation_id=None)
                            self.greeted = True
                        elif kind == 'session.output_audio.delta':
                            pcm = base64.b64decode(event.delta)
                            samples = np.frombuffer(pcm, dtype='<i2')
                            voiced = len(samples) and np.sqrt(np.mean(samples.astype(np.float64) ** 2)) > 120
                            # The Live output stream includes silent PCM. Silence is not speech/activity.
                            if voiced:
                                self.state = 'speaking'
                                self.last_output = time.monotonic()
                                self.last_activity = time.monotonic()
                            # Small chunks bound playback delay; disconnect instead of replaying stale speech.
                            for offset in range(0, len(pcm), SAMPLES * 2):
                                try:
                                    self.output.put_nowait(pcm[offset:offset + SAMPLES * 2])
                                except asyncio.QueueFull:
                                    self.source.clear_queue()
                                    while not self.output.empty():
                                        self.output.get_nowait()
                                    break
                        elif kind in ('session.input_transcript.delta', 'session.output_transcript.delta'):
                            speaker = self.agent
                            if kind == 'session.input_transcript.delta':
                                start, end = getattr(event, 'start_ms', 0), getattr(event, 'end_ms', 0)
                                speaker = self.router.owner(start, end)
                                self.transcripts.append((start, end, speaker, event.delta))
                            if speaker:
                                await self.report(caption=event.delta, speaker=speaker)
                        elif kind == 'session.delegation.created':
                            if event.delegation.id not in self.delegations:
                                self.delegations.add(event.delegation.id)
                                self.spawn(self.delegate(connection, event.delegation.id, event.offset_ms))
                        elif kind == 'session.closed':
                            finalized = True
                            provider_seconds = event.usage.seconds
                            break
                        elif kind == 'error':
                            raise RuntimeError('provider session error')
                finally:
                    if sender:
                        sender.cancel()
                        await asyncio.gather(sender, return_exceptions=True)
                    # Finalization is a protocol event, not merely a closed socket.
                    if not finalized:
                        with contextlib.suppress(Exception):
                            async with asyncio.timeout(3):
                                await connection.session.close()
                                async for final in connection:
                                    if final.type == 'session.closed':
                                        provider_seconds = final.usage.seconds
                                        finalized = True
                                        break
                    self.usage += provider_seconds if provider_seconds is not None else time.monotonic() - session_start
                    self.model_started = None
                    if not finalized:
                        LOG.warning('provider finalization unconfirmed room=%s', self.room_id)
                    self.connection = None
                    self.clear_input()
            if time.monotonic() - self.started >= min(self.settings['session_seconds'], self.config.get('session_seconds', 600)):
                return

    async def send_audio(self, connection):
        deadline = time.monotonic()
        while not self.closed:
            pcm, actors = await self.input_frames.get()
            if actors:
                if not self.had_input:
                    self.source.clear_queue()
                    while not self.output.empty():
                        self.output.get_nowait()
                self.last_activity = time.monotonic()
                self.state = 'listening'
            self.had_input = bool(actors)
            await connection.session.input_audio.append(audio=base64.b64encode(pcm).decode())
            self.router.record(actors)
            idle = time.monotonic() - self.last_activity
            quiet_output = time.monotonic() - self.last_output > .8
            timeout = self.idle_timeout()
            # Finish the current reply/work, then close promptly if everyone muted.
            if quiet_output and self.work_count == 0 and (idle > timeout or (not self.router.open_mics and idle > self.muted_timeout())):
                self.source.clear_queue()
                await connection.session.close()
                return
            deadline += .02
            await asyncio.sleep(max(0, deadline - time.monotonic()))

    async def delegate(self, connection, delegation_id, offset):
        self.work_count += 1
        try:
            candidates = [s for s in self.transcripts if offset - 12000 <= s[1] <= offset + 500]
            spans = []
            for span in reversed(candidates):
                if spans and spans[0][0] - span[1] > 800:
                    break
                spans.insert(0, span)
            actor = self.router.owner(min(s[0] for s in spans), max(s[1] for s in spans)) if spans else None
            if not actor:
                await connection.session.commentary.append(content='Ask one person to repeat their request without overlapping speech; the initiating speaker could not be verified.', delegation_id=delegation_id)
                return
            self.state = 'working'
            await connection.session.thinking.append(content='Checking the current workspace and permissions.', delegation_id=delegation_id)
            context = await self.authority.call('context', self.payload(actor=actor, id=delegation_id)) if 'workspace.read' in self.actions and 'workspace' in self.tools else {'scope': 'Workspace read access is disabled.'}
            tools = [{'type': 'function', 'name': 'propose_task', 'description': 'Propose a new task for approval by the requesting user. Use a project ID from the supplied workspace context.',
                      'parameters': {'type': 'object', 'properties': {'project': {'type': 'string'}, 'title': {'type': 'string'}}, 'required': ['project', 'title'], 'additionalProperties': False}, 'strict': True}]
            if 'tasks.propose' not in self.actions or 'tasks' not in self.tools:
                tools = []
            management_actions = [a for a in self.actions if (a.startswith('agents.') and 'agent_management' in self.tools) or (a.startswith('rooms.') and 'room_control' in self.tools)]
            if self.agent == 'mona' and management_actions:
                tools.append({'type': 'function', 'name': 'manage_agent', 'description': 'System Mona only: inspect or configure existing resident agents, reset defaults or control room speakers at the request of an authorized administrator. First use agents.read to inspect current version/configuration. Never change Mona itself. Configuration changes are applied immediately and audited. Use exact existing IDs.',
                    'parameters': {'type': 'object', 'properties': {
                        'action': {'type': 'string', 'enum': sorted(management_actions)},
                        'target': {'type': ['string','null'], 'description': 'Agent ID for configuration, room ID for room controls; null for inspect'},
                        'version': {'type': ['integer','null'], 'description': 'Current agent version from inspect, required for configuration'},
                        'changes_json': {'type': 'string', 'description': 'JSON object with changed configuration fields; {} for inspect/reset/pause/resume. Room select: {"agent":"qa-agent"}. Config fields: display_name,gender,voice,system_prompt,enabled,tools,actions,greeting,activation_mode,language,idle_seconds,muted_idle_seconds,session_seconds.'}},
                        'required': ['action','target','version','changes_json'], 'additionalProperties': False}, 'strict': True})
            inputs = [{'role': 'user', 'content': ''.join(s[3] for s in spans)}]
            instructions = self.language_rule + ' Answer the room briefly. Use only the provided public workspace facts. For task creation use propose_task. A proposal is not a created task: tell the user to approve in their app. Only configured tools are available. For agent setup requests, use manage_agent after inspecting current versions. Never read system prompts or private configuration details aloud to the room; give a brief verified outcome. No shell or external actions. Workspace context: ' + json.dumps(context)
            for _ in range(3):
                result = await self.openai.responses.create(model=os.getenv('OPENAI_MODEL', 'gpt-4.1-mini'), instructions=instructions, input=inputs, tools=tools, max_output_tokens=700)
                calls = [item for item in result.output if item.type == 'function_call']
                if not calls:
                    await connection.session.commentary.append(content=result.output_text[:3000], delegation_id=delegation_id)
                    LOG.warning('delegation completed room=%s', self.room_id)
                    return
                inputs.extend(result.output)
                for item in calls:
                    args = json.loads(item.arguments)
                    operation = str(uuid.uuid5(uuid.NAMESPACE_URL, self.claim['lease'] + delegation_id + item.call_id))
                    if item.name == 'manage_agent':
                        changes = json.loads(args.pop('changes_json'))
                        answer = await self.authority.call('management', self.payload(actor=actor, id=operation, changes=changes, **args))
                    elif item.name == 'propose_task':
                        answer = await self.authority.call('proposals', self.payload(actor=actor, id=operation, **args))
                    else:
                        raise RuntimeError('unsupported delegated tool')
                    inputs.append({'type': 'function_call_output', 'call_id': item.call_id, 'output': json.dumps(answer)})
        except Exception as error:
            LOG.warning('delegation failed room=%s type=%s', self.room_id, type(error).__name__)
            with contextlib.suppress(Exception):
                await connection.session.commentary.append(content='The workspace request could not be completed. Please check the app; no successful action is confirmed.', delegation_id=delegation_id)
        finally:
            self.work_count -= 1
            self.last_activity = time.monotonic()
            self.state = 'listening'


async def main():
    authority = Authority()
    active = {}
    retry = {}
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, stop.set)
    try:
        while not stop.is_set():
            try:
                settings = await authority.call('rooms')
                desired = {p['room']: p for p in settings['rooms']}
                for room, (plan, task) in list(active.items()):
                    target = desired.get(room)
                    if task.done() or not target or (target['agent'], target['epoch'], target.get('revision', 0)) != (plan['agent'], plan['epoch'], plan.get('revision', 0)):
                        task.cancel()
                        results = await asyncio.gather(task, return_exceptions=True)
                        if isinstance(results[0], Exception):
                            LOG.warning('room worker stopped room=%s type=%s', room, type(results[0]).__name__)
                        retry[room] = time.monotonic() + 10
                        del active[room]
                for room, plan in desired.items():
                    if room not in active and len(active) < settings['max_concurrent'] and time.monotonic() >= retry.get(room, 0):
                        bridge = Bridge(authority, plan, settings)
                        active[room] = (plan, asyncio.create_task(bridge.run()))
            except Exception as error:
                LOG.warning('authority unavailable type=%s', type(error).__name__)
                # Fail closed: do not keep a disconnected authority's audio alive.
                for _, task in active.values():
                    task.cancel()
                await asyncio.gather(*(t for _, t in active.values()), return_exceptions=True)
                active.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(stop.wait(), 2)
    finally:
        for _, task in active.values():
            task.cancel()
        await asyncio.gather(*(t for _, t in active.values()), return_exceptions=True)
        await authority.client.aclose()


if __name__ == '__main__':
    logging.basicConfig(level=logging.WARNING, format='%(asctime)s %(name)s %(message)s')
    asyncio.run(main())
