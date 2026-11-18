import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HISTORY = ROOT / "scripts" / "checks" / "history.py"


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "cache"
        self.addCleanup(self.tmp.cleanup)

    def history(self, command, record):
        path = Path(self.tmp.name) / "record.txt"
        path.write_text(record)
        env = dict(os.environ, PROXMOX_SKILL_CACHE=str(self.cache))
        result = subprocess.run([sys.executable, str(HISTORY), command, str(path)],
                                capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

        return result.stdout.splitlines()

    def saved(self):
        return sorted((self.cache / "checks").glob("*.txt"))

    def test_new_warning_listed(self):
        self.history("save", "WARN\tzfs\tpool tank is 90% full\n")
        lines = self.history("diff", "WARN\tzfs\tpool tank is 90% full\nWARN\tservices\tservice x is failed\n")

        self.assertEqual(lines, ["NEW services: service x is failed"])

    def test_gone_warning_listed(self):
        self.history("save", "WARN\tzfs\tpool tank is 90% full\nWARN\tservices\tservice x is failed\n")
        lines = self.history("diff", "WARN\tzfs\tpool tank is 90% full\n")

        self.assertEqual(lines, ["GONE services: service x is failed"])

    def test_metric_moved(self):
        self.history("save", "METRIC\tzfs.tank.cap\t58\nMETRIC\tdisk.root.use\t51\n")
        lines = self.history("diff", "METRIC\tzfs.tank.cap\t61\nMETRIC\tdisk.root.use\t51\n")

        self.assertEqual(lines, ["MOVED zfs.tank.cap 58 -> 61"])

    def test_changed_number_in_warning_is_not_new(self):
        self.history("save", "WARN\tsnapshots\tguest 101 snapshot 'a' is 31 days old\n")
        lines = self.history("diff", "WARN\tsnapshots\tguest 101 snapshot 'a' is 32 days old\n")

        self.assertEqual(lines, [])

    def test_second_warning_differing_only_in_digits_is_new(self):
        self.history("save", "WARN\tsmart\tdisk /dev/nvme0n1 has 3 reallocated sector(s)\n")
        lines = self.history("diff", "WARN\tsmart\tdisk /dev/nvme0n1 has 3 reallocated sector(s)\n"
                                     "WARN\tsmart\tdisk /dev/nvme1n1 has 5 reallocated sector(s)\n")

        self.assertEqual(lines, ["NEW smart: disk /dev/nvme1n1 has 5 reallocated sector(s)"])

    def test_keeps_newest_20(self):
        checks = self.cache / "checks"
        checks.mkdir(parents=True)
        for day in range(1, 26):
            (checks / f"202601{day:02d}-120000.txt").write_text("")
        self.history("save", "WARN\tzfs\tx\n")

        saved = self.saved()
        self.assertEqual(len(saved), 20)
        self.assertEqual(saved[0].name, "20260107-120000.txt")
        self.assertEqual(saved[-1].read_text(), "WARN\tzfs\tx\n")

    def test_no_previous_run_is_note(self):
        lines = self.history("diff", "WARN\tzfs\tx\n")

        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("NOTE "), lines)


if __name__ == "__main__":
    unittest.main()
