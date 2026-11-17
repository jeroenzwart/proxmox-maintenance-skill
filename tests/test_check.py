import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STUBS = ROOT / "tests" / "stubs"


def run_check(installed, *args):
    env = dict(os.environ)
    env["PATH"] = f"{STUBS}:{env['PATH']}"
    env["STUB_INSTALLED"] = installed

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


if __name__ == "__main__":
    unittest.main()
