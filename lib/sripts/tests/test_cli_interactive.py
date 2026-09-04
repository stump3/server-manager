#!/usr/bin/env python3
import pexpect
import sys
import os

REPO = "/home/claude/work/server-manager"

DRIVER_SCRIPT = """
export PATH="/home/claude/work/mockbin:$PATH"
cd {repo}
source lib/ui/output.sh
source lib/common.sh
source lib/panel.sh
source lib/telemt.sh
source /tmp/telemt_sandbox/env.sh

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


def run_case(name, mode, answers, setup_fn=None):
    print(f"\n=== {name} (MODE={mode}) ===")
    if setup_fn:
        setup_fn()
    script_path = "/tmp/_cli_driver.sh"
    with open(script_path, "w") as f:
        f.write(DRIVER_SCRIPT.format(repo=REPO, mode=mode))
    child = pexpect.spawn("bash", [script_path], timeout=10, cwd=REPO, env=os.environ)
    child.logfile = sys.stdout.buffer
    result = {}
    try:
        for ans in answers:
            child.expect(r".*")
            child.sendline(ans)
        child.expect("===END===", timeout=5)
    except pexpect.exceptions.TIMEOUT:
        print("!!! TIMEOUT waiting for prompt/end !!!")
    child.expect(pexpect.EOF, timeout=5)
    out = child.before.decode(errors="replace") if isinstance(child.before, bytes) else (child.before or "")
    for line in out.splitlines():
        if line.startswith("TELEMT_"):
            k, _, v = line.partition("=")
            result[k] = v
    return result


def reset_sandbox():
    os.system("rm -rf /tmp/telemt_sandbox/docker_work /tmp/telemt_sandbox/systemd_cfg")
    os.system("mkdir -p /tmp/telemt_sandbox/docker_work /tmp/telemt_sandbox/systemd_cfg")


def write_standalone_fixture():
    reset_sandbox()
    with open("/tmp/telemt_sandbox/docker_work/telemt.toml", "w") as f:
        f.write('''[general]
use_middle_proxy = true
[server]
port = 8443
[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]
[[server.listeners]]
ip = "0.0.0.0"
[censorship]
tls_domain = "petrovich.ru"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"
[access.users]
someone = "cccccccccccccccccccccccccccccccc"
''')


def write_integrated_fixture():
    reset_sandbox()
    with open("/tmp/telemt_sandbox/docker_work/telemt.toml", "w") as f:
        f.write('''[general]
use_middle_proxy = true
[server]
port = 9443
[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]
[[server.listeners]]
ip = "127.0.0.1"
proxy_protocol = true
[censorship]
tls_domain = "mtproto.example.com"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"
[access.users]
alice = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
''')


results = {}

# A: MODE=F, TeleMT absent, operator declines -> disabled
reset_sandbox()
results["A"] = run_case("A: MODE=F, absent, decline", "F", ["n"])

# B: MODE=F, TeleMT absent, operator enables -> new
reset_sandbox()
results["B"] = run_case("B: MODE=F, absent, enable", "F",
                         ["y", "mtproto.example.com", "9443"])

# C: MODE=J, TeleMT absent, operator declines -> disabled
reset_sandbox()
results["C"] = run_case("C: MODE=J, absent, decline", "J", ["n"])

# D: MODE=J, TeleMT absent, operator enables -> new
reset_sandbox()
results["D"] = run_case("D: MODE=J, absent, enable", "J",
                         ["y", "mtproto.example.com", "9443"])

# F: existing standalone + Panel run again -> must refuse silently (no prompts consumed)
results["F"] = run_case("F: MODE=J, standalone exists", "J", [],
                         setup_fn=write_standalone_fixture)

# G1: existing integrated + Panel reinstall, operator keeps as-is
results["G1"] = run_case("G1: MODE=J, integrated exists, keep", "J", ["y"],
                          setup_fn=write_integrated_fixture)

# G2: existing integrated + Panel reinstall, operator disables integration
results["G2"] = run_case("G2: MODE=J, integrated exists, disable", "J", ["n", "y"],
                          setup_fn=write_integrated_fixture)

# G3: existing integrated + Panel reinstall, operator reconfigures (new domain/port)
results["G3"] = run_case("G3: MODE=F, integrated exists, reconfigure", "F",
                          ["n", "n", "new-mtproto.example.com", "9555"],
                          setup_fn=write_integrated_fixture)

print("\n\n========== SUMMARY ==========")
for k, v in results.items():
    print(k, v)
