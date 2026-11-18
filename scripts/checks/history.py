#!/usr/bin/env python3
"""Keep check.sh runs and compare a run with the previous one.

Usage: history.py save RECORD_FILE
       history.py diff RECORD_FILE

A record holds tab-separated lines: `WARN <section> <message>`,
`NOTE <section> <message>` and `METRIC <name> <value>`. `save` stores it under
<cache>/checks/<YYYYmmdd-HHMMSS>.txt and keeps the newest KEEP_RUNS. `diff`
compares it with the newest saved run and prints NEW, GONE and MOVED lines.
Always exits 0: a missing or unreadable history is a note, not a failure.
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

KEEP_RUNS = 20

CACHE_ROOT = Path(
    os.environ.get("PROXMOX_SKILL_CACHE")
    or (Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "proxmox-skill")
)
CHECKS = CACHE_ROOT / "checks"


def parse(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """Warnings keyed by their text with numbers masked, and metrics by name."""
    warnings: dict[str, str] = {}
    metrics: dict[str, str] = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        kind, first, second = fields
        if kind == "WARN":
            shown = f"{first}: {second}"
            # Ages and percentages tick on every run; a warning whose numbers
            # moved is the same finding, and the metrics carry the movement.
            warnings[re.sub(r"\d+(\.\d+)?", "#", shown)] = shown
        elif kind == "METRIC":
            metrics[first] = second

    return warnings, metrics


def save(record: Path) -> list[str]:
    CHECKS.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = CHECKS / f"{stamp}.txt"
    suffix = 1
    while target.exists():
        suffix += 1
        target = CHECKS / f"{stamp}-{suffix}.txt"
    target.write_text(record.read_text())
    for old in sorted(CHECKS.glob("*.txt"))[:-KEEP_RUNS]:
        old.unlink()

    return []


def diff(record: Path) -> list[str]:
    runs = sorted(CHECKS.glob("*.txt")) if CHECKS.is_dir() else []
    if not runs:
        return [f"NOTE no previous run saved in {CHECKS} - nothing to compare with yet"]
    old_warnings, old_metrics = parse(runs[-1].read_text())
    new_warnings, new_metrics = parse(record.read_text())

    lines = [f"NEW {new_warnings[key]}" for key in new_warnings if key not in old_warnings]
    lines += [f"GONE {old_warnings[key]}" for key in old_warnings if key not in new_warnings]
    lines += [f"MOVED {name} {old_metrics[name]} -> {value}" for name, value in new_metrics.items()
              if name in old_metrics and old_metrics[name] != value]

    return lines


COMMANDS = {"save": save, "diff": diff}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in COMMANDS:
        print(f"NOTE history.py: usage history.py save|diff RECORD_FILE, got {argv!r}")
        return 0
    try:
        lines = COMMANDS[argv[0]](Path(argv[1]))
    except (OSError, UnicodeDecodeError) as error:
        print(f"NOTE history.py {argv[0]} failed: {error}")
        return 0
    for line in lines:
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
