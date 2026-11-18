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


def replication(raw: str, now: float) -> list[str]:
    """Jobs from /nodes/<node>/replication (fields as in pvesr status)."""
    findings = []
    for job in json.loads(raw):
        if job.get("disable"):
            continue
        fail_count = int(job.get("fail_count") or 0)
        if fail_count or job.get("error"):
            findings.append(f"WARN replication job {job['id']} (guest {job.get('guest', '?')} -> "
                            f"{job.get('target', '?')}) failed {fail_count} time(s) in a row: "
                            f"{job.get('error') or 'no error text'}")

    return findings


# HA states that need a human; the rest are normal or transitional.
HA_BAD_STATES = {"error", "fence", "recovery"}


def ha(raw: str, now: float) -> list[str]:
    """Entries from /cluster/ha/status/current."""
    findings = []
    for entry in json.loads(raw):
        if entry.get("type") == "service" and entry.get("state") in HA_BAD_STATES:
            findings.append(f"WARN HA resource {entry['sid']} is in state '{entry['state']}' on "
                            f"{entry.get('node', '?')} - see 'ha-manager status' and the HA chapter")

    return findings


def parse_sections(text: str) -> list[tuple[str, str, dict[str, list[str]]]]:
    """`type: name` blocks with indented `key value` lines; keys may repeat."""
    sections = []
    for line in text.splitlines():
        head = re.match(r"^(\S+):\s*(\S+)\s*$", line)
        if head:
            sections.append((head.group(1), head.group(2), {}))
        elif sections and line[:1] in (" ", "\t") and line.strip():
            key, _, value = line.strip().partition(" ")
            sections[-1][2].setdefault(key, []).append(value.strip())

    return sections


def enabled(options: dict[str, list[str]]) -> bool:
    return options.get("disable", ["0"])[-1] not in ("1", "true")


# What PVE and PBS use when notifications.cfg has no entries of its own.
DEFAULT_NOTIFICATIONS = """sendmail: mail-to-root
\tmailto-user root@pam

matcher: default-matcher
\tmode all
\ttarget mail-to-root
"""


def notifications(raw: str, now: float) -> list[str]:
    """notifications.cfg, then `### users` and one `<userid> <email>` per line."""
    config, marker, users_text = raw.partition("### users\n")
    if not marker:
        raise ValueError("expected a '### users' line")
    emails = {}
    for line in users_text.splitlines():
        user, _, email = line.strip().partition(" ")
        if user and email:
            emails[user] = email
    sections = parse_sections(config) or parse_sections(DEFAULT_NOTIFICATIONS)

    targets = {name: (kind, options) for kind, name, options in sections if kind != "matcher"}
    used = {target for kind, _, options in sections if kind == "matcher" and enabled(options)
            for target in options.get("target", [])}
    reachable = [name for name in sorted(used) if name in targets and enabled(targets[name][1])]
    if not reachable:
        return ["WARN no enabled notification matcher routes to an enabled target - "
                "failed backups and jobs notify nobody"]

    def has_recipient(name: str) -> bool:
        kind, options = targets[name]
        if kind not in ("sendmail", "smtp"):
            return True  # gotify, webhook: their endpoint is the recipient
        if options.get("mailto"):
            return True
        return any(user in emails for user in options.get("mailto-user", []))

    if not any(has_recipient(name) for name in reachable):
        users = sorted({user for name in reachable for user in targets[name][1].get("mailto-user", [])})
        return [f"WARN notifications only go to mail target(s) {', '.join(reachable)}, whose recipient(s) "
                f"{', '.join(users) or '(none)'} have no e-mail address - failed backups and jobs notify nobody; "
                f"set an address on the user or add a target"]

    return []


def blocks(raw: str) -> dict[str, str]:
    """Input split on `### <name>` lines."""
    found: dict[str, str] = {}
    name = None
    for line in raw.splitlines(keepends=True):
        head = re.match(r"^### (\S+)\s*$", line)
        if head:
            name = head.group(1)
            found[name] = ""
        elif name:
            found[name] += line

    return found


# Kinds of second factor that count; recovery keys alone are a fallback, not a factor.
TFA_KINDS = ("totp", "webauthn", "u2f", "yubico")


def security(raw: str, now: float) -> list[str]:
    """Blocks: `### tfa` (tfa.cfg JSON, UNREADABLE, or SKIP without PVE), `### sshd` (sshd -T),
    optionally `### firewall` (cluster.fw; PVE only)."""
    parts = blocks(raw)
    if "tfa" not in parts or "sshd" not in parts:
        raise ValueError("expected '### tfa' and '### sshd' blocks")
    findings = []

    tfa = parts["tfa"].strip()
    if tfa == "SKIP":
        pass
    elif tfa == "UNREADABLE":
        findings.append("NOTE could not read the two-factor configuration (needs root) - root@pam's second factor not checked")
    else:
        root = json.loads(tfa or "{}").get("users", {}).get("root@pam", {})
        factors = [entry for kind in TFA_KINDS for entry in root.get(kind, [])
                   if entry.get("info", {}).get("enable", True)]
        if not factors:
            findings.append("WARN root@pam has no second factor (TOTP, WebAuthn or YubiKey) - "
                            "its password alone opens the whole host; add one under Datacenter > Permissions > Two Factor")

    sshd = dict(line.split(None, 1) for line in parts["sshd"].splitlines() if len(line.split(None, 1)) == 2)
    if sshd.get("permitrootlogin") == "yes" and sshd.get("passwordauthentication") == "yes":
        findings.append("WARN SSH allows root to log in with a password (PermitRootLogin yes, PasswordAuthentication yes) - "
                        "use keys for root ('PermitRootLogin prohibit-password'); keep a working key session open while changing it")

    if "firewall" in parts:
        enabled_line = re.search(r"^enable:\s*(\d)", parts["firewall"], re.MULTILINE)
        if not enabled_line or enabled_line.group(1) != "1":
            findings.append("NOTE the datacenter firewall is disabled - fine behind a trusted network edge; "
                            "whether ports are reachable from outside cannot be seen from this host")

    return findings


def ceph(raw: str, now: float) -> list[str]:
    """`ceph -s --format json`. Built from the documented fields; not yet seen on a Ceph host."""
    data = json.loads(raw)
    health = data["health"]
    osdmap = data.get("osdmap", {})
    osdmap = osdmap.get("osdmap", osdmap)  # nested one level deeper before Ceph Reef
    total = int(osdmap.get("num_osds", 0))
    up = int(osdmap.get("num_up_osds", total))
    in_ = int(osdmap.get("num_in_osds", total))

    findings = []
    # Down OSDs get their own line with the count, so OSD_DOWN is not repeated.
    if up < total:
        findings.append(f"WARN Ceph: {total - up} of {total} OSDs are down - data has reduced redundancy until they return")
    if in_ < total:
        findings.append(f"WARN Ceph: {total - in_} of {total} OSDs are out - their data is being or was moved to the others")
    for code, check in sorted(health.get("checks", {}).items()):
        if code == "OSD_DOWN" and up < total:
            continue
        message = check.get("summary", {}).get("message", "")
        if check.get("muted"):
            findings.append(f"NOTE Ceph {code} is muted: {message}")
        else:
            findings.append(f"WARN Ceph {check.get('severity', health.get('status'))} {code}: {message} - "
                            f"'ceph health detail' lists the affected daemons")

    return findings


REPORTS = {
    "coverage": coverage,
    "snapshots": snapshots,
    "replication": replication,
    "ha": ha,
    "notifications": notifications,
    "security": security,
    "ceph": ceph,
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
