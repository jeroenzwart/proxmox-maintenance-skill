import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "scripts" / "checks" / "json_report.py"


def report(name, payload):
    data = payload if isinstance(payload, str) else json.dumps(payload)
    result = subprocess.run([sys.executable, str(REPORT), name], input=data,
                            capture_output=True, text=True, timeout=30)

    return result.returncode, result.stdout.splitlines()


class PdmRemotesTest(unittest.TestCase):
    def test_pdm_remote_ids(self):
        code, lines = report("pdm-remotes", [{"id": "pve1", "type": "pve"}])

        self.assertEqual(code, 0)
        self.assertEqual(lines, ["ID pve1"])


class InvalidInputTest(unittest.TestCase):
    def test_invalid_json_is_a_note(self):
        code, lines = report("pdm-remotes", "not json")

        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("NOTE "))


if __name__ == "__main__":
    unittest.main()
