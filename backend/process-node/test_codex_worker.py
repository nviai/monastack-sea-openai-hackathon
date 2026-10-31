import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import codex_worker as worker


class CodexWorkerTests(unittest.TestCase):
    def run_case(self, status):
        calls = []
        def request(base, token, method, path, body=None):
            calls.append((path, body))
            if path == 'host/jobs':
                return [{'id':'job', 'agent':'dev-agent'}]
            if path == 'host/claim':
                return {'instruction':'test', 'fence':'fence', 'context':{}}
        class Process:
            def __init__(self, command, **kwargs):
                self.returncode = 0
                self.stdin = open('/dev/null', 'wb')
                output = Path(command[command.index('--output-last-message')+1])
                output.write_text(json.dumps({'status':status,'summary':'Verified summary'}))
            def poll(self):
                return 0
        with tempfile.TemporaryDirectory() as folder, patch.object(worker,'request',side_effect=request), patch.object(worker.subprocess,'Popen',Process):
            result = worker.run_once('http://127.0.0.1:1','test',Path(folder),'codex')
        return calls, result

    def test_question_pauses_instead_of_reporting_success(self):
        calls, result = self.run_case('needs_input')
        self.assertTrue(any(path.endswith('/question') for path, _ in calls))
        self.assertFalse(any(path.endswith('/report') for path, _ in calls))
        self.assertEqual(result, 'Waiting for user input')

    def test_success_still_requires_review(self):
        calls, result = self.run_case('completed')
        self.assertEqual(calls[-1][1]['outcome'], 'success')
        self.assertEqual(result, 'Result submitted for review')


if __name__ == '__main__':
    unittest.main()
