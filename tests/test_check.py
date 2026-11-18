import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STUBS = ROOT / "tests" / "stubs"
QUIET = STUBS / "quiet"


CACHE = tempfile.TemporaryDirectory()


def run_check(installed, *args, log="", quiet=False):
    env = dict(os.environ)
    # Full runs save their record; keep that out of the real cache.
    env["PROXMOX_SKILL_CACHE"] = CACHE.name
    env["PATH"] = f"{STUBS}:{env['PATH']}"
    if quiet:
        env["PATH"] = f"{QUIET}:{env['PATH']}"
    env["STUB_INSTALLED"] = installed
    env["STUB_LOG"] = log

    return subprocess.run(
        ["bash", str(ROOT / "scripts" / "check.sh"), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


class ProductDetectionTest(unittest.TestCase):
    def test_products_pve_only(self):
        result = run_check("pve-manager", "--products")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "pve")

    def test_products_pve_and_pbs(self):
        result = run_check("pve-manager proxmox-backup-server", "--products")

        self.assertEqual(result.stdout.strip(), "pve pbs")

    def test_backup_client_is_not_pbs(self):
        result = run_check("pve-manager proxmox-backup-client", "--products")

        self.assertEqual(result.stdout.strip(), "pve")


class SectionValidationTest(unittest.TestCase):
    def test_unknown_section_exits_2(self):
        result = run_check("pve-manager", "--section", "stroage")

        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown section", result.stderr)

    def test_section_of_missing_product_exits_2(self):
        result = run_check("pve-manager", "--section", "datastores")

        self.assertEqual(result.returncode, 2)
        self.assertIn("not installed", result.stderr)


class UpdateSectionTest(unittest.TestCase):
    def test_update_not_in_default_sweep(self):
        result = run_check("pve-manager", quiet=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("===== SUMMARY", result.stdout)
        self.assertNotIn("===== UPDATE", result.stdout)

    def test_update_section_accepted(self):
        result = run_check("pve-manager", "--section", "update", quiet=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("===== UPDATE", result.stdout)
        self.assertIn("pve8to9", result.stdout)


class DiffTest(unittest.TestCase):
    def test_diff_with_section_exits_2(self):
        result = run_check("pve-manager", "--diff", "--section", "storage")

        self.assertEqual(result.returncode, 2)
        self.assertIn("full runs", result.stderr)


class PdmRemotesTest(unittest.TestCase):
    def test_pdm_remote_timeout(self):
        with tempfile.NamedTemporaryFile("r") as log:
            run_check("proxmox-datacenter-manager", "--section", "remotes", log=log.name)
            calls = [line.split() for line in log.read().splitlines()]

        remote_calls = [call for call in calls if call[1:4] == ["proxmox-datacenter-manager-admin", "remote", "version"]]
        self.assertTrue(remote_calls, calls)
        self.assertEqual(remote_calls[0][0], "15")


if __name__ == "__main__":
    unittest.main()
