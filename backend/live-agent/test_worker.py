import unittest
import numpy as np
from worker import AudioRouter, SAMPLES, SILENCE

LOUD = np.full(SAMPLES, 2000, dtype='<i2').tobytes()
class AudioRoutingTests(unittest.TestCase):
    def setUp(self):
        self.router = AudioRouter()
        self.router.roster([{'actor': 'an', 'session': '1234567890123456'}, {'actor': 'van', 'session': 'abcdefghijklmnop'}])

    def test_unknown_and_bot_tracks_are_not_forwarded(self):
        for identity in ['mona.bot', 'an.forged', 'out-of-room.session']:
            self.router.push(identity, LOUD)
        self.assertEqual(self.router.tick(), (SILENCE, frozenset()))

    def test_attribution_uses_authenticated_track(self):
        self.router.push('an.123456789012', LOUD)
        pcm, actors = self.router.tick()
        self.assertEqual(pcm, LOUD)
        self.assertEqual(actors, {'an'})
        self.assertEqual(self.router.owner(0, 20), 'an')

    def test_overlapping_speakers_cannot_authorize_commands(self):
        self.router.push('an.123456789012', LOUD)
        self.router.push('van.abcdefghijkl', LOUD)
        self.router.tick()
        self.assertIsNone(self.router.owner(0, 20))

    def test_removed_participants_stop_immediately(self):
        self.router.push('an.123456789012', LOUD)
        self.router.roster([])
        self.assertEqual(self.router.tick()[0], SILENCE)

    def test_backpressure_bounds_lag(self):
        for _ in range(1000):
            self.router.push('an.123456789012', LOUD)
        self.assertEqual(len(self.router.frames['an.123456789012']), 10)

    def test_two_sessions_of_one_actor_are_one_owner(self):
        self.router.roster([{'actor': 'an', 'session': '123456789012'}, {'actor': 'an', 'session': 'abcdefghijkl'}])
        self.router.push('an.123456789012', LOUD)
        self.router.push('an.abcdefghijkl', LOUD)
        self.router.tick()
        self.assertEqual(self.router.owner(0, 20), 'an')


class SpeechActivationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from worker import Bridge
        from types import SimpleNamespace
        self.bridge = Bridge(None, {'room':'lobby','agent':'mona','users':[{'actor':'an','session':'123456789012'}]}, {'idle_seconds':60,'session_seconds':600})
        await self.bridge.openai.close()
        self.connections = 0
        owner = self
        class StopConnect:
            async def __aenter__(self):
                owner.connections += 1
                raise RuntimeError('test connection sentinel')
            async def __aexit__(self,*args): pass
        self.bridge.openai = SimpleNamespace(live=SimpleNamespace(connect=lambda **kwargs:StopConnect()))
        self.bridge.router.microphones([])
        import asyncio
        self.tasks=[asyncio.create_task(self.bridge.pump_input()),asyncio.create_task(self.bridge.converse())]

    async def asyncTearDown(self):
        import asyncio
        self.bridge.closed=True
        for task in self.tasks: task.cancel()
        await asyncio.gather(*self.tasks,return_exceptions=True)
        await self.bridge.source.aclose()

    async def test_camera_or_presence_without_a_mic_never_opens_live(self):
        import asyncio
        await asyncio.sleep(.12)
        self.assertEqual(self.connections,0)
        self.assertEqual(self.bridge.usage,0)

    async def test_unmuted_but_silent_mic_does_not_open_live(self):
        import asyncio
        self.bridge.router.microphones(['an.123456789012'])
        for _ in range(8): self.bridge.router.push('an.123456789012',SILENCE)
        await asyncio.sleep(.2)
        self.assertEqual(self.connections,0)

    async def test_muted_track_and_one_click_cannot_wake_live(self):
        import asyncio
        for _ in range(5): self.bridge.router.push('an.123456789012',LOUD)
        await asyncio.sleep(.1)
        self.assertEqual(self.connections,0)
        self.bridge.router.microphones(['an.123456789012'])
        self.bridge.router.push('an.123456789012',LOUD)
        for _ in range(7): self.bridge.router.push('an.123456789012',SILENCE)
        await asyncio.sleep(.2)
        self.assertEqual(self.connections,0)

    async def test_continuous_speech_wakes_live_and_preserves_opening_audio(self):
        import asyncio
        self.bridge.router.microphones(['an.123456789012'])
        for _ in range(6): self.bridge.router.push('an.123456789012',LOUD)
        await asyncio.sleep(.15)
        self.assertEqual(self.connections,1)
        self.assertTrue(self.tasks[1].done())
        with self.assertRaisesRegex(RuntimeError,'sentinel'):
            await self.tasks[1]
        pcm,actors=self.bridge.input_frames.get_nowait()
        self.assertEqual(pcm,LOUD)
        self.assertEqual(actors,{'an'})

    async def test_muting_discards_unprocessed_speech(self):
        import asyncio
        self.bridge.router.microphones(['an.123456789012'])
        for _ in range(6): self.bridge.router.push('an.123456789012',LOUD)
        self.bridge.router.microphones([])
        await asyncio.sleep(.2)
        self.assertEqual(self.connections,0)


class ActivationConfigurationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from worker import Bridge
        self.bridge=Bridge(None, {'room':'lobby','agent':'mona','users':[{'actor':'an','session':'123456789012'}], 'config':{'activation_mode':'automatic','idle_seconds':180,'muted_idle_seconds':12}}, {'idle_seconds':60,'max_idle_seconds':600,'session_seconds':600})
        self.bridge.router.microphones([])
    async def asyncTearDown(self):
        await self.bridge.source.aclose()
        await self.bridge.openai.close()
    async def test_automatic_entry_can_start_with_microphones_off(self):
        self.bridge.on_connected_users({'an.123456789012'})
        self.assertTrue(self.bridge.wake.is_set())
        self.assertTrue(self.bridge.can_start())
        self.assertEqual(self.bridge.wake_reason,'automatic')
    async def test_same_presence_heartbeat_never_reopens_an_idle_session(self):
        self.bridge.on_connected_users({'an.123456789012'})
        self.bridge.clear_input()
        self.bridge.on_connected_users({'an.123456789012'})
        self.assertFalse(self.bridge.wake.is_set())
        self.bridge.on_connected_users({'an.123456789012','late-human'})
        self.assertTrue(self.bridge.wake.is_set())
    async def test_voice_mode_still_requires_mic_and_speech_on_entry(self):
        self.bridge.config['activation_mode']='voice'
        self.bridge.on_connected_users({'an.123456789012'})
        self.assertFalse(self.bridge.wake.is_set())
        self.assertFalse(self.bridge.can_start())
    async def test_per_agent_timeout_can_exceed_old_sixty_second_default(self):
        self.assertEqual(self.bridge.idle_timeout(),180)
        self.assertEqual(self.bridge.muted_timeout(),12)
        self.bridge.settings['max_idle_seconds']=120
        self.assertEqual(self.bridge.idle_timeout(),120)
    async def test_new_arrival_is_greeted_in_existing_session_once(self):
        from unittest.mock import AsyncMock, MagicMock
        connection = MagicMock()
        connection.session.commentary.append = AsyncMock()
        self.bridge.connection = connection
        self.bridge.on_connected_users({'an.123456789012'})
        await __import__('asyncio').sleep(0)
        connection.session.commentary.append.assert_awaited_once()
        self.bridge.on_connected_users({'an.123456789012'})
        await __import__('asyncio').sleep(0)
        connection.session.commentary.append.assert_awaited_once()

    async def test_departure_cancels_automatic_start_before_provider_session(self):
        self.bridge.on_connected_users({'an.123456789012'})
        self.bridge.on_connected_users(set())
        self.assertFalse(self.bridge.can_start())

class OutputBufferTests(unittest.IsolatedAsyncioTestCase):
    async def test_large_provider_burst_preserves_every_sample(self):
        import asyncio
        from worker import Bridge
        bridge = object.__new__(Bridge)
        bridge.output = asyncio.Queue(maxsize=25)
        bridge.output_epoch = 0
        pcm = bytes(range(256)) * 300  # 1.6 seconds, larger than output capacity.
        chunks = []
        async def consume():
            while sum(map(len, chunks)) < len(pcm):
                _, chunk = await bridge.output.get()
                chunks.append(chunk)
                await asyncio.sleep(0)
        await asyncio.wait_for(asyncio.gather(bridge.enqueue_audio(pcm), consume()), 2)
        self.assertEqual(b''.join(chunks), pcm)

    async def test_interruption_invalidates_blocked_old_audio(self):
        import asyncio
        from unittest.mock import MagicMock
        from worker import Bridge
        bridge = object.__new__(Bridge)
        bridge.output = asyncio.Queue(maxsize=1)
        bridge.output_epoch = 0
        bridge.source = MagicMock()
        producer = asyncio.create_task(bridge.enqueue_audio(LOUD * 4))
        await asyncio.sleep(0)
        bridge.clear_output()
        await asyncio.wait_for(producer, 1)
        while not bridge.output.empty():
            epoch, _ = bridge.output.get_nowait()
            self.assertNotEqual(epoch, bridge.output_epoch)
        bridge.source.clear_queue.assert_called_once()


if __name__ == '__main__':
    unittest.main()
