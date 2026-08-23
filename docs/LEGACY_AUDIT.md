# Legacy Code Audit

> Inventory of `beta`'s actual current behaviour, produced to support a
> safe migration plan. This is **not** an architecture document — it
> does not decide anything `docs/ARCHITECTURE.md` hasn't already
> decided, and it does not restate contracts already fully specified in
> `docs/CONTRACTS.md`. Where a finding below simply confirms an existing
> `docs/CONTRACTS.md` violation with the same evidence already on
> record there, it is referenced by contract number rather than
> duplicated verbatim.

## 1. Scope and baseline

- code baseline: `beta` @ `33135602c5c2e799575b0081cbfd137a40f7527c`
  (`3313560`) — verified unchanged; all commits after it are docs-only.
- branch: `beta`. No code, `btemp`, contract, or architecture file was
  modified to produce this document — see §13.
- Canonical sources used: the code itself (primary evidence for every
  finding below), `docs/CONTRACTS.md` (14 contracts), `docs/
  ARCHITECTURE.md` (target tree/decisions), `docs/ENGINEER_GUIDELINES.md`
  (practice rules).
- Scope: `lib/**` and `server-manager.sh`. `lib/system/`, `lib/
  subscription/`, and a real `lib/cli/` beyond the `router.sh` stub do
  **not exist yet** on `beta` — those are target-tree names only; this
  audit inventories what's actually there today, not what the target
  tree calls it.
- Current top-level domains, with approximate size: `lib/panel/**`
  (~2,950 lines across 17 files, largest domain), `lib/hy2/**` (~1,800
  lines, 5 files), `lib/telemt/**` (~1,520 lines, 6 files), `lib/
  common/**` (~380 lines, 5 files — `core`, `generators`, `network`,
  `ssh`, `menu`), `lib/ui/output.sh` (36 lines), `lib/core/config.sh`
  (global path/var definitions), plus `lib/migrate.sh`, `lib/panel.sh`
  / `lib/telemt.sh` / `lib/hysteria.sh` (domain loaders), `lib/cli/
  router.sh` (stub).

## 2. Runtime entry points

**EP-01 — top-level bootstrap and module load order**
- Location: `server-manager.sh`
- Current behaviour: on first run (`curl | bash`), clones itself to
  `/root/server-manager`, symlinks `/usr/local/bin/server-manager`, and
  re-execs from the clone. On every run it loads modules in a fixed
  order via `_load_module`: `core/config` → `ui/output` → `common` →
  `panel` → `telemt` → `hysteria` → `migrate` → `cli/router`, then
  calls `check_root` and `cli_run`. Each of `common`/`panel`/`telemt`/
  `hysteria` is itself a loader that sources its domain's submodules in
  a fixed order (e.g. `lib/panel.sh` sources `core, cert, install,
  compose, mgmt_script, api, selfsteal, nginx/config, caddy/config,
  node/compose, node/api, node/install, management, warp, subpage,
  template, migrate, menu` in that order).
- Evidence: `server-manager.sh:38-129`; `lib/common.sh`, `lib/panel.sh`,
  `lib/telemt.sh`, `lib/hysteria.sh`.
- Related contract: none directly (bootstrap/loading isn't one of the
  14 contracts).
- Risk: P3. Load order is a real implicit dependency (later domains can
  assume earlier ones' globals exist) but nothing found in this audit
  actually breaks on it.
- Target implication: none — out of scope for the 14 contracts as
  written.

**EP-02 — remote-module integrity check is present but currently inert**
- Location: `server-manager.sh:78-121` (`_sm_source_file`,
  `_MODULE_SHA256`)
- Current behaviour: when running without a local checkout (the
  `curl | bash` path), each module is fetched over HTTPS from
  `raw.githubusercontent.com` and, if a SHA256 is registered for it,
  verified before `source`. Every entry in `_MODULE_SHA256` is
  currently the empty string, which the code treats as "skip
  verification" — so today, every remotely-fetched module is sourced
  with **no integrity check at all**, despite the mechanism and its
  error message (`"Возможна компрометация репозитория"`) existing in
  the code.
- Evidence: `server-manager.sh:80-89` (all-empty map), `server-
  manager.sh:104-112` (skip-if-empty logic).
- Related contract: none of the 14 (supply-chain integrity for the
  bootstrap path isn't a covered contract).
- Risk: P2. Not a violation of any stated contract, but it's a
  documented-and-then-disabled safety mechanism on a `curl | bash`
  install path — worth a decision (fill in the hashes, or remove the
  mechanism) before that path is relied on more heavily.
- Target implication: none — flagged as a gap for a future decision,
  not something this audit or `docs/CONTRACTS.md` currently governs.

## 3. Configuration ownership

This is the gap `docs/CONTRACTS.md` explicitly left open pending this
audit. Findings are **current-state only** — no target ownership model
is proposed here.

| Object | Current owner (creates) | Other writers | Readers | Generated? | Runtime-owned? | Restart/reload required? |
|---|---|---|---|---|---|---|
| `/opt/remnawave/.env` | `lib/panel/install.sh` (`cat >`) | `lib/panel/mgmt_script.sh` (deployed script, `sed -i`), `lib/panel/migrate.sh` (`sed -i`) — see CFG-01 | `lib/panel/menu.sh`, `lib/panel/mgmt_script.sh`, `docker compose` (`env_file: .env` in `lib/panel/compose.sh`) | Yes (secrets generated at install) | No — file, read by container at (re)start | Yes, panel container restart |
| `/opt/remnawave/docker-compose.yml` | `lib/panel/compose.sh` / `lib/panel/install.sh` (4 near-duplicate `cat >` blocks depending on nginx/caddy × mode) | `lib/panel/api.sh:46` (`sed -i` for `SECRET_KEY` post-generation) | `lib/panel/mgmt_script.sh` (`_detect_ws`, greps it), `docker compose` | Yes | No | Yes (`docker compose up -d`/restart) |
| `/opt/remnawave/nginx.conf` | `lib/panel/nginx/config.sh:26` (`cat >`) | `lib/hy2/menu.sh:307` (`sed -i`, cross-domain — see CFG-02) | `docker exec remnawave-nginx nginx -t` (`mgmt_script.sh:132`) | Yes | No | Yes (`docker compose restart remnawave-nginx`) |
| `/opt/remnawave/Caddyfile` | `lib/panel/caddy/config.sh` (`cat >`, 2 call sites for mode 1/2) | none found | `docker compose restart remnawave-caddy` | Yes | No | Yes |
| `/etc/hysteria/config.yaml` (`$HYSTERIA_CONFIG`) | `lib/hy2/install.sh:262` (`cat >`) | `lib/hy2/install.sh:338-339`, `lib/hy2/users.sh:55-56,136-137` — all via the **same** temp-file-then-`mv`-then-`chmod 644` pattern | `lib/hy2/core.sh`, `lib/hy2/integration.sh`, `lib/hy2/menu.sh` | Yes | No | Yes, `systemctl restart hysteria-server` |
| `/etc/hy-webhook.env` | `lib/hy2/install.sh:451-452` (`sed -i` delete + `printf >>`, no prior creation guard shown) | same file only | webhook service (external) | Yes | No | Yes, `systemctl restart hy-webhook` |
| Telemt config (`$TELEMT_CONFIG_FILE`, systemd- or docker-path variant) | `lib/telemt/install.sh:95` (`} > file`) | `lib/telemt/menu.sh:276` (`sed -i`, single field, no backup), `lib/telemt/migrate.sh:190-199` (full `sed`-rewrite piped to a **remote** host via `RRUN "cat >"`) | `lib/telemt/core.sh`, `menu.sh`, `users.sh`, `migrate.sh` (all via `grep`/`awk`) | Yes | No | Yes, `systemctl restart/stop/start telemt` |
| `/etc/letsencrypt/renewal/*.conf` | certbot (external tool) | `lib/panel/cert.sh:140` (`sed -i` or `echo >>` to set `renew_hook`) | certbot itself | No (third-party-owned) | N/A | No (hook only fires on renew) |
| root crontab | operator/system | `lib/panel/cert.sh:133-134` (`crontab -l \| ... \| crontab -`) | certbot's cron trigger | No | N/A | No |
| systemd units (`hysteria-server`, `telemt.service`, `hy-merger.service`, `hy-webhook`, `remna-sub-injector`) | each domain writes its own unit file (`hy2/install.sh`, `telemt/install.sh`, `hy2/menu.sh`, etc.) | none found writing another domain's unit | `systemctl` (77 call sites total across the repo) | Yes | No | `daemon-reload` + `enable`/`restart` per unit |
| Secrets (`APP_SECRET`, `SECRET_KEY`, JWT values, x25519 keys, panel token) | generated inline at the call site that needs them (`gen_hex64`, `openssl rand -hex 8`, Panel API responses) | — | scattered: some land in `.env`, some are `sed`-injected into `docker-compose.yml`, the panel auth token is written to a plain file (`$PANEL_TOKEN_FILE`, read/write in `lib/panel/core.sh`) | Yes | Mixed | N/A |
| Ports/domains (`SELFSTEAL_DOMAIN`, various `*_PORT` vars) | each domain tracks its own — no shared registry found | — | — | N/A | N/A | N/A |

**CFG-01 — `.env` JWT migration logic duplicated in two independent places**
- Location: `lib/panel/mgmt_script.sh:26-43` (heredoc, becomes the
  deployed `/usr/local/bin/remnawave_panel` on the target host) and
  `lib/panel/migrate.sh:4-20` (runs inside `server-manager` itself)
- Current behaviour: both blocks contain byte-for-byte the same
  `JWT_AUTH_SECRET` → `APP_SECRET` rename/dedupe logic against
  `/opt/remnawave/.env`, each via its own non-atomic `sed -i` (no temp
  file, no backup, no validation of the result). One copy is baked
  into a script deployed to the target server at panel-install time
  (`panel_install_mgmt_script`); the other runs from `server-manager`
  during a migration flow. They are two independent copies of the same
  logic, not one shared function.
- Evidence: `lib/panel/mgmt_script.sh:26-43`, `lib/panel/migrate.sh:4-20`
  (diff of the two blocks is textually identical apart from `_ok`/`ok`
  helper naming).
- Related contract: contract 8 (`.env` / config atomicity — the
  mechanism here is `sed -i`, which contract 8's invariant already
  names as forbidden for shared-state config).
- Risk: P2. Not data corruption today, but a fix to one copy (e.g.
  fixing the `sed -i` non-atomicity per contract 8) silently does not
  reach the other, and any already-deployed `remnawave_panel` script on
  an existing install is permanently stuck with whatever logic it was
  generated with, unless the panel install/mgmt-script generation is
  re-run.
- Target implication: reinforces contract 8's existing invariant — a
  future `.env` atomicity fix needs to land in both places (or the
  duplication needs to be resolved as part of that fix), not an
  architecture change.

**CFG-02 — `nginx.conf` mutated across a domain boundary**
- Location: `lib/hy2/menu.sh:293-309`
- Current behaviour: when installing the `hy-merger` service (a Hysteria2
  feature), the code checks `[ -f /opt/remnawave/nginx.conf ]` — a file
  owned and generated by the **panel** domain, not by `hy2` — and if
  present, greps for an existing `hy-merger` location block
  (idempotency check) and, if absent, `sed -i`s a new `location` block
  in before `docker compose restart remnawave-nginx`. If Caddy was
  chosen instead of nginx, the file won't exist and the code warns and
  skips (`warn "nginx.conf не найден — добавьте location вручную"`) —
  this path degrades gracefully rather than corrupting anything.
- Evidence: `lib/hy2/menu.sh:293-309`.
- Related contract: none of the 14 directly (cross-domain config
  coupling isn't itself a named contract), but it's exactly the "B
  assumes it owns a file A generated" pattern this audit was asked to
  surface.
- Risk: P2. Currently guarded (idempotent, existence-checked, graceful
  Caddy fallback) so it isn't presently destructive, but it's real
  coupling between two domains that the target tree (per `docs/
  ARCHITECTURE.md` §2) treats as separate, and the mutation itself is
  still an unguarded in-place `sed -i` with no backup.
- Target implication: a future configuration-ownership contract (still
  correctly out of scope for `docs/CONTRACTS.md` today, per its own
  stated gap) would need to decide whether `hy2` is allowed to mutate a
  panel-owned file at all, or whether this becomes a panel-side
  extension point instead. Not decided here.

**CFG-03 — generated secrets have no single storage convention**
- Location: repo-wide (see table above)
- Current behaviour: some secrets live only in `.env`
  (`APP_SECRET`), some are generated and then `sed`-injected into a
  *different* generated file after the fact (`SECRET_KEY` into
  `docker-compose.yml`, `lib/panel/api.sh:46`), and one (`$PANEL_TOKEN_FILE`)
  is a bare plaintext file read/written directly by `panel_get_token()`
  with no permission-hardening call found near its creation.
- Evidence: `lib/panel/api.sh:45-47`, `lib/panel/core.sh:34-50`
  (`$PANEL_TOKEN_FILE` read/write), `lib/panel/install.sh:54,64`
  (`APP_SECRET`).
- Related contract: contract 7 (secrets never in argv/stdout, generated
  files with secrets get owner-only permissions). The `docker-
  compose.yml` half of this is already the exact evidence cited in
  contract 7's "Current violation" row; `$PANEL_TOKEN_FILE`'s
  permissions were not previously audited and are added here as new
  evidence for that same contract.
- Risk: P1 (extends an existing contract-7 violation with one more
  concrete instance; still not P0 since there's no indication these
  files are served or transmitted beyond the local host).
- Target implication: feeds contract 7's existing "generated files
  containing secrets get owner-only permissions" target behaviour — no
  new contract needed, this is more evidence for the one that exists.

## 4. Mutation paths

Aggregate counts (repo-wide, `lib/` + `server-manager.sh`): `sed -i` —
19 call sites across 9 files; `cat > <<EOF`-style heredoc writes — 29
sites; `systemctl` — 77 sites; `docker`-related (`compose`/`exec`/
`restart`) — 93 sites; `curl` — 52 sites; `chmod`/`chown` — 27 sites;
`rm -rf`/`rm -f` — 68 sites. No `tee` usage and no bare `mv` outside
the atomic-rename pattern noted below were found.

**MUT-01 — two distinct config-write idioms coexist, with different
safety properties**
- Location: repo-wide
- Current behaviour: two clearly different patterns are in active use
  for "rewrite an existing config file":
  1. **Non-atomic, in-place**: `sed -i` directly against the live file
     — used for `.env` (CFG-01), `/etc/hy-webhook.env`, `nginx.conf`
     (CFG-02), Telemt config's `use_middle_proxy` toggle
     (`lib/telemt/menu.sh:276`), and the Reality `SECRET_KEY`
     injection into `docker-compose.yml`. None of these back up the
     file first or validate the result before considering the
     operation done.
  2. **Atomic temp-file + `mv`**: write to a temp file, then `mv` over
     the target, then `chmod` — used consistently for `$HYSTERIA_CONFIG`
     in both `lib/hy2/install.sh:338-339` and `lib/hy2/users.sh:55-
     56,136-137` (all four call sites use the identical `... > "$_tmp"
     && mv "$_tmp" "$TARGET" && chmod 644 "$TARGET" || rm -f "$_tmp"`
     shape).
- Evidence: as cited above; `grep -rn "mv \"\$_tmp\""` across `lib/hy2/`
  returns exactly these four sites.
- Related contract: contract 8's invariant (prepare → validate → commit,
  atomic rename) already exists; this finding is that **an in-repo
  precedent for exactly that pattern already exists in Bash**, just
  for a different file (`$HYSTERIA_CONFIG`) than the one contract 8
  currently cites (`.env`).
- Risk: P2 (migration-relevant precedent, not itself a new violation).
- Target implication: strengthens contract 8's migration story — the
  eventual `.env`/config-atomicity fix has a working in-repo Bash
  precedent to point to (`lib/hy2/users.sh`'s temp+`mv`+`chmod`
  sequence), even though contract 8's target behaviour specifies Python
  (`tempfile` + `os.replace()`) as the actual accepted implementation.
  No contract change implied — just evidence worth keeping for the
  migration PR.

**MUT-02 — certbot renewal-hook file mutated by two different
mechanisms depending on prior state**
- Location: `lib/panel/cert.sh:136-142`
- Current behaviour: `grep -q "renew_hook" "$renewal" && sed -i
  "/renew_hook/c\$hook" "$renewal" || echo "$hook" >> "$renewal"` — if
  a `renew_hook` line already exists, it's replaced in place via
  `sed -i`; if not, the new line is appended via `>>`. Both are
  non-atomic, and the target file is owned by certbot (an external
  tool), not by server-manager.
- Evidence: `lib/panel/cert.sh:136-142`.
- Related contract: contract 8 (same class of finding — direct
  in-place mutation of a config file another process reads), applied
  here to a third-party-owned file rather than a server-manager-
  generated one, which contract 8 doesn't currently distinguish.
- Risk: P3 — `renew_hook` is only read by certbot at renewal time
  (roughly weekly per the cron job also configured here), so a
  half-written line has a narrow, low-frequency exposure window.
- Target implication: none beyond noting it as one more contract-8-
  adjacent site if that contract's scope is ever widened to
  third-party-owned files — not proposed here.

## 5. Bash/Python boundary

Per contract 9's own current-status wording, this section supplies the
per-site classification contract 9 asks for but doesn't itself carry.

**PY-01 — heredoc-form Python (contract 9's "Current violation" class)**
- Location: `lib/hy2/users.sh` (2 sites), `lib/hy2/integration.sh` (4
  sites), `lib/hy2/install.sh` (1 site), `lib/panel/subpage.sh` (1
  site), `lib/panel/warp.sh` (3 sites) — 11 heredoc sites across 5
  files, confirming contract 9's "5 files" count and adding the
  per-file site count contract 9's text didn't break out.
- Current behaviour: each is Bash invoking `python3 <<EOF` /
  `python3 - <<EOF` with a multi-line inline script — used for
  structured file rewrites (`$HYSTERIA_CONFIG` YAML editing in
  `hy2/users.sh`, `hy2/install.sh`), UA-string / server config patching
  in `hy2/integration.sh`, and subscription/warp JSON handling in
  `panel/subpage.sh` and `panel/warp.sh`.
- Evidence: exact line numbers already on record in `docs/
  CONTRACTS.md` contract 9's "Current status" row; this audit re-
  confirms the same 11 sites, same 5 files.
- Related contract: 9 (Bash/Python boundary) directly.
- Risk: matches contract 9's own risk framing — P2 (migration
  coupling), not re-scored here.
- Target implication: none beyond contract 9's existing target
  behaviour (extract into real `lib/*/py/` scripts, contract 10's
  shape) — no new decision needed.

**PY-02 — single-operation `python3 -c` JSON field extraction (allowed-
adjacent, not classified by contract 9)**
- Location: `lib/telemt/api.sh:17,21`, `lib/panel/core.sh:41,53`, and
  ~31 further sites across `lib/telemt/{users,migrate,menu,core}.sh`,
  `lib/hy2/{users,install}.sh`, `lib/panel/{template,subpage,warp,
  selfsteal}.sh` (35 `python3 -c` sites total, 12 files).
- Current behaviour: nearly all sampled sites are single-expression
  `import sys,json; d=json.load(sys.stdin); ...` one-liners extracting
  one field or doing one boolean check (e.g. `panel_get_token`'s
  `d.get('response',{}).get('accessToken','')`). This is closer to
  contract 9's stated exceptions ("module-existence checks, single
  boolean greps") than to the heredoc "business logic" case, though
  contract 9's own text doesn't explicitly carve out single-field JSON
  extraction — this audit surfaces that gap rather than resolving it.
- Evidence: `lib/telemt/api.sh:17,21`, `lib/panel/core.sh:41,53` (full
  sampled text quoted in this repo's own source, not reproduced here).
- Related contract: 9.
- Risk: P3 — none of the sampled sites do multi-statement logic; they
  read as data-extraction, not business logic, but this was a sample,
  not all 35 sites individually re-verified.
- Target implication: contract 9's invariant already draws the
  "exceeding ~3 lines of data-logic" line; whether single-field JSON
  extraction counts as under that line is a scope question for
  whoever implements contract 9's migration, not something this audit
  resolves.

## 6. stdout/stderr

This section supplies the per-callsite table contracts 1 and 3 already
describe at the mechanism level; no new violations beyond what's
already on record in `docs/CONTRACTS.md` were found.

**IO-01 — `panel_get_token` stdout contamination on the fresh-login path**
- Location: `lib/panel/core.sh:29-51`
- Current behaviour: `caller` is any `token=$(panel_get_token)` call
  site; `callee` chain is `panel_get_token` → `panel_api_request` →
  `curl`. On the **cached-token fast path** (lines 31-35), output is a
  single clean `echo "$token"` — pure data. On the **fresh-login path**
  (lines 43-50), `ok "Авторизация успешна"` (line 46, stdout via
  `lib/ui/output.sh`) executes *before* the final `echo "$token"`
  (line 47) — so `$(panel_get_token)` on that path captures both
  lines, i.e. mixed output, exactly as already recorded in `docs/
  CONTRACTS.md` contract 3.
- Evidence: `lib/panel/core.sh:29-51` (re-read this round; matches
  contract 3's existing citation exactly).
- Related contract: 1, 3.
- Risk: matches contract 3's existing framing (not re-scored).
- Target implication: none beyond contract 3's existing target
  behaviour.

**IO-02 — `panel_node_register`'s exit-code-vs-emptiness check**
- Location: `lib/panel/node/install.sh:112-118`
- Current behaviour: re-confirms contract 2's existing finding —
  `_reg_out=$(panel_node_register ...)` then `[ -z "$_reg_out" ]` as
  the failure test, not `$?`.
- Evidence: as above; identical to contract 2's citation.
- Related contract: 2, 3.
- Risk: matches contract 2 (not re-scored).
- Target implication: none beyond contract 2/3's existing target
  behaviour.

## 7. HTTP lifecycle

**HTTP-01 — `panel_api()` has no timeout of any kind**
- Location: `lib/common/network.sh:27-41`
- Current behaviour: the actual Panel HTTP wrapper (the function `curl
  --max-time`/`--connect-timeout` is missing from) — confirms contract
  6's citation exactly; no flag limits either connection or total
  request time.
- Evidence: `lib/common/network.sh:27-41` (full function body).
- Related contract: 4, 6.
- Risk: matches contract 6 (not re-scored).
- Target implication: none beyond contract 6's existing target
  behaviour.

**HTTP-02 — `telemt_api()` already has a total-time timeout (partial
compliance, new evidence not previously on record)**
- Location: `lib/telemt/api.sh:6-14`
- Current behaviour: unlike `panel_api()`, `telemt_api()` already calls
  `curl -s --max-time 10 ...` on every request — a total-time bound is
  present, though `--connect-timeout` specifically is not set
  separately (so a slow-connect vs slow-response distinction, which
  contract 6's invariant asks for, isn't made — but *some* bound
  exists, unlike the Panel wrapper).
- Evidence: `lib/telemt/api.sh:6-14`.
- Related contract: 6.
- Risk: P3 — this is a positive finding relative to contract 6, not a
  new violation; flagged so the eventual timeout-policy migration
  doesn't treat all HTTP call sites as equally non-compliant.
- Target implication: contract 6's "assign concrete numeric defaults
  during implementation" note can point to `telemt_api()`'s existing
  `10`s as one real in-repo data point, alongside whatever the Panel
  side ends up needing.

**HTTP-03 — response-shape validation is inconsistent and call-site-
specific**
- Location: `panel_get_token` (`lib/panel/core.sh:43-49`, does check
  shape and reports `err "Не удалось получить токен: $resp"` on
  failure) vs. most other `panel_api`/`telemt_api` callers, which pipe
  the response straight into a `python3 -c` field-extraction (§5,
  PY-02) with no separate "is this response well-formed" check —
  a missing field silently becomes an empty string rather than a
  detected failure.
- Evidence: contrast `lib/panel/core.sh:43-49` against, e.g.,
  `lib/panel/node/api.sh:42,50,62` (`jq -r '... // empty'` with no
  prior shape check).
- Related contract: 4 (already flagged "Not re-verified this round" /
  gap; this audit supplies the concrete contrast as requested evidence
  for that gap, not a new contract).
- Risk: P2 — matches contract 4's existing framing of this as a
  pre-existing, not-yet-closed gap.
- Target implication: none beyond contract 4's existing target
  behaviour ("every call site validates transport, HTTP status, and
  response shape as three distinct checks").

## 8. SSH lifecycle

**SSH-01 — `RUN`/`PUT` lifecycle: connect timeout present, no execution
timeout, no signal traps**
- Location: `lib/common/ssh.sh:38-51`
- Current behaviour: `init_ssh_helpers()` builds `_SSH_OPTS="-p
  $_SSH_PORT -o $strict_opt -o ConnectTimeout=10"` and defines `RUN()`
  / `PUT()` as thin `sshpass -p "$_SSH_PASS" ssh/scp $_SSH_OPTS ...`
  wrappers. `ConnectTimeout=10` bounds the connect phase only; nothing
  bounds a hung remote command once connected. No `INT`/`TERM` trap
  exists anywhere in the repo (confirmed: `grep -rn "trap.*(INT|
  TERM)" lib/` → 0 results); exactly 2 `RETURN` traps exist repo-wide
  (`lib/common/ssh.sh:20`, `lib/panel/node/install.sh:32`).
- Evidence: `lib/common/ssh.sh:38-51`; trap grep as above.
- Related contract: 5. Matches contract 5's existing citation exactly.
- Risk: matches contract 5 (not re-scored).
- Target implication: none beyond contract 5's existing target
  behaviour.

**SSH-02 — password passed via `-p`, exposed for process lifetime**
- Location: `lib/common/ssh.sh:49-50` (`RUN`/`PUT` definitions)
- Current behaviour: `sshpass -p "$_SSH_PASS" ssh ...` / `sshpass -p
  "$_SSH_PASS" scp ...` — matches contract 7's existing citation
  (previously cited at line numbers 56-57 in an earlier docs pass; the
  actual definitions are at 49-50 in the current file — this audit
  updates the line reference, no behavioural change).
- Evidence: `lib/common/ssh.sh:49-50`.
- Related contract: 7.
- Risk: matches contract 7 (not re-scored).
- Target implication: none beyond contract 7's existing target
  behaviour; note the corrected line numbers for whoever does the
  eventual fix.

**SSH-03 — `PUT()` reused ssh-style `-p $_SSH_PORT` for `scp`, which
takes a stray positional argument instead of a port**
- Location: `lib/common/ssh.sh` (`init_ssh_helpers()`, `_SSH_OPTS`
  construction and the `PUT()` definition)
- Current behaviour: `_SSH_OPTS="-p $_SSH_PORT -o ..."` is correct for
  `ssh` (`-p` takes the port as its argument) but `PUT()` passed the
  same string to `scp -rp $_SSH_OPTS ...`. `scp`'s `-p` is a
  no-argument preserve-attributes switch, not a port selector (`scp`
  uses `-P PORT`) — so `$_SSH_PORT`'s value was left as a bare
  positional token, which `scp` parses as an extra source-file
  operand rather than a port number. Reproduced directly against the
  actual sourced `PUT()` (stub `scp`/`sshpass` capturing argv, not a
  rewritten copy): with `_SSH_PORT=22`, `PUT src dst` produced `scp
  -rp -p 22 -o ... src dst` — three source operands (`22`, `src`) and
  one destination (`dst`), instead of the intended one-source
  transfer on port 22.
- Evidence: `lib/common/ssh.sh` `_SSH_OPTS`/`PUT()` definitions;
  argv reproduction as above. All ~24 call sites across
  `lib/migrate.sh`, `lib/hy2/menu.sh`, `lib/panel/node/install.sh`,
  `lib/panel/mgmt_script.sh`, and `lib/telemt/migrate.sh`'s
  `RSCP()` wrapper (`telemt_menu_migrate`, systemd path) go through
  this one shared `PUT()`, so all inherited the same bug. The two
  independent direct `scp` invocations in the repo
  (`lib/migrate.sh`'s `migrate_transfer_panel_ssl()` and
  `lib/telemt/migrate.sh`'s `RSCP()` in `telemt_menu_migrate_docker()`,
  the docker path) already use `-P` correctly and were unaffected.
- Related contract: none of the 14 directly — this is CLI flag
  syntax correctness, not a named contract invariant (confirmed: no
  match for `scp`/`_SSH_OPTS`/`SSH_PORT` in `docs/CONTRACTS.md` or
  `docs/ARCHITECTURE.md`). Adjacent to contract 5 (SSH execution
  lifecycle) in subject matter only.
- Risk: P1 — silently breaks every non-default-port `PUT()` transfer
  (migration file copies, cert transfers, script deployment); on the
  default port 22 the effect is more subtle (`22` as a spurious first
  source operand) but still incorrect and error-prone depending on
  `scp` version/behaviour.
- Status: fixed locally (`lib/common/ssh.sh`) in the same session
  this finding was recorded — mechanical CLI-syntax correction, no
  architectural decision involved, public `PUT()` signature
  unchanged. `_SCP_OPTS` (using `-P`) was added alongside the
  existing `_SSH_OPTS` (using `-p`, unchanged, still used by `RUN()`);
  the previously-hardcoded `-p` (preserve attributes) in `scp -rp` was
  dropped rather than reassigned — no contract, architecture doc, or
  call site was found to depend on attribute preservation (the call
  sites that need an executable bit, e.g. `remnawave_panel` in
  `lib/panel/mgmt_script.sh`, already `RUN "chmod +x ..."` immediately
  after `PUT` rather than relying on it).
- Target implication: none — already resolved at the code level; no
  further migration-stage dependency.

## 9. Idempotency / reconcile

**IDEM-01 — Remote Node registration: unconditional POST, no lookup**
- Location: `lib/panel/node/api.sh:32-90` (`panel_node_register`)
- Current behaviour: confirms contract 13's existing citation —
  `config-profiles`, `nodes`, and `hosts` are all created via
  unconditional `POST` on every call, with no prior `GET`+lookup. Also
  observed in this pass: the `internal-squads` step (lines 82-88) loops
  over every existing squad and `PATCH`es each one unconditionally,
  swallowing failures (`|| true`) — a partial-failure here leaves some
  squads updated and others not, with no reported inconsistency.
- Evidence: `lib/panel/node/api.sh:32-90`.
- Related contract: 13.
- Risk: matches contract 13 for the POST/lookup finding (not
  re-scored); the squad-loop partial-failure behaviour is new evidence
  for the same contract's "partial failure behaviour" question — P2.
- Target implication: none beyond contract 13's existing target
  behaviour; the squad-loop detail is additional evidence for whoever
  designs the RECONCILE step contract 13 already calls for.

**IDEM-02 — `panel_setup_api`'s existing precedent is lookup-then-
delete-then-create, not lookup-then-reuse**
- Location: `lib/panel/api.sh:50-53`
- Current behaviour: looks up any existing `config-profile` named
  `Default-Profile`, and if found, **deletes** it before unconditionally
  creating a new one — this is the "existing in-repo precedent" that
  `docs/CONTRACTS.md` contract 13 and `docs/ARCHITECTURE.md` cite as
  the pattern to generalize from. Worth being precise that the
  precedent is delete-and-recreate, not idempotent reuse — a
  reconcile/repair implementation modeled directly on this precedent
  would still not be a true no-op on a repeated run (it would delete
  and recreate every time, not skip when nothing changed).
- Evidence: `lib/panel/api.sh:50-53`.
- Related contract: 13.
- Risk: P2 — nuance on an already-cited precedent, not a new
  violation.
- Target implication: none beyond contract 13's existing target
  behaviour; flagged so the "generalize from this precedent" migration
  note doesn't assume the precedent is already idempotent-reuse when
  it's actually delete-and-recreate.

**IDEM-03 — Telemt config field toggle and full-rewrite paths both skip
idempotency questions differently**
- Location: `lib/telemt/menu.sh:276` (single-field `sed -i`, no
  before/after check) vs. `lib/telemt/migrate.sh:190-199` (full
  config re-sent to a remote host on every migration run, no lookup of
  remote state first)
- Current behaviour: the menu toggle unconditionally rewrites
  `use_middle_proxy` every time the menu action is chosen (harmless
  since it's operator-triggered and idempotent by construction — same
  value in, same value out). The migration path always sends the full
  rewritten config to the remote host via `RRUN "cat > ..."` with no
  check of what's already there.
- Evidence: `lib/telemt/menu.sh:276`, `lib/telemt/migrate.sh:190-199`.
- Related contract: 13 (idempotency), loosely — Telemt isn't contract
  13's primary subject (that's Remote Node), but the same question
  applies.
- Risk: P3 — both are operator-invoked, low-frequency actions; no
  observed partial-failure handling gap beyond what's already true of
  `RRUN` in general (§8).
- Target implication: none — flagged only as supporting evidence,
  no contract currently covers Telemt idempotency specifically.

## 10. Telemt current data paths

Per the task's instruction, this section is CURRENT-only — no
`collect_stats.py`, `stats.db`, or `status_render.py` exist on `beta`,
and none were created for this audit.

| Endpoint | Caller(s) | Purpose | Read/Write | Plane |
|---|---|---|---|---|
| `GET /v1/users` | `lib/telemt/api.sh:39`, `core.sh:136`, `users.sh:121,128,172,211`, `migrate.sh` (3 sites) | list/add/delete users, migration snapshot | Read (+ `POST`/`DELETE` variants for mutation) | management-plane |
| `GET /v1/stats/summary` | `lib/telemt/menu.sh:124` (`telemt_menu_status`) | live interactive status display | Read | status-plane |
| `GET /v1/runtime/gates` | `lib/telemt/menu.sh:125` (same function) | live interactive status display | Read | status-plane |
| `GET /v1/system/info` | `lib/telemt/menu.sh:126` (same function) | live interactive status display | Read | status-plane |

This matches `docs/CONTRACTS.md` contract 14's existing citation of
`telemt_menu_status()` (`lib/telemt/menu.sh:120-126`) exactly — no new
endpoints or call sites found beyond what contract 14 already records.
No historical/ingestion-plane code exists yet, confirming contract
11/14's "N/A, implementation deferred" status is still accurate.

## 11. Service lifecycle

| Service | Install | Enable | Start/Stop/Restart | Status check | Uninstall | Owner |
|---|---|---|---|---|---|---|
| Panel (`remnawave`, `remnawave-nginx`/`-caddy`, etc.) | `lib/panel/install.sh`, `compose.sh` (`docker compose up -d`) | implicit (compose) | `docker compose restart <svc>` (`mgmt_script.sh:77`) | `docker inspect`, `curl .../api/auth/status` (`api.sh:18-21`) | not found as a single path — multiple partial-removal sites | `lib/panel/**` |
| Hysteria2 (`hysteria-server`) | `lib/hy2/install.sh` (writes unit, `systemctl enable`) | `systemctl enable` (3 sites) | `systemctl restart/stop hysteria-server` (9 sites combined) | `systemctl is-active --quiet` | `lib/hy2/install.sh` has an uninstall path (`rm -f "$HYSTERIA_CONFIG"` etc., line 486) | `lib/hy2/**` |
| `hy-webhook` | `lib/hy2/install.sh` | not explicitly found separate from install | `systemctl restart hy-webhook` (8 sites — the most-restarted unit in the repo) | not found | not found | `lib/hy2/**` |
| `hy-merger` | `lib/hy2/menu.sh` (writes unit at install time) | `systemctl enable --now` | `systemctl restart hy-merger` (1 site) | `systemctl is-active --quiet` | not found | `lib/hy2/**` |
| Telemt | `lib/telemt/install.sh` | `systemctl enable` (3 sites) | `systemctl start/stop/restart telemt` (start 2, stop 6, restart 5) | `systemctl status telemt` (1 site) | `lib/telemt/menu.sh` has a disable path (`systemctl disable telemt`) | `lib/telemt/**` |
| `remna-sub-injector` | not located in this pass — referenced only at start/stop/restart/enable (1 site each) | `systemctl enable` | start/stop/restart (1 each) | not found | not found | `lib/panel/**` (inferred from naming, not independently verified this round) |
| `docker`, `cron` | system packages | `systemctl enable docker` (3 sites), `systemctl enable cron`/`start cron` (1 each) | N/A | N/A | N/A | `lib/common/ssh.sh` (remote bootstrap) |

**SVC-01 — no service currently has an audited "what happens on partial
install failure" path**
- Location: repo-wide (see table)
- Current behaviour: install flows generally proceed linearly (write
  config → write unit → `daemon-reload` → `enable`/`start` → check
  `is-active`) and `warn` on failure, but a failure partway through
  (e.g. unit written, `enable` fails) is not consistently rolled back
  or cleaned up across domains — this matches the traps/cleanup gap
  already recorded in contract 12 (0 `INT`/`TERM` traps repo-wide),
  extended here to service-install sequences specifically rather than
  only SSH/remote operations.
- Evidence: representative pattern at `lib/hy2/menu.sh:283-290`
  (`hy-merger` install: `daemon-reload` → `enable --now` → `is-active`
  check → `warn` and `return 1` on failure, with no cleanup of the
  already-written unit file).
- Related contract: 12.
- Risk: P2 — consistent with contract 12's existing framing, applied
  to one more category of operation (local service install, not just
  remote/SSH).
- Target implication: none beyond contract 12's existing target
  behaviour.

## 12. Contract violations

All violations found in this audit that trace to one of the 14
contracts are already itemized above with their contract number; no
new contract-level violation was found that isn't already represented
in `docs/CONTRACTS.md`'s own "Current violation" rows. Summary of
where this audit adds **new evidence** to an existing contract (rather
than just re-confirming the existing citation):

- Contract 6 (timeout policy): `telemt_api()` already has partial
  compliance (HTTP-02) — evidence not previously on record.
- Contract 7 (secrets): `$PANEL_TOKEN_FILE` permissions add one more
  concrete instance (CFG-03).
- Contract 8 (`.env` atomicity): the duplication in CFG-01, and the
  in-repo atomic-write precedent already existing for
  `$HYSTERIA_CONFIG` (MUT-01).
- Contract 13 (idempotency): the `internal-squads` partial-failure
  loop (IDEM-01) and the precise "delete-then-recreate, not reuse"
  nature of the cited precedent (IDEM-02).

## 13. Migration blockers

- **MB-01**: CFG-01's duplication means any `.env`-atomicity fix
  (contract 8) must update both `lib/panel/mgmt_script.sh`'s heredoc
  and `lib/panel/migrate.sh`, or resolve the duplication first —
  otherwise the fix silently only half-lands.
- **MB-02**: HTTP-03's inconsistent response-shape validation means
  contract 4's eventual fix needs a full call-site enumeration (still
  not done — contract 4 itself already says "not independently
  re-audited line-by-line" and this audit did not close that gap
  either, per its own scope limits).
- **MB-03**: EP-02 (inert module integrity check) isn't blocking any
  of the 14 contracts, but is worth resolving before any migration
  work that increases reliance on the `curl | bash` fetch-without-local-
  checkout path.

No blocker was found that isn't already implied by one of the 14
existing contracts' own "Migration implication" rows.

## 14. Open questions requiring evidence

- PY-02's boundary question (does single-field `python3 -c` JSON
  extraction count as "exceeding ~3 lines of data-logic" under
  contract 9) is not resolved by this audit and needs a decision, not
  more evidence-gathering — flagged here rather than answered.
- SVC-01's "no consistent partial-install cleanup" finding was sampled
  (one representative site per service, not all install paths
  individually re-walked) — a full per-service install-failure audit
  would need more time than this pass allowed.
- CFG-03's `$PANEL_TOKEN_FILE` permissions were checked for a
  `chmod`/creation-mode call near its write site and none was found,
  but the umask in effect at runtime (which would determine the
  file's actual default permissions) was not traced — stated as
  "no explicit permission-hardening found," not "confirmed
  world-readable."

---

*This document does not modify, supersede, or restate `docs/
CONTRACTS.md` or `docs/ARCHITECTURE.md`. Where a finding here implies
a target-side decision, it points at the existing contract or
architecture section that already governs it rather than proposing a
new one.*
