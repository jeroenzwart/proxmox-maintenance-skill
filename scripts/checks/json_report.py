#!/usr/bin/env python3
"""Turn the JSON output of the Proxmox CLIs into findings for check.sh.

Usage: <cli> --output-format json | json_report.py <report>

Prints one finding per line, prefixed WARN or NOTE (or ID for lists the
shell loops over), and always exits 0: a CLI that changed its output or
refused to answer is worth a note, never a crashed health check.
"""

from __future__ import annotations

import json
import sys


def pdm_remotes(data: list) -> list[str]:
    return [f"ID {remote['id']}" for remote in data if remote.get("id")]


REPORTS = {
    "pdm-remotes": pdm_remotes,
}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in REPORTS:
        print(f"NOTE json_report.py: unknown report {sys.argv[1:]!r}")
        return 0
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        lines = REPORTS[sys.argv[1]](data)
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print(f"NOTE could not read the {sys.argv[1]} output ({type(error).__name__}): {raw[:120].strip()!r}")
        return 0
    for line in lines:
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
