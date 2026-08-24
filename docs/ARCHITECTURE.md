# server-manager — Architecture

> Canonical architecture document. **Code source of truth is `beta` only**
> (verified `git rev-parse HEAD` = `33135602c5c2e799575b0081cbfd137a40f7527c`,
> `git branch --show-current` = `beta`). `btemp` is storage-only for
> prepared documents — its own code tree is a stale, pre-Stage-2 snapshot
> and is never read as current implementation.
>
> This is a **decisive** document: every structural question that could be
> answered from the available sources has been answered below, with
> DECISION / WHY / ALTERNATIVES CONSIDERED / CONSEQUENCES. Only genuinely
> unanswerable questions are left as `DECISION REQUIRED` (§8) — kept
> deliberately short.
>
> Tags: `CURRENT` (verified against `beta`), `TARGET` (decided, not yet
> implemented), `DECISION`, `DECISION REQUIRED`, `INVARIANT`,
> `DEPRECATED`, `UNKNOWN`.

---

## 0. Source reconciliation

| Source | Claims | Status | Superseded / stale parts |
|---|---|---|---|
| `beta` code | Ground truth | CURRENT | — |
| `docs/ARCHITECTURE_AUDIT.md` (beta) | Earlier audit + its own proposed tree (`lib/panel/{index,install,env_builder,api,branding}.sh`) | Its "current state" narrative predates Stage 2 (calls `panel.sh` a monolith with top-level globals) — **stale**, re-verified: `panel.sh` is a 24-line loader today, the cited globals are already `local`. Its proposed tree is **not adopted** (see §2) | Current-state section; proposed tree |
| `tmp/engineer_guidelines.md` (btemp) | Bash/Python boundary, stdout/stderr, CLI execution model, atomicity, idempotency | TARGET, written in present tense as if already binding — **zero mechanisms exist on `beta`** (verified: no `cli_result_ok` etc., no `lib/tmt/py/` or `lib/*/py/` anywhere). Rules themselves are **adopted as-is**, unmodified | None of the rules are stale — only the "as if implemented" framing needed correction |
| `tmp/sm_integration.md` (btemp) | TeleMT target contract: `stats.db`, `collect_stats.py`, single-writer | TARGET / NOT YET IMPLEMENTED, verified against `beta`'s actual `lib/telemt/*.sh` (no SQLite, no `py/`) | Names `lib/tmt/` — **not adopted**, see §5 |
| `tmp/Pre-Refactor-Audit-Summary.md` (btemp) | BUG-01..03, NODE-01..07 | CURRENT findings, independently re-verified by direct `beta` source reading (file:line citations given below) | None stale — every citation checked against `beta` and confirmed |
| `tmp/architecture.md` (btemp) | Proposed `lib/web/` adapter; current-state narrative | Its current-state section is **stale** (predates Stage 2: claims `get_hysteria_version()` still duplicated — already deduped; claims `panel.sh` is 2428 lines — it's 24). Its `lib/web/` proposal is **not adopted** as a top-level domain (see §6) but its provider-abstraction idea is kept, nested | Entire "current state" section; top-level placement of `lib/web/` |
| `tmp/architecture_v1.md` (btemp) | Most detailed file tree read; TeleMT API contract detail (delta/reset, IP union semantics); `lib/cli/` file layout matching `engineer_guidelines.md` §10 exactly | TARGET, most internally consistent with `engineer_guidelines.md`. Its TeleMT API contract detail is **adopted** (§5). Its file tree is **partially adopted** — see per-domain decisions below | Disagrees with `tmp/architecture.md` on `lib/web/` (v1 keeps TLS nested in panel — this document sides with v1 on that point, see §6) |
| User's proposed tree (this task) | Full target tree | TARGET, **used as the starting point**, but not adopted verbatim — three deliberate deviations are made and justified below (§2.3: no separate `lib/ui/`; §2.4: no `lib/core/logging.sh`; §4: `lib/panel/` keeps its current fine-grained shape instead of consolidating to the 8 names listed) | — |

**Rule applied throughout**: a more recent document is not automatically
more correct. Every "current state" claim from any `tmp/` document was
checked against actual `beta` source before being trusted; several were
found stale and are marked so explicitly rather than silently corrected.

---

## 1. Current architecture map (`CURRENT`, verified)

```text
server-manager.sh
  _load_module() → _sm_source_file()
    lib/core/config.sh       # single file today (31 lines)
    lib/ui/output.sh          # single file today (36 lines)
    lib/common.sh             # facade → lib/common/{core,generators,menu,network,ssh}.sh (401 lines total)
    lib/panel.sh               # facade loader (24 lines) → lib/panel/{...} (2954 lines across 17 files)
    lib/telemt.sh               # facade → lib/telemt/{core,install,menu,migrate,users,api}.sh (1516 lines)
    lib/hysteria.sh              # facade → lib/hy2/{core,install,users,integration,menu}.sh
    lib/migrate.sh                # top-level, cross-domain migration menu
    lib/cli/router.sh              # cli_run() { main_menu; } — one function, self-described transitional
```

`lib/panel/` current file sizes (verified, drives §4's decision):
```
migrate.sh 23 · selfsteal.sh 29 · core.sh 61 · template.sh 85 ·
node/compose.sh 95 · api.sh 107 · menu.sh 108 · subpage.sh 108 ·
warp.sh 122 · node/api.sh 141 · node/install.sh 141 · cert.sh 150 ·
caddy/config.sh 176 · nginx/config.sh 176 · management.sh 229 ·
install.sh 277 · mgmt_script.sh 398 · compose.sh 528
```
`lib/telemt/` current: `core.sh 179 · install.sh 184 · api.sh 203 ·
users.sh 224 · migrate.sh 234 · menu.sh 492`.

Non-existent today, confirmed: `lib/system/`, `lib/*/py/` (any domain),
`lib/integrations/`, `docs/CONTRACTS.md`, `tests/`, `scripts/` (repo
root), `lib/panel/tls.sh` (currently `cert.sh`).

---

## 2. Canonical target tree

```text
server-manager.sh

lib/
├── core/
│   ├── config.sh        # unchanged — shared constants
│   ├── common.sh         # generic helpers (from lib/common/core.sh)
│   ├── versions.sh        # get_*_version() consolidation
│   ├── errors.sh           # die/err resolution (§8), cleanup-trap helpers
│   └── utils.sh             # small generic helpers (from lib/common/generators.sh)
│
├── cli/                      # NEW — non-interactive, scriptable layer only
│   ├── router.sh
│   ├── flags.sh
│   ├── common.sh               # cli_ok/cli_warn/cli_err/cli_result_ok/cli_result_err
│   └── exec.sh                  # cli_exec_py_stream/cli_exec_py_capture/cli_exec_py_check
│
├── panel/                        # KEEPS its current fine-grained shape — see §2.2/§4
│   ├── core.sh · install.sh · api.sh · compose.sh · mgmt_script.sh ·
│   │   management.sh · selfsteal.sh · subpage.sh · template.sh · warp.sh ·
│   │   menu.sh · tls.sh (renamed from cert.sh)
│   ├── nginx/config.sh · caddy/config.sh    # provider pattern, nested (§6)
│   ├── node/core.sh · node/api.sh · node/install.sh   # gains reconcile/repair (§3)
│   └── py/                                    # NEW, TARGET — panel_branding.py etc.
│
├── hy2/
│   ├── core.sh · install.sh · integration.sh · users.sh · menu.sh   # unchanged names
│   └── py/                                    # NEW, TARGET
│
├── telemt/                       # kept — NOT renamed to lib/tmt/, see §5.1
│   ├── core.sh · install.sh · users.sh · manage.sh (renamed from api.sh) · menu.sh
│   └── py/                                    # NEW, TARGET — collect_stats.py etc. (§5)
│
├── system/                       # NEW — consolidates scattered infra logic
│   ├── core.sh          # SSH RUN/PUT (from lib/common/ssh.sh)
│   ├── services.sh        # systemctl wrappers (currently ad-hoc per-domain)
│   ├── firewall.sh          # ufw wrappers (currently ad-hoc per-domain)
│   ├── network.sh             # genuinely system-level networking only — see §2.5
│   └── migrate.sh               # consolidates lib/migrate.sh + panel/migrate.sh + telemt/migrate.sh
│
└── (no lib/ui/, no lib/integrations/ — see §2.3, §2.6)

integrations/        # unchanged — standalone Python/Rust runtimes
sub-injector/         # unchanged
scripts/               # NEW, TARGET — no concrete content proposed by any source yet
tests/
└── cli/                 # NEW, TARGET — the only test content any source actually specifies
docs/
├── ARCHITECTURE.md · CONTRACTS.md (new, §3) · ENGINEER.md · ENGINEER_GUIDELINES.md
├── CHANGELOG.md · MIGRATION_GUIDE.md · ARCHITECTURE_AUDIT.md (historical, superseded by this file)
```

### 2.1 — What changed from the user's proposed tree, and why

Three deliberate deviations from the tree given in this task, each argued
individually below. Everything else in the user's tree is adopted as
proposed.

### 2.2 — `lib/panel/` keeps its current shape instead of consolidating to `{core,install,manage,nginx,tls,docker,node,py}`

**DECISION**: do not force-consolidate. Keep the current 13-file +
3-subdirectory shape, with exactly two changes: `cert.sh` → `tls.sh`
(rename only, no merge), and `migrate.sh` extracted to
`lib/system/migrate.sh` (infra concern, not panel-specific).

**WHY**: the current shape is the direct result of this project's own
Stage 2–7 refactor — real, tested, independently audited code with
verified single-responsibility boundaries (each of the 13 files does
exactly one thing: `compose.sh` generates the compose file,
`mgmt_script.sh` generates the remote management script,
`management.sh` is the *different* thing of executing management
operations interactively, `selfsteal.sh`/`subpage.sh`/`warp.sh`/
`template.sh` are each a self-contained feature). Forcing these into 8
coarser files (e.g. merging `mgmt_script.sh` (398 lines, generates a
script) with `management.sh` (229 lines, executes commands directly) into
one `manage.sh`) would produce a ~630-line file mixing two genuinely
different responsibilities, undoing real engineering work for the sake
of matching a tree that no source document justifies at this level of
detail — none of the five `btemp` documents give file-by-file
justification for the 8-name consolidation; it appears to be a
logical/conceptual grouping, not a literal file-count mandate.

**ALTERNATIVES CONSIDERED**:
- Adopt the 8-file consolidation literally, as proposed. Rejected —
  no source justifies merging tested, single-responsibility files, and
  doing so during an "architecture only, no code changes" phase would
  itself require a large, risky code change later with no functional
  benefit identified anywhere.
- Adopt `architecture_v1.md`'s tree instead (`lib/panel/{core,cert,
  install,management,warp,subpage,template,migrate,menu}.sh` +
  `py/panel_branding.py`) — closer to current reality (keeps `cert.sh`,
  keeps `warp.sh`/`subpage.sh`/`template.sh` separate) but still omits
  `compose.sh`, `mgmt_script.sh`, `api.sh`, and the `node/`/`nginx/`/
  `caddy/` subdirectories entirely, i.e. it doesn't fully describe
  current `beta` either. Rejected as the literal target, but its
  conservative instinct (don't over-merge) is the one adopted here.

**CONSEQUENCES**: the "8 names" in the user's original tree
(`core/install/manage/nginx/tls/docker/node/py`) are kept **only as a
documentation-level concept map** — a reader's guide to which physical
files answer which concern — not as literal filenames:

| Concept | Physical file(s) |
|---|---|
| `core` | `core.sh` |
| `install` | `install.sh`, `api.sh` (install-time-only Panel API bootstrap) |
| `manage` | `management.sh` (interactive ops), `mgmt_script.sh` (generates the remote script), `warp.sh` |
| `nginx` | `nginx/config.sh`, `caddy/config.sh`, `subpage.sh`, `selfsteal.sh` (all web-server-adjacent) |
| `tls` | `tls.sh` (renamed from `cert.sh`) |
| `docker` | `compose.sh` |
| `node` | `node/core.sh`, `node/api.sh`, `node/install.sh` (kept as 3 files — see §3, the incoming reconcile/repair lifecycle needs the room) |
| `py` | new, empty until a concrete Python component is proposed (`panel_branding.py` per `architecture_v1.md` is the only concrete candidate any source names) |

### 2.3 — No separate `lib/ui/` tree

**DECISION**: interactive menus stay domain-owned (`lib/panel/menu.sh`,
`lib/hy2/menu.sh`, `lib/telemt/menu.sh`), as they are today. Do not
create `lib/ui/{main_menu,panel_menu,hysteria_menu,telemt_menu,
system_menu}.sh`.

**WHY**: this project's own stated contract (from this task's contract
list) is "domain owns its state." A domain's interactive menu is part of
its state/behavior, not a separate concern — `lib/panel/menu.sh` calling
directly into `lib/panel/install.sh`'s functions is the same trust
boundary, not a boundary crossing. Splitting menu text into a sibling
tree only adds an indirection layer (menu file → domain file) with no
identified benefit; no source document explains what problem this split
solves. By contrast, the **new** `lib/cli/` layer is justified precisely
*because* it has a fundamentally different contract from interactive
menus — `lib/cli/`'s stdout must be pure machine-readable data
(`engineer_guidelines.md` §10), while an interactive menu's terminal
output is never captured by `$(...)` and has no such constraint. That
distinction is real and load-bearing; a `lib/ui/` vs `lib/panel/menu.sh`
distinction is not.

**ALTERNATIVES CONSIDERED**: adopt `lib/ui/` as proposed, for
"consistency" with `lib/cli/`. Rejected — CLI and interactive-menu are
different enough in their output contract that treating them as
"the same kind of split" is the actual inconsistency.

**CONSEQUENCES**: `lib/common/menu.sh` (98 lines, the top-level
`main_menu()` dispatcher that routes to each domain's `menu.sh`) is the
one file that is genuinely cross-domain and stays outside any single
domain — recommend it moves to `lib/core/common.sh` or remains a small
standalone file; this is low-stakes and can be decided during the actual
migration PR rather than in this document.

### 2.4 — No `lib/core/logging.sh`

**DECISION**: not adopted. `lib/ui/output.sh` remains the single home for
`ok/info/warn/err/die/step/detail`, once its stdout/stderr contract is
fixed (§3; `docs/CONTRACTS.md` contract 1).

**WHY**: no source — not `engineer_guidelines.md`, not either
`architecture*.md`, not `sm_integration.md` — establishes a distinct
"logging" concept separate from these existing UI/diagnostic helpers.
Whether file-based logging (a persistent log file, as opposed to
terminal/stderr diagnostic output) is in scope at all remains `UNKNOWN`
— no source commits to it. Creating an empty `logging.sh` now would be
exactly the "artificial abstraction for a pretty tree" this task
explicitly warns against.

**CONSEQUENCES**: if file-based logging is later decided to be in scope,
`lib/core/logging.sh` can be added then, with concrete content. Until
then, `lib/ui/output.sh` is where diagnostic output lives, full stop.

### 2.5 — `lib/system/network.sh` does not absorb `panel_api()`

**DECISION**: `lib/common/network.sh`'s `panel_api()` moves to
`lib/panel/core.sh` (alongside the existing, deliberately-not-merged
`panel_api_request()` — see the earlier Stage 2 decision recorded in
this project's history to keep them separate), not to
`lib/system/network.sh`.

**WHY**: `panel_api()` is Remnawave-Panel-API-specific (hardcoded
endpoint/auth conventions), used today only from `lib/panel/warp.sh` —
verified by repo-wide grep. It is not a generic networking primitive
despite its current generic-sounding location and name.
`lib/system/network.sh` is reserved for genuinely domain-agnostic
networking concerns, if and when a concrete one is identified; none is
named by any source today, so this file starts empty/aspirational —
noted plainly rather than hidden.

### 2.6 — No `lib/integrations/` (shell)

**DECISION**: dropped from the target tree entirely.

**WHY**: no source gives concrete content for it. Top-level
`integrations/` (standalone Python/Rust runtime services, per
`engineer_guidelines.md` §2) and `lib/*/py/` (domain-specific Python
helpers, same source) already cover every runtime-Python need any
document describes. An empty `lib/integrations/` next to the existing,
differently-scoped top-level `integrations/` would only be a naming
collision risk with no offsetting benefit (this exact risk was flagged
in an earlier round of this reconciliation). If a genuine cross-domain
*shell* integration need is identified later, it can be added with a
concrete justification at that time.

---

## 3. Canonical contracts — summary (full tables in `docs/CONTRACTS.md`)

Every item below is now `DECISION`, not `OPEN QUESTION` — several were
previously listed as open only because the normative source
(`engineer_guidelines.md`) had not yet been read.

| # | Contract | Decision |
|---|---|---|
| 1 | stdout / stderr | stdout = machine-readable data only, at every layer (CLI, Python, **and** domain-shell `lib/ui/output.sh` — the last is this document's own extension, since `engineer_guidelines.md` only covers the first two). stderr = all diagnostics/UI/errors |
| 2 | Exit codes | 0 = success only; every failure class gets a distinct non-zero code where practical; callers **must** check exit code, never infer failure from stdout content |
| 3 | Command substitution | A function ever called as `X=$(f ...)` must never print UI/diagnostic text on any path (success or failure) until stdout/stderr are separated; must signal failure via exit code only; must never rely on an `exit`-driven fatal helper (`err`/`die`) internally, since `exit` inside `$(...)` only kills the substitution subshell |
| 4 | HTTP transport vs API success | `curl` exit 0 ≠ HTTP 200 ≠ valid API response; all three must be checked independently before a response is used |
| 5 | SSH execution lifecycle | connect → execute → verify exit code → cleanup, as four distinct, individually-checked steps; no step is skipped |
| 6 | Timeout policy | `panel_api()` and SSH `RUN`/`PUT` get default timeouts, overridable per call. Concrete numeric defaults: `UNKNOWN` — no source gives them; assign during implementation, not architecture |
| 7 | Secrets | Never in argv (fixes `sshpass -p`, NODE-04); never in stdout/diagnostic output; generated files containing secrets get owner-only permissions (fixes NODE-03) |
| 8 | `.env` / config atomicity | Python utility, `tempfile` + `os.replace()` only; `sed -i`/`echo >>` on `.env` forbidden (current confirmed violation: `lib/hy2/install.sh:451`) |
| 9 | Bash/Python boundary | JSON/YAML/TOML/`.env`/SQL/hashing → Python only; a Bash function doing more than ~3 lines of data logic is mis-scoped and belongs in Python (current confirmed violations: 5 files with `python3 <<` heredocs) |
| 10 | Python component contracts | Every script in `integrations/` or `lib/*/py/` must have a recorded contract (type, file path, ENV vars, stdin, stdout shape, stderr policy, exit codes, idempotency) before merge, not retroactively; none exist yet on `beta`, so this applies starting with the first script added |
| 11 | Single-writer ownership | Exactly one component writes any given piece of persistent state; `collect_stats.py` is the sole writer of `stats.db` (TeleMT, §5); each Hysteria2 ingestion script owns exactly one storage target (extends `sm_integration.md`'s rule, which only covers TeleMT, to Hysteria2 — see §5.3) |
| 12 | Traps / cleanup | `RETURN` trap for local staging cleanup (existing correct example: `lib/panel/node/install.sh:32`); `INT`/`TERM` trap for remote-state-creating operations (currently absent everywhere — 0 such traps repo-wide) |
| 13 | Idempotency / reconcile | Install-time operations that create durable remote resources (Remote Node, Panel API resources) must become lookup-before-create; `panel_setup_api()`'s existing `Default-Profile` lookup (`lib/panel/api.sh:50-53`) is the in-repo precedent to generalize from |
| 14 | Telemt ingestion boundary | `collect_stats.py` (target, not yet built) is the sole ingestion boundary between the telemt API and `stats.db`; `status_render.py` (target, not yet built) is a named, sanctioned exception for live runtime/status display only, never ingestion or `stats.db` writes; management-plane reads of `/v1/users` stay outside this boundary. Not yet applicable on `beta` — `collect_stats.py`/`stats.db` don't exist yet |

Full per-contract `invariant / current violation / target behaviour /
migration implication / test implication` tables are in the new
`docs/CONTRACTS.md` (§8) — this section is the summary, not the source of
truth for contract details.

---

## 4. Remote Node lifecycle — final model

### 4.1 — State machine

```text
                    ┌─────────────┐
                    │   ABSENT    │
                    └──────┬──────┘
                           │ deploy requested
                           ▼
                    ┌─────────────┐
              ┌────▶│   CREATE    │  config-profile → node → host → squad
              │     └──────┬──────┘  (transactional — see 4.4)
              │            │ success
              │            ▼
              │     ┌─────────────┐
   repair     │     │   HEALTHY   │◀───────────────┐
   succeeds   │     └──────┬──────┘                 │
              │            │ next run: HEALTH CHECK  │ repair succeeds
              │            ▼                         │
              │     ┌─────────────┐            ┌─────┴──────┐
              └─────│  RECONCILE  │───────────▶│   REPAIR   │
                    │ lookup →    │ drift/      │ fix only   │
                    │ diff →      │ incomplete  │ what       │
                    │ apply       │ found       │ differs    │
                    └──────┬──────┘             └─────┬──────┘
              no drift ────┘  lookup fails              │ repair fails
              found → NO-OP                              ▼
                           ▼                       ┌─────────────┐
                    ┌─────────────┐                │   FAILED    │
                    │ INCOMPLETE  │                └─────────────┘
                    └──────┬──────┘
                           │ explicit user action only
                           ▼
                    ┌─────────────┐
                    │  REINSTALL  │  controlled teardown → CREATE
                    └─────────────┘
```

### 4.2 — Identity: `DECISION` (no longer open)

**DECISION**: identity = `SELFSTEAL_DOMAIN`.

**WHY**: already used as the naming key for both the config profile and
the node today (`RemoteNode-${SELFSTEAL_DOMAIN}`, confirmed in
`panel_node_register()`); no other candidate identity exists anywhere in
the current API surface or in any source document; a `GET`-by-name lookup
is directly implementable against the existing convention, following the
same shape as `panel_setup_api()`'s existing `Default-Profile` lookup
(§3, contract 12).

**ALTERNATIVES CONSIDERED**: a Panel-side stable UUID persisted locally
by server-manager (e.g. next to `PANEL_TOKEN_FILE`). Rejected for now —
whether the Panel API exposes such a UUID independent of the
name-derived lookup was not verified in this repository (would require
reading Remnawave Panel's own API surface, out of this repo's scope), and
no source proposes concrete storage/lookup mechanics for it. Revisit if
domain rotation (see consequence below) proves too costly in practice.

**CONSEQUENCES — accepted trade-off, not solved**: if `SELFSTEAL_DOMAIN`
changes (domain rotation), the old Node/Host/Profile become orphaned —
nothing but the name string ties them together, so a changed name means
a changed identity, full stop. This is **explicitly not handled** by
RECONCILE; the recovery path for domain rotation is a manual/explicit
`REINSTALL` against the new domain, leaving the old entities to be
cleaned up separately (not automated by this lifecycle). This is a
conscious scope limitation, not an oversight.

### 4.3 — Health check

Runs at the start of RECONCILE, and is invokable standalone. Observed
state classification:
- **HEALTHY**: lookup succeeds, Node/Host/Squad all present and match
  desired config → NO-OP.
- **DRIFT**: lookup succeeds, entities present but some field differs
  from desired state (e.g. `NODE_ADDR` changed) → RECONCILE applies only
  the differing fields.
- **INCOMPLETE**: lookup succeeds but one or more of
  Node/Host/Squad/Config-Profile is missing (BUG-03's partial-failure
  scenario, made recoverable instead of silently masked) → REPAIR
  creates only the missing pieces.
- **lookup fails entirely** (e.g. API unreachable) → does not conclude
  ABSENT; surfaces as a failed health check, retried on the next
  invocation, never silently treated as "safe to CREATE" (that would risk
  a duplicate).

### 4.4 — Transactional vs compensating

**DECISION**: CREATE is transactional — on any step's failure
(config-profile, node, host, or squad creation), the already-created
steps in that same CREATE attempt are rolled back (deleted) rather than
left as BUG-03-style orphaned partial state; the operation reports FAILED
as a whole, cleanly, ready for a fresh CREATE or explicit REPAIR.
RECONCILE/REPAIR are inherently compensating by design — they act only
on the specific fields/entities that differ or are missing, never
delete-and-recreate what's already correct.

**WHY**: CREATE is a one-shot flow with a well-defined "nothing existed
before, nothing should exist after a failure" invariant, making
transactional rollback both meaningful and implementable. RECONCILE, by
definition, operates on a resource that already has a legitimate prior
state — compensating action (fix only what's wrong) is the only safe
default there.

### 4.5 — Retry

**DECISION**: individual external-command failures (a single failed
`panel_api()` call, a single failed SSH command) get bounded retry with
backoff at the *external command* layer (contract 6/11, §3) — not at
the lifecycle-state layer. The lifecycle state machine itself does not
retry automatically; a FAILED CREATE requires an explicit new invocation
(by the operator or by the CLI's own retry logic, not by RECONCILE
silently re-attempting CREATE). This keeps the two concerns
(transient-fault retry vs. lifecycle-state transitions) separate and
independently testable.

---

## 5. TeleMT — final architecture

### 5.1 — Naming: `lib/telemt/`, not `lib/tmt/`

**DECISION**: keep `lib/telemt/` (current name), reject `sm_integration.md`'s
and `architecture_v1.md`'s `lib/tmt/`.

**WHY**: `lib/telemt/` is the current, working name (this task's own
proposed tree also uses `lib/telemt/`, not `lib/tmt/` — the two normative
`btemp` research documents are the only sources proposing the rename).
The domain name used throughout this task and throughout `beta` is
"TeleMT" — closer to `telemt` than to the abbreviation `tmt`. A rename
here is pure churn (every reference, every doc, every menu string) for a
cosmetic gain no source argues for beyond internal consistency within
those two documents. Not adopted.

**CONSEQUENCES**: every `lib/tmt/...` path named in `sm_integration.md`
and `architecture_v1.md` maps 1:1 to `lib/telemt/...` in this project's
actual target (e.g. `lib/tmt/py/collect_stats.py` → `lib/telemt/py/collect_stats.py`).

### 5.2 — Current vs target

**Current (`beta`, verified)**: `lib/telemt/{core,install,menu,migrate,
users,api}.sh` — plain shell, menu-routed, no SQLite, no Python
ingestion, no `stats.db`, no `lib/telemt/py/`.

**Target** (`sm_integration.md` + `architecture_v1.md`'s API-contract
detail, adapted to the `lib/telemt/` name):

- The external telemt (Rust) runtime exposes a management+stats API on
  `localhost:9091`; it owns no history and is not source-of-truth for
  statistics — it is queried live for current counters/status only.
- `lib/telemt/py/collect_stats.py` becomes the **single writer** of a
  new SQLite `stats.db` (`snapshots`/`daily`/`monthly` tables, WAL mode,
  `BEGIN EXCLUSIVE` for concurrency safety).
- **Delta/reset semantics** (`architecture_v1.md` §2.1, adopted
  verbatim): `total_octets` is cumulative from the telemt API and resets
  to 0 on telemt restart; the collector must compute
  `delta = current if current >= previous else current` (treat a
  decrease as a counter reset, not negative traffic).
- **`telemetry.user_enabled = true` is a hard requirement** — without it,
  `total_octets` silently stays 0, and this failure mode is **not
  detectable** from the `/v1/users` response alone (`architecture_v1.md`
  §2.1). This must be checked and surfaced explicitly, not discovered
  as an operator mystery.
- **IP semantics**: union of `active_unique_ips_list ∪
  recent_unique_ips_list`, both explicitly best-effort/non-exhaustive —
  never treated as a complete list.
- **Read-only rendering** (`render_users.py`, `user_ips.py`,
  `stats_settings.py`) reads `stats.db` read-only, never writes.
- `status_render.py` is a **named, explicit exception** to the
  single-writer/no-direct-API rule (`docs/CONTRACTS.md` contracts 11 and
  14) — it reads the telemt API
  directly because service status is inherently ephemeral, not
  historical data appropriate for `stats.db`.
- `lib/telemt/api.sh` (current, 203 lines) is renamed to
  `lib/telemt/manage.sh` (matches this task's proposed tree naming) —
  management-plane calls (add/delete/list users) continue to go through
  `lib/telemt/manage.sh` → telemt API directly, and are **kept separate**
  from stats ingestion (`collect_stats.py`); reading traffic/counters
  from the telemt API anywhere other than `collect_stats.py` is
  forbidden.
- `traffic.json` (current storage, implied by "не считай его уже
  реализованным") is `DEPRECATED` in this target — not read, not
  written once `collect_stats.py` ships, removed via a one-shot
  `migrate_json_to_sqlite.py`.
- CLI boundary (`lib/cli/telemt.sh` — actually: per §2.3's decision, this
  is `lib/telemt/menu.sh`'s **non-interactive** counterpart, living under
  `lib/cli/`, not a domain file) uses `cli_exec_py_stream`/
  `cli_exec_py_capture` (contract 3, §3) — never touches `stats.db` or
  the telemt API directly, only ever through `lib/telemt/`'s own
  functions.

### 5.3 — Ownership table (extends `sm_integration.md`'s TeleMT-only rule to Hysteria2)

| Writer | Owns |
|---|---|
| `collect_stats.py` | `stats.db` (TeleMT) — sole writer |
| `hy_traffic_collect.py` | Hysteria2 traffic storage — sole writer (per existing `docs/CHANGELOG.md` history of this component) |
| `hy_online_poller.py` | Hysteria2 online-status field — sole writer |
| `hy_node_register.py` | one-shot, not a persistent-state writer |
| CLI / menu layer (any domain) | never writes storage directly — always through the domain's own owning script |

### 5.4 — Migration from current state

Not attempted in this document (no code changes this round). Sequenced
in §7 stage 9 — after the directory-tree and identity decisions above are
final and stable, since TeleMT's Python ingestion layer is new
construction, not a rename of existing code.

---

## 6. Web / TLS / nginx / caddy — final decision

**DECISION**: web-server/TLS is **not** promoted to a top-level
`lib/web/` domain. It remains part of the Panel domain
(`lib/panel/{tls.sh, nginx/config.sh, caddy/config.sh, subpage.sh,
selfsteal.sh}`), with the nginx/caddy provider-pattern abstraction that
`tmp/architecture.md` proposed **kept, but nested under `lib/panel/`
instead of promoted to a sibling of `panel/hy2/telemt`.**

**WHY**: promoting web/TLS to a top-level domain implies it is a shared,
reusable concern across multiple domains. That premise does not hold on
`beta` today — Hysteria2 does not route through nginx/caddy (its own UDP
listener handles TLS independently); TeleMT does not either. Every
current nginx/caddy/cert consumer is Panel-specific: the Remnawave panel
frontend, its subscription page, and the selfsteal reverse-proxy.
Creating a top-level domain for a concern with exactly one consumer is
the "artificial abstraction for a pretty tree" this task explicitly
warns against — even though the *internal* provider-pattern idea
(`web_server_detect`/`configure_proxy`/... dispatching to
`providers/{nginx,caddy}.sh`) is a genuinely good idea on its own merits,
independent of where it's nested.

**ALTERNATIVES CONSIDERED**:
- Adopt `tmp/architecture.md`'s `lib/web/{core,detect,tls,providers/}`
  as proposed. Rejected per above — no evidence of cross-domain reuse
  exists anywhere in `beta` or in any source document.
- `architecture_v1.md`'s approach (keep `cert.sh` nested in
  `lib/panel/`, no separate TLS abstraction at all). This document
  **agrees with `architecture_v1.md`'s placement** but goes one step
  further by keeping (not discarding) `architecture.md`'s clean
  provider-dispatch idea for the nginx/caddy split specifically, since
  that duplication (two nearly-parallel 176-line config generators) is
  real and already visible in current `beta` file sizes.

**CONSEQUENCES**: `cert.sh` → `tls.sh` (rename, §2.2); `nginx/config.sh`
and `caddy/config.sh` stay as today's already-correct provider split,
just documented explicitly as implementing this pattern; no new
directory is created. If TeleMT or Hysteria2 ever *do* grow a genuine
need to share TLS/web-server logic with Panel, promoting to `lib/web/`
at that point — with concrete evidence in hand — would be the correct
call; that evidence does not exist today.

### 6.1 — Variant F: nginx owns public :443, Xray/REALITY moves internal

**PURPOSE**: MODE=1 and MODE=2 both let *something other than nginx* own
public TCP 443 whenever a co-located Node exists (Xray/REALITY does, in
MODE=1). Variant F is for operators who need nginx to be the sole public
:443 owner even with a co-located Node — e.g. because their environment
mandates a single well-understood public listener, or because they want
Panel/sub/selfsteal and the proxy data-plane visibly multiplexed through
one process for firewall/audit purposes. It does not replace MODE=1; it
is a third value of the same `MODE` variable, alongside `1` and `2`.

**DECISION**: expressed as a third `MODE` value (`"F"`), not a new
`TOPOLOGY` variable or a parallel contract system. `MODE` already *is*
the "who owns 443 / where does Xray live" lever throughout
`lib/panel/{api.sh,compose.sh,install.sh,nginx/config.sh}` — adding a
third value to an existing three-way lever is the minimal extension;
inventing a second variable would mean every one of those call sites
grows a second axis to check, for no behavioural gain.

**Decision table** (`WEB_SERVER` × `MODE` → supported):

| WEB_SERVER | MODE | Supported | Reason |
|---|---|---|---|
| 1 (nginx) | 1 | ✅ | existing — Xray owns public 443, nginx on unix socket |
| 1 (nginx) | 2 | ✅ | existing — Panel-only, Node deployed separately later |
| 1 (nginx) | F | ✅ | this section — nginx owns public 443, Xray moves internal |
| 2 (Caddy) | 1 | ✅ | existing — Xray owns public 443, Caddy on unix socket |
| 2 (Caddy) | 2 | ✅ | existing — Panel-only, Node deployed separately later |
| 2 (Caddy) | F | ❌ | F's mechanism is nginx's `stream{}` + `ssl_preread` module ([VERIFIED](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html), and confirmed present in the official `nginxinc/docker-nginx` build already used here — no custom image needed). Caddy's equivalent is the third-party `mholt/caddy-l4` plugin, which is **not** part of the stock `caddy:2.11` image this project already uses elsewhere — it requires a custom `xcaddy` build. Rejected for this pass on that basis, not because the underlying TCP/TLS-passthrough mechanism is impossible with Caddy — it's a scope decision, not an architecture one. Revisit if Caddy support is explicitly requested. |

**Port ownership table**:

| Mode | nginx public :443 | nginx internal HTTPS | Xray/REALITY listen | Selfsteal fallback |
|---|---|---|---|---|
| MODE=1 | not applicable — nginx has no public listener at all | n/a | `0.0.0.0:443` (public) | `unix:/dev/shm/nginx.sock` |
| MODE=2 | `0.0.0.0:443` (public, Panel+sub only, no co-located Node) | n/a | not applicable | n/a |
| MODE=F | `0.0.0.0:443` (public — `stream{}` block) | `127.0.0.1:7443` (Panel+sub, TLS terminated here) | `127.0.0.1:8443` (loopback only) | `unix:/dev/shm/nginx.sock` (unchanged from MODE=1) |

**Topology**:

```
Internet
   │ TCP :443
   ▼
nginx stream{} (ssl_preread — reads SNI, does NOT terminate TLS)
   │
   ├── SNI = PANEL_DOMAIN / SUB_DOMAIN ──▶ 127.0.0.1:7443 (nginx http{}, TLS terminated normally)
   │                                            │
   │                                            ├── Panel   → 127.0.0.1:3000
   │                                            └── Sub     → 127.0.0.1:3010
   │
   └── default (SELFSTEAL_DOMAIN + any non-matching SNI,
       i.e. exactly what REALITY itself already treats
       as "not my client") ──▶ 127.0.0.1:8443 (Xray/REALITY, raw TCP, untouched)
                                     │
                                     ├── genuine REALITY client → proxy
                                     └── everything else (Xray's own fallback,
                                         UNCHANGED from MODE=1) → unix:/dev/shm/nginx.sock
                                                                        │
                                                                        └── nginx serves the
                                                                            decoy site (same
                                                                            http{} block MODE=1
                                                                            already has)
```

**Why raw TCP passthrough, not HTTP reverse proxy, for the Xray leg**:
REALITY inspects the genuine TLS ClientHello itself to decide "real
client vs. everyone else." If nginx terminated TLS before handing
traffic to Xray, Xray would never see a real handshake and REALITY's
entire security model would have nothing to inspect. `ssl_preread`
reads only the SNI from the ClientHello without terminating TLS/SSL
([VERIFIED](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)),
so `proxy_pass` in the `stream{}` block forwards the original,
untouched bytes — Xray's REALITY inbound sees exactly what it would see
if it still owned public 443 directly.

**Selfsteal/fallback flow**: completely unchanged from MODE=1. Xray's
own `realitySettings.dest` still points at `/dev/shm/nginx.sock`; that
mechanism lives entirely inside Xray and fires only after Xray's own
REALITY handshake inspection decides a connection isn't a genuine proxy
client. Variant F only changes *how traffic reaches Xray's public-facing
inbound*, not what Xray does once it has that traffic.

**Docker networking**: no new requirement beyond what MODE=1 already
has. `remnawave-nginx` and `remnanode` both already use `network_mode:
host` in MODE=1's compose branch — this is what makes
`proxy_pass 127.0.0.1:8443;` inside nginx's `stream{}` block correctly
reach the host's loopback where Xray binds, rather than falling into
the "nginx container's own loopback, not the host's" trap that would
occur if either container used bridge networking instead. Panel/DB/
Redis/sub-page stay on the bridge `remnawave-network`, reached via their
published `127.0.0.1:PORT` mappings — exactly as MODE=1 already does.

**Required mounts**: `nginx.conf` must be mounted at
`/etc/nginx/nginx.conf` (replacing the base image's top-level config
entirely), **not** `/etc/nginx/conf.d/default.conf` as MODE=1/2 do —
`stream {}` is only valid at the top level of nginx's config, never
nested inside `http {}}`; this is a hard nginx constraint, so
`panel_generate_nginx_config_f()` emits a complete top-level config
(events/http/stream) rather than an `http{}`-only fragment.
`/dev/shm` and `/var/www/html` mounts are unchanged from MODE=1 (still
needed for the selfsteal decoy).

**Required firewall rule**: the same `ufw allow from 172.30.0.0/16 to
any port 2222 proto tcp` rule MODE=1 applies — F is co-located, same
Docker-bridge-to-host-networked-container topology, same reason the
rule exists at all.

**Generated config responsibilities**:
- `lib/panel/nginx/config.sh`'s `panel_generate_nginx_config_f()` — the
  full top-level `nginx.conf` (§ above).
- `lib/panel/compose.sh` — a `WEB_SERVER=1 ∧ MODE=F` branch, structurally
  identical to the existing MODE=1 branch except the nginx service's
  volume mount target (`nginx.conf` → `/etc/nginx/nginx.conf`, not
  `conf.d/default.conf`). This mirrors the file's own established
  pattern of near-duplicate heredoc variants per `WEB_SERVER`×`MODE`
  combination (see the file's own header comment) rather than
  introducing a new abstraction layer for one differing line.
- `lib/panel/api.sh` — three MODE-aware values needed: the REALITY
  inbound's `port` (443 normally, the F-internal port for MODE=F), the
  REALITY fallback `DEST_VAL` (must be `/dev/shm/nginx.sock` for F, same
  as MODE=1 — not `${SELFSTEAL_DOMAIN}:443`, since nginx's own public
  entrypoint now owns that address:port, and pointing REALITY's
  fallback back through it would be a needless, fragile loop instead of
  the direct local-socket handoff MODE=1 already uses), and ufw
  eligibility (F needs the same rule MODE=1 does). Implemented as three
  small named pure functions rather than three more scattered
  `[ "$MODE" = ... ]` ternaries, so each is independently testable and
  the decision reads as "what MODE=F needs" in one place instead of
  three separate inline conditionals.

**Compatibility invariants** (binding on any future change to this
area):
- MODE=1 output (nginx config, compose, API values) MUST NOT change.
- MODE=2 output MUST NOT change.
- WEB_SERVER=2 (Caddy) topology for MODE=1/2 MUST NOT change.
- In MODE=F, only nginx may bind public TCP 443. Xray MUST NOT bind a
  public interface — its REALITY inbound listens on `127.0.0.1` only.
- `WEB_SERVER=2 ∧ MODE=F` MUST be rejected before any generation step
  runs (already enforced in `lib/panel/install.sh`).

**ALTERNATIVES CONSIDERED**: a `caddy-l4`-based Caddy equivalent (F2,
per the original research pass) — rejected for now per the decision
table above, not ruled out permanently. A generic layer-4 router
independent of nginx/Caddy (e.g. HAProxy) — rejected as an unnecessary
third dependency when nginx's own `stream` module already does this
natively and is already the WEB_SERVER=1 provider in this project.

---

## 7. Migration strategy — dependency-ordered stages

Not a file-move checklist — each stage lists its prerequisite, what must
stay backward-compatible during it, how to verify it, and its rollback.

| # | Stage | Prerequisite | Must stay compatible | Verification | Rollback |
|---|---|---|---|---|---|
| 1 | Contracts documentation | none | n/a — docs only | this document + `docs/CONTRACTS.md` exist and are internally consistent | revert the doc commit |
| 2 | `lib/core/` split (`common.sh`/`versions.sh`/`errors.sh`/`utils.sh` from current `lib/common/core.sh`+`generators.sh`) | stage 1 | every existing caller of the moved functions must still resolve them (same function names, new file) | `bash -n` on every touched file; full `server-manager.sh` source-load test (as used in the earlier Stage 7 runtime audit) | git revert; loader `source` order is unaffected either way since functions are name-resolved at call time |
| 3 | stdout/stderr separation in `lib/ui/output.sh` (contract 1, extended to domain layer) | stage 1 | every one of the 63 UI-emitting functions repo-wide changes only its output *sink*, never its call signature | repo-wide grep confirming zero `ok/info/warn/step/detail` write to stdout after the change; the two confirmed contamination call sites (`panel_node_register`'s caller, `panel_get_token`'s callers) specifically re-tested | git revert single file |
| 4 | Fix the two contamination call sites (BUG-01/02) | stage 3 | `panel_node_register`'s return contract (currently `"TOKEN NODE_UUID"` on stdout) — decide here whether to keep or restructure as part of the same change, not separately | live mock test (as used in the earlier runtime audit round) confirming failure paths now correctly signal via exit code | git revert |
| 5 | `lib/system/` extraction (SSH, firewall, services, migrate consolidation) | stage 2 | `lib/common/ssh.sh`'s `RUN`/`PUT` call signatures unchanged; `lib/migrate.sh`+`lib/panel/migrate.sh`+`lib/telemt/migrate.sh`'s combined behavior unchanged, verified via the same before/after artifact-comparison technique used in the Stage 7 audit | artifact/behavior diff before vs after consolidation | git revert; facades (`lib/common.sh`) can stay temporarily if a full cutover isn't ready |
| 6 | `lib/cli/` real implementation (contract 3/§10 of `engineer_guidelines.md`) | stages 3–4 (stdout contract must be correct before CLI is built on top of it) | interactive menus (`lib/panel/menu.sh` etc., §2.3) are entirely unaffected — CLI is additive, not a replacement | `tests/cli/` (stage 10) exercises this directly once it exists; until then, manual smoke test of `cli_exec_py_stream`/`capture` | git revert; `cli_run()` stub remains functional throughout since nothing in earlier stages depends on the new CLI layer existing |
| 7 | `cert.sh` → `tls.sh` rename (§6) | none (independent, low-risk) | every caller updated in the same commit (rename is atomic, not a gradual migration) | `bash -n` + grep for any remaining `cert.sh` reference | git revert |
| 8 | Remote Node lifecycle (CREATE/RECONCILE/REPAIR/REINSTALL, §4) | stage 4 (needs the corrected stdout/exit-code contract to safely detect failure at each state transition), stage 1's identity decision (§4.2, already made) | current single-path install remains the CREATE branch — no regression for first-time installs | the health-check/lookup logic can be tested against a mock Panel API independent of real infrastructure, following the mock-execution technique from the earlier runtime audit | feature-flag or branch the new lifecycle behind an explicit opt-in until proven; git revert otherwise |
| 9 | TeleMT SQLite ingestion layer (§5) | stages 2, 6 (needs `lib/system/` for any shared infra, needs `lib/cli/` for the CLI boundary) | `traffic.json` keeps working until `collect_stats.py` ships in the same release — no gap where neither exists | `migrate_json_to_sqlite.py` run against real historical `traffic.json` data as its own verification step | keep `traffic.json` path available (documented `DEPRECATED`, not removed) for at least one release after cutover |
| 10 | `tests/cli/` | stage 6 | n/a — new addition | the tests themselves are the verification | delete the directory |
| 11 | Cleanup/deprecation pass | all prior stages | remove `lib/common.sh` facade and any other compatibility shims only once nothing references them (grep-verified) | full repo-wide grep for the deprecated paths returning zero results | n/a — this stage is itself the point of no return per shim; do it last |

---

## 8. Architecture Decision Record

| Decision point | Status |
|---|---|
| stdout = data only, all layers | `DECISION` |
| stderr = all UI/diagnostics/errors, all layers | `DECISION` |
| Exit code is the only valid failure signal | `INVARIANT` |
| Functions callable via `$(...)` never rely on exit-driven fatal helpers | `DECISION` (elevated from the prior round's `PROPOSED`) |
| `lib/telemt/` (not `lib/tmt/`) | `DECISION` — §5.1 |
| Web/TLS stays nested in `lib/panel/`, no `lib/web/` | `DECISION` — §6 |
| Variant F expressed as third `MODE` value (`"F"`), not a new variable | `DECISION` — §6.1 |
| Variant F mechanism: nginx `stream{}` + `ssl_preread`, raw TCP passthrough to Xray | `DECISION` — §6.1 |
| Variant F + Caddy (`WEB_SERVER=2`) | `NOT SUPPORTED` — §6.1 (scope decision: `caddy-l4` needs a custom image; revisit on demand, not ruled out architecturally) |
| `lib/panel/` keeps current fine-grained file shape | `DECISION` — §2.2 |
| No separate `lib/ui/` tree | `DECISION` — §2.3 |
| No `lib/core/logging.sh` | `DECISION` — §2.4 |
| No `lib/integrations/` (shell) | `DECISION` — §2.6 |
| `panel_api()` → `lib/panel/core.sh`, not `lib/system/network.sh` | `DECISION` — §2.5 |
| Remote Node identity = `SELFSTEAL_DOMAIN` | `DECISION` — §4.2 (domain-rotation handling is an accepted trade-off, not solved) |
| CREATE transactional, RECONCILE/REPAIR compensating | `DECISION` — §4.4 |
| Retry lives at the external-command layer, not the lifecycle layer | `DECISION` — §4.5 |
| `status_render.py` as a named exception to the single-writer rule | `DECISION` — §5.2 |
| `err()` vs `die()` — which fatal helper survives | **`DECISION REQUIRED`** — no source picks one; low-stakes, resolve during stage 3 implementation |
| Concrete timeout default values (HTTP, SSH) | **`DECISION REQUIRED`** — no source gives numbers; assign during stage 6/implementation, not architecture |
| `docs/CONTRACTS.md` schema-migration mechanism for `stats.db` | **`DECISION REQUIRED`** — `init_db.py` (per `architecture_v1.md`) creates but does not specify an alter/upgrade path; needed before stage 9 ships, not before this document is finalized |

Three `DECISION REQUIRED` items remain, deliberately — each is either
low-stakes (helper-function naming) or genuinely implementation-detail
(numeric timeouts, a migration-tooling mechanism) rather than a
structural architecture question. No structural question was left open.

---

## 9. Cross-references

- `docs/CONTRACTS.md` — full per-contract invariant/violation/target/
  migration/test tables (§3 above is the summary).
- `docs/ENGINEER_GUIDELINES.md` — engineering practice rules, verbatim
  from `tmp/engineer_guidelines.md`, CURRENT/TARGET-annotated.
- `docs/ENGINEER.md` — operational/reference runbook, pointers updated to
  this document and to `CONTRACTS.md`/`ENGINEER_GUIDELINES.md`.
- `docs/ARCHITECTURE_AUDIT.md` — historical prior audit; superseded by
  this document for architecture purposes, kept for its still-valid
  module-boundary invariant (domains don't source CLI/menu modules) and
  historical record.
