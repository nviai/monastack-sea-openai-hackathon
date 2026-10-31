"""Private file creation, exact bootstrap recovery, empty Zellij inventory."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0,str(Path(__file__).resolve().parents[3]/'tools'))
from matrix_stack import registration_conflict
from visible_service import write_private, zellij_tab


class OpsTests(unittest.TestCase):
    def test_private_from_creation_and_repair(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'secret'
            previous=os.umask(0)
            try:
                write_private(path,'private')
                self.assertEqual(path.stat().st_mode&0o777,0o600)
                path.chmod(0o666)
                write_private(path,'short')
                self.assertEqual(path.stat().st_mode&0o777,0o600)
                self.assertEqual(path.read_text(),'short')
            finally: os.umask(previous)

    def test_registration_recovers_only_the_exact_existing_user_conflict(self):
        for status,body,expected in [
            (400,b'{"error":"User ID already taken."}',True),
            (400,b'{"error":"Bad shared secret"}',False),
            (400,b'[]',False),(400,b'not JSON',False),
            (403,b'{"error":"User ID already taken."}',False),
        ]:
            error=HTTPError('http://127.0.0.1/register',status,'error',{},io.BytesIO(body))
            self.assertEqual(registration_conflict(error),expected)
            error.close()

    def test_no_sessions_exit_one_can_create_a_fresh_session(self):
        calls=[]
        def run(command,**kwargs):
            calls.append(command)
            if 'list-sessions' in command:
                return subprocess.CompletedProcess(command,1,'','No active zellij sessions found.')
            if 'list-panes' in command:
                return subprocess.CompletedProcess(command,0,'[{"id":1,"tab_id":1,"is_plugin":false}]','')
            return subprocess.CompletedProcess(command,0,'','')
        with patch('visible_service.shutil.which',return_value='/zellij'),patch('visible_service.subprocess.run',side_effect=run):
            self.assertTrue(zellij_tab('fresh','BE-test',['true']))
        self.assertTrue(any('--create-background' in c for c in calls))
        self.assertTrue(any('new-pane' in c for c in calls))


if __name__=='__main__': unittest.main()
