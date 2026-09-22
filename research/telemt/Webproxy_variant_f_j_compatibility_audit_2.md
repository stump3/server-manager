# TeleMT WEBPROXY — Implementation Plan (variant-f-j @ 70485b8)

*Planning only. No code changed. No commits. No pushes. No new MODE. No
Desired State / Plan IR / Capability Registry invented.*

**Branch state note:** `variant-f-j` moved from `e74c74c` (the audit's
baseline) to `70485b8` between that audit and this plan. Diffed the two
directly (`git diff --name-only`) — the 8 new commits touch only
`lib/migrate.sh`, `lib/telemt/migrate.sh`,
`lib/sripts/tests/test_migrate_all_mtproxy_failure_continuation.sh`,
`lib/sripts/tests/test_telemt_migrate_colocate.sh`, and four new
`poc/network-inspect/executors/*` files (an "Executor" layer for
artifact validation — unrelated to WEBPROXY, not used below). Nothing in
that diff touches `lib/core/*`, `lib/panel/nginx/*`, `lib/telemt/install.sh`,
`lib/telemt/core.sh`, `lib/telemt/api.sh`, or `docs/*`. Every file read for
this plan was re-checked at `70485b8` directly (not carried over from the
audit unread) — where the diff *did* touch a file relevant here
(`test_telemt_migrate_colocate.sh`), that file's new content is what's
cited below (§4, §14), not the audit's prior knowledge of it.

---

## 1. Re-reading the actual target (what this plan is grounded in)

Read at `70485b8` in this session, in full or by targeted section:
`lib/core/topology.sh`, `lib/core/port_allocation.sh` (full),
`lib/core/deployment.sh` (TELEMT fields + validation block),
`lib/core/runtime_component.sh` (header + enum), `lib/panel/nginx/variant_f.sh`
(full, 355 lines), `lib/panel/nginx/variant_j.sh` (full, 338 lines),
`lib/telemt/install.sh` (`telemt_write_config()` in full, plus its UFW
lines), `lib/telemt/api.sh` (`telemt_fetch_links()` in full),
`lib/telemt/core.sh` (lifecycle/state helpers), `lib/panel/cli.sh` (TeleMT
domain/port collection block), `lib/panel/cert.sh` (`panel_issue_cert()`
call sites), `lib/sripts/tests/test_telemt_migrate_colocate.sh` (full, at
its current `70485b8` content), `docs/edge_contracts.md`,
`docs/TELEMT_CONFIG.md`, `docs/MULTI_PROTOCOL_L4_INGRESS.md` and
`_REVIEW.md`. Also directly cloned and read **actual current upstream
TeleMT source** (`github.com/telemt/telemt @ 935b5a3`, the same commit the
prior research report anchored on) — `src/config/types/server.rs`,
`src/config/load/validate_web.rs` — to settle a contradiction the two
project docs left open (§4).

Not re-read this pass (unchanged from the prior audit's own "not
inspected" list, and still not needed to answer what's below): `lib/telemt/menu.sh`
and `lib/telemt/users.sh` beyond their function-name inventory;
`lib/core/adapter_webserver.sh` / `adapter_reality.sh` internals (nothing
in this plan touches WEB_SERVER or REALITY's adapters); the new
`poc/network-inspect/executors/*` files (unrelated, per the diff above).

---

## 2. Implementation boundary

**WEBPROXY is:** a second, optional TeleMT transport/listener
(`transport = "web"`) — additive to the TeleMT `RuntimeComponent` that
already exists for classic MTProto, following the exact precedent
`DEPLOYMENT_TELEMT_*` already set for classic TeleMT's own
optionality.

**WEBPROXY is not**, and this plan does not produce:
- A new MODE — F and J's `topology.sh` capability lists are untouched
  (§8; matches classic TeleMT's own precedent of living in `Deployment`,
  not `Topology`).
- A new Deployment architecture — `core_resolve_deployment()`'s existing
  shape gains three more optional fields, following the exact
  `TELEMT_PRESENT/DOMAIN/PORT` triple already there (§7).
- A generic HTTP proxy or WebSocket framework — this plan wires exactly
  one new upstream (TeleMT's own WEB listener) through exactly one new
  nginx vhost, reusing directives already in `variant_f.sh`/`variant_j.sh`
  (§9). No new abstraction layer.
- A new lifecycle framework — WEB reuses `lib/telemt/core.sh`'s existing
  systemd/Docker start/stop/status functions verbatim; the TeleMT process
  doesn't fork or multiply, it gains one more `[[server.listeners]]` entry
  in the one config file it already writes (§14).
- A Capability Registry / Desired State / Plan IR implementation — these
  remain what they are today: vocabulary in `docs/edge_contracts.md` and
  an explicitly out-of-scope `poc/`, per `port_allocation.sh:62-64`. This
  plan adds rows to the *existing* `PortAllocation`/`Listener` shapes, not
  a new registry to hold them.

---

## 3. Target runtime topology (verified against the actual generators, not assumed)

For **shared** layout (WEB rides the existing `:443` SNI router — the
only layout this plan designs; **split** layout, a dedicated public port,
is noted as a config-only variant in §5 and not otherwise developed here
since nothing in the evidence suggests it needs different nginx/TeleMT
wiring beyond swapping the map entry for a second `stream{} server{}`
block, the same shape J's own XHTTP leg already uses):

```
Internet
  │
  ▼
outer nginx stream{} server{ listen 443; ssl_preread on; proxy_protocol on; }
  │  (map $ssl_preread_server_name — SNI peek only, raw bytes forwarded, unchanged existing branches)
  ├── PANEL_DOMAIN / SUB_DOMAIN  → panel_and_sub  (existing)
  ├── TELEMT_DOMAIN (classic)    → telemt         (existing)
  ├── default                    → xray_reality / xray_vision (existing)
  └── TELEMT_WEB_DOMAIN (NEW)    → panel_and_sub  ← reuses the SAME upstream/port
                                                     Panel/Sub already use — see below
        │
        ▼
    internal nginx http{} block, same listen 127.0.0.1:$F_NGINX_HTTPS_PORT / $J_NGINX_HTTPS_PORT
    ssl proxy_protocol; port Panel/Sub already terminate on
        │
        ├── existing server{server_name PANEL_DOMAIN} — unchanged
        ├── existing server{server_name SUB_DOMAIN}   — unchanged
        └── NEW server{server_name TELEMT_WEB_DOMAIN}  ← third name-vhost, same port
                ├── TLS termination (real cert, own domain — §11)
                ├── $proxy_protocol_addr available (same "ssl proxy_protocol;" listen flag)
                ├── proxy_set_header X-Forwarded-For $proxy_protocol_addr;  (same pattern as remnawave/remnawave-sub locations)
                ├── proxy_http_version 1.1; proxy_set_header Upgrade/Connection $connection_upgrade;
                │     (the SAME map $http_upgrade $connection_upgrade already declared once per http{} block)
                └── proxy_pass http://telemt_web;   (NEW upstream, plain http, loopback)
                        │
                        ▼
                TeleMT WEB listener (127.0.0.1:$TELEMT_WEB_PORT, NEW loopback port,
                distinct from $TELEMT_PORT — a WEB [[server.listeners]] entry is a
                separate entry from the classic one, per TeleMT's schema)
```

This is **not** the shape sketched in this task's own brief (a dedicated
"internal TLS/HTTP nginx" instance separate from Panel/Sub's). The actual
F/J generators already run exactly one internal `http{}` context per
variant, and Panel/Sub already prove that context can host more than one
`server_name` vhost on the same loopback port (`variant_f.sh:209-279`,
`variant_j.sh:155-225`). Reusing that same context/port for WEB is the
smaller change — no second internal nginx process, no second internal
port, no second `ssl proxy_protocol;` listen line to maintain.

**Ownership answers, stated explicitly:**
- Public listener: the existing shared `:443` `stream{}` server (unchanged binary — one new `map` line).
- Internal listener: the existing `127.0.0.1:$F_NGINX_HTTPS_PORT` / `$J_NGINX_HTTPS_PORT` (unchanged port number — one new `server{}` block on it).
- SNI ownership at the outer layer: the existing `map $ssl_preread_server_name` (one new case).
- SNI/TLS ownership at the inner layer: the new `server_name ${TELEMT_WEB_DOMAIN}` vhost's own real certificate (§11) — nginx's own inner TLS handshake, exactly like Panel/Sub's.
- HTTP/WebSocket termination point: nginx's inner `server{}` block for WEB — `proxy_pass http://telemt_web;` with `proxy_http_version 1.1;` and the existing `$connection_upgrade` map (already declared in this same `http{}` block for remnawave/remnawave-sub, reused verbatim).
- PROXY protocol termination point: the SAME inner listener (`ssl proxy_protocol;` on the shared `listen` line — already there for Panel/Sub, applies to the new vhost automatically since it's a directive on the `listen` socket, not per-`server_name`).
- X-Forwarded-For generation point: the new WEB `location /` block, `proxy_set_header X-Forwarded-For $proxy_protocol_addr;` — identical line to the existing remnawave/remnawave-sub locations.
- TeleMT listener: a second `[[server.listeners]]` entry in the SAME `telemt.toml` this project already writes (`telemt_write_config()`), not a second config file or process.
- Runtime owner: `lib/telemt/*` (unchanged — same `RuntimeComponent{type=telemt}`).
- Integration owner: Panel (nginx generation + Deployment threading), same as classic TeleMT — Panel never becomes TeleMT's runtime owner (matches `edge_contracts.md`'s existing invariant).

---

## 4. PROXY protocol design — the one point this plan had to resolve a real contradiction on

**The contradiction found:** `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md` (dated
2026-08-25, claims direct verification against `github.com/telemt/telemt`'s
`config.toml`) states `proxy_protocol` is "a top-level, single, process-wide
`[server]` field... there is no per-listener equivalent anywhere in the
schema" and rates this "VERIFIED" against upstream issue #777. But
`lib/telemt/install.sh`'s `telemt_write_config()` (dated 2026-09-04, i.e.
ten days *after* that review) deliberately writes a **per-listener**
override instead (`proxy_protocol = true` inside `[[server.listeners]]`,
not under `[server]`), with a comment explicitly citing
`docs/TELEMT_CONFIG.md`'s documented per-listener field as its reason for
doing so.

**Resolution, verified directly against upstream source in this session**
(cloned `telemt/telemt @ 935b5a3` — the same commit the project's own
research report already anchors on, i.e. more recent than either project
doc):
- `src/config/types/server.rs:448-450` — a real struct field:
  `/// Per-listener PROXY protocol override. When set, overrides global
  server.proxy_protocol.` `pub proxy_protocol: Option<bool>`.
- `src/config/load/validate_web.rs:158-163` — WEB's own validation reads
  the **effective** value as `listener.proxy_protocol.unwrap_or(config.server.proxy_protocol)`
  and rejects the config if that effective value is `true`, with the exact
  message `"server.listeners[{idx}].proxy_protocol must be false for
  transport=web; WEB identity is accepted only from the configured L7
  header"`.

**Conclusion:** the per-listener override is real in the TeleMT version
this project's own research already targets. `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md`'s
Aug-25 finding was accurate for whatever upstream state it checked then;
upstream has since shipped issue #777's request. `install.sh`'s Sep-4 code
is correct, not a latent bug — and this is independently confirmed by
`lib/sripts/tests/test_telemt_migrate_colocate.sh` (current at `70485b8`),
whose test #2 and #5 assert, against real generated TOML via
`telemt_detect_listener_proxy_protocol()`, that `ip = "127.0.0.1"` +
`proxy_protocol = true` under `[[server.listeners]]` is exactly what a
co-located install produces and what migration must preserve
byte-for-byte ("THE bug" comments mark this as a previously-fixed
regression, i.e. this shape is deliberately protected, not incidental).

**The one binding rule this leaves for WEB, stated precisely because
`.unwrap_or()` makes the wrong default dangerous:** WEB's
`[[server.listeners]]` entry **must explicitly write** `proxy_protocol =
false` whenever the process also has `[server].proxy_protocol = true` set
(i.e. whenever classic TeleMT is co-located in the same process). Omitting
the field on the WEB listener is **not safe** — `unwrap_or()` would fall
back to the global `true` and TeleMT would refuse to start the whole
config (validation error), not just the WEB listener.

Answering the brief's explicit questions:
- Where does nginx receive PROXY? Never, for WEB — WEB's path never goes through a `stream{}` `proxy_pass` leg at all; it's reached only via the inner `http{}` vhost, an ordinary reverse-proxy hop.
- Where does nginx terminate it? N/A for WEB specifically (see above) — but the *outer* `stream{}` server's `proxy_protocol on;` still applies process-wide to that socket for the branches that DO use it (Panel/Sub, classic TeleMT, Vision/REALITY) — WEB's traffic reaches the inner listener via the SAME outer socket (its SNI is matched by the SAME `map`), so it DOES receive a PROXY v1 preamble at the outer hop like every other branch (§6/§10 of the prior audit's finding stands: this directive can't be scoped per-SNI-branch). The inner nginx listener (`ssl proxy_protocol;`) is what actually **consumes** that preamble for the WEB branch — same as it already does for Panel/Sub.
- Which nginx server has `proxy_protocol` enabled? Both: the outer `stream{}` server (unavoidably, block-wide) and the inner `127.0.0.1:$F/J_NGINX_HTTPS_PORT` `listen ... ssl proxy_protocol;` line (already there, unchanged).
- Which internal listener does NOT receive PROXY? None in this design — TeleMT's WEB listener itself never sees a PROXY preamble; it's the inner nginx→TeleMT hop (plain `proxy_pass http://telemt_web;`) that carries no PROXY protocol at all, only `X-Forwarded-For`.
- Where is `$proxy_protocol_addr` available? In the inner nginx `server{server_name TELEMT_WEB_DOMAIN}` block, same as Panel/Sub's.
- Where is `X-Forwarded-For` created? In that same block's `location /`, exactly mirroring the existing `proxy_set_header X-Forwarded-For $proxy_protocol_addr;` lines already in the Panel/Sub locations.
- Does TeleMT receive PROXY? No — the WEB listener must have `proxy_protocol = false` explicitly (see above). Only the classic listener (a different `[[server.listeners]]` entry, reached via a *different* nginx path — direct `stream{}` passthrough, no inner nginx hop) receives PROXY, and does so directly from the outer stream, not through the inner HTTP layer.
- Does TeleMT get the real client IP via HTTP headers instead? Yes — via TeleMT's own `censorship`/`web`-side config field for reading a trusted forwarded-for header (name not independently re-verified against upstream source this pass; the prior research report names it `web_client_ip_source = "x_forwarded_for"` — treat that exact field name as REPORT-SOURCED, not re-verified against `server.rs`/`validate_web.rs` in this session, and confirm it before writing config-generation code).

---

## 5. Listener model

```
Listener
  id                 : "TeleMT-WEB (F or J)"
  transport          : tcp
  bind               : 0.0.0.0 (outer, shared with existing :443) / 127.0.0.1 (TeleMT's own WEB socket)
  public_port        : 443  (shared layout — this plan's only developed layout)
  internal_port      : NONE at the nginx layer — WEB reuses $F_NGINX_HTTPS_PORT / $J_NGINX_HTTPS_PORT
                        (7443 / 7444) unchanged, via a third server_name vhost (§3). A genuinely NEW
                        internal port only exists one hop further in: TeleMT's own loopback WEB
                        listener port ($TELEMT_WEB_PORT), which nginx's new upstream telemt_web
                        points at.
  public             : yes
  protocol           : NEEDS A FIFTH VALUE on the existing four-value enum
                        (vision | xhttp | panel_sub | telemt) → add "telemt_web".
                        Not a new field — same enum, one more member, matching how the row-based
                        table in port_allocation.sh already keys everything off (topology, role).
  tls_mode           : the one value this plan's WEB row genuinely differs on from every existing
                        row: Vision/telemt/panel_sub are each either full "passthrough" (Vision,
                        classic TeleMT) or terminated at the SAME point they're routed to
                        (panel_sub). WEB is also "terminated at the routed-to point" — i.e. it's
                        the SAME tls_mode value panel_sub already has, not a new value. (The prior
                        audit's draft treated this as needing a new tls_mode concept; re-reading
                        the actual generator code shows panel_sub already IS this shape — no new
                        value needed.)
  routing_mode       : sni (existing value, shared layout)
  proxy_protocol_in  : yes — inherited from the shared outer stream{} block, same as every branch on :443
  proxy_protocol_out : NEW distinction needed here (existing rows only have "yes"/"yes (in)"/"no" as a single
                        combined proxy_protocol_* field — see port_allocation.sh's own
                        `core_port_allocation_proxy_protocol` vocabulary): WEB's row needs the SAME
                        "yes (in)" value panel_sub already uses (PROXY consumed at nginx, not forwarded
                        raw) — reuse that existing vocabulary value, do not invent a new one.
  backend            : loopback TeleMT WEB listener (127.0.0.1:$TELEMT_WEB_PORT)
  runtime_owner      : TeleMT (unchanged — reuses port_allocation.sh's existing "TeleMT" owner string)
  integration_owner  : nginx for the routing hop / Panel for config-threading (matches panel_sub's
                        existing owner value exactly — "nginx" — since WEB's shape is the panel_sub
                        shape, not the telemt-classic shape)
```

**Correction versus the prior audit's draft**: re-reading the actual
generator code this pass shows WEB's correct analogy is **panel_sub**,
not "a new fourth shape." `core_port_allocation_proxy_protocol()`'s
existing three-value vocabulary (`"yes"`, `"yes (in)"`, `"no"`) already
has the exact value WEB needs (`"yes (in)"` — panel_sub's value). Nothing
about the `PortAllocation`/`Listener` contract's *shape* needs to change;
only the `protocol` enum needs its fifth member.

---

## 6. Port allocation

New rows, following `_core_port_allocation_row()`'s exact
`public_port|internal_port|protocol|proxy_protocol|owner` shape
(`lib/core/port_allocation.sh:135-148`):

```
"F:telemt_web")    echo "443|DYNAMIC|web/tls|yes (in)|TeleMT" ;;
"J:telemt_web")    echo "443|DYNAMIC|web/tls|yes (in)|TeleMT" ;;
```

- `public_port=443`: same shared entry as `panel_sub`/`telemt`/`vision`, per §3/§5.
- `internal_port=DYNAMIC`: following the EXACT precedent the file already
  established for `telemt`'s row (§ file header: "TELEMT'S internal_port:
  NOT a fixed topology fact... it is whatever the operator configured at
  CLI time... `core_port_allocation_internal()` fails (exit 1) for
  role=telemt specifically, on purpose"). `telemt_web`'s internal port
  (TeleMT's own loopback WEB socket) is exactly as deployment-specific as
  classic TeleMT's — same DYNAMIC/fail-on-purpose treatment,
  `core_port_allocation_role_is_valid()`'s case statement gains `telemt_web`
  alongside `telemt`.
- `protocol="web/tls"`: a new label, following the existing
  `"reality/tcp"` / `"http/tls"` / `"reality/xhttp"` / `"mtproto/tls"`
  naming convention (transport/security-mode pairs).
- `proxy_protocol="yes (in)"`: per §5, reusing `panel_sub`'s existing value verbatim.
- `owner="TeleMT"`: reusing `telemt`'s existing value verbatim (nginx
  terminates PROXY protocol and TLS, but TeleMT is still the process that
  ultimately owns/terminates this traffic's application layer — same
  reasoning `port_allocation.sh` already applies to classic `telemt`'s
  owner field, which is `"TeleMT"` despite nginx also being in that
  path).

No new **canonical source** — `_core_port_allocation_row()` remains the
single table. No **mirror** to update — `variant_f.sh`/`variant_j.sh`
don't read this file (by design, per the file's own "WHY THIS FILE DOES
NOT READ $F_*/$J_* DIRECTLY" section) so adding these two rows here does
not, by itself, change any generated `nginx.conf`; the actual new port
number(s) still get interpolated directly in the generator functions
(§9), and `lib/sripts/tests/test_port_allocation.sscript` (existing
convention, per the file's header comment) is where these two new rows'
literals get pinned as a regression check, mirroring how `F:xhttp`'s
`"19444"` is pinned today.

**Collision constraint**: `TELEMT_WEB_PORT` (the new loopback TeleMT
socket) must not collide with any existing reserved loopback port for the
chosen variant. `cli.sh`'s existing TeleMT-port collision check (line
~264-267, `[ "$TELEMT_PORT" = "$_p" ] && _collision=1`) is the pattern to
extend — add `$TELEMT_WEB_PORT` to both sides of that comparison (checked
against the same reserved-port set, and the reserved-port set gains
`$TELEMT_WEB_PORT` once chosen).

---

## 7. Deployment / config threading

`lib/core/deployment.sh`'s existing `DEPLOYMENT_TELEMT_*` triple
(`PRESENT` / `DOMAIN` / `PORT` — lines 98-100, 150-152, 184-186) is the
precedent to mirror exactly:

```
DEPLOYMENT_TELEMT_WEB_PRESENT   "1" | "0"
DEPLOYMENT_TELEMT_WEB_DOMAIN    "" when PRESENT=0
DEPLOYMENT_TELEMT_WEB_PORT      "" when PRESENT=0   (TeleMT's own loopback WEB socket)
```

Three fields, not more. Categories from the brief's list, checked against
what actually has a concrete consumer:
- **enable/disable** → `DEPLOYMENT_TELEMT_WEB_PRESENT` (consumer: the same conditional-generation gate `TELEMT_DOMAIN`-non-empty already uses in `variant_f.sh`/`variant_j.sh`, §9).
- **domain/SNI** → `DEPLOYMENT_TELEMT_WEB_DOMAIN` (consumer: the new `map` line + new `server_name`, §9).
- **internal/listener port** → `DEPLOYMENT_TELEMT_WEB_PORT` (consumer: the new `upstream telemt_web` line, §9, and `telemt_write_config()`'s new `[[server.listeners]]` entry, §8).
- **public port** → NOT a new field — shared layout reuses the existing `443` constant already baked into both generators; nothing to thread.
- **path** → NOT added — TeleMT's WEB carrier is Host-header-discriminated at TeleMT's own layer (REPORT-SOURCED), not path-based at the nginx layer; nginx's `proxy_pass http://telemt_web;` forwards the full request untouched, no `location` sub-path needed beyond the single `location /` block panel_sub already uses.
- **WebSocket settings** → NOT a new field — reuses the existing `map $http_upgrade $connection_upgrade` already declared once per `http{}` block.
- **frontend mode** → NOT a new field — always nginx in this plan's shared-layout design; a future split-layout addition would be a value on `routing_mode` (already an existing Listener field), not a new Deployment field.
- **TLS mode** → NOT a new field — always "terminate-and-forward" per §5, no variability to encode yet.

Validation additions to `lib/core/deployment.sh`'s existing block (lines
~293-302 pattern, mirrored):
```
if [ "$DEPLOYMENT_TELEMT_WEB_PRESENT" = "1" ]; then
    [ -z "$DEPLOYMENT_TELEMT_WEB_DOMAIN" ] && CORE_VALIDATION_ERRORS+=("telemt_web: present but domain is empty")
    [ -z "$DEPLOYMENT_TELEMT_WEB_PORT" ]   && CORE_VALIDATION_ERRORS+=("telemt_web: present but port is empty")
    # NEW, not mirrored from classic (classic has no analogous check):
    [ "$DEPLOYMENT_TELEMT_WEB_DOMAIN" = "$DEPLOYMENT_TELEMT_DOMAIN" ] && CORE_VALIDATION_ERRORS+=("telemt_web: domain must differ from classic telemt domain when both share :443")
else
    [ -n "$DEPLOYMENT_TELEMT_WEB_DOMAIN" ] && CORE_VALIDATION_ERRORS+=("telemt_web: not present but domain is set")
    [ -n "$DEPLOYMENT_TELEMT_WEB_PORT" ]   && CORE_VALIDATION_ERRORS+=("telemt_web: not present but port is set")
fi
```
The domain-must-differ check has no classic-TeleMT analog because classic
never had a second same-process SNI-sharing sibling to collide with —
this is a genuinely new invariant, not a copy-paste omission.

---

## 8. TeleMT configuration (`telemt_write_config()`, `lib/telemt/install.sh`)

Exact TOML delta, following the file's own `TELEMT_COLOCATE` conditional-block
pattern (lines 88-92) rather than a parallel, differently-shaped mechanism:

```bash
# NEW, mirrors the existing TELEMT_COLOCATE block immediately above it:
local web_listener_block=""
if [ "${TELEMT_WEB_ENABLE:-0}" = "1" ]; then
    web_listener_block=$'\n\n[[server.listeners]]\n'"ip = \"127.0.0.1\""$'\n'"port = ${web_port}"$'\n'"proxy_protocol = false"$'\n\n[web]\n'"carrier = \"...\""$'\n\n[[web.vhosts]]\n'"host = \"${web_domain}\""$'\n'"..."
fi
```

Marked explicitly as **NOT fully specified here** — the exact `[web]` /
`[[web.vhosts]]` / `[[web.vhosts.profiles]]` field names and required
values were not independently re-verified against `server.rs`/a
`web.rs`-equivalent in this session (only `proxy_protocol`'s validation
path was checked, §4). Before writing this block for real:
1. Verify the exact `[web]`/`[[web.vhosts]]` schema against
   `src/config/types/` in the pinned upstream commit (935b5a3 per the
   research report — re-confirm the version this project's
   `TELEMT_GITHUB_REPO`/`telemt_pick_version()` actually resolves to
   before trusting that pin).
2. Confirm the `port` field belongs at the `[[server.listeners]]` level
   (as this project's existing classic entry has no explicit `port =`
   line — it inherits the top-level `[server] port = $port` — meaning
   TeleMT's schema may or may not support **two different ports on two
   listeners in one config** at all; this is a genuine, concrete, currently
   **UNVERIFIED** question this plan cannot answer from evidence gathered
   so far and must not guess at, since if a single `[server] port` is
   shared across all listeners, WEB cannot have its own distinct loopback
   port the way this whole plan assumes).

**This is a STOP CONDITION (§20)** — not a detail to fill in while coding.
Server-manager's job (writing the file, threading the port) is
independent of and downstream from this question, but the file's shape
depends on the answer.

---

## 9. Nginx implementation

Both generators (`variant_f.sh`, `variant_j.sh`) get the same three
additions, since both already carry the identical `panel_and_sub` +
TeleMT-classic-branch machinery this reuses:

**Outer `stream{}` (per file, additive, same "append to end of preceding
line" discipline `TELEMT_MAP_LINE` already uses to preserve byte-identity
in the disabled case — `variant_f.sh:109-128`, `variant_j.sh:100-105`):**
```
local TELEMT_WEB_MAP_LINE=""
if [ -n "$TELEMT_WEB_DOMAIN" ]; then
    TELEMT_WEB_MAP_LINE=$'\n'"        ${TELEMT_WEB_DOMAIN}   panel_and_sub;"
fi
```
— appended into the SAME `map $ssl_preread_server_name` block, pointing
at the SAME `panel_and_sub` upstream Panel/Sub already declare (§3). **No
new outer upstream** — this is the one place this plan differs sharply
from a naive "give WEB its own upstream at every layer" design: WEB's
outer-layer destination is identical to Panel/Sub's.

**Inner `http{}` (new `server{}` block, placed alongside the existing
`server{server_name ${PANEL_DOMAIN}}` / `server{server_name ${SUB_DOMAIN}}`
blocks, same `listen 127.0.0.1:${F_NGINX_HTTPS_PORT} ssl proxy_protocol;` /
`${J_NGINX_HTTPS_PORT}` line):**
```
    server {
        server_name ${TELEMT_WEB_DOMAIN};
        listen 127.0.0.1:${F_NGINX_HTTPS_PORT} ssl proxy_protocol;   # (J: ${J_NGINX_HTTPS_PORT})
        http2 on;
        ssl_certificate     "/etc/letsencrypt/live/${TWC}/fullchain.pem";   # TWC = new cert-domain arg, §11
        ssl_certificate_key "/etc/letsencrypt/live/${TWC}/privkey.pem";
        location / {
            proxy_http_version 1.1;
            proxy_pass http://telemt_web;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header X-Forwarded-For $proxy_protocol_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
```
Deliberately omits `X-Real-IP` / `X-Forwarded-Host` / `X-Forwarded-Port` /
the cookie-auth `location ^~ /oauth2/` block / `error_page`/`@unauthorized`
machinery Panel's own vhost carries — those are Panel-specific
(cookie-gated admin UI), not generic to "an inner vhost on this port,"
and WEB has no equivalent requirement in any evidence gathered.

**New upstream (declared once per file, alongside the existing
`upstream panel_and_sub`/`upstream xray_reality`/`upstream telemt`
lines):**
```
local TELEMT_WEB_UPSTREAM=""
if [ -n "$TELEMT_WEB_DOMAIN" ]; then
    TELEMT_WEB_UPSTREAM=$'\n'"    upstream telemt_web { server 127.0.0.1:${TELEMT_WEB_PORT}; }"
fi
```

**No shared helper exists to reuse or duplicate** — both files are
already fully self-contained by design (`variant_j.sh`'s own header: "not
extending Variant F... nothing here is shared"), so this addition is
made independently in both files, matching that established convention,
not factored into a new shared function.

---

## 10. F vs. J

| | F | J |
|---|---|---|
| WEB branch attaches to | The single existing `:443` `stream{}` (F only ever has one public leg for this SNI router) | The SAME `:443` `stream{}` J already uses for Panel/Sub + classic TeleMT + Vision (J's *second* public port, `$J_XHTTP_PUBLIC_PORT`, is a separate, non-SNI, single-destination passthrough leg — WEB has no reason to touch it, per §3) |
| Interaction with XHTTP | None — F's XHTTP leg is `$F_XHTTP_PUBLIC_PORT` → `xray_xhttp_f`, an entirely separate `stream{} server{}` block (`variant_f.sh:144-156`); WEB never shares a block, port, or upstream with it | None — J's XHTTP leg is `$J_XHTTP_PUBLIC_PORT` → `xray_xhttp`, equally separate (`variant_j.sh:319-334`) |
| Interaction with Reality | None directly — WEB's SNI branch is matched *before* the `default` case that routes to `xray_reality`/`xray_vision`; adding a case ahead of `default` cannot change what unmatched SNIs do | Same reasoning, same non-interaction |
| Required nginx changes | §9, on `panel_generate_nginx_config_f()` | §9, on `panel_generate_nginx_config_j()` |
| Required ports | Reuses `$F_NGINX_HTTPS_PORT` (7443, unchanged) + one new loopback `$TELEMT_WEB_PORT` | Reuses `$J_NGINX_HTTPS_PORT` (7444, unchanged) + one new loopback `$TELEMT_WEB_PORT` (independently chosen from F's, per the existing "F and J never share a port number" convention both files already state) |

**Note on which function is actually live**: `variant_f.sh`'s own header
states its `panel_generate_nginx_config_f()` is **not currently the
active definition** — `lib/panel/nginx/config.sh` still carries the
sourced-and-called copy, not yet migrated to this file. Any real
implementation must confirm (re-check at implementation time, not assumed
from this plan) whether that migration has landed by then, and edit
whichever file `panel_generate_webserver_config()` actually dispatches to
— editing `variant_f.sh` alone could silently produce a dead change if
`config.sh`'s copy is still what's called.

**Shared implementation that can safely be factored**: none identified —
per §9, both files are independently self-contained by explicit design
choice already made for this codebase; this plan does not introduce a
first shared helper against that established grain.

---

## 11. TLS / domain / certificate ownership

- **New domain role**: `TELEMT_WEB_DOMAIN`, collected in `cli.sh`
  alongside the existing `TELEMT_DOMAIN` prompt (§7's collision check
  extended to include it: must differ from `PANEL_DOMAIN`, `SUB_DOMAIN`,
  `SELFSTEAL_DOMAIN`, **and now `TELEMT_DOMAIN` too**, since both TeleMT
  domains would share the same outer SNI router).
- **Certificate**: verified via `lib/panel/cert.sh:112,118,120` —
  `panel_issue_cert()` is already domain-generic (`local domain`
  parameter, no per-role hardcoding); it's called in a loop over
  `domains_arr=("$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN")`.
  **`TELEMT_DOMAIN` (classic) is conspicuously absent from that array** —
  correctly, since classic TeleMT terminates its own FakeTLS mimicry
  internally and nginx never presents a real certificate for that SNI
  branch (pure passthrough, §3). **`TELEMT_WEB_DOMAIN` is different and
  DOES need to join `domains_arr`** — WEB's inner vhost genuinely
  terminates real TLS and must present a real, browser/WebView-trusted
  certificate (REPORT-SOURCED requirement from the original TeleMT
  research). This is answerable with confidence, not a BLOCKED item: add
  `TELEMT_WEB_DOMAIN` to the array, gated the same way `TELEMT_ENABLED`
  already gates the prompt for the domain itself.
- **TLS termination**: nginx's inner vhost (§3/§9) — not TeleMT, not a
  passthrough.

---

## 12. Link generation

**CURRENT BEHAVIOR** (verified, `lib/telemt/api.sh:34-245`,
`telemt_fetch_links()`): server-manager does not construct any link
itself. It polls TeleMT's own `GET /v1/users` API and:
1. **Gates readiness** on the raw JSON response containing the literal
   substring `"tg://proxy"` anywhere (line 40) — if absent after
   `attempts_max` retries, it prints "API не ответил" and returns 1,
   *even if the API is actually up and returning valid (but classic-link-
   free) data*.
2. For display, reads each user's `links.tls` array and prints only
   `tls[0]` (line 126, 213) — nothing else in `links` is read or shown.

**REQUIRED WEB BEHAVIOR**: users with a WEB profile need their WEB link
(and/or WebSocket URL, per TeleMT's own link format for that transport —
not independently verified this session, marked below) surfaced the same
way `tls[0]` is today.

**FILES INVOLVED**: `lib/telemt/api.sh` (`telemt_fetch_links()`),
possibly `lib/telemt/users.sh` (`telemt_menu_links()` — name inventoried,
body not read this session) and `lib/telemt/migrate.sh` (two more
`"tg://proxy"` grep sites at lines 191/246, same readiness-gating pattern,
found by grep, not independently read this session — likely need the
identical fix if WEB-only migration should ever be supported, per §16's
"WEB without classic TeleMT if supported" test case).

**A genuine, concrete risk this plan surfaces (not previously flagged)**:
if a deployment ever has WEB-transport users but zero classic users (or
before any classic-format link has been issued), `telemt_fetch_links()`'s
`"tg://proxy"` substring-gate would **never fire**, and the function would
report "API не ответил" indefinitely even though the API is healthy — a
misleading failure mode. This needs its own fix (e.g. gate on
`telemt_api_ok()`'s existing `{"ok": ...}` check instead of a
link-format-specific substring), independent of adding WEB-link display.

**UNKNOWN DETAILS, left as explicit follow-ups, not invented**:
- The exact field name TeleMT's `/v1/users` response would use for a
  WEB link (`links.web`? `links.tls` extended with a second entry? a
  wholly separate top-level key?) — not verified against upstream API
  response schema this session.
- Whether a WebSocket URL is a distinct value from the "link" TeleMT
  returns, or whether one implies the other.
- `telemt_menu_links()`'s actual current body (not read this session) —
  needs checking before assuming it shares `telemt_fetch_links()`'s exact
  gating logic or has its own, separate copy.

---

## 13. Firewall / UFW

**Resolved, not left open** (contrary to the prior research's flag —
directly checkable from `install.sh`/`migrate.sh`/`panel/install.sh`):
- Public `:443` is already open — `lib/panel/install.sh:40`,
  `ufw allow 443/tcp comment 'HTTPS'`, unconditional for F/J, unrelated to
  TeleMT at all.
- `TELEMT_COLOCATE=1` (classic, today) **deliberately does not open any
  UFW rule for its own loopback port** — `install.sh:305,338`: "порт
  $port не публикуется через ufw — единственным public ingress является
  Nginx" (comment + code both confirm this is intentional, not an
  oversight). The `ufw allow ${port}/tcp` call (line 340) is reached only
  in the **standalone** (non-co-located) branch.
- **WEB, in this plan's shared-layout design, needs the identical
  treatment**: its loopback TeleMT-WEB port must **not** get a UFW rule
  either — nginx (already covered by the existing `:443` rule) is its
  only public ingress, exactly matching classic co-located TeleMT's
  already-established pattern. No new UFW code needed at all for the
  shared layout this plan develops.
- A split-layout WEB (dedicated public port, not developed in this plan)
  would need its own `ufw allow` call, following the standalone branch's
  existing pattern instead — noted for completeness, out of this plan's
  scope per §3.

---

## 14. Lifecycle / runtime

Reuses `lib/telemt/core.sh`'s existing functions **verbatim** — no new
lifecycle framework, confirmed by reading the actual functions:
- **install**: `telemt_download_binary()` — unchanged, one binary serves
  both transports (WEB is a config-only addition per upstream, not a
  separate binary/build).
- **configure**: `telemt_write_config()` — gains the new conditional
  block, §8.
- **start/restart**: existing systemd/Docker restart calls (unchanged —
  the same process, same unit/container, just a config with one more
  listener).
- **health**: `telemt_wait_api()` (checks `/v1/health` for `"ok":true`) —
  unchanged; this is a process-level health check, not per-listener, so
  it already covers a WEB-enabled instance with no modification.
- **status**: `telemt_detect_state()` (`core.sh:203-217`) currently
  classifies "integrated" vs. "standalone" purely from
  `ip=127.0.0.1 && proxy_protocol=true` on the (single) listener it reads.
  This function reads **one** listener's fields
  (`telemt_detect_listener_ip`/`telemt_detect_listener_proxy_protocol`,
  by name singular) — with two listener entries once WEB exists, this
  function's behavior against a WEB-enabled config is **UNVERIFIED**
  (does it read the first `[[server.listeners]]` block? Fail? Silently
  misreport?) and needs checking against the actual
  `telemt_detect_listener_ip()`/`telemt_detect_listener_proxy_protocol()`
  implementations (not read this session) before this plan's config
  changes ship, since a status-detection regression would be silent and
  easy to miss.
- **remove**: `telemt_menu_uninstall()` (`menu.sh:425`) — name
  inventoried, body not read this session; likely needs no change (it
  presumably removes the binary/config/unit wholesale, not per-listener)
  but not confirmed.
- **migration**: `lib/telemt/migrate.sh` and
  `lib/sripts/tests/test_telemt_migrate_colocate.sh` already prove the
  project takes "preserve unknown/future TOML fields verbatim" seriously
  (test #2's `"UNKNOWN future field survives (sni_override)"` check) —
  migration should, by that same already-tested mechanism, carry a WEB
  `[[server.listeners]]`/`[web]` block through unmodified **without any
  WEB-specific migration code being written at all**, provided the
  migration function's copy-and-substitute approach (proven in test #2)
  doesn't specifically enumerate/rebuild the listeners array (it doesn't,
  per that test's own "proves the fixed function instead copies the
  source config and substitutes only port/tls_domain" description) — this
  is a genuine, low-risk **already-covered** case, worth a new explicit
  test asserting it (§16) rather than new migration code.

---

## 15. Failure / safety cases

Using existing validation conventions (`CORE_VALIDATION_ERRORS` array,
`cli.sh`'s inline collision checks) rather than a new safety framework:

- **WEB enabled but required frontend capability absent**: N/A for F/J
  (both always have the `stream{}` router this plan depends on) — this
  case only matters for MODE=1/2, where WEB is simply not offered at all
  (no CLI path reaches the TeleMT-WEB prompt outside F/J — enforce at the
  same point `cli.sh` already gates the classic-TeleMT prompt, if it's
  topology-gated there; not independently re-verified whether it currently is).
- **SNI/domain collision**: §7's new `DEPLOYMENT_TELEMT_WEB_DOMAIN`
  validation line, extended `cli.sh` collision check (§6/§11).
- **Public port collision**: N/A in shared layout (reuses `:443`, no new
  public port to collide).
- **Internal port collision**: §6's extended `cli.sh` reserved-port check.
- **Invalid WEB configuration**: deferred to TeleMT's own
  `validate_web.rs` (§4/§8) — server-manager should surface TeleMT's own
  validation error (from `telemt_wait_api()`'s failure, or a startup-log
  check) rather than re-implementing TeleMT's validation rules itself.
- **Certificate unavailable**: `panel_issue_cert()`'s existing
  failure/retry behavior (not independently re-read this session) applies
  unchanged once `TELEMT_WEB_DOMAIN` joins `domains_arr` (§11).
- **nginx configuration invalid**: NOT independently solved by this plan
  — worth noting the new `poc/network-inspect/executors/nginx.py`
  ("NginxExecutor for artifact validation," added in the `70485b8`
  fast-forward, §1) sounds directly relevant to this exact case, but it
  was not read this session (out of the diff's relevance at the time of
  reading) and its actual capability/maturity is **UNKNOWN** — worth a
  follow-up look before assuming it can or should validate the new WEB
  vhost, rather than assuming a new bespoke check is needed.
- **TeleMT WEB listener fails (post-config, at runtime)**: `telemt_wait_api()`
  already exists as the health gate; a config that passes TOML validation
  but fails to bind (e.g. `$TELEMT_WEB_PORT` already in use by something
  outside this project's own port table) is not distinguished from any
  other `/v1/health` failure today — no WEB-specific handling needed
  beyond what already exists, but also no WEB-specific improvement
  offered.
- **PROXY protocol accidentally enabled on TeleMT WEB**: this is exactly
  what `validate_web.rs` (§4) already refuses to start on — treat a
  startup failure here as an assertion that the config-generation code
  has a bug (the explicit `proxy_protocol = false` line, §8, must never
  be omitted or accidentally overridden), not as a case server-manager
  needs its own duplicate check for.
- **Unmanaged nginx config conflict**: not investigated this session (no
  existing "detect hand-edited nginx.conf" mechanism found or looked
  for) — genuinely open, not resolved here.

---

## 16. Test plan

**Static/unit** (mirroring `test_port_allocation.sh`'s existing
convention, name TBD e.g. `test_port_allocation_telemt_web.sh` or an
extension of the existing file):
- `core_port_allocation_role_is_valid telemt_web` → 0
- `core_port_allocation_public F telemt_web` → `443` (and J)
- `core_port_allocation_internal F telemt_web` → fails (DYNAMIC), matching `telemt`'s existing convention
- `core_port_allocation_proxy_protocol F telemt_web` → `"yes (in)"`
- `core_port_allocation_owner F telemt_web` → `"TeleMT"`
- Deployment threading: `DEPLOYMENT_TELEMT_WEB_PRESENT/DOMAIN/PORT` round-trip through `core_resolve_deployment()`, plus the new domain-collision validation error (§7)
- TeleMT config generation: `telemt_write_config()` with `TELEMT_WEB_ENABLE=1` produces the expected `[[server.listeners]]`/`[web]` block **once §8's stop condition is resolved** — cannot be written correctly before then
- nginx config generation: byte-diff test in the same style as `variant_f.sh`'s own header note ("verified by SHA256 comparison against the pre-Phase-C baseline") — WEB-disabled output must remain byte-identical to today's output, mirroring the exact discipline already required of the classic-TeleMT and F+XHTTP additions
- Listener/PortAllocation model: as above

**Integration**: F + WEB; F + XHTTP + WEB (confirm XHTTP's separate port/stream-block truly doesn't interact, per §10); J + WEB; TeleMT classic + WEB (same process — the §4 proxy_protocol-per-listener design, and §8's still-open port-field question); WEB without classic TeleMT (§12's readiness-gate risk applies directly here — this combination should be an explicit test specifically because §12 identifies it as currently broken).

**Runtime**: nginx config test (`nginx -t` against generated output);
TeleMT startup with the new listener; TLS handshake against
`TELEMT_WEB_DOMAIN`; plain HTTP request through to a stub/real TeleMT WEB
backend; WebSocket upgrade through the same path; real client IP
propagation — assert `X-Forwarded-For` at TeleMT's own log/API reflects
the true client, not `127.0.0.1`; `$proxy_protocol_addr` populated
correctly at the inner nginx hop; SNI routing (`TELEMT_WEB_DOMAIN` hits
`panel_and_sub`, not `default`); coexistence — Panel/Sub/Vision/classic-TeleMT
all still function unmodified alongside WEB in the same generated config.

**Negative**: wrong SNI (WEB domain requested but not the configured
one — should hit the inner catch-all/reject, same as Panel/Sub's existing
`server { listen ...; server_name _; ssl_reject_handshake on; }` pattern
if that applies at this internal port too — not independently confirmed
this session whether the inner `http{}` block has an equivalent
catch-all; the ones read (`variant_f.sh:297-304`) are on the
`/dev/shm/nginx.sock` selfsteal listener, a **different** socket than
`$F_NGINX_HTTPS_PORT` — whether the inner HTTPS port has its own
catch-all is **UNVERIFIED**, worth checking before assuming default nginx
behavior — SNI mismatch without any catch-all — is acceptable); wrong
domain (collision case, §7/§11); port collision (§6); invalid certificate;
PROXY protocol mismatch (the exact §4 misconfiguration, deliberately
tested to confirm TeleMT itself refuses to start rather than silently
misbehaving); missing nginx capability (N/A per §15's first bullet);
unmanaged config conflict (not designed for, per §15's last bullet — no
negative test possible until a detection mechanism exists).

---

## 17. Documentation

Per the brief's own instruction to preserve "no contract redesign" unless
proven otherwise: **no contract redesign is required**, confirmed again
by this deeper pass (§5's correction — WEB reuses panel_sub's existing
shape, needing zero new Listener-contract concepts). Updates needed are
additive, not structural:
- `docs/edge_contracts.md`: extend the Port allocation / Listener /
  Domain contract tables with the WEB rows (§5/§6/§11) — same table
  shapes, new rows, matching how classic TeleMT's own addition was
  documented there originally.
- `docs/CORE_RUNTIME_CONTRACTS.md`: note `telemt_web` alongside `telemt`
  wherever the existing `protocol`/role enum is enumerated (§5's fifth
  enum value).
- `docs/TELEMT_CONFIG.md`: add the `[web]`/`[[web.vhosts]]` schema
  section — **blocked on §8's stop condition** being resolved first,
  since this doc should describe the real, verified schema, not a guess.
- `docs/MULTI_PROTOCOL_L4_INGRESS.md` / `_REVIEW.md`: **do not silently
  reconcile** the proxy_protocol contradiction this plan found (§4) by
  editing history — add a dated correction note to the REVIEW doc instead
  (matching its own existing style of dated, sourced corrections),
  pointing at the newer upstream commit and `install.sh`'s
  already-shipped resolution, so a future reader doesn't re-discover the
  same apparent contradiction from scratch.

---

## 18. File-level implementation plan

| File | Change | Why | Risk | Tests |
|---|---|---|---|---|
| `lib/core/port_allocation.sh` | Add `telemt_web` to `core_port_allocation_role_is_valid()`; add `F:telemt_web`/`J:telemt_web` rows to `_core_port_allocation_row()` | §6 | Low — additive, existing rows untouched | New static/unit cases, §16 |
| `lib/core/deployment.sh` | Add `DEPLOYMENT_TELEMT_WEB_PRESENT/DOMAIN/PORT`, parsing + validation block | §7 | Low — mirrors existing triple exactly | Deployment round-trip test, §16 |
| `lib/panel/cli.sh` | New prompt block for `TELEMT_WEB_DOMAIN`/`TELEMT_WEB_PORT`, extending the existing collision checks (§6/§11) to include the new values on both sides | §7/§11 | Medium — this is the one file where a mis-placed collision check could silently let a real collision through | Manual/interactive test + the domain-collision unit case |
| `lib/telemt/install.sh` (`telemt_write_config()`) | New conditional block per §8 — **blocked on the `[server].port` question** | §8 | High until unblocked — writing this before resolving §8 risks generating a config TeleMT rejects, or worse, one it silently misinterprets | Config-generation test, §16 — cannot be written meaningfully before §8 resolves |
| `lib/panel/nginx/variant_f.sh` **and/or** `lib/panel/nginx/config.sh` | New map line, new upstream, new inner `server{}` block, per §9 — target file depends on which one is actually live (§10's note) | §9 | Medium — byte-identity-when-disabled discipline must be followed exactly, per this file's own established convention | Byte-diff regression test (WEB-disabled case), §16 |
| `lib/panel/nginx/variant_j.sh` | Same three additions, independently (no shared helper, §10) | §9 | Same as above | Same |
| `lib/panel/cert.sh` | Add `TELEMT_WEB_DOMAIN` to the `domains_arr` construction site(s) (§11), gated on `TELEMT_WEB_ENABLE`/equivalent | §11 | Low — `panel_issue_cert()` itself is already generic | Manual cert-issuance test (not readily unit-testable) |
| `lib/telemt/api.sh` (`telemt_fetch_links()`) | Fix the `"tg://proxy"` readiness-gate (§12) to use `telemt_api_ok()` instead; add WEB-link display line once §12's UNKNOWN schema question is answered | §12 | Medium — the gate fix is a real, independent bug fix worth doing regardless of WEB; the display addition is blocked on schema verification | New integration case: "WEB without classic TeleMT," §16 |
| `lib/telemt/migrate.sh` | Likely no code change (§14) — but add a test proving the WEB block survives migration unmodified, using the SAME copy-and-substitute mechanism `test_telemt_migrate_colocate.sh` already proves for other unknown fields | §14 | Low, if the "no enumeration of listeners" premise holds — **not independently re-verified this session**, only inferred from test #2's description | New test extending `test_telemt_migrate_colocate.sh`'s pattern |
| `lib/telemt/core.sh` (`telemt_detect_state()`) | **Needs investigation before any change is planned** — current behavior against a two-listener config is unverified (§14) | §14 | Unknown until investigated — flagged, not sized | N/A until investigated |
| `docs/edge_contracts.md`, `docs/CORE_RUNTIME_CONTRACTS.md`, `docs/TELEMT_CONFIG.md`, `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md` | Additive documentation updates, §17 | §17 | Low | N/A |

---

## 19. Implementation order

Derived from actual dependency, not the brief's suggested default order
(which turns out to need one reordering — TeleMT config schema
verification has to come before Deployment/PortAllocation field-naming is
finalized, since §8's open question could change what `TELEMT_WEB_PORT`
even means):

1. **Resolve §8's stop condition** (TeleMT `[server].port` vs.
   per-listener port — verify against pinned upstream source directly).
   Nothing downstream can be correctly specified until this is answered.
2. Resolve §14's `telemt_detect_state()` question (does it already tolerate two listeners, or does it need a change).
3. `lib/core/port_allocation.sh` + `lib/core/deployment.sh` (model/config contract — now safely specifiable given #1's answer).
4. `lib/telemt/install.sh` (TeleMT config generation, §8 — now specifiable).
5. `lib/panel/cli.sh` (domain/port collection + collision checks, §7/§11 — needs #3's field names to exist first).
6. `lib/panel/nginx/variant_f.sh`/`variant_j.sh` (or `config.sh`, per §10's live-file check) — outer routing + inner termination together, since both are one nginx reload unit, not separable in practice.
7. `lib/panel/cert.sh` (§11 — needs #5's `TELEMT_WEB_DOMAIN` to exist).
8. `lib/telemt/api.sh` link-generation fix + addition (§12 — independent of everything above except needing a running WEB listener to test against; the readiness-gate bug fix (§12) can actually happen at ANY point, including before step 1, since it's a pre-existing bug unrelated to WEB).
9. `lib/telemt/migrate.sh` test addition (§14/§16 — needs #4 to exist to have something to migrate).
10. Tests (interleaved with each step above per the file table, §18/§16 — not a single trailing phase).
11. Documentation (§17 — last, once the above is real rather than planned).

---

## 20. Stop conditions — must not be implemented past this point until verified

- **§8**: the exact `[web]`/`[[web.vhosts]]` TOML schema, and specifically
  whether `[[server.listeners]]` supports a per-listener `port` distinct
  from top-level `[server] port`. This blocks §8, §9 (the upstream's
  actual field names), and therefore realistically blocks steps 3-4 of
  §19 from being more than placeholders.
- **§14**: `telemt_detect_state()`'s (and
  `telemt_detect_listener_ip()`/`telemt_detect_listener_proxy_protocol()`'s)
  actual behavior against a two-`[[server.listeners]]` config — not
  verified, could silently misreport status.
- **§12**: the exact API response field TeleMT uses for a WEB link/URL —
  not verified; do not invent a field name and build display code around
  a guess.
- **§17/§8, jointly**: do not write `docs/TELEMT_CONFIG.md`'s `[web]`
  section from the research report's REPORT-SOURCED schema alone — it was
  sourced from TeleMT's own docs/source at a point in time; re-verify
  against the exact pinned commit this project resolves to
  (`telemt_pick_version()`) before documenting it as this project's fact,
  the same standard this plan applied to the proxy_protocol question in §4.
- **Certificate renewal interaction**: not investigated at all this
  session (only issuance, §11) — do not assume renewal automation already
  generalizes to a fourth domain without checking.

---

## 21. Out of scope (explicitly not being changed)

- MODE=1, MODE=2 — no WEB support planned or possible without first
  introducing a `stream{}` layer neither topology has (§3's table,
  carried over from the prior audit, re-confirmed unchanged this pass).
- Split layout (dedicated public port for WEB) — noted as a plausible
  future variant (§3, §6, §13) but not designed; would reuse J's own
  dedicated-XHTTP-port shape as its nearest precedent if ever built.
- Any change to REALITY, Vision, XHTTP, Panel, or Sub's own behavior,
  ports, or certificates — every existing branch's generated output must
  remain byte-identical when `TELEMT_WEB_DOMAIN` is unset, per the exact
  discipline `variant_f.sh`'s own header already demands of every prior
  addition.
- A Capability Registry, Desired State model, or Plan IR implementation —
  unchanged from §2.
- A new MODE — unchanged from §2.
- Rewriting `lib/telemt/menu.sh`'s or `users.sh`'s interactive UI to
  expose WEB-specific management screens — not investigated, not planned;
  the existing `telemt_submenu_users()`/`telemt_menu_links()` may need
  WEB-awareness eventually but this plan does not size that work.
- Multi-instance TeleMT (running WEB in a genuinely separate TeleMT
  process from classic) — considered as a theoretical alternative to §4's
  per-listener design during this session's research, rejected as
  unnecessary once the per-listener override was confirmed real; not
  designed further.
