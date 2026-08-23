# server-manager — Contracts

> Canonical, structured specification of this project's engineering
> contracts. Where `docs/ARCHITECTURE.md` explains *why*, and
> `docs/ENGINEER_GUIDELINES.md` explains *how to write code that
> complies*, this document is the terse, checkable *what* — one table
> per contract: invariant, current violation (if any, with file:line),
> target behaviour, migration implication, test implication.
>
> Every "current violation" below was verified by direct reading of
> `beta` @ `33135602c5c2e799575b0081cbfd137a40f7527c`, not asserted from
> a `tmp/` document without checking. Where no current violation is
> listed, the contract is either already satisfied or not yet
> applicable (no code exists yet to violate it).

---

## 1. stdout / stderr

| | |
|---|---|
| **Invariant** | stdout carries machine-readable return data only; stderr carries all UI text, diagnostics, warnings, and errors |
| **Current violation** | `lib/ui/output.sh`: `ok()`, `info()`, `warn()`, `err()`, `step()`, `detail()` all write to stdout via `echo -e`. Only `die()` writes to stderr. `err()` and `die()` are both fatal (`exit 1`) but write to different streams — an internal inconsistency independent of the stdout/stderr question |
| **Target behaviour** | All of `ok/info/warn/err/step/detail/die` write to stderr. A function's stdout, if any, is exclusively its return value for `$(...)` capture |
| **Migration implication** | Single-file change (`lib/ui/output.sh`); every one of the 63 repo-wide functions that call these helpers changes only in *sink*, not call signature — see `docs/ARCHITECTURE.md` §7 stage 3 |
| **Test implication** | Repo-wide grep asserting zero stdout writes from these helpers post-change; the two known command-substitution call sites (`panel_node_register`, `panel_get_token`) specifically re-tested with a mock harness |

## 2. Exit codes

| | |
|---|---|
| **Invariant** | 0 = success only. Any failure — API unavailable, DB error, missing dependency, validation error, SSH failure — is a non-zero exit. Different failure classes get distinct codes where practical (convention: `3` = missing dependency, per `engineer_guidelines.md` §8). Bash callers must check the exit code after every call; ignoring it is forbidden |
| **Current violation** | `lib/panel/node/install.sh:114-115` — `_reg_out=$(panel_node_register ...)`; `[ -z "$_reg_out" ]` is used as the failure test instead of the propagated exit code. Because `panel_node_register`'s failure paths write non-empty text to stdout (contract 1's violation), this check passes even on failure |
| **Target behaviour** | `if ! _reg_out=$(panel_node_register ...); then` (or equivalent), checking `$?` directly, once contract 1 is fixed and `panel_node_register` no longer contaminates stdout on failure |
| **Migration implication** | Fix is coupled to contract 1's fix — cannot be done independently, since the emptiness check only "worked" by accident of the stdout contamination. See `docs/ARCHITECTURE.md` §7 stage 4 |
| **Test implication** | Mock `panel_node_register` failure paths (auth failure, node-creation failure, host-creation failure, squad failure) and assert the caller correctly detects each as a failure via exit code |

## 3. Command substitution

| | |
|---|---|
| **Invariant** | For any function invoked as `X=$(f ...)`: (a) stdout is pure data, no UI text on any path; (b) failure signaled via exit code only; (c) the function never calls an `exit`-driven fatal helper (`err`/`die`) internally — `exit` inside a `$(...)` subshell terminates only that subshell, not the calling script, so relying on it silently breaks the "stop on fatal error" expectation |
| **Current violation** | Two functions repo-wide (of 164 total, 63 UI-emitting): `panel_node_register` (`lib/panel/node/api.sh`) violates (a) and (b) — confirmed bug, see contract 2. `panel_get_token` (`lib/panel/core.sh:55`) violates (a) and (c) — calls `err()` (which does `exit 1`) inside a function invoked via `$(...)` at `lib/panel/warp.sh:40,61`; does **not** currently manifest as a bug because both call sites happen to check the propagated exit code correctly (`local token; token=$(panel_get_token) \|\| return 1`), but any future call site written as `local token=$(panel_get_token)` (the classic bash `local`-masks-`$?` trap) would reintroduce the same failure class immediately |
| **Target behaviour** | Both functions rewritten to `return` instead of calling a fatal helper; `panel_node_register`'s caller rewritten per contract 2 |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 4 |
| **Test implication** | Static repo-wide check (already scripted once, in the runtime-audit round that found these two): every UI-emitting function cross-referenced against every `$(funcname ...)` call site, zero results expected after the fix |

## 4. HTTP transport vs API success

| | |
|---|---|
| **Invariant** | `curl` exit 0, HTTP 2xx, and a semantically valid API response body are three independent checks — none implies the others |
| **Current violation** | `panel_api()` (`lib/common/network.sh`) — not independently re-audited line-by-line for response validation in this round; `panel_get_token()` (`lib/panel/core.sh`) does check the response shape (`err "Не удалось получить токен: $resp"` on a bad response), which is correct practice, but this is not verified as consistent across every `panel_api()`/`panel_api_request()` call site repo-wide |
| **Target behaviour** | Every Panel API call site validates transport, HTTP status, and response shape as three distinct checks before using the response |
| **Migration implication** | Not currently blocking any other stage; recommend a dedicated audit pass before or during `docs/ARCHITECTURE.md` §7 stage 8 (Remote Node lifecycle), since RECONCILE/health-check logic will depend heavily on trustworthy API-response validation |
| **Test implication** | Mock `panel_api()`/`panel_api_request()` returning: curl failure, HTTP 4xx/5xx, malformed JSON, well-formed-but-semantically-invalid JSON (missing expected fields) — assert each is treated as failure, not silently used |

## 5. SSH execution lifecycle

| | |
|---|---|
| **Invariant** | connect → execute → verify exit code → cleanup, as four distinct, individually-checked steps; a remote operation is never considered successful merely because the SSH connection was established |
| **Current violation** | `lib/common/ssh.sh` `RUN()`/`PUT()` — `ConnectTimeout=10` is present (connect-phase timeout exists), but no command-execution-level timeout exists (confirms NODE-02's timeout half); zero `INT`/`TERM` traps exist anywhere in the repo (confirms NODE-02's cleanup half) — only 2 `RETURN` traps total repo-wide (`lib/common/ssh.sh:20`, `lib/panel/node/install.sh:32`) |
| **Target behaviour** | Command-level timeout on remote execution; `INT`/`TERM` trapped during remote-state-creating operations for best-effort cleanup or a clear partial-state signal |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5 (`lib/system/core.sh`, where SSH primitives land) |
| **Test implication** | Simulate a hung remote command (mock `ssh` that sleeps past the timeout) and assert the caller does not block indefinitely; simulate `SIGINT` during a remote-state-creating operation and assert cleanup runs |

## 6. Timeout policy (general)

| | |
|---|---|
| **Invariant** | Any external command that can hang (HTTP, SSH, `docker`, `systemctl`) has a default timeout, overridable per call |
| **Current violation** | `panel_api()` — no `--connect-timeout`/`--max-time` flags on the underlying `curl` call (confirms NODE-01) |
| **Target behaviour** | Default timeout applied; caller can override for genuinely long-running calls (e.g. a remote `docker pull`) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5. Concrete numeric defaults are `DECISION REQUIRED` — no source specifies them; assign during implementation |
| **Test implication** | Mock a hung `curl`/SSH call, assert the timeout fires and the caller receives a clear failure rather than hanging |

## 7. Secrets

| | |
|---|---|
| **Invariant** | Secrets never appear in argv, stdout, or diagnostic/log output; generated files containing secrets are never left world-readable |
| **Current violation** | `lib/common/ssh.sh:56-57` — `sshpass -p "$_SSH_PASS"` exposes the SSH migration password via `ps`/`/proc/<pid>/cmdline` for the process lifetime (confirms NODE-04). Generated `docker-compose.yml` (both panel and remote-node variants) embeds `SECRET_KEY`/token values in plaintext with no `chmod 600`/`640` call anywhere in `lib/panel/**` (confirms NODE-03) |
| **Target behaviour** | `sshpass -f <(...)` or `SSHPASS` env var instead of `-p`; `chmod 600` on every generated file containing a secret, immediately after generation |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5, independent of any other decision — can be fixed in isolation |
| **Test implication** | Assert generated files' permission bits post-generation; assert the password never appears in a captured `ps`/argv snapshot during a mocked SSH call |

## 8. `.env` / config atomicity

| | |
|---|---|
| **Invariant** | `.env` and other shared-state config files are only ever modified via prepare → validate → commit (`tempfile` + `os.replace()` in Python); never `sed -i`, `echo >>`, or direct `open(path, 'w')` |
| **Current violation** | `lib/hy2/install.sh:451` — `sed -i '/^HY_TRAFFIC_SECRET=/d;/^HY_TRAFFIC_PORT=/d' /etc/hy-webhook.env` |
| **Target behaviour** | A single `_update_env_file(path, updates: dict)` Python utility, atomic, is the only permitted way to modify any `.env` file |
| **Migration implication** | Requires the Bash/Python boundary work (contract 9) to exist first — this specific fix is a small, isolated change once that utility exists |
| **Test implication** | Kill the process mid-write (simulated) and assert the `.env` file is never left in a half-written state — this is the actual value of the atomic-write requirement, not just "use the right API" |

## 9. Bash/Python boundary

| | |
|---|---|
| **Invariant** | JSON/YAML/TOML parsing, `.env` mutation, hashing/crypto, SQL, and any Bash function exceeding ~3 lines of data-logic → Python. Bash decides *where/when*; Python decides *what* |
| **Current violation** | `python3 <<` heredocs in 5 files: `lib/hy2/install.sh`, `lib/hy2/integration.sh`, `lib/hy2/users.sh`, `lib/panel/subpage.sh`, `lib/panel/warp.sh`. `python3 -c` appears 36 times repo-wide — not individually audited for "more than one logical operation" this round |
| **Target behaviour** | Heredocs replaced by proper `lib/*/py/` scripts with the contract shape in §10 below; `python3 -c` usage reduced to the permitted exceptions only (module-existence checks, single boolean greps) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 9 (naturally bundled with the domain's Python-layer construction, e.g. TeleMT's `collect_stats.py` work) — not a standalone stage, since extracting a heredoc into a real script is exactly the same work as building the target Python layer |
| **Test implication** | The "Быстрая проверка перед коммитом" grep block in `docs/ENGINEER_GUIDELINES.md` becomes a CI check once `tests/` exists (stage 10) |

## 10. Python component contracts

| | |
|---|---|
| **Invariant** | Every script in `integrations/` or `lib/*/py/` has a recorded contract: type (`service`/`job`/`one-shot`/`thread`), file path, ENV vars (required/optional), stdin, stdout shape, stderr policy, exit codes, idempotency statement |
| **Current violation** | N/A — no `lib/*/py/` scripts exist yet on `beta`; this contract has nothing to violate today. Recorded here so the very first script added is held to it from the start |
| **Target behaviour** | Every new Python component gets an entry in this document (below, once the first one is added) before merge, not retroactively |
| **Migration implication** | First applies at `docs/ARCHITECTURE.md` §7 stage 9 |
| **Test implication** | A script without a recorded contract entry fails CI once `tests/` exists (checklist already specified in `docs/ENGINEER_GUIDELINES.md` §3/quick-check) |

*(No entries yet — this section is populated as real Python components are added, per stage 9 onward.)*

## 11. Single-writer ownership

| | |
|---|---|
| **Invariant** | Exactly one component writes any given piece of persistent state |
| **Current violation** | N/A — no shared persistent-state files exist yet in the areas this applies to (`stats.db` doesn't exist; `traffic.json`'s current writer(s) were not re-audited this round) |
| **Target behaviour** | `collect_stats.py` = sole writer of `stats.db`; `hy_traffic_collect.py`/`hy_online_poller.py` each own exactly one Hysteria2 storage target; CLI/menu layers never write storage directly |
| **Migration implication** | `docs/ARCHITECTURE.md` §5.3, §7 stage 9 |
| **Test implication** | For each storage target, assert exactly one script path in the codebase ever opens it for writing (grep-based CI check, once `tests/` exists) |

## 12. Traps / cleanup

| | |
|---|---|
| **Invariant** | Functions creating local staging state trap `RETURN` for cleanup; functions creating remote/durable state additionally trap `INT`/`TERM` |
| **Current violation** | Only 2 `RETURN` traps exist repo-wide; 0 `INT`/`TERM` traps exist anywhere |
| **Target behaviour** | Per `docs/ARCHITECTURE.md` §3 contract 11 — extends the existing correct pattern (`lib/panel/node/install.sh:32`) to every remote-state-creating operation |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 8 (bundled with Remote Node lifecycle work, since that's where remote-state creation is concentrated) |
| **Test implication** | Simulate `SIGINT` mid-operation, assert cleanup ran and no orphaned local/remote state remains |

## 13. Idempotency / reconcile

| | |
|---|---|
| **Invariant** | Install-time operations creating durable remote resources are lookup-before-create, not always-create |
| **Current violation** | `panel_node_register()`/`lib/panel/node/install.sh` — unconditional `POST` on every run, no lookup (confirms NODE-07) |
| **Target behaviour** | Full CREATE/RECONCILE/REPAIR/REINSTALL lifecycle per `docs/ARCHITECTURE.md` §4. Existing in-repo precedent to generalize from: `panel_setup_api()`'s `Default-Profile` lookup (`lib/panel/api.sh:50-53`) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 8 |
| **Test implication** | Run the install/reconcile operation twice against a mocked Panel API and assert the second run makes zero creation calls when nothing has changed |

---

## Cross-references

- `docs/ARCHITECTURE.md` §3 — summary table pointing here.
- `docs/ENGINEER_GUIDELINES.md` — practice-level guidance for satisfying
  contracts 8–10 specifically (atomic writes, dependency handling,
  logging, resilience patterns).
