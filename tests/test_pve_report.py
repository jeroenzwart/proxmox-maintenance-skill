import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "scripts" / "checks" / "pve_report.py"
FIXTURES = ROOT / "tests" / "fixtures" / "pve"
NOW = 1_002_600_000
DAY = 86_400


def report(name, payload, now=NOW):
    data = payload if isinstance(payload, str) else json.dumps(payload)
    result = subprocess.run([sys.executable, str(REPORT), name, "--now", str(now)], input=data,
                            capture_output=True, text=True, timeout=30)

    return result.returncode, result.stdout.splitlines()


def coverage(backups, excluded=()):
    return {"guests": [{"vmid": 101, "name": "web"}], "backups": backups, "excluded": list(excluded)}


class CoverageTest(unittest.TestCase):
    def test_guest_without_backup_warns(self):
        code, lines = report("coverage", coverage([]))

        self.assertEqual(code, 0)
        self.assertEqual(lines, ["WARN 101 (web) has no backup"])

    def test_old_backup_warns(self):
        code, lines = report("coverage", coverage([{"vmid": 101, "ctime": NOW - 8 * DAY - 60},
                                                   {"vmid": 101, "ctime": NOW - 20 * DAY}]))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN 101 (web)"), lines)
        self.assertIn("8 days", lines[0])

    def test_recent_backup_is_silent(self):
        code, lines = report("coverage", coverage([{"vmid": 101, "ctime": NOW - 20 * DAY},
                                                   {"vmid": 101, "ctime": NOW - DAY}]))

        self.assertEqual(lines, [])

    def test_excluded_guest_is_note(self):
        code, lines = report("coverage", coverage([], excluded=[101]))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("NOTE 101 (web)"), lines)


class SnapshotsTest(unittest.TestCase):
    def setUp(self):
        code, self.lines = report("snapshots", (FIXTURES / "snapshots.txt").read_text())
        self.assertEqual(code, 0)

    def test_old_snapshot_warns(self):
        old = [line for line in self.lines if "before-upgrade" in line]

        self.assertEqual(len(old), 1, self.lines)
        self.assertTrue(old[0].startswith("WARN "), old)
        self.assertIn("101", old[0])
        self.assertIn("31 days", old[0])

    def test_leftover_vzdump_snapshot_warns(self):
        leftover = [line for line in self.lines if "vzdump" in line]

        self.assertEqual(len(leftover), 1, self.lines)
        self.assertTrue(leftover[0].startswith("WARN "), leftover)
        self.assertIn("102", leftover[0])

    def test_recent_snapshot_and_pending_are_silent(self):
        self.assertEqual(len(self.lines), 2, self.lines)


class ReplicationTest(unittest.TestCase):
    def setUp(self):
        code, self.lines = report("replication", (FIXTURES / "replication.json").read_text())
        self.assertEqual(code, 0)

    def test_replication_failcount_warns(self):
        failing = [line for line in self.lines if "101-0" in line]

        self.assertEqual(len(failing), 1, self.lines)
        self.assertTrue(failing[0].startswith("WARN "), failing)
        self.assertIn("3", failing[0])
        self.assertIn("not available", failing[0])

    def test_replication_ok_is_silent(self):
        self.assertFalse([line for line in self.lines if "102-0" in line], self.lines)

    def test_disabled_replication_is_not_a_warning(self):
        self.assertFalse([line for line in self.lines if "103-0" in line and line.startswith("WARN")], self.lines)


class HaTest(unittest.TestCase):
    def setUp(self):
        code, self.lines = report("ha", (FIXTURES / "ha-status.json").read_text())
        self.assertEqual(code, 0)

    def test_ha_error_state_warns(self):
        error = [line for line in self.lines if "vm:101" in line]

        self.assertEqual(len(error), 1, self.lines)
        self.assertTrue(error[0].startswith("WARN "), error)
        self.assertIn("error", error[0])

    def test_ha_fence_state_warns(self):
        self.assertTrue([line for line in self.lines if "ct:102" in line and line.startswith("WARN")], self.lines)

    def test_ha_started_is_silent(self):
        self.assertFalse([line for line in self.lines if "vm:103" in line], self.lines)


class InvalidInputTest(unittest.TestCase):
    def test_invalid_input_is_note(self):
        code, lines = report("coverage", "not json")

        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("NOTE "), lines)


if __name__ == "__main__":
    unittest.main()
