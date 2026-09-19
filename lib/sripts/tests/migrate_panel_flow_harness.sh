#!/bin/bash
# migrate_panel_flow_harness.sh — functional control-flow harness for migrate_transfer_panel()
#
# Usage:  bash migrate_panel_flow_harness.sh <repo_root> [path/to/migrate.sh]
#   repo_root   : checkout containing lib/ui/output.sh
#   migrate.sh  : file under test (default: <repo_root>/lib/migrate.sh, the ACTIVE one)
#
# Real function, real lib/ui/output.sh, production shell options (set -euo pipefail).
# Mocked: RUN, PUT, docker (records to a call log; RUN's `bash -s` stdin is captured).
# `read ... < /dev/tty` is driven through a real PTY (python3 pty), not stubbed out.
# Nothing is written into the repo. SAFETY: the function hard-codes /opt/remnawave, so the
# harness refuses to run if /opt/remnawave already exists (unless SM_HARNESS_FORCE=1) and
# removes what it created on exit. Intended for a sandbox/CI box, NOT a live Panel server.
set -uo pipefail
ROOT=$(cd "${1:?repo_root}" && pwd); MIG=${2:-$ROOT/lib/migrate.sh}
[ -f "$MIG" ] && [ -f "$ROOT/lib/ui/output.sh" ] || { echo "bad paths"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
CREATED=0
if [ -e /opt/remnawave ] && [ "${SM_HARNESS_FORCE:-0}" != 1 ]; then
    echo "REFUSING: /opt/remnawave exists (would be touched). Use a sandbox or SM_HARNESS_FORCE=1."; exit 2
fi
[ -e /opt/remnawave ] || { CREATED=1; mkdir -p /opt/remnawave; }
W=$(mktemp -d); trap '[ "$CREATED" = 1 ] && rm -rf /opt/remnawave; find /tmp -maxdepth 1 -name "panel_migrate_*.sql.gz" -newer "$W" -delete 2>/dev/null; rm -rf "$W"' EXIT
[ -f /opt/remnawave/docker-compose.yml ] || : > /opt/remnawave/docker-compose.yml

cat > "$W/child.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
scenario="$1"; MIG="$2"; ROOT="$3"; log="$4"; : > "$log"
source "$ROOT/lib/ui/output.sh"; source "$MIG"
RUN() { local cmd="$*"; echo "RUN:$cmd" >> "$log"
  if [ "$cmd" = "bash -s" ]; then cat > "$log.remote"; return 0; fi
  if [ "$cmd" = "command -v docker >/dev/null 2>&1 && docker volume inspect remnawave-db-data >/dev/null 2>&1" ]; then
     [ "$scenario" = "exists" ] && return 0 || return 1; fi
  return 0; }
PUT() { echo "PUT:$1 -> $2" >> "$log"; return 0; }
docker() { echo "docker:$*" >> "$log"; case "$*" in *pg_dumpall*) head -c 200000 /dev/urandom;; esac; return 0; }
rip=203.0.113.10; ruser=root; rport=22
rc=0; migrate_transfer_panel || rc=$?     # exact status kept; no $(...) around the call
echo "RC=$rc" >> "$log"
EOF
cat > "$W/driver.py" <<'EOF'
import os, pty, sys, select, time
scen, ans, mig, repo, log, child = sys.argv[1:7]
if ans == "EMPTY": ans = ""
pid, fd = pty.fork()
if pid == 0: os.execvp("bash", ["bash", child, scen, mig, repo, log])
out = b""; sent = False; end = time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
        if not sent and ans != "-" and b"'YES'" in out: os.write(fd, (ans + "\n").encode()); sent = True
    else:
        try:
            p, _ = os.waitpid(pid, os.WNOHANG)
            if p: break
        except ChildProcessError: break
try: _, st = os.waitpid(pid, 0)
except ChildProcessError: st = 0
open(log + ".tty", "wb").write(out)
print(os.waitstatus_to_exitcode(st) if st >= 0 else -1)
EOF

PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected [$3] got [$2])"; fi; }
scen() { # name scenario answer
  LEAK0=$(ls /tmp/panel_migrate_*.sql.gz 2>/dev/null | wc -l)
  L="$W/log_$1"; CH=$(python3 "$W/driver.py" "$2" "$3" "$MIG" "$ROOT" "$L" "$W/child.sh")
  RC=$(grep -o '^RC=.*' "$L" | cut -d= -f2); RC=${RC:-DIED}
  PUTS=$(grep -c '^PUT:' "$L"); DUMP=$(grep -c 'pg_dumpall' "$L"); BS=$(grep -c '^RUN:bash -s' "$L")
  PROMPT=$(grep -c "'YES'" "$L.tty" 2>/dev/null); LEAK=$(( $(ls /tmp/panel_migrate_*.sql.gz 2>/dev/null | wc -l) - LEAK0 ))
}
echo "target: $MIG"; echo

echo "A) destination volume ABSENT -> guard false, migration proceeds"
scen A absent -
chk "no prompt shown" "$PROMPT" 0; chk "returns 0" "$RC" 0; chk "dump taken" "$DUMP" 1; chk "PUT executed (>0)" "$([ $PUTS -gt 0 ] && echo y)" y; chk "restore heredoc reached (RUN bash -s)" "$BS" 1
chk "guard RUN is the first recorded call" "$(sed -n 1p $L)" "RUN:command -v docker >/dev/null 2>&1 && docker volume inspect remnawave-db-data >/dev/null 2>&1"

for a in no yes EMPTY "YES-x"; do
  echo; echo "B) destination volume EXISTS, answer='$a' -> must abort, no destination mutation"
  scen "B_$a" exists "$a"
  chk "prompt shown" "$PROMPT" 1; chk "returns 1" "$RC" 1; chk "no PUT" "$PUTS" 0; chk "no dump" "$DUMP" 0; chk "no restore/volume rm (RUN bash -s)" "$BS" 0; chk "no leaked dump file" "$LEAK" 0
done

echo; echo "C) destination volume EXISTS, answer='YES' -> proceeds through restore"
scen C exists YES
chk "prompt shown" "$PROMPT" 1; chk "process alive, returns 0" "$RC" 0; chk "dump taken (>1000 B check passed)" "$DUMP" 1
chk "PUT x3 (dump, compose, remnawave_panel)" "$PUTS" 3; chk "restore heredoc reached" "$BS" 1
LG=$(grep -n '^RUN:command -v docker' "$L" | head -1 | cut -d: -f1); LP=$(grep -n '^PUT:' "$L" | head -1 | cut -d: -f1); LR=$(grep -n '^RUN:bash -s' "$L" | head -1 | cut -d: -f1)
chk "order: guard(line $LG) < first PUT(line $LP) < restore(line $LR)" "$([ "$LG" -lt "$LP" ] && [ "$LP" -lt "$LR" ] && echo yes)" yes
R="$L.remote"
if [ -f "$R" ]; then
  chk "remote script: \$((_pg_wait+1)) reaches REMOTE literally" "$(grep -cF '_pg_wait=$((_pg_wait+1))' "$R")" 1
  chk "remote script: \"\$_pg_wait\" reaches REMOTE literally"      "$(grep -cF '"$_pg_wait" -ge 60' "$R")" 1
  chk "remote script: \$dumpb expanded LOCALLY to a filename"        "$(grep -cE 'zcat /opt/remnawave/panel_migrate_[0-9_]+\.sql\.gz \|' "$R")" 1
  bash -n "$R" 2>/dev/null; chk "remote script: bash -n" "$?" 0
  B="$W/fb"; mkdir "$B"
  printf '#!/bin/bash\necho "docker $*" >> %s/dk.log\nif [[ "$*" == *pg_isready* ]]; then n=$(cat %s/n 2>/dev/null||echo 0); n=$((n+1)); echo $n > %s/n; [ "$n" -gt "${FAKE_FAIL_FIRST:-0}" ]; exit $?; fi\n[[ "$*" == *psql* ]] && cat >/dev/null\nexit 0\n' "$W" "$W" "$W" > "$B/docker"
  printf '#!/bin/bash\nexit 0\n' > "$B/sleep"; printf '#!/bin/bash\necho x\n' > "$B/zcat"; chmod +x "$B"/*
  rm -f "$W/n" "$W/dk.log"; PATH="$B:$PATH" FAKE_FAIL_FIRST=3 bash -s < "$R" >/dev/null 2>&1; rc=$?
  chk "remote run: ready after 3 failures -> rc 0" "$rc" 0; chk "remote run: counter incremented remotely (4 pg_isready calls)" "$(grep -c pg_isready "$W/dk.log")" 4
  rm -f "$W/n" "$W/dk.log"; PATH="$B:$PATH" FAKE_FAIL_FIRST=99999 bash -s < "$R" >/dev/null 2>&1; rc=$?
  chk "remote run: never ready -> aborts rc 1 after exactly 60 tries" "$rc:$(grep -c pg_isready "$W/dk.log")" "1:60"
else
  chk "remote script captured (process died before RUN bash -s?)" "missing" "present"
  echo "  --- tty transcript tail:"; sed 's/\x1b\[[0-9;]*m//g' "$L.tty" | tail -3 | sed 's/^/      /'
fi
echo; echo "=== PASS=$PASS FAIL=$FAIL ==="; [ "$FAIL" -eq 0 ]
