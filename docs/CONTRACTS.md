# server-manager — Contracts

> Canonical, structured specification of this project's engineering
> contracts. Where `docs/ARCHITECTURE.md` explains *why*, and
> `docs/ENGINEER_GUIDELINES.md` explains *how to write code that
> complies*, this document is the terse, checkable *what* — one table
> per contract: invariant, current violation (if any, with file:line),
> target behaviour, migration implication, test implication.
>
> **Verified baseline**: `beta` @ `33135602c5c2e799575b0081cbfd137a40f7527c`
> — every "current violation" row below was established by direct
> reading of the code at this commit, not asserted from a `tmp/`
> document without checking.
>
> **Current status**: re-verified against `beta` HEAD `3162cb4` (five
> docs-only commits on top of the baseline above — the prior four plus
> this document's own previous revision; `git diff --stat` from baseline
> to this HEAD touches only `docs/`, confirmed — the code itself has not
> moved). Each contract below carries its own **Current
> status** line, one of:
> - **Still present** — re-checked against current HEAD, violation
>   confirmed unchanged.
> - **Not re-verified this round** — the baseline finding is trusted,
>   but this pass did not re-read the relevant code; treat as
>   provisional until it is.
> - **Fixed** — would be used once a violation is closed; none are yet.
>
> A "current violation" is never load-bearing as "true forever." The
> **Verified baseline** commit is the evidence trail; **Current status**
> is what's actually true right now. After any future fix, only the
> **Current status** line changes — the baseline citation and the
> target/migration/test cells stay put as the historical record of what
> was found and how it was reasoned about. Where no current violation is
> listed, the contract is either already satisfied or not yet applicable
> (no code exists yet to violate it) — this too gets its own **Current
> status** confirmation below, not a silent absence.

---

## 1. stdout / stderr

| | |
|---|---|
| **Invariant** | stdout carries machine-readable return data only; stderr carries all UI text, diagnostics, warnings, and errors |
| **Current violation** | `lib/ui/output.sh`: `ok()`, `info()`, `warn()`, `err()`, `step()`, `detail()` all write to stdout via `echo -e`. Only `die()` writes to stderr. `err()` and `die()` are both fatal (`exit 1`) but write to different streams — an internal inconsistency independent of the stdout/stderr question |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round) (`ok()`/`info()` re-read directly, both still `echo -e` to stdout) |
| **Target behaviour** | All of `ok/info/warn/err/step/detail/die` write to stderr. A function's stdout, if any, is exclusively its return value for `$(...)` capture |
| **Migration implication** | Single-file change (`lib/ui/output.sh`); every one of the 63 repo-wide functions that call these helpers changes only in *sink*, not call signature — see `docs/ARCHITECTURE.md` §7 stage 3 |
| **Test implication** | Repo-wide grep asserting zero stdout writes from these helpers post-change; the two known command-substitution call sites (`panel_node_register`, `panel_get_token`) specifically re-tested with a mock harness |

## 2. Exit codes

| | |
|---|---|
| **Invariant** | 0 = success only. Any failure — API unavailable, DB error, missing dependency, validation error, SSH failure — is a non-zero exit. Different failure classes get distinct codes where practical (convention: `3` = missing dependency, per `engineer_guidelines.md` §8). Bash callers must check the exit code after every call; ignoring it is forbidden |
| **Current violation** | `lib/panel/node/install.sh:114-115` — `_reg_out=$(panel_node_register ...)`; `[ -z "$_reg_out" ]` is used as the failure test instead of the propagated exit code. Because `panel_node_register`'s failure paths write non-empty text to stdout (contract 1's violation), this check passes even on failure |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round), lines unchanged |
| **Target behaviour** | `if ! _reg_out=$(panel_node_register ...); then` (or equivalent), checking `$?` directly, once contract 1 is fixed and `panel_node_register` no longer contaminates stdout on failure |
| **Migration implication** | Fix is coupled to contract 1's fix — cannot be done independently, since the emptiness check only "worked" by accident of the stdout contamination. See `docs/ARCHITECTURE.md` §7 stage 4 |
| **Test implication** | Mock `panel_node_register` failure paths (auth failure, node-creation failure, host-creation failure, squad failure) and assert the caller correctly detects each as a failure via exit code |

## 3. Command substitution

| | |
|---|---|
| **Invariant** | For any function invoked as `X=$(f ...)`: (a) stdout is pure data, no UI text on any path; (b) failure signaled via exit code only; (c) the function never calls an `exit`-driven fatal helper (`err`/`die`) internally — `exit` inside a `$(...)` subshell terminates only that subshell, not the calling script, so relying on it silently breaks the "stop on fatal error" expectation |
| **Current violation** | Two functions repo-wide (of 164 total, 63 UI-emitting): `panel_node_register` (`lib/panel/node/api.sh`) violates (a) and (b) — confirmed bug, see contract 2. `panel_get_token` (`lib/panel/core.sh`) violates both (a) and (c), at two **separate** lines: (a) line 59 — `ok "Авторизация успешна"` is called on the fresh-login success path *before* the final `echo "$token"` on line 60, so `$(panel_get_token)` captures both lines on that path (the cached-token fast-path, lines 41-43, is clean — single `echo`, no contamination); (c) line 55 — calls `err()` (which does `exit 1`) inside a function invoked via `$(...)`. Call sites: `lib/panel/warp.sh:57,96` (corrected — not `:40,61` as an earlier draft of this row cited). The (c) violation does **not** currently manifest as a bug: `exit` inside a `$(...)` subshell only terminates that subshell, and both call sites check the propagated exit code correctly (`local token; token=$(panel_get_token) \|\| return 1`) — but any future call site written as `local token=$(panel_get_token)` (the classic bash `local`-masks-`$?` trap) would reintroduce that failure class immediately. The (a) violation is **not similarly safe**: on the fresh-login path, `token` gets set to the two-line contaminated capture regardless of the `\|\| return 1` guard, since the function still returns exit code 0 — this has the same shape as contract 2/BUG-01, just not yet traced through to confirm a live user-facing symptom this round |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round); citation corrected this round (call-site line numbers, explicit (a)-violation location) |
| **Target behaviour** | Both functions rewritten to `return` instead of calling a fatal helper; `panel_node_register`'s caller rewritten per contract 2 |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 4 |
| **Test implication** | Static repo-wide check (already scripted once, in the runtime-audit round that found these two): every UI-emitting function cross-referenced against every `$(funcname ...)` call site, zero results expected after the fix |

## 4. HTTP transport vs API success

| | |
|---|---|
| **Invariant** | `curl` exit 0, HTTP 2xx, and a semantically valid API response body are three independent checks — none implies the others |
| **Current violation** | `panel_api()` (`lib/common/network.sh`) — not independently re-audited line-by-line for response validation in this round; `panel_get_token()` (`lib/panel/core.sh`) does check the response shape (`err "Не удалось получить токен: $resp"` on a bad response), which is correct practice, but this is not verified as consistent across every `panel_api()`/`panel_api_request()` call site repo-wide |
| **Current status** | Not re-verified this round — same gap as the baseline round; a dedicated per-call-site pass is still owed (see Migration implication below) |
| **Target behaviour** | Every Panel API call site validates transport, HTTP status, and response shape as three distinct checks before using the response |
| **Migration implication** | Not currently blocking any other stage; recommend a dedicated audit pass before or during `docs/ARCHITECTURE.md` §7 stage 8 (Remote Node lifecycle), since RECONCILE/health-check logic will depend heavily on trustworthy API-response validation |
| **Test implication** | Mock `panel_api()`/`panel_api_request()` returning: curl failure, HTTP 4xx/5xx, malformed JSON, well-formed-but-semantically-invalid JSON (missing expected fields) — assert each is treated as failure, not silently used |

## 5. SSH execution lifecycle

| | |
|---|---|
| **Invariant** | connect → execute → verify exit code → cleanup, as four distinct, individually-checked steps; a remote operation is never considered successful merely because the SSH connection was established |
| **Current violation** | `lib/common/ssh.sh` `RUN()`/`PUT()` — `ConnectTimeout=10` is present (connect-phase timeout exists), but no command-execution-level timeout exists (confirms NODE-02's timeout half); zero `INT`/`TERM` traps exist anywhere in the repo (confirms NODE-02's cleanup half) — only 2 `RETURN` traps total repo-wide (`lib/common/ssh.sh:20`, `lib/panel/node/install.sh:32`) |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round): `grep -rn "trap.*RETURN" lib/` returns exactly those 2 lines; `grep -rn "trap.*(INT\|TERM)" lib/` returns 0 |
| **Target behaviour** | Command-level timeout on remote execution; `INT`/`TERM` trapped during remote-state-creating operations for best-effort cleanup or a clear partial-state signal |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5 (`lib/system/core.sh`, where SSH primitives land) |
| **Test implication** | Simulate a hung remote command (mock `ssh` that sleeps past the timeout) and assert the caller does not block indefinitely; simulate `SIGINT` during a remote-state-creating operation and assert cleanup runs |

## 6. Timeout policy (general)

| | |
|---|---|
| **Invariant** | Every external operation that may block (HTTP, SSH, `docker`, `systemctl`) has an explicit timeout policy: a default timeout applies unless overridden, and any genuinely long-running call (e.g. a remote `docker pull`) gets an explicit, deliberate override — never an unbounded wait by omission |
| **Current violation** | `panel_api()` — no `--connect-timeout`/`--max-time` flags on the underlying `curl` call (confirms NODE-01) |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round) |
| **Target behaviour** | Default timeout applied; caller can override for genuinely long-running calls (e.g. a remote `docker pull`) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5. Concrete numeric defaults are `DECISION REQUIRED` — no source specifies them; assign during implementation |
| **Test implication** | Mock a hung `curl`/SSH call, assert the timeout fires and the caller receives a clear failure rather than hanging |

## 7. Secrets

| | |
|---|---|
| **Invariant** | Secrets never appear in argv, stdout, or diagnostic/log output; generated files containing secrets are never left world-readable |
| **Current violation** | `lib/common/ssh.sh:56-57` — `sshpass -p "$_SSH_PASS"` exposes the SSH migration password via `ps`/`/proc/<pid>/cmdline` for the process lifetime (confirms NODE-04). Generated `docker-compose.yml` (both panel and remote-node variants) embeds `SECRET_KEY`/token values in plaintext with no `chmod 600`/`640` call anywhere in `lib/panel/**` (confirms NODE-03) |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round) |
| **Target behaviour** | Passwords/secrets never appear in argv, at any layer; every generated file containing a secret gets owner-only permissions, applied immediately after generation, not as an afterthought |
| **Implementation note** | *Not part of the contract itself* — which exact mechanism satisfies "never in argv" (`sshpass -f <(...)`, `SSHPASS` env var, or another approach) is an engineering decision made at implementation time, recorded in `docs/ARCHITECTURE.md`/the migration PR, not fixed here. Same for the exact permission bits (`600` vs `640` depending on whether a service group needs read access) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 5, independent of any other decision — can be fixed in isolation |
| **Test implication** | Assert generated files' permission bits post-generation; assert the password never appears in a captured `ps`/argv snapshot during a mocked SSH call |

## 8. `.env` / config atomicity

| | |
|---|---|
| **Invariant** | `.env` and other shared-state config files are only ever modified via prepare → validate → commit (`tempfile` + `os.replace()` in Python); never `sed -i`, `echo >>`, or direct `open(path, 'w')` |
| **Current violation** | `lib/hy2/install.sh:451` — `sed -i '/^HY_TRAFFIC_SECRET=/d;/^HY_TRAFFIC_PORT=/d' /etc/hy-webhook.env` |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round), line unchanged |
| **Target behaviour** | `.env` and other shared-state config files are modified only via prepare → validate → commit (atomic rename), in Python; direct in-place editing (`sed -i`, `echo >>`, `open(path, 'w')`) is forbidden on any file another process reads |
| **Implementation note** | *Not part of the contract itself* — `docs/ENGINEER_GUIDELINES.md` §4 names a specific utility (`_update_env_file(path, updates: dict)`, `tempfile` + `os.replace()`) as the accepted implementation; that is an engineering decision recorded there, not an invariant this document fixes. If the function's name or signature changes later, this contract does not need to change — only the guideline does |
| **Migration implication** | Requires the Bash/Python boundary work (contract 9) to exist first — this specific fix is a small, isolated change once that utility exists |
| **Test implication** | Kill the process mid-write (simulated) and assert the `.env` file is never left in a half-written state — this is the actual value of the atomic-write requirement, not just "use the right API" |

## 9. Bash/Python boundary

| | |
|---|---|
| **Invariant** | JSON/YAML/TOML parsing, `.env` mutation, hashing/crypto, SQL, and any Bash function exceeding ~3 lines of data-logic → Python. Bash decides *where/when*; Python decides *what* |
| **Current violation** | `python3 <<` heredocs in 5 files: `lib/hy2/install.sh`, `lib/hy2/integration.sh`, `lib/hy2/users.sh`, `lib/panel/subpage.sh`, `lib/panel/warp.sh`. `python3 -c` appears 36 times repo-wide — not individually audited for "more than one logical operation" this round |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round), all 5 files confirmed (note: `python3 - <<` counts as this pattern too, e.g. `lib/hy2/integration.sh:20,314,404,438` and `lib/panel/warp.sh:30,42,67,106` — a naive `grep "python3 <<"` undercounts to 3 files; the broader pattern confirms the original 5) |
| **Target behaviour** | Heredocs replaced by proper `lib/*/py/` scripts with the contract shape in §10 below; `python3 -c` usage reduced to the permitted exceptions only (module-existence checks, single boolean greps) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 9 (naturally bundled with the domain's Python-layer construction, e.g. TeleMT's `collect_stats.py` work) — not a standalone stage, since extracting a heredoc into a real script is exactly the same work as building the target Python layer |
| **Test implication** | The "Быстрая проверка перед коммитом" grep block in `docs/ENGINEER_GUIDELINES.md` becomes a CI check once `tests/` exists (stage 10) |

## 10. Python component contracts

| | |
|---|---|
| **Invariant** | Every script in `integrations/` or `lib/*/py/` has a recorded contract: type (`service`/`job`/`one-shot`/`thread`), file path, ENV vars (required/optional), stdin, stdout shape, stderr policy, exit codes, idempotency statement |
| **Current violation** | N/A — no `lib/*/py/` scripts exist yet on `beta`; this contract has nothing to violate today. Recorded here so the very first script added is held to it from the start |
| **Current status** | Still N/A — re-verified against code-baseline `3313560` (still current — re-read fresh this round): no `lib/*/py/` directory exists anywhere (`find lib -type d -name py` returns nothing), `integrations/` holds only `hy-sub-install.sh` and `hy-webhook.py` (the latter pre-dates this contract and is not yet retrofitted) |
| **Target behaviour** | Every new Python component gets an entry in this document (below, once the first one is added) before merge, not retroactively |
| **Migration implication** | First applies at `docs/ARCHITECTURE.md` §7 stage 9 |
| **Test implication** | A script without a recorded contract entry fails CI once `tests/` exists (checklist already specified in `docs/ENGINEER_GUIDELINES.md` §3/quick-check) |

*(No entries yet — this section is populated as real Python components are added, per stage 9 onward.)*

## 11. Single-writer ownership

| | |
|---|---|
| **Invariant** | Exactly one component writes any given piece of persistent state |
| **Current violation** | N/A — no shared persistent-state files exist yet in the areas this applies to (`stats.db` doesn't exist; `traffic.json`'s current writer(s) were not re-audited this round) |
| **Current status** | Still N/A on `beta` — re-verified against code-baseline `3313560` (still current — re-read fresh this round): no `stats.db`, no `collect_stats.py`, no `status_render.py` anywhere in the tree. **This is implementation status only.** The target ownership model itself is no longer undecided — it is recorded as a `DECISION` in `docs/ARCHITECTURE.md` §5.2/§5.3 (this round's reconciliation). Do not read "N/A, nothing to violate" as "no design exists" — it means "the design exists and is written down, the code implementing it does not exist yet." Deferred implementation ≠ absent architecture |
| **Target behaviour** | `collect_stats.py` = sole writer of `stats.db`; `hy_traffic_collect.py`/`hy_online_poller.py` each own exactly one Hysteria2 storage target; CLI/menu layers never write storage directly. Full detail (delta/reset semantics, `telemetry.user_enabled` requirement, IP-list non-exhaustiveness, `status_render.py`'s named exception) lives in `docs/ARCHITECTURE.md` §5.2 — not duplicated here; see also contract 14 below, which formalizes the ingestion-boundary piece of this same model as its own checkable invariant |
| **Migration implication** | `docs/ARCHITECTURE.md` §5.3, §7 stage 9 |
| **Test implication** | For each storage target, assert exactly one script path in the codebase ever opens it for writing (grep-based CI check, once `tests/` exists) |

## 12. Traps / cleanup

| | |
|---|---|
| **Invariant** | Functions creating local staging state trap `RETURN` for cleanup; functions creating remote/durable state additionally trap `INT`/`TERM` |
| **Current violation** | Only 2 `RETURN` traps exist repo-wide; 0 `INT`/`TERM` traps exist anywhere |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round), same 2 `RETURN` traps, same 0 `INT`/`TERM` traps |
| **Target behaviour** | Per `docs/ARCHITECTURE.md` §3 contract 11 — extends the existing correct pattern (`lib/panel/node/install.sh:32`) to every remote-state-creating operation |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 8 (bundled with Remote Node lifecycle work, since that's where remote-state creation is concentrated) |
| **Test implication** | Simulate `SIGINT` mid-operation, assert cleanup ran and no orphaned local/remote state remains |

## 13. Idempotency / reconcile

| | |
|---|---|
| **Invariant** | Install-time operations creating durable remote resources are lookup-before-create, not always-create |
| **Current violation** | `panel_node_register()`/`lib/panel/node/install.sh` — unconditional `POST` on every run, no lookup (confirms NODE-07) |
| **Current status** | Still present — re-verified against code-baseline `3313560` (still current — re-read fresh this round): `panel_node_register()` still does unconditional `POST` on `/api/config-profiles`, `/api/nodes`, `/api/hosts`, no `GET`+lookup anywhere in `lib/panel/node/api.sh`. The precedent (`panel_setup_api()`'s `Default-Profile` lookup, `lib/panel/api.sh:50-53`) is also re-confirmed present and unchanged |
| **Target behaviour** | Full CREATE/RECONCILE/REPAIR/REINSTALL lifecycle per `docs/ARCHITECTURE.md` §4. Existing in-repo precedent to generalize from: `panel_setup_api()`'s `Default-Profile` lookup (`lib/panel/api.sh:50-53`) |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 8 |
| **Test implication** | Run the install/reconcile operation twice against a mocked Panel API and assert the second run makes zero creation calls when nothing has changed |

## 14. Telemt ingestion boundary

| | |
|---|---|
| **Invariant** | `collect_stats.py` (target, not yet built — see contract 11) is the sole ingestion boundary between the telemt API and `stats.db`; no other component reads the telemt API for the purpose of building historical/statistical storage. The telemt API is an external dependency whose individual responses are not assumed complete — this is already the accepted model for one field today (IP lists) and this contract generalizes the *boundary* rule, not the completeness claim itself (see the excluded item below) |
| **Current violation** | N/A — not yet applicable, same reason as contract 11 (`collect_stats.py` doesn't exist on `beta` yet, so there is no ingestion path to violate). What exists today: `/v1/users` is read directly from three call sites (`lib/telemt/api.sh`, `lib/telemt/users.sh`, `lib/telemt/migrate.sh`) for **management-plane** purposes (add/delete/list users, migration) — this is correct today and stays correct going forward (`docs/ARCHITECTURE.md` §5.2: management calls via `lib/telemt/manage.sh` are explicitly kept separate from, and are not, ingestion) |
| **Current status** | N/A, re-verified against code-baseline `3313560` (still current — re-read fresh this round) — no `collect_stats.py`, no `stats.db` |
| **Target behaviour** | (1) `collect_stats.py` is the only script that reads the telemt API in order to persist historical data. (2) `status_render.py` (target, not yet built) is a **named, sanctioned exception** — it reads the telemt API directly for live runtime/status display, never for historical ingestion, and never writes `stats.db`. Its allowed surface, per the real endpoints already in use today for exactly this purpose in `lib/telemt/menu.sh:120-126` (`telemt_menu_status()`, current interactive status display — confirmed present against code-baseline `3313560` (still current — re-read fresh this round)): `GET /v1/stats/summary`, `GET /v1/runtime/gates`, `GET /v1/system/info`. Forbidden for `status_render.py`: `GET /v1/users` (management/ingestion surface, not status), any write to `stats.db`. (3) List/IP fields returned by the telemt API are treated as best-effort/non-exhaustive wherever `collect_stats.py` consumes them (already decided for IP-list fields specifically, per `docs/ARCHITECTURE.md` §5.2 — this contract does not extend that non-exhaustiveness claim to any other field, e.g. user presence/absence, since no source addresses that) |
| **Explicitly excluded from this contract** | A "destructive sweep" invariant — i.e. a rule about whether a user's absence from one telemt poll cycle may trigger deletion of that user's row in `stats.db` — was considered for inclusion this round and **not added**. No current source (`docs/ARCHITECTURE.md`, `docs/ENGINEER_GUIDELINES.md`, or `beta` code) defines `collect_stats.py`'s reconciliation/deletion behaviour at all; the actual `beta` telemt code has no automatic user-deletion logic tied to poll results (`telemt_menu_delete_user()` is an explicit, operator-initiated interactive command, unrelated to any poll cycle). Adding a specific sweep-safety rule here would be inventing an architecture decision, not recording one. This is a genuine open design question for `collect_stats.py`'s eventual implementation — flagged here as a gap, not resolved |
| **Migration implication** | `docs/ARCHITECTURE.md` §7 stage 9, bundled with the rest of the TeleMT SQLite ingestion layer construction |
| **Test implication** | Once `collect_stats.py`/`status_render.py` exist: repo-wide grep confirming no script outside `collect_stats.py` reads `/v1/stats/summary` or equivalent stats-ingestion endpoints for the purpose of writing `stats.db`; a mock telemt API returning a partial/short `/v1/users` response asserted to not, by itself, cause any write to `stats.db` (this specific assertion depends on the excluded sweep design question above being resolved first — cannot be made concrete until then) |

---

## Cross-references

- `docs/ARCHITECTURE.md` §3 — summary table pointing here.
- `docs/ENGINEER_GUIDELINES.md` — practice-level guidance for satisfying
  contracts 8–10 specifically (atomic writes, dependency handling,
  logging, resilience patterns).
