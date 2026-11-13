import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ax_batch', Path(__file__).resolve().parents[1] / 'tools/run_ax_prototype.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RearviewAppLaunchTests(unittest.TestCase):
    def invoke(self, app_status):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            commands = []
            def run(command, name):
                commands.append(command)
                Path(command[command.index('--stdout') + 1]).write_text('/report/folder\n')
                Path(command[command.index('--stderr') + 1]).write_text('app diagnostic')
                if app_status is not None:
                    Path(command[command.index('--command-status-file') + 1]).write_text(str(app_status))
                return subprocess.CompletedProcess(command, 0, '', '')
            result = runner.run_rearview_app(root / 'dist/Rearview-dev.app', ['--root', str(root)], run, 'collect', root)
            return result, commands[0]

    def test_launches_app_bundle_through_launch_services(self):
        result, command = self.invoke(0)
        self.assertEqual(command[0], '/usr/bin/open')
        self.assertIn('-n', command)
        self.assertTrue(command[command.index('-a') + 1].endswith('/dist/Rearview-dev.app'))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '/report/folder')

    def test_app_failure_is_preserved_when_open_succeeds(self):
        result, _ = self.invoke(2)
        self.assertEqual(result.returncode, 2)
        self.assertIn('app diagnostic', result.stderr)

    def test_missing_status_receipt_is_failure(self):
        result, _ = self.invoke(None)
        self.assertEqual(result.returncode, 1)
        self.assertIn('receipt missing', result.stderr)
