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


def notifications(config, users):
    return (FIXTURES / config).read_text() + "### users\n" + "".join(f"{user} {mail}\n" for user, mail in users.items())


class NotificationsTest(unittest.TestCase):
    def test_only_default_target_without_root_mail_warns(self):
        code, lines = report("notifications", notifications("notifications-default.cfg", {}))

        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN "), lines)
        self.assertIn("root@pam", lines[0])

    def test_default_target_with_root_mail_is_silent(self):
        code, lines = report("notifications", notifications("notifications-default.cfg",
                                                            {"root@pam": "ops@example.org"}))

        self.assertEqual(lines, [])

    def test_extra_target_is_silent(self):
        code, lines = report("notifications", notifications("notifications-smtp.cfg",
                                                            {"admin@pam": "admin@example.org"}))

        self.assertEqual(lines, [])

    def test_builtin_targets_apply_next_to_user_targets(self):
        # proxmox-notify always merges the built-in mail-to-root and default-matcher.
        config = "smtp: extra\n\tmailto ops@example.org\n\tserver mail.example.org\n"
        code, lines = report("notifications", config + "### users\nroot@pam root@example.org\n")

        self.assertEqual(lines, [])

    def test_matcher_without_enabled_target_warns(self):
        config = "sendmail: mail-to-root\n\tdisable true\n\tmailto-user root@pam\n\n" \
                 "matcher: default-matcher\n\tmode all\n\ttarget mail-to-root\n"
        code, lines = report("notifications", config + "### users\nroot@pam ops@example.org\n")

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN "), lines)


SSHD_SAFE = "permitrootlogin prohibit-password\npasswordauthentication yes\n"
SSHD_OPEN = "permitrootlogin yes\npasswordauthentication yes\n"
TOTP = json.dumps({"users": {"root@pam": {"totp": [{"info": {"id": "x", "description": "phone",
                                                             "created": 1, "enable": True}, "entry": "…"}]}}})
FIREWALL_ON = "[OPTIONS]\n\nenable: 1\n"


def security(tfa=TOTP, sshd=SSHD_SAFE, firewall=FIREWALL_ON):
    return f"### tfa\n{tfa}\n### sshd\n{sshd}### firewall\n{firewall}"


def excluded(jobs, *vmids):
    code, lines = report("excluded", jobs + "### guests\n" + "".join(f"{v}\n" for v in vmids))
    return [line for line in lines if not line.startswith("NOTE ")]


class ExcludedTest(unittest.TestCase):
    def test_excluded_by_every_job(self):
        jobs = "vzdump: a\n\tall 1\n\texclude 101,102\n\tschedule 03:00\n"

        self.assertEqual(excluded(jobs, 101, 103), ["ID 101"])

    def test_selected_by_another_job_is_not_excluded(self):
        jobs = ("vzdump: a\n\tall 1\n\texclude 101\n\nvzdump: b\n\tall 1\n\tschedule sat\n")

        self.assertEqual(excluded(jobs, 101), [])

    def test_listed_by_vmid_is_not_excluded(self):
        jobs = ("vzdump: a\n\tall 1\n\texclude 101\n\nvzdump: b\n\tvmid 101\n")

        self.assertEqual(excluded(jobs, 101), [])

    def test_disabled_job_selects_nothing(self):
        jobs = ("vzdump: a\n\tall 1\n\texclude 101\n\nvzdump: b\n\tall 1\n\tenabled 0\n")

        self.assertEqual(excluded(jobs, 101), ["ID 101"])

    def test_pool_job_may_select_anything(self):
        jobs = ("vzdump: a\n\tall 1\n\texclude 101\n\nvzdump: b\n\tpool web\n")

        self.assertEqual(excluded(jobs, 101), [])


class SecurityTest(unittest.TestCase):
    def test_root_without_tfa_warns(self):
        code, lines = report("security", security(tfa="{}"))

        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN "), lines)
        self.assertIn("root@pam", lines[0])

    def test_root_with_only_recovery_keys_warns(self):
        code, lines = report("security", security(tfa=json.dumps({"users": {"root@pam": {"recovery": {"keys": []}}}})))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN "), lines)

    def test_root_with_totp_is_silent(self):
        code, lines = report("security", security())

        self.assertEqual(lines, [])

    def test_unreadable_tfa_is_note(self):
        code, lines = report("security", security(tfa="UNREADABLE"))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("NOTE "), lines)

    def test_tfa_skip_is_silent(self):
        code, lines = report("security", security(tfa="SKIP"))

        self.assertEqual(lines, [])

    def test_ssh_password_and_root_login_warns(self):
        code, lines = report("security", security(sshd=SSHD_OPEN))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("WARN "), lines)
        self.assertIn("PermitRootLogin", lines[0])

    def test_firewall_disabled_is_note(self):
        code, lines = report("security", security(firewall=""))

        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("NOTE "), lines)
        self.assertIn("firewall", lines[0])


class CephTest(unittest.TestCase):
    def test_health_warn_lists_checks(self):
        code, lines = report("ceph", (FIXTURES / "ceph-warn.json").read_text())

        self.assertEqual(code, 0)
        self.assertTrue([line for line in lines if line.startswith("WARN ") and "OSD_NEARFULL" in line], lines)
        self.assertTrue([line for line in lines if line.startswith("NOTE ") and "AUTH_INSECURE_KEY" in line], lines)

    def test_osd_down_warns(self):
        code, lines = report("ceph", (FIXTURES / "ceph-warn.json").read_text())

        down = [line for line in lines if "down" in line and line.startswith("WARN ")]
        self.assertEqual(len(down), 1, lines)
        self.assertIn("1 of 3", down[0])

    def test_health_ok_is_silent(self):
        code, lines = report("ceph", (FIXTURES / "ceph-ok.json").read_text())

        self.assertEqual(lines, [])


class InvalidInputTest(unittest.TestCase):
    def test_invalid_input_is_note(self):
        code, lines = report("coverage", "not json")

        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("NOTE "), lines)


if __name__ == "__main__":
    unittest.main()
