#!/usr/bin/env python3
"""
Diagnostic-only interactive CLI test (NOT part of the repo / not committed).
Confirms panel_cli_collect_j_options() actually behaves correctly when
driven through a real pty (/dev/tty works inside a pexpect-spawned
child even though it's unavailable via plain shell redirection in this
sandbox) -- with real pass/fail assertions, unlike the now-removed
lib/sripts/tests/test_cli_interactive.py.
"""
import pexpect
import sys
import os

REPO = "/home/claude/work/server-manager"

DRIVER = """
export PATH="{mockbin}:$PATH"
cd {repo}
source lib/ui/output.sh
source lib/common.sh
source lib/panel.sh
source lib/telemt.sh

TELEMT_BIN="{work}/telemt-bin"
TELEMT_CONFIG_DIR="{work}/systemd_cfg"
TELEMT_CONFIG_SYSTEMD="${{TELEMT_CONFIG_DIR}}/telemt.toml"
TELEMT_WORK_DIR_SYSTEMD="{work}/systemd_work"
TELEMT_TLSFRONT_DIR="${{TELEMT_WORK_DIR_SYSTEMD}}/tlsfront"
TELEMT_SERVICE_FILE="{work}/telemt.service"
TELEMT_WORK_DIR_DOCKER="{work}/docker_work"
TELEMT_CONFIG_DOCKER="${{TELEMT_WORK_DIR_DOCKER}}/telemt.toml"
TELEMT_COMPOSE_FILE="${{TELEMT_WORK_DIR_DOCKER}}/docker-compose.yml"

MODE="{mode}"
PANEL_DOMAIN="panel.example.com"
SUB_DOMAIN="sub.example.com"
SELFSTEAL_DOMAIN="node.example.com"
TELEMT_ENABLED="" TELEMT_DOMAIN="" TELEMT_PORT=""
TELEMT_INSTALL_ACTION="" TELEMT_INSTALL_MODE=""

panel_cli_collect_j_options

echo "===RESULT==="
echo "TELEMT_ENABLED=$TELEMT_ENABLED"
echo "TELEMT_DOMAIN=$TELEMT_DOMAIN"
echo "TELEMT_PORT=$TELEMT_PORT"
echo "TELEMT_INSTALL_ACTION=$TELEMT_INSTALL_ACTION"
echo "TELEMT_INSTALL_MODE=$TELEMT_INSTALL_MODE"
echo "===END==="
"""

WORK = "/tmp/it_cli_work"
MOCKBIN = "/tmp/it_cli_mockbin"


def setup_mockbin():
    os.makedirs(MOCKBIN, exist_ok=True)
    for cmd in ("docker", "systemctl", "useradd", "chown", "ufw", "id"):
        p = os.path.join(MOCKBIN, cmd)
        with open(p, "w") as f:
            f.write("#!/bin/bash\nexit 0\n")
        os.chmod(p, 0o755)


def reset_work():
    os.system(f"rm -rf {WORK}")
    os.makedirs(f"{WORK}/docker_work", exist_ok=True)
    os.makedirs(f"{WORK}/systemd_cfg", exist_ok=True)


def write_fixture(content):
    reset_work()
    with open(f"{WORK}/docker_work/telemt.toml", "w") as f:
        f.write(content)


STANDALONE_FIXTURE = '''[general]
use_middle_proxy = true
[server]
port = 8443
[[server.listeners]]
ip = "0.0.0.0"
[censorship]
tls_domain = "petrovich.ru"
[access.users]
someone = "cccccccccccccccccccccccccccccccc"
'''

INTEGRATED_FIXTURE = '''[general]
use_middle_proxy = true
[server]
port = 9443
[[server.listeners]]
ip = "127.0.0.1"
proxy_protocol = true
[censorship]
tls_domain = "mtproto.example.com"
[access.users]
alice = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'''


def run_case(mode, answers):
    script_path = "/tmp/_it_cli_driver.sh"
    with open(script_path, "w") as f:
        f.write(DRIVER.format(repo=REPO, mode=mode, work=WORK, mockbin=MOCKBIN))
    child = pexpect.spawn("bash", [script_path], timeout=10, cwd=REPO)
    out_chunks = []
    try:
        for ans in answers:
            child.expect(r".*", timeout=5)
            out_chunks.append(child.before)
            child.sendline(ans)
        child.expect("===END===", timeout=5)
        out_chunks.append(child.before)
    except pexpect.exceptions.TIMEOUT:
        out_chunks.append(b"!!!TIMEOUT!!!")
    try:
        child.expect(pexpect.EOF, timeout=5)
        out_chunks.append(child.before)
    except pexpect.exceptions.TIMEOUT:
        pass
    full = b"".join(c if isinstance(c, bytes) else b"" for c in out_chunks).decode(errors="replace")
    result = {}
    for line in full.splitlines():
        line = line.strip()
        if line.startswith("TELEMT_") and "=" in line:
            k, _, v = line.partition("=")
            result[k] = v
    return result, full


PASS = 0
FAIL = 0


def check(desc, got, expected):
    global PASS, FAIL
    if got == expected:
        print(f"  PASS: {desc}")
        PASS += 1
    else:
        print(f"  FAIL: {desc} (expected [{expected}], got [{got}])")
        FAIL += 1


setup_mockbin()

print("=== A: MODE=F, absent, decline ===")
reset_work()
r, _ = run_case("F", ["n"])
check("A TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "false")
check("A TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "")

print("=== B: MODE=F, absent, enable ===")
reset_work()
r, _ = run_case("F", ["y", "mtproto.example.com", "9443"])
check("B TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "true")
check("B TELEMT_DOMAIN", r.get("TELEMT_DOMAIN"), "mtproto.example.com")
check("B TELEMT_PORT", r.get("TELEMT_PORT"), "9443")
check("B TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "new")
check("B TELEMT_INSTALL_MODE", r.get("TELEMT_INSTALL_MODE"), "docker")

print("=== C: MODE=J, absent, decline ===")
reset_work()
r, _ = run_case("J", ["n"])
check("C TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "false")

print("=== D: MODE=J, absent, enable ===")
reset_work()
r, _ = run_case("J", ["y", "mtproto.example.com", "9443"])
check("D TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "true")
check("D TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "new")

print("=== E-equivalent: standalone exists, Panel refuses without prompting ===")
write_fixture(STANDALONE_FIXTURE)
r, full = run_case("J", [])
check("standalone TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "false")
check("standalone TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "")
check("standalone warning printed", "standalone-установка" in full, True)

print("=== G1: integrated exists, keep ===")
write_fixture(INTEGRATED_FIXTURE)
r, _ = run_case("J", ["y"])
check("G1 TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "true")
check("G1 TELEMT_DOMAIN (reused)", r.get("TELEMT_DOMAIN"), "mtproto.example.com")
check("G1 TELEMT_PORT (reused)", r.get("TELEMT_PORT"), "9443")
check("G1 TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "keep")

print("=== G2: integrated exists, disable ===")
write_fixture(INTEGRATED_FIXTURE)
r, _ = run_case("J", ["n", "y"])
check("G2 TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "false")
check("G2 TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "")

print("=== G3: integrated exists, reconfigure (MODE=F this time) ===")
write_fixture(INTEGRATED_FIXTURE)
r, _ = run_case("F", ["n", "n", "new-mtproto.example.com", "9555"])
check("G3 TELEMT_ENABLED", r.get("TELEMT_ENABLED"), "true")
check("G3 TELEMT_DOMAIN", r.get("TELEMT_DOMAIN"), "new-mtproto.example.com")
check("G3 TELEMT_PORT", r.get("TELEMT_PORT"), "9555")
check("G3 TELEMT_INSTALL_ACTION", r.get("TELEMT_INSTALL_ACTION"), "reconfigure")
check("G3 TELEMT_INSTALL_MODE (reused docker)", r.get("TELEMT_INSTALL_MODE"), "docker")

print(f"\n=== SUMMARY: {PASS} passed, {FAIL} failed ===")
sys.exit(0 if FAIL == 0 else 1)
