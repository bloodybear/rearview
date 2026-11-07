import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_tool.baselines import BaselineError, publish_baseline


class BaselineTests(unittest.TestCase):
    def test_publishes_shared_screen_and_manifest_without_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "run" / "screen.png"
            source.parent.mkdir()
            source.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + struct.pack(">II", 7, 5) + b"\x08\x02\x00\x00\x00")
            scenario = dict(id="case-one", fixtureId="fixture-one", version=2, fixtureVersion="a" * 64)
            report = dict(
                runId="run-1", scenarioId="case-one", scenarioVersion=2,
                fixtureVersion="a" * 64, status="verified", documentUnchanged=True,
                screenshot=dict(file="screen.png", capturedAt="2026-11-07T00:00:00Z", frame=[1, 2, 3, 4], pixelWidth=7, pixelHeight=5),
            )

            published = publish_baseline(scenario, report, source, root / "captures")
            directory = root / "captures" / "fixture-one" / "case-one" / "v2"
            manifest = json.loads((directory / "manifest.json").read_text())

            self.assertEqual((directory / "screen.png").read_bytes(), source.read_bytes())
            self.assertEqual(manifest["scenarioVersion"], 2)
            self.assertEqual(manifest["pixelWidth"], 7)
            self.assertEqual(manifest["pixelHeight"], 5)
            self.assertFalse(published["alreadyRegistered"])
            self.assertFalse((root / "captures" / "index.json").exists())

    def test_rejects_baseline_when_document_integrity_is_unverified(self):
        report = dict(documentUnchanged=False)
        with self.assertRaises(BaselineError):
            publish_baseline(dict(), report, "missing.png", "/tmp/captures")


if __name__ == "__main__":
    unittest.main()
