#!/usr/bin/env python3
"""
poc/network-inspect/inventory_build.py
=======================================

EXPERIMENTAL / RESEARCH POC — not wired into server-manager.sh, not
registered in lib/cli/router.sh, does not touch any file under lib/.
See poc/network-inspect/README.md for scope and rationale.

Tип:        one-shot
Файл:       poc/network-inspect/inventory_build.py

ENV:
  SM_NETWORK_INSPECT_TIMEOUT   optional   per-subprocess timeout in
                                            seconds, default 5
  SM_NETWORK_INSPECT_NO_DOCKER optional   set to "1" to skip the Docker
                                            Engine API socket entirely
                                            (still read-only either way)
  SM_NETWORK_INSPECT_HYSTERIA_CONFIG
                                optional   overrides the Hysteria2 config
                                            path this script reads
                                            (read-only) to determine
                                            obfs.type. Defaults to
                                            /etc/hysteria/config.yaml,
                                            which is this project's own
                                            actual convention — verified
                                            by direct read of
                                            lib/core/config.sh
                                            (HYSTERIA_DIR="/etc/hysteria",
                                            HYSTERIA_CONFIG="${HYSTERIA_DIR}/config.yaml"),
                                            not assumed. This env var
                                            exists purely so tests/
                                            fixtures can point at a
                                            temp file instead of the
                                            real system path — this
                                            script still never WRITES
                                            to whatever path it ends up
                                            reading.

stdin:      none
stdout:     single JSON document (the normalized Inventory), see
            build_inventory() docstring for the schema. Nothing else is
            ever written to stdout — this follows this repo's own
            Contract 1 (docs/CONTRACTS.md §1): stdout is pure
            machine-readable data, all UI/diagnostic text goes to
            stderr.
stderr:     human-readable warnings only (e.g. "not running as root,
            some PIDs will be unresolved")

Exit codes:
  0   inventory built (possibly with partial/degraded fields — a
      degraded field is recorded IN the JSON as such, not treated as
      a tool failure)
  1   could not build any inventory at all (neither `ss` nor
      /proc/net/{tcp,udp}* available — genuinely unsupported host)
  2   invalid invocation (bad CLI argument)

Идемпотентность: да — this script never writes, mutates, reloads, or
restarts anything. Every subprocess call it makes is a read-only query
equivalent (ss, ip -j addr, docker inspect, systemctl show, firewall
"--state"/"status"/"list ruleset"/"-save", `nginx -T`, `caddy version`/
`list-modules`, a GET to Caddy's local admin API). Running it any
number of times produces the same class of side effects: none.

Design notes tying this back to the accompanying research report
(smart-configurator-research.md, delivered earlier in this thread):
  - port -> socket -> pid -> process -> service/container -> exposure
    chain: see collect_listeners() / correlate_pid_by_inode() /
    classify_ownership() below, following the same /proc walk osquery,
    gopsutil, and portview all use (report §3/§4).
  - "privilege silently degrading results" risk (report §3, §19): a
    socket whose owning PID could not be resolved is NEVER silently
    treated as "no owner" — see PID_UNRESOLVED_* reasons below, which
    keep "insufficient privilege" and "genuinely unowned" distinct.
  - firewall-authority detection order (firewalld -> ufw -> raw
    nftables -> legacy iptables), report §6.
  - Docker dual-stack HostIp":"::"` duplicate-port bug (moby#42313),
    report §5/§16 — deduped in docker_container_info().
  - nginx/Caddy/HAProxy "detected_ingress" block intentionally stays
    shallow (binary presence + version + running-process cross-check
    + a crude stream{} count for nginx) — full AST-level parsing via
    nginxinc/crossplane is explicitly deferred (report §17, SHOULD
    HAVE, not part of this MVP `inspect` PoC).

Schema poc-2 (additive over poc-1) — added per the
"Shared UDP & TCP/UDP Topology Planner" research document's own
"Concrete next implementation step" (§30): four new read-only Discovery
facts a future Capability Registry / Planner will need and cannot
safely infer from anything poc-1 already collected:
  - nginx: compiled-module facts (--with-stream,
    --with-stream_ssl_preread_module), read from `nginx -V`'s own
    "configure arguments:" line — see nginx_stream_capabilities().
  - Caddy: full compiled-module list + specifically whether `layer4`
    and its `layer4.matchers.quic` / `layer4.matchers.tls` sub-modules
    are present, read from `caddy list-modules --versions` — see
    caddy_layer4_capabilities(). Per the research document's own
    warning (and this repo's Contract-style "don't invent capability"
    principle), "a caddy binary exists" is NEVER treated as evidence
    that `layer4` is compiled in — these are two independently-checked
    facts.
  - Hysteria2: whether `obfs.type` is configured, and to what value,
    read from this project's own config path convention
    (lib/core/config.sh's HYSTERIA_CONFIG, verified by direct read —
    see hysteria2_obfuscation()). This is the single most
    safety-critical new fact per the research document (§13/§19):
    Salamander/Gecko obfuscation silently defeats every surveyed
    QUIC-aware L4 router, so a planner that cannot see this value
    cannot safely evaluate a shared-UDP topology at all.
  - Public IPv4 address count, reusing collect_interfaces()'s already-
    gathered data (no new network call) — see public_ipv4_summary().
    Deliberately uses a STRICTER "is this actually globally routable"
    test than the existing classify_bind_address()/_is_public_ip()
    pair used for per-listener public_exposure (see
    _is_globally_routable_ipv4() docstring for why: RFC 6598 CGNAT
    shared address space, 100.64.0.0/10, is NOT `ipaddress`-module
    "private" but also is NOT globally routable, and the existing
    _is_public_ip() would have silently over-counted it — see this
    PoC's README "Research findings requiring correction" section for
    the full writeup of this discrepancy).

None of the above changes any poc-1 field's meaning, type, or
presence — every poc-2 addition is either a new top-level Inventory
key (`hysteria2`, `public_ipv4`) or a new nested key inside an
already-optional per-tool dict (`detected_ingress.nginx`,
`detected_ingress.caddy`), except for one deliberate, narrow
restructuring: `detected_ingress.nginx`/`.caddy`/`.haproxy` are now
ALWAYS present as keys (with an explicit `present: bool` field)
instead of being omitted entirely when the binary is absent — see
README.md's schema changelog for the justification (this project has
zero current consumers of this experimental PoC's JSON, so the
backward-compatibility bar for tightening an already-inconsistent
"omit vs explicit-false" convention is low, and the honest-unknown
principle this whole PoC exists to demonstrate applies exactly as much
to tool-absence as it does to PID-resolution).
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import os
import re
import shutil
import socket as socket_module
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

DEFAULT_TIMEOUT = float(os.environ.get("SM_NETWORK_INSPECT_TIMEOUT", "5"))
SKIP_DOCKER = os.environ.get("SM_NETWORK_INSPECT_NO_DOCKER") == "1"
DOCKER_SOCK = "/var/run/docker.sock"

# Verified by direct read of lib/core/config.sh (this repo, not
# assumed): HYSTERIA_DIR="/etc/hysteria",
# HYSTERIA_CONFIG="${HYSTERIA_DIR}/config.yaml". This PoC does not
# source lib/ (per its own README's stated boundary, the only
# exception being an optional read-only source of lib/ui/output.sh for
# stderr formatting), so the value is duplicated here as a literal,
# not imported — with the override below existing purely for test
# fixtures.
HYSTERIA_CONFIG_PATH = os.environ.get(
    "SM_NETWORK_INSPECT_HYSTERIA_CONFIG", "/etc/hysteria/config.yaml"
)

PID_UNRESOLVED_PERMISSION = "permission_denied"
PID_UNRESOLVED_NOT_FOUND = "not_found_or_cross_namespace"
PID_UNRESOLVED_RACE = "process_exited_during_lookup"

_warnings: list[str] = []


def warn(msg: str) -> None:
    _warnings.append(msg)
    print(f"  ⚠  {msg}", file=sys.stderr)


# ─────────────────────────────────────────────────────────────────────
# subprocess helper — every external call in this file goes through
# this, so the timeout policy (Contract 6) and the
# "couldn't-run vs ran-and-said-no" distinction are enforced in one
# place, not re-implemented ad hoc per call site.
# ─────────────────────────────────────────────────────────────────────

@dataclass
class RunResult:
    ok: bool               # did we get a completed process at all
    returncode: Optional[int]
    stdout: str
    stderr: str
    reason: Optional[str] = None   # "not_found" | "timeout" | None


def run(cmd: list[str], timeout: float = DEFAULT_TIMEOUT) -> RunResult:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return RunResult(True, proc.returncode, proc.stdout, proc.stderr)
    except FileNotFoundError:
        return RunResult(False, None, "", "", reason="not_found")
    except subprocess.TimeoutExpired:
        return RunResult(False, None, "", "", reason="timeout")


def which(binname: str) -> Optional[str]:
    return shutil.which(binname)


# ─────────────────────────────────────────────────────────────────────
# 1. Interfaces
# ─────────────────────────────────────────────────────────────────────

def collect_interfaces() -> dict:
    """`ip -j addr` already emits JSON — no text parsing needed, just
    reshape it. Falls back to a degraded stub on very old iproute2
    (<4.x) that lacks -j; a full text-mode ip-addr parser is out of
    scope for this PoC (report §17: not MUST-HAVE)."""
    if not which("ip"):
        warn("`ip` not found — interface list unavailable")
        return {"available": False, "reason": "ip_not_found", "interfaces": []}

    res = run(["ip", "-j", "addr"])
    if not res.ok or res.returncode != 0:
        warn("`ip -j addr` failed — degraded interface visibility")
        return {"available": False, "reason": "ip_failed", "interfaces": []}

    try:
        raw = json.loads(res.stdout)
    except json.JSONDecodeError:
        warn("`ip -j addr` did not return valid JSON (old iproute2 without -j support?)")
        return {"available": False, "reason": "no_json_support", "interfaces": []}

    interfaces = []
    for iface in raw:
        addrs = []
        for a in iface.get("addr_info", []):
            addrs.append({
                "family": a.get("family"),
                "address": a.get("local"),
                "prefixlen": a.get("prefixlen"),
                "scope": a.get("scope"),
            })
        interfaces.append({
            "name": iface.get("ifname"),
            "state": iface.get("operstate"),
            "flags": iface.get("flags", []),
            "addresses": addrs,
        })
    return {"available": True, "reason": None, "interfaces": interfaces}


def classify_bind_address(addr: str, interfaces: list[dict]) -> str:
    """Cross-checks a listener's bind address against real configured
    interface addresses — report §3 explicitly flags this as required,
    since a bare 0.0.0.0 check alone can't tell "public" from
    "all-interfaces but no public IP exists on this host"."""
    if addr in ("0.0.0.0", "*"):
        has_public = any(
            _is_public_ip(a["address"])
            for iface in interfaces for a in iface.get("addresses", [])
            if a.get("family") == "inet"
        )
        return "all-interfaces-with-public-ipv4" if has_public else "all-interfaces-no-public-ipv4"
    if addr in ("::", "*6"):
        has_public = any(
            _is_public_ip(a["address"])
            for iface in interfaces for a in iface.get("addresses", [])
            if a.get("family") == "inet6"
        )
        return "all-interfaces-with-public-ipv6" if has_public else "all-interfaces-no-public-ipv6"
    try:
        ip_obj = ipaddress.ip_address(addr)
    except ValueError:
        return "unparseable"
    if ip_obj.is_loopback:
        return "loopback"
    if ip_obj.is_link_local:
        return "link-local"
    if ip_obj.is_private:
        return "private-interface"
    return "public"


def _is_public_ip(addr: Optional[str]) -> bool:
    if not addr:
        return False
    try:
        ip_obj = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return not (ip_obj.is_loopback or ip_obj.is_link_local or ip_obj.is_private)


# ─────────────────────────────────────────────────────────────────────
# 2. Listeners (ss primary, /proc/net/* fallback)
# ─────────────────────────────────────────────────────────────────────

_SS_LINE_RE = re.compile(
    r"^(?P<proto>tcp|udp)\s+"
    r"(?P<state>\S+)?\s*"
    r"(?P<recvq>\d+)\s+(?P<sendq>\d+)\s+"
    r"(?P<local>\S+)\s+(?P<peer>\S+)"
    r"(?P<rest>.*)$"
)
_SS_INO_RE = re.compile(r"ino:(\d+)")
_SS_PID_RE = re.compile(r'pid=(\d+)')
_SS_PROC_RE = re.compile(r'\(\("([^"]+)",pid=(\d+),fd=(\d+)\)\)')


def _split_addr_port(field_: str) -> tuple[str, Optional[int]]:
    # ss uses [addr]:port for IPv6, addr:port for IPv4/*
    m = re.match(r"^\[(?P<addr>.+)\]:(?P<port>\*|\d+)$", field_)
    if m:
        port = m.group("port")
        return m.group("addr"), (None if port == "*" else int(port))
    if ":" in field_:
        addr, _, port = field_.rpartition(":")
        return addr, (None if port == "*" else int(port))
    return field_, None


def collect_listeners_via_ss() -> Optional[list[dict]]:
    if not which("ss"):
        return None
    # -H no header, -t tcp, -u udp, -l listening only, -n numeric,
    # -p process (best-effort, may be blank without matching
    # privilege/namespace — see report §3), -e extended (gives ino:N,
    # which is the ground-truth correlation key regardless of whether
    # -p succeeded).
    res = run(["ss", "-H", "-tulnpe"])
    if not res.ok:
        warn(f"`ss` invocation failed ({res.reason}) — falling back to /proc/net/*")
        return None
    if res.returncode != 0:
        warn("`ss -tulnpe` returned non-zero — falling back to /proc/net/*")
        return None

    listeners = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        m = _SS_LINE_RE.match(line)
        if not m:
            continue
        proto = m.group("proto")
        local_addr, local_port = _split_addr_port(m.group("local"))
        if local_port is None:
            continue
        rest = m.group("rest")
        ino_m = _SS_INO_RE.search(rest)
        proc_m = _SS_PROC_RE.search(rest)
        listeners.append({
            "proto": proto,
            "bind_address": local_addr,
            "bind_port": local_port,
            "state": m.group("state") or ("LISTEN" if proto == "tcp" else None),
            "inode": int(ino_m.group(1)) if ino_m else None,
            "ss_reported_process": (
                {"comm": proc_m.group(1), "pid": int(proc_m.group(2)), "fd": int(proc_m.group(3))}
                if proc_m else None
            ),
            "source": "ss",
        })
    return listeners


# Minimal IPv4-only /proc/net/{tcp,udp} fallback. IPv6 fallback parsing
# is intentionally NOT implemented here (would roughly double this
# function for a path only hit when `ss` itself is missing, which per
# the research report is already an unusual/stripped-host case) —
# flagged as a known limitation, not silently pretended-complete.
def _decode_proc_net_line(line: str, proto: str) -> Optional[dict]:
    parts = line.split()
    if len(parts) < 10:
        return None
    local_addr_hex, local_port_hex = parts[1].split(":")
    state_hex = parts[3]
    inode = int(parts[9])
    try:
        addr_int = int(local_addr_hex, 16)
        addr = socket_module.inet_ntoa(addr_int.to_bytes(4, "little"))
    except (ValueError, OverflowError):
        return None
    port = int(local_port_hex, 16)
    if proto == "tcp" and state_hex != "0A":  # 0A = TCP_LISTEN
        return None
    if proto == "udp":
        # UDP has no LISTEN state; treat any locally-bound, unconnected
        # (remote 0.0.0.0:0) entry as a "listener" for this PoC's
        # purposes.
        remote_addr_hex, remote_port_hex = parts[2].split(":")
        if remote_addr_hex != "00000000" or remote_port_hex != "0000":
            return None
    return {
        "proto": proto,
        "bind_address": addr,
        "bind_port": port,
        "state": "LISTEN" if proto == "tcp" else None,
        "inode": inode,
        "ss_reported_process": None,
        "source": "proc_net",
    }


def collect_listeners_via_proc() -> list[dict]:
    listeners = []
    for proto, path in (("tcp", "/proc/net/tcp"), ("udp", "/proc/net/udp")):
        try:
            with open(path, "r", encoding="ascii", errors="replace") as fh:
                lines = fh.readlines()[1:]  # skip header
        except OSError as exc:
            warn(f"could not read {path}: {exc}")
            continue
        for line in lines:
            entry = _decode_proc_net_line(line, proto)
            if entry:
                listeners.append(entry)
    if not listeners:
        warn(
            "/proc/net/{tcp,udp} fallback found nothing either — "
            "IPv6-only listeners will not appear (fallback path is "
            "IPv4-only by design, see docstring above collect_listeners_via_proc)"
        )
    return listeners


def collect_listeners() -> list[dict]:
    via_ss = collect_listeners_via_ss()
    if via_ss is not None:
        return via_ss
    return collect_listeners_via_proc()


# ─────────────────────────────────────────────────────────────────────
# 3. inode -> PID correlation (the actual "port -> socket -> PID" step)
# ─────────────────────────────────────────────────────────────────────

_PROC_PID_RE = re.compile(r"^\d+$")


def build_inode_to_pid_map() -> tuple[dict[int, int], bool]:
    """One /proc walk, reused for every listener, instead of walking
    /proc once per socket — same approach osquery/gopsutil/portview
    all use (report §3/§4). Returns (map, saw_any_permission_denied)."""
    mapping: dict[int, int] = {}
    saw_permission_denied = False
    try:
        pids = [p for p in os.listdir("/proc") if _PROC_PID_RE.match(p)]
    except OSError as exc:
        warn(f"could not list /proc: {exc}")
        return mapping, False

    for pid_s in pids:
        fd_dir = f"/proc/{pid_s}/fd"
        try:
            fds = os.listdir(fd_dir)
        except PermissionError:
            saw_permission_denied = True
            continue
        except FileNotFoundError:
            continue  # process exited between listdir(/proc) and here

        for fd in fds:
            try:
                link = os.readlink(f"{fd_dir}/{fd}")
            except (PermissionError, FileNotFoundError):
                continue
            m = re.match(r"socket:\[(\d+)\]", link)
            if m:
                mapping[int(m.group(1))] = int(pid_s)
    return mapping, saw_permission_denied


# ─────────────────────────────────────────────────────────────────────
# 4. PID -> process -> systemd unit / docker container
# ─────────────────────────────────────────────────────────────────────

def process_info(pid: int) -> Optional[dict]:
    base = f"/proc/{pid}"
    try:
        with open(f"{base}/comm") as fh:
            comm = fh.read().strip()
    except (FileNotFoundError, ProcessLookupError):
        return None  # PID_UNRESOLVED_RACE at the caller
    except PermissionError:
        return {"pid": pid, "comm": None, "cmdline": None, "exe": None,
                "cgroup_raw": None, "unresolved_reason": PID_UNRESOLVED_PERMISSION}

    cmdline = None
    try:
        with open(f"{base}/cmdline", "rb") as fh:
            raw = fh.read()
        cmdline = " ".join(p.decode(errors="replace") for p in raw.split(b"\x00") if p)
    except OSError:
        pass

    exe = None
    try:
        exe = os.readlink(f"{base}/exe")
    except OSError:
        pass

    cgroup_raw = None
    try:
        with open(f"{base}/cgroup") as fh:
            cgroup_raw = fh.read().strip()
    except OSError:
        pass

    return {
        "pid": pid, "comm": comm, "cmdline": cmdline, "exe": exe,
        "cgroup_raw": cgroup_raw, "unresolved_reason": None,
    }


_DOCKER_CGROUP_RE = re.compile(r"docker[/-]([0-9a-f]{12,64})")
_SYSTEMD_UNIT_RE = re.compile(r"/([\w@.\-]+\.service)$")


def classify_ownership(proc: dict) -> dict:
    """PID -> {kind: docker|systemd|process|unknown, ...}. This is
    exactly the "process -> service -> container" hop the research
    report calls out as the piece plain /proc reading cannot skip
    past on its own."""
    cgroup_raw = proc.get("cgroup_raw") or ""
    docker_m = _DOCKER_CGROUP_RE.search(cgroup_raw)
    if docker_m:
        return {"kind": "docker", "container_id": docker_m.group(1)}
    unit_m = _SYSTEMD_UNIT_RE.search(cgroup_raw)
    if unit_m:
        return {"kind": "systemd", "unit": unit_m.group(1)}
    if proc.get("comm"):
        return {"kind": "process", "comm": proc["comm"]}
    return {"kind": "unknown"}


# ─────────────────────────────────────────────────────────────────────
# 5. Docker Engine API (read-only GET over the unix socket, no `docker`
#    CLI dependency, no extra pip package)
# ─────────────────────────────────────────────────────────────────────

class _UnixSocketHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float = DEFAULT_TIMEOUT):
        super().__init__("localhost", timeout=timeout)
        self._unix_path = path

    def connect(self):
        self.sock = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._unix_path)


_docker_cache: dict[str, Optional[dict]] = {}
_docker_available: Optional[bool] = None


def docker_container_info(container_id_prefix: str) -> Optional[dict]:
    global _docker_available
    if SKIP_DOCKER:
        return None
    if _docker_available is False:
        return None
    if container_id_prefix in _docker_cache:
        return _docker_cache[container_id_prefix]
    if not os.path.exists(DOCKER_SOCK):
        _docker_available = False
        return None

    try:
        conn = _UnixSocketHTTPConnection(DOCKER_SOCK)
        conn.request("GET", f"/containers/{container_id_prefix}/json")
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
    except (OSError, http.client.HTTPException) as exc:
        warn(f"Docker Engine API unreachable via {DOCKER_SOCK}: {exc}")
        _docker_available = False
        return None

    _docker_available = True
    if resp.status != 200:
        _docker_cache[container_id_prefix] = None
        return None

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        _docker_cache[container_id_prefix] = None
        return None

    ns_ports = data.get("NetworkSettings", {}).get("Ports") or {}
    # moby#42313: dual-stack hosts can list the same host port twice,
    # once with HostIp "0.0.0.0" and once with the invalid-looking
    # HostIp "::" — dedupe by (container_port_proto, host_port) as the
    # research report calls out explicitly.
    seen = set()
    published = []
    for cport_proto, bindings in ns_ports.items():
        for b in (bindings or []):
            key = (cport_proto, b.get("HostPort"))
            if key in seen:
                continue
            seen.add(key)
            published.append({
                "container_port_proto": cport_proto,
                "host_ip": b.get("HostIp"),
                "host_port": b.get("HostPort"),
            })

    labels = data.get("Config", {}).get("Labels") or {}
    info = {
        "name": (data.get("Name") or "").lstrip("/"),
        "image": data.get("Config", {}).get("Image"),
        "compose_project": labels.get("com.docker.compose.project"),
        "compose_service": labels.get("com.docker.compose.service"),
        "published_ports": published,
    }
    _docker_cache[container_id_prefix] = info
    return info


# ─────────────────────────────────────────────────────────────────────
# 6. systemd unit lookup
# ─────────────────────────────────────────────────────────────────────

_systemd_available: Optional[bool] = None
_systemd_cache: dict[str, Optional[dict]] = {}


def systemd_unit_info(unit: str) -> Optional[dict]:
    global _systemd_available
    if _systemd_available is False:
        return None
    if unit in _systemd_cache:
        return _systemd_cache[unit]
    if not which("systemctl"):
        _systemd_available = False
        return None

    res = run([
        "systemctl", "show", "--no-pager",
        "-p", "Id,MainPID,FragmentPath,ActiveState,SubState",
        unit,
    ])
    if not res.ok or res.returncode != 0 or "Host is down" in res.stderr:
        # covers both "systemctl binary present but no systemd PID 1"
        # (containers) and genuine D-Bus failures — both mean
        # "systemd introspection unavailable", not "unit doesn't exist"
        if _systemd_available is None:
            warn("systemd D-Bus unavailable (not running under systemd as PID 1?) — unit lookups skipped")
        _systemd_available = False
        return None

    _systemd_available = True
    fields = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            fields[k] = v
    info = {
        "id": fields.get("Id"),
        "main_pid": fields.get("MainPID"),
        "fragment_path": fields.get("FragmentPath"),
        "active_state": fields.get("ActiveState"),
        "sub_state": fields.get("SubState"),
    }
    _systemd_cache[unit] = info
    return info


# ─────────────────────────────────────────────────────────────────────
# 7. Firewall authority detection (report §6 detection order)
# ─────────────────────────────────────────────────────────────────────

def detect_firewall() -> dict:
    # 1. firewalld
    if which("firewall-cmd"):
        res = run(["firewall-cmd", "--state"])
        if res.ok and res.returncode == 0 and "running" in res.stdout.lower():
            backend = "unknown"
            try:
                with open("/etc/firewalld/firewalld.conf") as fh:
                    for line in fh:
                        line = line.strip()
                        if line.startswith("FirewallBackend"):
                            backend = line.split("=", 1)[1].strip() or "nftables"
                            break
                    else:
                        backend = "nftables"  # documented default since firewalld 0.6.0
            except OSError:
                pass
            return {"authoritative_frontend": "firewalld", "backend": backend, "detail": "firewall-cmd --state == running"}

    # 2. ufw
    if which("ufw"):
        res = run(["ufw", "status"])
        if res.ok and res.returncode == 0 and "status: active" in res.stdout.lower():
            return {"authoritative_frontend": "ufw", "backend": "iptables-nft/nftables (distro-dependent)",
                    "detail": "ufw status == active"}

    # 3. raw nftables
    if which("nft"):
        res = run(["nft", "-j", "list", "ruleset"])
        if res.ok and res.returncode == 0:
            try:
                parsed = json.loads(res.stdout)
                if parsed.get("nftables"):
                    return {"authoritative_frontend": "nftables-raw", "backend": "nftables",
                            "detail": f"{len(parsed['nftables'])} ruleset entries"}
            except json.JSONDecodeError:
                pass

    # 4. legacy iptables
    if which("iptables-save"):
        res = run(["iptables-save"])
        if res.ok and res.returncode == 0 and res.stdout.strip():
            return {"authoritative_frontend": "iptables-legacy", "backend": "iptables",
                    "detail": "iptables-save produced non-empty output"}

    return {"authoritative_frontend": "none-detected", "backend": None, "detail": None}


# ─────────────────────────────────────────────────────────────────────
# 8. Detected ingress (nginx / caddy / haproxy) — shallow by design,
#    see module docstring.
# ─────────────────────────────────────────────────────────────────────

def _version_of(cmd: list[str]) -> Optional[str]:
    res = run(cmd)
    if not res.ok or res.returncode not in (0, 1):
        # nginx -v exits 0 but writes to stderr; keep both streams
        return None
    text = (res.stdout + res.stderr).strip().splitlines()
    return text[0] if text else None


# ─────────────────────────────────────────────────────────────────────
# 8a. nginx compiled-module capability facts (schema poc-2)
#
# Raw-fact only — this function records what `nginx -V` says was
# compiled in. It does NOT decide whether that makes any topology
# "possible"; that interpretation belongs to a future Capability
# Registry, not to Discovery (research doc §7 principle, restated in
# this file's own module docstring above).
# ─────────────────────────────────────────────────────────────────────

# Whole-token match: "--with-stream" must NOT match inside
# "--with-stream_ssl_preread_module" (a real, easy-to-get-wrong
# collision — the two flags share a common prefix). The (?<!\S)/(?!\S)
# boundaries require actual whitespace (or string start/end) around
# the token, which a naive substring check does not enforce.
_NGINX_WITH_STREAM_RE = re.compile(r"(?<!\S)--with-stream(?:=\S+)?(?!\S)")
_NGINX_WITH_STREAM_SSL_PREREAD_RE = re.compile(
    r"(?<!\S)--with-stream_ssl_preread_module(?:=\S+)?(?!\S)"
)
_NGINX_CONFIGURE_ARGS_RE = re.compile(r"^configure arguments:\s*(.*)$", re.MULTILINE)


def nginx_stream_capabilities(nginx_bin: str) -> dict:
    """Reads `nginx -V` (note: capital -V, the flag that prints the
    configure-time arguments; distinct from `nginx -v`, the
    version-only flag already used above for `entry["version"]`).
    nginx famously writes this to STDERR, not stdout — `_version_of()`
    already concatenates both streams for exactly this reason, and
    this function does the same rather than assuming one stream.

    Returns a dict that always has a "status" of "available" or
    "unresolved" (never a silent success-with-nulls) and, when
    available, three independently-meaningful facts: whether
    --with-stream was compiled in, whether
    --with-stream_ssl_preread_module was compiled in, and whether
    either was compiled as a *dynamic* module (in which case actually
    being active at runtime additionally depends on a `load_module`
    directive in nginx.conf — a fact this shallow-by-design PoC does
    NOT check, per the module docstring's "no full AST parsing" scope;
    recorded explicitly as `dynamic_module_caveat` rather than silently
    assumed away).
    """
    res = run(["nginx", "-V"])
    if not res.ok:
        return {
            "status": "unresolved",
            "unresolved_reason": f"version_probe_failed:{res.reason}",
            "compiled_with_stream": None,
            "compiled_with_stream_ssl_preread": None,
            "stream_module_type": None,
            "dynamic_module_caveat": None,
            "configure_arguments_raw": None,
        }
    if res.returncode not in (0, 1):
        # nginx -V exits 0 on most builds but some distro wrappers
        # return 1 while still printing the expected text — matches
        # the existing _version_of() tolerance above, kept consistent
        # rather than inventing a stricter rule for this new call site.
        return {
            "status": "unresolved",
            "unresolved_reason": f"version_probe_failed:returncode_{res.returncode}",
            "compiled_with_stream": None,
            "compiled_with_stream_ssl_preread": None,
            "stream_module_type": None,
            "dynamic_module_caveat": None,
            "configure_arguments_raw": None,
        }

    combined = res.stdout + res.stderr
    m = _NGINX_CONFIGURE_ARGS_RE.search(combined)
    if not m:
        # Binary ran and returned successfully, but the expected
        # "configure arguments:" line wasn't found — an unexpected
        # output format (very old nginx, or a distro fork with a
        # different -V layout) is a real "couldn't check" case, not
        # evidence stream is absent.
        return {
            "status": "unresolved",
            "unresolved_reason": "configure_arguments_not_found",
            "compiled_with_stream": None,
            "compiled_with_stream_ssl_preread": None,
            "stream_module_type": None,
            "dynamic_module_caveat": None,
            "configure_arguments_raw": combined.strip() or None,
        }

    configure_args = m.group(1).strip()
    has_stream = bool(_NGINX_WITH_STREAM_RE.search(configure_args))
    has_stream_ssl_preread = bool(
        _NGINX_WITH_STREAM_SSL_PREREAD_RE.search(configure_args)
    )
    # --with-X=dynamic is the documented nginx configure-time syntax
    # for building a module as a loadable .so instead of statically
    # linking it in.
    is_dynamic = bool(re.search(r"(?<!\S)--with-stream(?:_ssl_preread_module)?=dynamic(?!\S)", configure_args))

    return {
        "status": "available",
        "unresolved_reason": None,
        "compiled_with_stream": has_stream,
        "compiled_with_stream_ssl_preread": has_stream_ssl_preread,
        "stream_module_type": ("dynamic" if is_dynamic else "static") if has_stream else None,
        "dynamic_module_caveat": (
            "compiled as a dynamic module — actually being active at "
            "runtime additionally requires a `load_module` directive "
            "in nginx.conf, which this PoC does NOT check (shallow by "
            "design, see module docstring)"
        ) if is_dynamic else None,
        "configure_arguments_raw": configure_args,
    }


# ─────────────────────────────────────────────────────────────────────
# 8b. Caddy / caddy-l4 module-list capability facts (schema poc-2)
#
# Raw-fact only, per the same principle as 8a — this records the
# module list `caddy list-modules --versions` reports; it does not
# decide what that implies for any topology (research doc §7/§20).
#
# Critical invariant (research doc §7, this repo's own task brief
# §3): "Caddy installed" != "caddy-l4 available" != "QUIC matcher
# available". These are three independently-recorded facts below,
# never collapsed into one boolean.
# ─────────────────────────────────────────────────────────────────────

def caddy_layer4_capabilities(caddy_bin: str) -> dict:
    res = run(["caddy", "list-modules", "--versions"])
    if not res.ok:
        return {
            "status": "unresolved",
            "unresolved_reason": f"list_modules_failed:{res.reason}",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": None,
        }
    if res.returncode != 0:
        return {
            "status": "unresolved",
            "unresolved_reason": f"list_modules_failed:returncode_{res.returncode}",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": None,
        }

    modules: list[str] = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Each line is "module.name" or "module.name  vX.Y.Z-..."; the
        # module name is always the first whitespace-separated token.
        # Caddy's own output also includes non-module header/footer
        # lines in some versions (e.g. "Standard modules:") — anything
        # that isn't a dotted-or-bare identifier-looking token is kept
        # in raw_module_list for transparency but not used for the
        # boolean facts below, since a false positive there would be
        # exactly the kind of invented capability this PoC must not
        # produce.
        token = line.split()[0]
        modules.append(token)

    if not modules:
        # Binary ran, exited 0, produced no parseable module lines at
        # all — this is unusual enough (a genuinely module-less Caddy
        # build is very rare) that treating it as a confirmed "no
        # layer4" would risk masking a parsing problem as a capability
        # fact. Recorded as unresolved instead.
        return {
            "status": "unresolved",
            "unresolved_reason": "empty_module_list",
            "layer4_present": None,
            "layer4_matchers_quic_present": None,
            "layer4_matchers_tls_present": None,
            "raw_module_list": [],
        }

    module_set = set(modules)
    layer4_present = ("layer4" in module_set) or any(
        m == "layer4" or m.startswith("layer4.") for m in module_set
    )
    return {
        "status": "available",
        "unresolved_reason": None,
        "layer4_present": layer4_present,
        "layer4_matchers_quic_present": "layer4.matchers.quic" in module_set,
        "layer4_matchers_tls_present": "layer4.matchers.tls" in module_set,
        "raw_module_list": modules,
    }


def detect_ingress(listener_comms: set[str]) -> dict:
    """Per schema poc-2: nginx/caddy/haproxy entries are now ALWAYS
    present as keys in the returned dict (with an explicit
    "present": bool field), rather than being omitted when the binary
    is absent — see the module docstring's schema-poc-2 note for why
    this narrow restructuring was judged safe and worthwhile."""
    result: dict = {}

    # nginx
    nginx_bin = which("nginx")
    if nginx_bin:
        entry = {
            "present": True,
            "binary": nginx_bin,
            "version": _version_of(["nginx", "-v"]),
            "running": "nginx" in listener_comms,
            "stream_block_count": None,
            "stream_capabilities": nginx_stream_capabilities(nginx_bin),
        }
        res = run(["nginx", "-T"])
        if res.ok and res.returncode == 0:
            entry["stream_block_count"] = len(re.findall(r"^\s*stream\s*{", res.stdout, re.MULTILINE))
        result["nginx"] = entry
    else:
        result["nginx"] = {
            "present": False,
            "binary": None,
            "version": None,
            "running": False,
            "stream_block_count": None,
            "stream_capabilities": None,
        }

    # caddy
    caddy_bin = which("caddy")
    if caddy_bin:
        entry = {
            "present": True,
            "binary": caddy_bin,
            "version": _version_of(["caddy", "version"]),
            "running": "caddy" in listener_comms,
            "layer4_module_compiled_in": None,
            "admin_api_reachable": None,
            "layer4_capabilities": caddy_layer4_capabilities(caddy_bin),
        }
        # Kept for backward-shape continuity with poc-1's boolean
        # field, now correctly derived from the same parsed module
        # list layer4_capabilities() already built (poc-1's version of
        # this field used a crude `"layer4." in res.stdout` substring
        # check against the raw text, which is superseded here by an
        # actual per-line module-name parse — see README changelog).
        if entry["layer4_capabilities"]["status"] == "available":
            entry["layer4_module_compiled_in"] = entry["layer4_capabilities"]["layer4_present"]
        if entry["running"]:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", 2019, timeout=DEFAULT_TIMEOUT)
                conn.request("GET", "/config/")
                resp = conn.getresponse()
                entry["admin_api_reachable"] = resp.status == 200
                conn.close()
            except OSError:
                entry["admin_api_reachable"] = False
        result["caddy"] = entry
    else:
        result["caddy"] = {
            "present": False,
            "binary": None,
            "version": None,
            "running": False,
            "layer4_module_compiled_in": None,
            "admin_api_reachable": None,
            "layer4_capabilities": None,
        }

    # haproxy
    haproxy_bin = which("haproxy")
    if haproxy_bin:
        entry = {
            "present": True,
            "binary": haproxy_bin,
            "version": _version_of(["haproxy", "-v"]),
            "running": "haproxy" in listener_comms,
            "dataplaneapi_detected": which("dataplaneapi") is not None or "dataplaneapi" in listener_comms,
        }
        result["haproxy"] = entry
    else:
        result["haproxy"] = {
            "present": False,
            "binary": None,
            "version": None,
            "running": False,
            "dataplaneapi_detected": False,
        }

    return result


# ─────────────────────────────────────────────────────────────────────
# 8c. Hysteria2 obfuscation discovery (schema poc-2)
#
# The single most safety-critical new discovery fact per the research
# document (§13/§19): a shared-UDP-QUIC-SNI planner decision can only
# ever be safe if this value is actually known, not assumed. This is
# a deliberately MINIMAL, TARGETED extractor for exactly the two-level
# `obfs: / type: <value>` block Hysteria2's own docs show (see
# module docstring / README for the upstream examples this was
# verified against) — it is NOT a general YAML parser, and does not
# try to be one. No PyYAML (or any other new) dependency is
# introduced: this project's existing Hysteria2 config-editing code
# (lib/hy2/install.sh, lib/hy2/integration.sh) already edits this same
# file with regex/line-oriented `re.sub`-style logic rather than a
# full YAML round-trip, and this function follows that same, already-
# established project convention rather than introducing a new one.
# ─────────────────────────────────────────────────────────────────────

_OBFS_TOP_KEY_RE = re.compile(r"^obfs:\s*(#.*)?$")
_OBFS_TOP_KEY_INLINE_RE = re.compile(r"^obfs:\s*(\S.*)$")
_OBFS_TYPE_LINE_RE = re.compile(r"^(?P<indent>[ ]+)type:\s*(?P<value>.*)$")


def _strip_yaml_comment(value: str) -> str:
    """Best-effort trailing-comment strip for a scalar value on one
    line — good enough for the specific `type: <bareword>` shape this
    extractor targets (Hysteria2's obfs.type is always a short
    unquoted identifier: none/salamander/gecko in every example this
    research found), not a general YAML scalar parser."""
    # A '#' preceded by whitespace (or at start) begins a comment in
    # block-style YAML scalars, as long as we're not inside quotes —
    # this function is only ever called on values already known not
    # to start with a quote character (checked by the caller).
    m = re.search(r"\s#", value)
    return (value[: m.start()] if m else value).strip()


def _hysteria2_obfs_unresolved(
    config_path: str, reason: str, field_present_in_config: Optional[bool] = None
) -> dict:
    return {
        "config_path": config_path,
        "status": "unresolved",
        "unresolved_reason": reason,
        "field_present_in_config": field_present_in_config,
        "raw_type_value": None,
        "effective_value": None,
        "effective_value_basis": None,
        "confidence": None,
    }


def hysteria2_obfuscation(config_path: str) -> dict:
    def unresolved(reason: str, field_present_in_config: Optional[bool] = None) -> dict:
        return _hysteria2_obfs_unresolved(config_path, reason, field_present_in_config)

    if not os.path.exists(config_path):
        return unresolved("config_missing")

    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            raw_bytes_ok = True
            try:
                text = fh.read()
            except UnicodeDecodeError:
                raw_bytes_ok = False
                text = ""
        if not raw_bytes_ok:
            return unresolved("decode_error")
    except PermissionError:
        return unresolved("config_unreadable")
    except OSError as exc:
        return unresolved(f"config_unreadable:{exc.__class__.__name__}")

    lines = text.splitlines()

    # YAML forbids tab characters for indentation — a tab anywhere in
    # a line's leading whitespace is an unambiguous, cheaply-detected
    # structural error worth flagging as malformed rather than risking
    # a misparse of the block below.
    for line in lines:
        stripped_leading = line[: len(line) - len(line.lstrip(" \t"))]
        if "\t" in stripped_leading:
            return unresolved("malformed_yaml:tab_indentation")

    top_key_idx = None
    for i, line in enumerate(lines):
        if _OBFS_TOP_KEY_RE.match(line):
            top_key_idx = i
            break
        if _OBFS_TOP_KEY_INLINE_RE.match(line):
            # `obfs: {type: salamander}` (flow style) or some other
            # non-block-mapping form on the same line — explicitly
            # out of scope for this minimal extractor, per its own
            # docstring. Do not guess; report the real limitation.
            return unresolved("flow_style_not_supported", field_present_in_config=True)

    if top_key_idx is None:
        # No top-level `obfs:` key anywhere in the file at all.
        # Per upstream Hysteria2/sing-box documentation ("Configs that
        # omit obfs use the unobfuscated path"), this is a real,
        # positively-resolvable fact, not an unknown — but the
        # PHYSICAL absence of the field is still recorded separately
        # from the EFFECTIVE value, per the task's own explicit
        # requirement.
        return {
            "config_path": config_path,
            "status": "resolved",
            "unresolved_reason": None,
            "field_present_in_config": False,
            "raw_type_value": None,
            "effective_value": "none",
            "effective_value_basis": "default_when_absent",
            "confidence": "high",
        }

    # Walk the indented block following `obfs:` looking for the first
    # `type:` line at the block's own (shallowest) indentation level.
    block_indent = None
    type_value_raw = None
    j = top_key_idx + 1
    while j < len(lines):
        line = lines[j]
        if line.strip() == "" or line.lstrip().startswith("#"):
            j += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            break  # dedented back to top level — obfs block has ended
        if block_indent is None:
            block_indent = indent
        if indent == block_indent:
            m = _OBFS_TYPE_LINE_RE.match(line)
            if m and len(m.group("indent")) == block_indent:
                candidate = m.group("value").strip()
                if candidate.startswith(("'", '"')):
                    # Quoted scalar — this minimal extractor does not
                    # attempt quote-aware unescaping; report the
                    # literal quoted form rather than guessing.
                    type_value_raw = candidate
                else:
                    type_value_raw = _strip_yaml_comment(candidate)
                break
        j += 1

    if type_value_raw is None:
        # `obfs:` block exists but no `type:` sub-key was found in it
        # before the block ended — malformed relative to Hysteria2's
        # own schema (type is the required selector field).
        return unresolved("obfs_block_present_but_type_missing", field_present_in_config=True)

    if not type_value_raw:
        return unresolved("obfs_type_value_empty", field_present_in_config=True)

    # Detect an obviously unbalanced quote as a light malformed-YAML
    # signal (e.g. `type: "salamander`), without attempting to be a
    # real YAML scalar validator.
    if type_value_raw.count('"') % 2 == 1 or type_value_raw.count("'") % 2 == 1:
        return unresolved("malformed_yaml:unbalanced_quote", field_present_in_config=True)

    normalized = type_value_raw.strip("'\"").strip().lower()
    effective = normalized if normalized in ("none", "salamander", "gecko") else "unknown"

    return {
        "config_path": config_path,
        "status": "resolved",
        "unresolved_reason": None,
        "field_present_in_config": True,
        "raw_type_value": type_value_raw,
        "effective_value": effective,
        "effective_value_basis": "explicit_in_config",
        "confidence": "high" if effective != "unknown" else "medium",
    }


# ─────────────────────────────────────────────────────────────────────
# 8d. Public IPv4 count (schema poc-2)
#
# Reuses collect_interfaces()'s already-gathered `ip -j addr` data —
# no new network call. Deliberately uses a STRICTER globally-routable
# test than the existing _is_public_ip()/classify_bind_address() pair
# (see _is_globally_routable_ipv4() docstring immediately below for
# the concrete discrepancy this surfaced — RFC 6598 CGNAT space).
# ─────────────────────────────────────────────────────────────────────

def _is_globally_routable_ipv4(addr: Optional[str]) -> Optional[bool]:
    """Stricter than the existing _is_public_ip() used for per-listener
    public_exposure classification. `ipaddress.IPv4Address.is_private`
    (used by _is_public_ip) does NOT cover RFC 6598 Carrier-Grade NAT
    shared address space (100.64.0.0/10) — verified directly against
    Python's own ipaddress module (100.64.0.1: is_private=False,
    is_global=False). A host whose only "public-looking" interface
    address is actually CGNAT space is NOT reachable from the public
    internet on that address, so counting it as a public IPv4 would be
    exactly the false-precision the research document and this task
    both warn against. `ipaddress`'s own `is_global` property is used
    instead, since it is the stdlib's own maintained answer to "is
    this IANA-globally-routable" and already correctly excludes
    loopback, link-local, RFC1918, CGNAT, and the various
    documentation/benchmarking ranges (verified: 198.18.0.1 and
    203.0.113.5 both come back is_private=True in this Python version,
    so those are already excluded by the pre-existing helper too —
    the CGNAT range was the one confirmed gap).

    Returns None (not True/False) if `addr` doesn't parse as an IPv4
    address at all — an unparseable address is an unresolved fact, not
    a confirmed non-public one.
    """
    if not addr:
        return None
    try:
        ip_obj = ipaddress.ip_address(addr)
    except ValueError:
        return None
    if not isinstance(ip_obj, ipaddress.IPv4Address):
        return None
    return bool(ip_obj.is_global)


def public_ipv4_summary(interfaces_block: dict) -> dict:
    if not interfaces_block.get("available"):
        return {
            "status": "unresolved",
            "unresolved_reason": interfaces_block.get("reason") or "interfaces_unavailable",
            "count": None,
            "addresses": [],
            "routability_verified": False,
        }

    addresses = []
    for iface in interfaces_block.get("interfaces", []):
        for a in iface.get("addresses", []):
            if a.get("family") != "inet":
                continue
            addr = a.get("address")
            is_global = _is_globally_routable_ipv4(addr)
            if is_global:
                addresses.append({
                    "interface": iface.get("name"),
                    "address": addr,
                    "prefixlen": a.get("prefixlen"),
                })

    return {
        "status": "available",
        "unresolved_reason": None,
        "count": len(addresses),
        "addresses": addresses,
        # This counts addresses the ipaddress stdlib module classifies
        # as globally-routable-per-IANA-registry. It does NOT verify
        # actual internet reachability (no outbound probe is made by
        # this read-only PoC) — a host could still be behind an
        # upstream NAT/firewall that this offline check cannot see.
        # Recorded explicitly so a consumer never mistakes this for a
        # stronger guarantee than it is.
        "routability_verified": False,
    }


# ─────────────────────────────────────────────────────────────────────
# 9. Orchestration
# ─────────────────────────────────────────────────────────────────────

def build_inventory() -> dict:
    """
    Output schema (schema_version "poc-2" — additive over "poc-1", see
    module docstring's "Schema poc-2" note for the full rationale):

    {
      "schema_version": "poc-2",
      "generated_at": <unix ts>,
      "privilege": {"euid": int, "is_root": bool},
      "interfaces": {...collect_interfaces()...},
      "listeners": [
        {
          "proto": "tcp"|"udp", "bind_address": str, "bind_port": int,
          "state": str|null, "inode": int|null,
          "pid": int|null, "pid_unresolved_reason": str|null,
          "process": {...process_info()...}|null,
          "owner": {...classify_ownership()...},
          "docker": {...docker_container_info()...}|null,
          "systemd": {...systemd_unit_info()...}|null,
          "public_exposure": str
        }, ...
      ],
      "firewall": {...detect_firewall()...},
      "detected_ingress": {
        "nginx": {..., "stream_capabilities": {...nginx_stream_capabilities()...}},
        "caddy": {..., "layer4_capabilities": {...caddy_layer4_capabilities()...}},
        "haproxy": {...}
      },
      "hysteria2": {"obfuscation": {...hysteria2_obfuscation()...}},
      "public_ipv4": {...public_ipv4_summary()...},
      "warnings": [str, ...]
    }
    """
    iface_block = collect_interfaces()
    raw_listeners = collect_listeners()
    inode_map, saw_perm_denied = build_inode_to_pid_map()
    if saw_perm_denied and os.geteuid() != 0:
        warn("some /proc/<pid>/fd directories were not readable (not root) — "
             "affected listeners will show pid_unresolved_reason=permission_denied, "
             "NOT be reported as unowned")

    listeners_out = []
    listener_comms: set[str] = set()

    for l in raw_listeners:
        pid = None
        pid_reason = None
        proc = None
        owner = {"kind": "unknown"}
        docker_info = None
        systemd_info = None

        # Ground-truth inode->pid map takes priority; ss's own -p
        # attribution is kept as a secondary hint only (ss_reported_process),
        # since it can be blank purely due to privilege/namespace and a
        # naive tool would misreport that as "no owner" (report §3/§19).
        if l["inode"] is not None:
            pid = inode_map.get(l["inode"])
            if pid is None:
                pid_reason = (
                    PID_UNRESOLVED_PERMISSION if saw_perm_denied and os.geteuid() != 0
                    else PID_UNRESOLVED_NOT_FOUND
                )
        elif l.get("ss_reported_process"):
            pid = l["ss_reported_process"]["pid"]

        if pid is not None:
            proc = process_info(pid)
            if proc is None:
                pid_reason = PID_UNRESOLVED_RACE
                pid = None
            else:
                owner = classify_ownership(proc)
                listener_comms.add(proc.get("comm") or "")
                if owner["kind"] == "docker":
                    docker_info = docker_container_info(owner["container_id"])
                elif owner["kind"] == "systemd":
                    systemd_info = systemd_unit_info(owner["unit"])

        listeners_out.append({
            "proto": l["proto"],
            "bind_address": l["bind_address"],
            "bind_port": l["bind_port"],
            "state": l["state"],
            "inode": l["inode"],
            "pid": pid,
            "pid_unresolved_reason": pid_reason,
            "process": proc,
            "owner": owner,
            "docker": docker_info,
            "systemd": systemd_info,
            "public_exposure": classify_bind_address(
                l["bind_address"], iface_block.get("interfaces", [])
            ),
            "source": l["source"],
        })

    return {
        "schema_version": "poc-2",
        "generated_at": int(time.time()),
        "privilege": {"euid": os.geteuid(), "is_root": os.geteuid() == 0},
        "interfaces": iface_block,
        "listeners": listeners_out,
        "firewall": detect_firewall(),
        "detected_ingress": detect_ingress(listener_comms),
        "hysteria2": {
            "obfuscation": hysteria2_obfuscation(HYSTERIA_CONFIG_PATH),
        },
        "public_ipv4": public_ipv4_summary(iface_block),
        "warnings": _warnings,
    }


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] not in ("--pretty", "-h", "--help"):
        print(f"usage: {sys.argv[0]} [--pretty]", file=sys.stderr)
        return 2
    if "-h" in sys.argv or "--help" in sys.argv:
        print(__doc__, file=sys.stderr)
        return 0

    if not which("ss") and not os.path.exists("/proc/net/tcp"):
        print("neither `ss` nor /proc/net/tcp is available — unsupported host", file=sys.stderr)
        return 1

    if os.geteuid() != 0:
        warn("not running as root — some PIDs/processes will be unresolved "
             "(pid_unresolved_reason=permission_denied), this is reported "
             "per-listener, not hidden")

    inventory = build_inventory()
    indent = 2 if "--pretty" in sys.argv else None
    print(json.dumps(inventory, indent=indent, sort_keys=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # Standard Python idiom for "downstream consumer (head/less/...)
        # closed the pipe early" — not a tool failure, must not print a
        # traceback to stderr or return a misleading non-zero code.
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        sys.exit(0)
