"""Gateway regression tests: actual HTTP rejections and revoked sync content."""
import http.client
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from matrix_proxy import ClientOnly, room_access, strip_revoked_sync


class Gateway(ClientOnly):
    def allowed(self, _):
        return {'!allowed:local', '#allowed:local'}


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, method, path, body=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        data = json.dumps(body)
        connection.request(method, path, data, {'Content-Type': 'application/json', 'Authorization': 'Bearer test'})
        result = connection.getresponse()
        content = result.read()
        connection.close()
        return result.status, json.loads(content)

    def test_non_object_login_is_bad_request_and_server_survives(self):
        for body in [[], 42, 'login', False]:
            self.assertEqual(self.request('POST', '/_matrix/client/v3/login', body)[0], 400)
        self.assertEqual(self.request('POST', '/_matrix/client/v3/login', None)[0], 400)

    def test_namespaced_room_and_alias_are_checked_over_http(self):
        for path in [
            '/_matrix/client/unstable/org.matrix.msc3030/rooms/%21denied:local/timestamp_to_event?ts=0&dir=b',
            '/_matrix/client/v3/join/%23denied:local',
            '/_matrix/client/v3/directory/room/%23denied:local',
            '/_matrix/client/v3/rooms/%21allowed:local/unknown_extension',
            '/_matrix/client/unstable/other/rooms/%21allowed:local/messages',
            '/_matrix/client/v3/rooms/%21allowed:local/state/custom/%21denied:local',
        ]:
            self.assertEqual(self.request('GET', path)[0], 403, path)

    def test_app_room_shapes_and_aliases_are_allowed(self):
        for path in [
            '/_matrix/client/v3/rooms/!allowed:local/messages',
            '/_matrix/client/v1/rooms/!allowed:local/relations/$event/m.thread/m.room.message',
            '/_matrix/client/v3/rooms/!allowed:local/send/m.room.message/transaction',
            '/_matrix/client/v3/rooms/!allowed:local/state/m.room.topic/',
            '/_matrix/client/v3/user/@human:local/rooms/!allowed:local/account_data/m.tag',
            '/_matrix/client/v3/join/#allowed:local',
            '/_matrix/client/unstable/org.matrix.msc3030/rooms/!allowed:local/timestamp_to_event',
        ]:
            self.assertTrue(room_access(path, {'!allowed:local', '#allowed:local'}), path)

    def test_revoked_leave_preserves_membership_only(self):
        leave = {'type': 'm.room.member', 'content': {'membership': 'leave'}}
        value = {'rooms': {
            'join': {'!denied:local': {'timeline': {'events': ['private']}}},
            'leave': {'!denied:local': {
                'timeline': {'events': [leave, {'type': 'm.room.message', 'content': {'body': 'private'}}]},
                'state': {'events': ['private']}, 'ephemeral': {'events': ['typing']},
                'account_data': {'events': ['private draft']},
            }},
        }}
        strip_revoked_sync(value, set())
        self.assertEqual(value['rooms']['join'], {})
        self.assertEqual(value['rooms']['leave']['!denied:local'], {'timeline': {'events': [leave]}})


if __name__ == '__main__':
    unittest.main()
