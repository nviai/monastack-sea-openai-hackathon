"""Minimal client for the realtime presence capability used by test harnesses.

Credentials are only sent to the loopback authority; the realtime service
receives a short-lived ticket.
"""
import json
import urllib.error
import urllib.request


def _call(url, method='GET', headers=None, body=None, timeout=3):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method, headers={
        **(headers or {}), **({'Content-Type': 'application/json'} if body is not None else {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode()
            return response.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as error:
        return error.code, None


def ticket(port, token):
    """Returns (ticket, realtime_url) for a bearer credential."""
    status, body = _call(f'http://127.0.0.1:{port}/v1/realtime/ticket', 'POST',
                         {'Authorization': 'Bearer ' + token}, {})
    if status != 200:
        raise RuntimeError(f'ticket request failed: {status}')
    assert body['realtime_url'].startswith('http://127.0.0.1:')
    return body['ticket'], body['realtime_url']


class Realtime:
    """Presence calls for one actor, refreshing its ticket before each call."""

    def __init__(self, port, token):
        self.port, self.token = port, token

    def request(self, method, path, body=None, ticket_override=None):
        value, url = ticket(self.port, self.token)
        return _call(f'{url}/v1/{path}', method,
                     {'Authorization': 'Ticket ' + (ticket_override or value)}, body)

    def presence(self):
        status, body = self.request('GET', 'presence')
        if status != 200:
            raise RuntimeError(f'presence read failed: {status}')
        return body

    def publish(self, session, room, x, y, seq):
        return self.request('POST', 'presence',
                            {'session': session, 'room': room, 'x': x, 'y': y, 'seq': seq})[0]

    def leave(self, session):
        return self.request('DELETE', 'presence/' + session)[0]
