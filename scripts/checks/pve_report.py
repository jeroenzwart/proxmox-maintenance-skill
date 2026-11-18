#!/usr/bin/env python3
"""Turn Proxmox VE state gathered by pve.sh into findings for check.sh.

Usage: <gathered state> | pve_report.py <report> [--now EPOCH]

Prints one finding per line, prefixed WARN or NOTE, and always exits 0: input
that cannot be read is worth a note, never a crashed health check. Same
contract as json_report.py.
"""

from __future__ import annotations

import json
import re
import sys
import time

# A nightly job that has silently stopped shows up within a week.
COVERAGE_MAX_DAYS = 7
# A snapshot pins every block it references; after a month it is usually forgotten.
SNAPSHOT_MAX_DAYS = 30

DAY = 86_400


def days(seconds: float) -> int:
    return int(seconds // DAY)


def coverage(raw: str, now: float) -> list[str]:
    data = json.loads(raw)
    newest: dict[int, float] = {}
    for backup in data["backups"]:
        vmid = int(backup["vmid"])
        newest[vmid] = max(newest.get(vmid, 0), float(backup["ctime"]))
    excluded = {int(vmid) for vmid in data.get("excluded", [])}

    findings = []
    for guest in data["guests"]:
        vmid = int(guest["vmid"])
        label = f"{vmid} ({guest.get('name') or '?'})"
        if vmid in excluded:
            findings.append(f"NOTE {label} is excluded from the backup jobs")
        elif vmid not in newest:
            findings.append(f"WARN {label} has no backup")
        elif now - newest[vmid] > COVERAGE_MAX_DAYS * DAY:
            findings.append(f"WARN {label} has no backup newer than {days(now - newest[vmid])} days")

    return findings


# Sections in a guest config that are not snapshots.
NOT_SNAPSHOTS = {"pending"}


def snapshots(raw: str, now: float) -> list[str]:
    if not raw.strip():
        return []
    if not raw.lstrip().startswith("### "):
        raise ValueError("expected '### <vmid>' headers")

    findings = []
    vmid = section = None
    for line in raw.splitlines():
        header = re.match(r"^### (\d+)\s*$", line)
        if header:
            vmid, section = header.group(1), None
            continue
        name = re.match(r"^\[([^\]]+)\]\s*$", line)
        if name:
            section = name.group(1)
            if section == "vzdump":
                findings.append(f"WARN guest {vmid} has a leftover 'vzdump' snapshot - a snapshot-mode backup "
                                f"aborted; remove it with 'qm delsnapshot {vmid} vzdump' / 'pct delsnapshot {vmid} vzdump' "
                                f"once no backup is running")
            continue
        stamp = re.match(r"^snaptime:\s*(\d+)", line)
        if stamp and section and section != "vzdump" and section not in NOT_SNAPSHOTS \
                and not section.startswith("special:"):
            age = now - int(stamp.group(1))
            if age > SNAPSHOT_MAX_DAYS * DAY:
                findings.append(f"WARN guest {vmid} snapshot '{section}' is {days(age)} days old - "
                                f"it keeps every changed block alive and grows with each write")

    return findings


REPORTS = {
    "coverage": coverage,
    "snapshots": snapshots,
}


def main(argv: list[str]) -> int:
    now = time.time()
    if "--now" in argv:
        at = argv.index("--now")
        now = float(argv[at + 1])
        argv = argv[:at] + argv[at + 2:]
    if len(argv) != 1 or argv[0] not in REPORTS:
        print(f"NOTE pve_report.py: unknown report {argv!r}")
        return 0
    raw = sys.stdin.read()
    try:
        lines = REPORTS[argv[0]](raw, now)
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print(f"NOTE could not read the {argv[0]} input ({type(error).__name__}): {raw[:120].strip()!r}")
        return 0
    for line in lines:
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
