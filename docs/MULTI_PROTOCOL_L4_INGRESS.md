# Multi-Protocol L4 Ingress — Research

> Status: RESEARCH ONLY. No code changed, no `lib/` touched, no MODE
> semantics altered. This document is a continuation of a prior agent's
> checkpoint (embedded task transcript, see history) — it re-verifies every
> disputed claim from that checkpoint against source (repo code + upstream
> docs/source), corrects two claims that were too conservative, and adds
> several load-bearing findings the checkpoint had not yet reached.
>
> **Branch verified against**: `variant-f`, `git rev-parse HEAD` =
> `c247a5ffb508d7d4771e1517f5de7583a04a9e60` (2026-08-24). This is **not**
> `beta`, which `docs/ARCHITECTURE.md`'s own header names as the canonical
> code source of truth (`33135602c5c2e799575b0081cbfd137a40f7527c`). Every
> finding below is verified against `variant-f` only. If `beta` and
> `variant-f` have diverged in `lib/panel/nginx/config.sh`, `api.sh`,
> `compose.sh`, or `lib/telemt/*` / `lib/hy2/*`, that drift has **not** been
> checked and is out of scope for this document.

---

# Scope

Independent technical research into whether a single nginx `stream{}` L4
ingress can front Xray/REALITY, TeleMT, and Hysteria2 on shared ports
(TCP :443 for the first two, UDP :443 for the third), and if so, under what
topology, with what code changes, and with what impact on existing MODE
semantics. Explicitly **not** in scope: writing code, changing `lib/`,
changing MODE=1/MODE=2/MODE=F behavior, patches, commits.

---

# Current Architecture

## A. What exists in code today (`variant-f`, verified by direct read)

**MODE=1** — `panel_generate_nginx_config()`, `lib/panel/nginx/config.sh:3-151`.
nginx listens on `unix:/dev/shm/nginx.sock` (`LISTEN_DIR`, :17) for
Panel/Sub/decoy, distinguished by `server_name` inside one `http{}` tree.
Xray/REALITY (`remnanode`) listens publicly on `0.0.0.0:443` directly —
nginx never touches Xray's ingress traffic. `remnanode` and
`remnawave-nginx` are both `network_mode: host`
(`lib/panel/compose.sh:88,123`). REALITY fallback `dest` =
`/dev/shm/nginx.sock` (`lib/panel/api.sh:20-27`, `panel_reality_dest_val()`).
This is a *different* Unix socket direction from the ingress question: it is
Xray, as a client, connecting outward to nginx's HTTP decoy after Xray's own
REALITY handshake inspection rejects a connection — see `REALITY fallback`
below.

**MODE=2** — Panel without co-located Node. nginx `0.0.0.0:443` public,
plain `http{}`. `panel_reality_dest_val()` returns `${SELFSTEAL_DOMAIN}:443`
for this branch (`api.sh:25`) — fallback points at a public
domain:port rather than a co-located decoy, which is the architecturally
questionable case already flagged in project memory; unchanged and out of
scope here per ARCHITECTURE.md Stage 4 deferral.
`lib/panel/node/compose.sh` (Remote Node generator) exists in the tree but
is explicitly **not wired into MODE=2 orchestration** — its own header
comment says so verbatim (`node/compose.sh:3-6`: "STEP 1 (Stage 7): только
генерация файлов... НЕ вызывается из panel_install()").

**MODE=F** — `panel_generate_nginx_config_f()`,
`lib/panel/nginx/config.sh:180-374`. nginx `stream{}` owns public `:443`,
uses `ssl_preread` (reads ClientHello SNI without terminating TLS —
VERIFIED: this is exactly what `ngx_stream_ssl_preread_module` does,
nginx.org docs) to route: `PANEL_DOMAIN`/`SUB_DOMAIN` →
`127.0.0.1:$F_NGINX_HTTPS_PORT` (7443, internal `http{}`, TLS terminated
normally); everything else (including no-SNI and `SELFSTEAL_DOMAIN`) →
`127.0.0.1:$F_XRAY_PORT` (8443, raw TCP passthrough to Xray REALITY).
`proxy_protocol on;` is set toward the `panel_and_sub` backend only, not
toward `xray_reality` (`config.sh:359-371`) — the file's own comment already
documents this as a deliberate, flagged gap (see PROXY Protocol section —
this repo comment is *more conservative* than what upstream Xray actually
supports; corrected below). REALITY fallback stays `/dev/shm/nginx.sock`,
untouched by MODE=F. `remnawave-nginx` + `remnanode` both `network_mode:
host` in the MODE=F compose branch (`compose.sh:145` onward — confirmed by
direct read, not just the doc's description of it).

`panel_generate_webserver_config()` (`config.sh:380-412`) is the dispatcher:
`WEB_SERVER=1` + `MODE=F` → `panel_generate_nginx_config_f()`; `WEB_SERVER=1`
+ MODE=1/2 → `panel_generate_nginx_config()` unmodified body (byte-identical
guarantee is structural — the F path is a separate function, not a branch
inside the MODE=1/2 one). `WEB_SERVER=2` (Caddy) + `MODE=F` is rejected
upstream at `lib/panel/install.sh:208-209` with an explicit `err`.

**TeleMT** (`lib/telemt/install.sh`, `lib/telemt/core.sh`) — fully separate
service, no code-level relationship to `lib/panel/*` anywhere in this repo.
Config is TOML: `[[server.listeners]] ip = "0.0.0.0"` (`install.sh:74-75`)
— **only an IP field, no socket field, in this project's config
generator**. Two deploy modes: systemd (binary from
`github.com/telemt/telemt` releases, `TELEMT_GITHUB_REPO="telemt/telemt"`,
`lib/core/config.sh:30`) or Docker (`ghcr.io/telemt/telemt:latest`,
`container_name: telemt`, own `docker compose`, `ports: -
"${port}:${port}/tcp"`, `install.sh:130-148`). TLS-mimicry mode is used
(`general.modes.tls = true`, `install.sh:61`, with `censorship.tls_domain`
set to a user-chosen masquerade domain). No Docker network, no `/dev/shm`,
no PROXY protocol field in this project's generated config.

**Hysteria2** (`lib/hy2/install.sh`, `lib/hy2/core.sh`) — fully separate,
systemd-only in this repo (Docker is not used for Hysteria2 here), installed
via the official installer script (`hy_run_official_installer`).
`listen_addr="0.0.0.0:${port}"` or a port-hopping range
(`install.sh:175,205`) — **always an `ip:port`-shaped string, never a
socket path, in this project's generator**. Separate UFW rules
(`install.sh:283-291`, opens both `/udp` and `/tcp` for the chosen port —
the `/tcp` opening is not explained anywhere in this repo; see Open
Questions). Own ACME on port 80. No Docker network, no `/dev/shm`.

**Remote Node** (`lib/panel/node/compose.sh`) — separate host,
`network_mode: host`, own Caddy (not nginx) as decoy on that host's own
`/dev/shm/nginx.sock`, comment explicit that `:443` belongs to
`remnanode`/Xray and Caddy never binds it (`node/compose.sh:8-11`). A Unix
socket cannot be shared between the Panel host and a Remote Node host — this
is not a Docker limitation, it is a property of Unix domain sockets being
filesystem inodes local to one kernel instance. **VERIFIED as a hard
physical constraint, not a project convention.**

## Docker/Network topology (current)

| Component | network_mode | Evidence |
|---|---|---|
| `remnawave-nginx` (all MODE) | `host` | `compose.sh:88,227,359,471,618` |
| `remnanode` (MODE=1, MODE=F) | `host` | `compose.sh:123,262,519` |
| `remnanode` (Remote Node) | `host` | `node/compose.sh:33` |
| TeleMT (Docker mode) | default bridge, explicit published ports | `telemt/install.sh:130-148` (no `network_mode` key at all) |
| Hysteria2 | N/A — systemd only, no container | `hy2/install.sh` |

Bridge network `remnawave-network` (DB/Redis/backend) is deliberately
**not** where nginx/remnanode live — those are pulled into host networking
specifically so `/dev/shm` and loopback ports are shared kernel-level
resources between the two. TeleMT and Hysteria2 today sit outside all of
this — neither shares a network namespace, a `/dev/shm`, nor a loopback
port space with Panel's nginx.

---

# Target Architecture

The checkpoint's target idea — one nginx `stream{}` owning both TCP:443 and
UDP:443, SNI-routing TCP to Xray/REALITY and (new) TeleMT, and UDP-forwarding
to Hysteria2 — is **directionally correct for TCP** (MODE=F already proves
the SNI-routing half works for Xray) but was **under-verified for the UDP
half and for TeleMT's PROXY-protocol story**, both corrected below. The
target is *not* a drop-in extension of Variant F; TeleMT and Hysteria2
co-location is a materially separate deployment-model change from anything
currently implemented, requiring new Docker/systemd wiring that doesn't
exist in this repo in any form today (verified: zero references to `telemt`
or `hysteria` anywhere under `lib/panel/`).

---

# TCP :443

**Can nginx `stream{}` be the single TCP ingress for Xray/REALITY, TeleMT,
and other TCP/TLS backends, with reliable backend routing?**

**Partially — yes, but only under conditions the checkpoint didn't fully
state.**

- Xray/REALITY alone: **VERIFIED, already implemented** (MODE=F). `ssl_preread`
  reads SNI without terminating TLS; REALITY's ClientHello passes through
  untouched to Xray, which is required for REALITY to work at all (if nginx
  terminated TLS here, Xray would never see a genuine ClientHello to inspect
  — comment in `config.sh:339-346` states this correctly and it matches
  upstream REALITY's design: the whole protocol depends on the *real*
  ClientHello reaching the REALITY inbound unmodified).

- REALITY cannot be *distinguished* from TeleMT-in-TLS-mode by SNI content
  alone in the general case — **this is the checkpoint's most important
  correct call, confirmed here.** Both mimic ordinary TLS 1.3 handshakes to
  an operator-chosen domain. The router does not need to tell them apart by
  *inspecting* the handshake; it tells them apart by **which SNI value is
  configured to route where** — exactly the same mechanism MODE=F already
  uses to separate Panel/Sub from "everything else." This works as long as
  the SNI value used for TeleMT's masquerade domain
  (`censorship.tls_domain`, and per upstream TeleMT config,
  optionally a `mask_hosts` map of several SNI values →
  `docs/Config_params/CONFIG_PARAMS.ru.md`, upstream `telemt/telemt`) does
  not collide with REALITY's `serverNames` list or with Panel/Sub domains.
  Xray REALITY's default branch in the existing `map` (`config.sh:348-352`,
  `default xray_reality;`) would need to become a three-way (or N-way) map
  keyed on all known SNI values, not just Panel/Sub vs. default — a real but
  small code change, not a structural blocker.

  **NEW FINDING beyond the checkpoint**: this exact pattern — nginx
  `stream{ ssl_preread; proxy_pass <telemt>:<port>; }` in front of TeleMT —
  is not a hypothetical this project would be inventing. TeleMT's own issue
  tracker documents it as *"the canonical pattern"* for multi-relay TeleMT
  deployments: `stream { server { listen 443; ssl_preread on; proxy_pass
  <main_ip>:443; } }` (upstream `telemt/telemt` issue #777, "Per-listener
  proxy_protocol (or per-CIDR fallback) for mixed direct + relay setups").
  This raises confidence in TCP-side feasibility for TeleMT specifically,
  beyond "SNI routing is generically possible."

- Client-without-SNI and clients presenting an SNI that matches neither
  Panel/Sub nor TeleMT's masquerade domain(s) both fall into the same
  "default" bucket that REALITY already claims — this is unavoidable and
  identical to how REALITY already treats unmatched traffic in MODE=F today.
  No new ambiguity is introduced beyond what already exists.

**Conclusion**: SNI-based coexistence of REALITY and TeleMT on one TCP:443
via nginx `stream{}` is **FEASIBLE**, contingent on non-colliding SNI/mask
domains (an operational/config constraint, not a protocol one) and on
extending the existing `map` block from binary to N-way. It is not a "REALITY
vs TeleMT fingerprinting" problem — the checkpoint was right to reject that
framing.

---

# UDP :443

**Deliberately verified separately, per instructions — the checkpoint did
not have this fully separated and had left two of its claims as NOT
VERIFIED.**

- `ngx_stream_proxy_module` **VERIFIED (nginx.org official docs)**: "allows
  proxying data streams over TCP, UDP (1.9.13), and UNIX-domain sockets."
  UDP proxying itself is real, shipped, documented with a working example
  (`listen 53 udp; proxy_pass dns.example.com:53;`).
- UDP session-to-backend semantics differ fundamentally from TCP: nginx
  treats a UDP "session" as a client 4-tuple within a timeout window
  (`proxy_timeout`, `proxy_responses`), not a persistent connection. This
  matters for Hysteria2/QUIC specifically because QUIC already multiplexes
  everything over one UDP flow per client — nginx's stream-UDP proxy adds a
  layer of session bookkeeping on top of a protocol that already does its
  own; this is architecturally redundant but not necessarily harmful. **NOT
  VERIFIED**: whether nginx's UDP session timeout/rebinding interacts badly
  with long-lived QUIC connections or with Hysteria2's own congestion
  control (Brutal) — would require an actual load test, out of scope here.
- **UDP → Unix-domain-socket backend**: the module's own doc line groups
  "UDP" and "UNIX-domain sockets" as two of the three transports it
  supports, but does **not** show a worked example combining the two (only
  TCP-listen-to-UDS and UDP-listen-to-TCP examples appear in nginx's
  documentation). This is genuinely **NOT VERIFIED** as a checkpoint left
  it — but see Unix Socket Analysis below: it is also **moot**, because
  Hysteria2 itself has no UDS listen mode in the first place, so this
  question has no live consequence for this project's target topology
  regardless of its answer.
- **PROXY protocol for UDP in nginx stream: NOT SUPPORTED, confirmed.**
  `nginx/nginx` GitHub issue #1061 ("Add PROXY Protocol v2 support for UDP
  in stream module"), open as of late 2025: *"NGINX supports PROXY Protocol
  for TCP in the stream module, but UDP proxying does not support PROXY
  Protocol."* This is an unresolved upstream feature gap, not a
  configuration question — **VERIFIED NOT FEASIBLE today**, independent of
  whether Hysteria2 would otherwise accept it.
- Does nginx need to sit in front of Hysteria2 at all? Hysteria2's own
  masquerade feature (`masquerade: {type: proxy, ...}`, upstream Hysteria2
  docs) already makes an unauthenticated Hysteria2 listener behave like an
  ordinary HTTP/3 server to a prober — it does its own camouflage at the
  QUIC/HTTP3 layer, unlike REALITY/TeleMT which rely on TCP-layer TLS
  mimicry that benefits from SNI-based multiplexing with other services on
  the same port. Putting nginx in front of Hysteria2 for *ingress
  multiplexing* purposes brings none of the SNI-sharing benefit that
  motivates it for TCP — the whole port already belongs to Hysteria2, there
  is no second UDP:443 tenant to multiplex against in this project's actual
  service set. **INFERENCE, not proven infeasible, but no evidence found
  that co-locating nginx in front of Hysteria2 solves a problem this project
  actually has**, other than a generic "unify all ingress behind nginx"
  aesthetic goal.

**Conclusion**: UDP:443 multiplexing through nginx `stream{}` is technically
real for the TCP-analog cases nginx documents (plain UDP passthrough works),
but the two specific things this project would need — PROXY protocol
(NOT SUPPORTED upstream) and UDS backend (NOT VERIFIED, and moot given
Hysteria2) — do not hold up. The clean answer for Hysteria2 is: **run it
standalone on its own UDP port**, not behind nginx. This differs from the
checkpoint's Variant recommendation, which had grouped UDP into the unified
ingress without flagging the PROXY-protocol gap as a hard blocker.

---

# Xray / REALITY

## PROXY protocol — checkpoint's "NOT VERIFIED" is corrected here

The checkpoint (and this repo's own `config.sh:360-370` comment) treats
`acceptProxyProtocol` on a `security:"reality"` inbound as unconfirmed. Direct
verification against upstream Xray-core documentation and source shows this
is **more supported than the repo comment assumes**:

- **VERIFIED (official docs)**: `sockopt.acceptProxyProtocol` is documented
  at the `streamSettings.sockopt` level — *"Only for inbound, indicates
  whether to accept PROXY protocol"* (xtls.github.io/config/transports/sockopt.html) —
  and `sockopt` is a **security-independent** structure; nothing in its
  definition restricts it by `security` value. This is corroborated by the
  Go source: `SocketConfig.AcceptProxyProtocol bool` in
  `infra/conf` and `transport/internet`, again with no coupling to REALITY
  vs TLS vs none.
- **VERIFIED (working community configuration)**: `XTLS/Xray-core`
  discussion #5545 ("transparent fallback xver proxy") shows a real
  production-style inbound with `"security": "reality"` **and**
  `"sockopt": {"acceptProxyProtocol": true}` in the same `streamSettings`
  block, actively running (the reported issue in that thread is about xver
  passthrough to the *fallback* destination, not about
  `acceptProxyProtocol` itself failing to work with REALITY).
- **Net correction**: `acceptProxyProtocol` on a REALITY inbound is
  **VERIFIED FEASIBLE at the protocol/software level**. What is genuinely
  unconfirmed is narrower than the repo comment states: whether *this
  project's* JSON builder (`api.sh:118-122`, the `jq -n` REALITY inbound
  template) should add it, and whether nginx's `stream{}` `proxy_protocol
  on;` toward the Xray backend would break existing non-PROXY-protocol-aware
  installs during a transition. That's a migration/compat question, not a
  feasibility unknown.

## Unix socket — ingress direction (nginx → Xray)

- **VERIFIED (official Xray docs, xtls.github.io/en/config/inbound.html)**:
  inbound `listen` supports "Unix domain sockets in absolute path format...
  protocol can currently be VLESS, VMess, or Trojan, and applies only to
  TCP-based transport methods, such as tcp, websocket, grpc." REALITY's
  `network` is `tcp`/`raw` — a TCP-based transport — and its protocol in
  this project is `vless`. Both conditions this doc lists are satisfied.
- **VERIFIED (nginx official docs)**: `ngx_stream_proxy_module` supports
  `proxy_pass unix:/path;` as a backend target, symmetrically with `server
  unix:/path;` in an `upstream{}` block. This is the same mechanism MODE=F
  already relies on for the fallback socket direction, just not yet used as
  an ingress-facing backend.
- **No directly observed example** combining "REALITY-secured inbound
  listening on a Unix socket, fed by an nginx `stream{}` SNI router" in one
  topology was found in upstream discussions — the closest is issue #4832,
  which shows a REALITY inbound whose **fallback `dest`** points at Unix
  sockets (a different direction, see REALITY fallback below), not the
  primary REALITY listener itself on a UDS.
- **Verdict on this specific composition: VERIFIED by composition of two
  independently documented capabilities (Xray inbound UDS support + nginx
  stream UDS proxy_pass support), not by an observed identical working
  example.** This is a meaningfully different confidence level than "an
  operator has already run exactly this" — flagged as INFERENCE, not
  blind assumption, and distinguished from the PROXY-protocol finding above
  which does have a directly observed matching example.
- **Practical benefit vs. loopback TCP (127.0.0.1:$F_XRAY_PORT)**: minimal
  and possibly negative for this project specifically. MODE=F's existing
  loopback-TCP backend (`127.0.0.1:8443`) already avoids ambient TCP/IP
  stack exposure (not bound to a public interface), works today, is proven,
  and does not require Xray's inbound config to know it is being fed by a
  reverse proxy rather than the raw internet — whereas the UDS path would
  need `acceptProxyProtocol` wiring (see above) to preserve real client IPs
  at the Xray leg, since a bare Unix socket connection carries no peer
  address information the way loopback TCP still nominally would if
  `proxy_protocol` weren't needed at all. **Recommendation embedded in this
  finding: Unix socket is not obviously better here — loopback TCP is the
  simpler, already-proven choice** for the nginx→Xray ingress leg
  specifically (this differs from REALITY's *own* fallback socket, which
  has independent reasons to be a UDS — see next section).

## REALITY fallback — no loop, direction confirmed

Chain: `Internet → nginx stream :443 → default branch → 127.0.0.1:$F_XRAY_PORT
(Xray REALITY) →` genuine client → proxy session, **or** → non-genuine →
Xray's own outbound connection to `dest` = `/dev/shm/nginx.sock` → nginx
`http{}` → decoy content.

- **VERIFIED no loop**: `stream{}` and `http{}` are independent
  top-level nginx configuration trees (this is a structural nginx property,
  not project-specific) — traffic entering via `stream{}`'s public listener
  can never be re-routed back into `stream{}` by anything the `http{}` tree
  does; the fallback socket is consumed only by Xray-as-client, never
  re-exposed to the internet-facing listener.
- Ingress socket (`127.0.0.1:$F_XRAY_PORT`, nginx→Xray direction) and
  fallback socket (`/dev/shm/nginx.sock`, Xray→nginx direction) **must**
  remain distinct listeners regardless of whether the ingress leg is TCP or
  UDS, because they are opposite-direction connections multiplexed through
  the same Xray process — collapsing them onto one listener would require
  that single listener to simultaneously be "the socket nginx dials
  outbound clients into" and "the socket Xray dials outbound *from*,"
  which is not how any listen socket works (a listener accepts, it does not
  originate). This reasoning is general (any process, any socket type), not
  Xray-specific — restated here because the checkpoint's phrasing implied it
  was more of a project convention than a structural necessity.
- `xver` in `realitySettings` (project sets `xver:1` implicitly via
  `LISTEN_DIR`'s `proxy_protocol` directive on the fallback socket,
  `config.sh:17`, matched with `api.sh`'s JSON not explicitly setting
  `xver` — defaults apply) governs the PROXY protocol version Xray sends
  **toward its fallback dest**, which is a separate mechanism from
  `sockopt.acceptProxyProtocol` (which governs what Xray's *own inbound*
  accepts). These are easy to conflate; verified they are two different
  fields on two different legs of the same feature (VERIFIED: Xray-examples
  REALITY.ENG.md documents `xver` as part of `realitySettings`, "format
  similar to VLESS fallbacks' xver").

---

# TeleMT

## Deployment reality (current, this repo)

Standalone systemd or standalone Docker, both fully separate from
`lib/panel/*`. TLS-mimicry mode active by default (`general.modes.tls =
true`). No socket concept for the primary listener in this project's
generated config — only `[[server.listeners]] ip = "0.0.0.0"`.

## PROXY protocol — NEW FINDING the checkpoint missed entirely

The checkpoint stated PROXY protocol is "не используется нигде" for TeleMT
and left it there. Direct verification against upstream `telemt/telemt`
source/docs shows this needs correction:

- **VERIFIED (upstream config schema + a live upstream bug report)**:
  TeleMT (≥3.4.10, per the reporting issue) has a top-level
  `[server] proxy_protocol = true`, plus `proxy_protocol_trusted_cidrs`
  and `proxy_protocol_header_timeout_ms`. PROXY protocol support **exists**
  in the software this project deploys.
- **Critical constraint, VERIFIED**: this flag is **process-wide**, not
  per-listener. Upstream issue #777 ("Per-listener proxy_protocol (or
  per-CIDR fallback) for mixed direct + relay setups") is *exactly* about
  the limitation this project would hit if TeleMT were co-located behind
  nginx: once `proxy_protocol = true` is set, **every** connection to that
  TeleMT process must present a valid PROXY protocol header, or it is
  dropped ("Invalid PROXY protocol header in logs and the connection
  closes"). There is no way to accept both direct (non-proxied) and
  nginx-relayed (proxied) clients on the same TeleMT process today.
- **Architectural consequence for this project**: if TeleMT is put behind
  nginx `stream{}` SNI routing, TeleMT must have **no other ingress path**
  (no direct public bind) — the co-located deployment mode is a genuinely
  different mode from standalone, not standalone-plus-an-optional-nginx-
  in-front. This is a real "STEP 1 → STEP 2" deployment-model fork, matching
  the checkpoint's instinct that co-location "требует существенного
  изменения deployment model," now with a concrete mechanism (not just a
  general intuition) backing that claim.
- This project's `lib/telemt/install.sh` **does not currently set
  `proxy_protocol` anywhere** (verified: absent from `telemt_write_config()`,
  `install.sh:44-97`) — this is a required code change for co-location, not
  something already half-done.

## SNI routing — feasible, with caveats

`censorship.tls_domain` (and, per upstream config docs, an optional
`mask_hosts` map for multiple per-SNI fallback targets) gives TeleMT a
recognizable, operator-controlled SNI value in TLS-mimicry mode. This is
sufficient for nginx `ssl_preread`-based routing to pick TeleMT's process
by SNI, on the same terms REALITY already uses for Panel/Sub vs. default.
**VERIFIED as protocol-level feasible**; not implemented in this repo's
`nginx/config.sh` today (no TeleMT branch exists in any `map` block).

## Unix socket — primary listener: no; fallback/mask backend: yes (new finding)

- Primary listener: **VERIFIED NOT SUPPORTED**. `[[server.listeners]]` only
  ever takes `ip` in every config schema example found (this project's
  generator, and every upstream/community config sample surveyed) — no
  socket-path form documented anywhere for the client-facing listener.
- **NEW FINDING**: TeleMT's *own* TLS-fronting mask/fallback backend (its
  rough analog of REALITY's `dest`) **does** support a Unix socket, per
  upstream `docs/Config_params/CONFIG_PARAMS.ru.md`: a `mask_unix_sock`
  parameter exists, and defaults to using `mask_host`/`tls_domain` as a
  TCP target when unset. This is architecturally symmetric with Xray
  REALITY's `dest` field accepting a UDS — both projects give the
  *decoy/fallback* leg UDS support while keeping the *primary listener*
  IP:port-only. Not previously identified in the checkpoint's socket matrix.
- Net effect: TeleMT co-location with nginx would use **loopback TCP or a
  co-located ingress port** for nginx→TeleMT (no listener-side UDS option
  exists to use anyway), but **could** reuse a Unix-socket-based decoy
  target for its own mask backend if a shared decoy/nginx-HTTP setup were
  ever built for TeleMT specifically — a possible but currently
  unimplemented parallel to REALITY's fallback pattern. Out of scope for
  this round beyond flagging it as a real, previously-unnoted option.

---

# Hysteria2

## Deployment reality (current, this repo)

Standalone systemd, official upstream installer, own ACME on port 80,
`listen: <ip>:<port>` (or a port range for hopping). No Docker path for
Hysteria2 in this repo at all (unlike TeleMT, which has both).

## Unix socket — VERIFIED NOT SUPPORTED for the primary listener

Upstream Hysteria2 server config (`v2.hysteria.network/docs/advanced/Full-Server-Config`)
documents `listen` as an address string only ("If omitted, the server will
listen on `:443`"). The only Unix-socket-related feature found anywhere in
Hysteria2's docs is `fdControlUnixSocket`
(`v2.hysteria.network/docs/advanced/FD-Control`) — this is a **client-side**,
Android-specific file-descriptor handoff mechanism for outbound QUIC
connections, unrelated to server ingress and not applicable here. **No
server-side UDS listen mode exists in Hysteria2.** This settles the
checkpoint's "NOT VERIFIED" as a clean **NOT SUPPORTED**.

## PROXY protocol — VERIFIED NOT APPLICABLE / NOT SUPPORTED

No PROXY protocol field found anywhere in Hysteria2's server or client
config surface (searched full server config docs — the only "proxy" surface
is Hysteria2's own client-facing SOCKS5/HTTP proxy modes, an unrelated
concept). Independent of that, nginx `stream{}` does not support PROXY
protocol for UDP at all (see UDP :443 section, GH issue #1061) — so this is
doubly not feasible today, from either side.

## Why co-locating nginx in front of Hysteria2 doesn't buy what it buys for TCP

For TCP:443, nginx-as-ingress lets REALITY and TeleMT (and Panel/Sub) share
one port via SNI. For UDP:443 in this project's actual service set,
Hysteria2 is the **only** tenant — there is no second UDP service competing
for the port that SNI-multiplexing would resolve. Hysteria2's own
`masquerade` feature already provides HTTP/3-level camouflage without
nginx's help. The motivating problem nginx solves for TCP (port contention
between multiple TLS-mimicking services) does not exist on the UDP side in
this codebase today. **Recommendation embedded here: Hysteria2 should stay
standalone on its own UDP port, not be pulled behind a stream-UDP nginx
proxy** — this is a stronger, more specific statement than the checkpoint's
"UDS and co-location... require a separate decision."

---

# Unix Socket Analysis (consolidated)

| Direction | Supported? | Evidence |
|---|---|---|
| Xray REALITY inbound → listen on UDS | VERIFIED supported (composition of two documented capabilities; no single observed matching example) | xtls.github.io/en/config/inbound.html; nginx stream UDS proxy_pass docs |
| nginx stream → Xray via UDS (as backend) | VERIFIED supported | `ngx_stream_proxy_module` docs |
| Xray REALITY fallback `dest` → UDS | VERIFIED, already in production use in this repo | `api.sh:23`, `/dev/shm/nginx.sock` |
| TeleMT primary listener → UDS | VERIFIED NOT SUPPORTED | upstream config schema, all samples surveyed |
| TeleMT mask/fallback backend → UDS | VERIFIED SUPPORTED (new finding) | upstream `CONFIG_PARAMS.ru.md`, `mask_unix_sock` |
| nginx → TeleMT via UDS (ingress) | Moot — TeleMT has no listener-side UDS to target | — |
| Hysteria2 primary listener → UDS | VERIFIED NOT SUPPORTED | upstream Full-Server-Config docs |
| nginx UDP stream → UDS backend (generic capability) | NOT VERIFIED (no matching worked example found) — and moot for this project given Hysteria2's lack of UDS | `ngx_stream_proxy_module` docs (groups UDP and UDS as separate supported transports, doesn't show them combined) |

Do not conflate the ingress-socket question above with the two
already-shipped Unix sockets in this repo (`/dev/shm/nginx.sock` for
Panel/Sub/decoy HTTP, and the same path reused as REALITY's fallback
`dest`) — those are settled, working, and unrelated to whether a *new*
ingress-facing socket should be added for TeleMT or Xray's primary listener.

---

# PROXY Protocol Analysis (consolidated)

| Component | Supports accepting PROXY protocol? | Constraint | Evidence |
|---|---|---|---|
| Xray REALITY inbound | VERIFIED yes, via `sockopt.acceptProxyProtocol`, security-independent | This repo's JSON builder doesn't set it yet (`api.sh:118-122`) | xtls.github.io/config/transports/sockopt.html; Xray-core discussion #5545 |
| TeleMT | VERIFIED yes, via `[server] proxy_protocol = true` | **Process-wide**, not per-listener — forces all-or-nothing PROXY protocol for the whole TeleMT instance | upstream `telemt/telemt` config schema; issue #777 |
| Hysteria2 | VERIFIED NOT SUPPORTED | N/A | No PROXY-protocol-related config field found in server/client docs |
| nginx stream, TCP mode, toward backend | VERIFIED supported | Already used in this repo (fallback socket direction) and MODE=F's Panel/Sub leg | `config.sh:17,371`; `ngx_stream_core_module` docs |
| nginx stream, UDP mode, toward backend | VERIFIED NOT SUPPORTED | Open upstream feature request | `nginx/nginx` issue #1061 |

**Net correction of the checkpoint**: REALITY+PROXY-protocol is more solid
than "NOT VERIFIED" suggested — it's a documented, demonstrated
combination, just not yet wired into this project's code. TeleMT+PROXY-
protocol is a **new finding** the checkpoint didn't have at all, and it
comes with a real architectural constraint (process-wide flag) that any
future co-location design must account for explicitly.

---

# Docker / Network Namespace

No changes to what the checkpoint already established, confirmed by direct
re-read:

- Panel-side co-location (nginx + Xray sharing `/dev/shm` and loopback ports)
  exists only where both are `network_mode: host` on the same physical/VM
  host — MODE=1 and MODE=F. Confirmed at `compose.sh:88,123` (MODE=1) and
  the MODE=F branch starting `compose.sh:145` (host confirmed at
  `compose.sh:227,262` inside that branch).
- TeleMT and Hysteria2 sit entirely outside this shared namespace today —
  zero code-level intersection with `lib/panel/*`, `remnawave-network`, or
  `/dev/shm` (grep-verified: no `telemt` or `hysteria` string anywhere under
  `lib/panel/`).
- Remote Node is a different host by definition; UDS sharing across hosts is
  impossible (kernel/filesystem property, restated above, not re-derived
  here).
- For TeleMT/Hysteria2 to join the Panel host's shared namespace, they would
  need `network_mode: host` (for loopback-port sharing with nginx) or
  explicit bind-mounts into a shared bridge network with published loopback
  ports — either is a real Docker/systemd wiring change, zero of which
  exists in this repo today for either service.

---

# MODE Analysis

| MODE | Current | Co-located multi-protocol ingress compatible? | Reasoning |
|---|---|---|---|
| MODE=1 | Xray public :443 direct, nginx on UDS | No, and shouldn't be forced to be | Xray already owns :443 publicly; inserting nginx stream ingress here would be a structural change to a mode that already works and has no TeleMT/Hysteria2 co-location need expressed anywhere in this repo |
| MODE=2 | Panel-only, Node separate, fallback dest = public domain:port | No | Node (and therefore Xray ingress) isn't even co-located with Panel's nginx in this mode: the multiplexing question doesn't arise |
| MODE=F | nginx stream owns :443, Xray via SNI default branch | **Extends naturally for TCP** (add TeleMT as a new SNI branch); UDP/Hysteria2 does not extend into MODE=F's existing `stream{}` block cleanly (see UDP section — PROXY protocol gap, and no shared-port motivation) | MODE=F is the only mode where nginx already owns public :443 as an L4 router — TeleMT-on-TCP fits its existing shape; Hysteria2-on-UDP does not need to |
| Remote Node | separate host | No | UDS non-shareable across hosts; would need its own independent multiplexing setup if ever needed, out of scope here |

**Backward compatibility**: nothing above requires changing MODE=1, MODE=2,
or MODE=F's *existing* Xray/Panel/Sub routing behavior. Adding a TeleMT SNI
branch to MODE=F's `map` block is additive (a new `map` case + a new
`upstream{}` + a new co-located TeleMT deployment path), not a modification
of the Panel/Sub/Xray cases already there.

**Is this a MODE, or a separate flag?** Recommendation, with reasoning:
**a new opt-in deployment flag layered on top of MODE=F, not a new MODE
letter.** MODE currently selects *how Xray/REALITY's ingress is exposed*
(direct-public vs. UDS-fallback-only vs. stream-SNI-routed). Adding TeleMT
co-location doesn't change any of those three existing semantics — it's an
orthogonal "also run TeleMT behind the same stream router" toggle that only
makes sense when MODE=F is already selected (since only MODE=F gives nginx
ownership of public :443 as an L4 router in the first place). Modeling it as
MODE=G or similar would incorrectly imply it's a fourth mutually-exclusive
ingress-exposure strategy for Xray, when it isn't one — Xray's exposure
doesn't change at all when TeleMT joins. A flag (e.g. something like
`TELEMT_COLOCATE=1`, gated on `MODE=F`) more accurately reflects that this
is an additive capability, not a new ingress strategy. Hysteria2 does not
need any MODE/flag change at all under this document's recommendation,
since it stays standalone.

---

# Standalone vs Co-located Deployment

## TeleMT

**CURRENT**: fully standalone, systemd or Docker, own public bind, no
PROXY-protocol dependency, no relationship to Panel's nginx.

**TARGET (for co-location)**: needs (a) `proxy_protocol = true` set in its
generated config — a real code change to `lib/telemt/install.sh`'s
`telemt_write_config()`; (b) TeleMT's public bind moved to loopback-only
(`127.0.0.1:<port>`, matching MODE=F's pattern for Xray) so its only
ingress path is via nginx; (c) an nginx `stream{}` SNI branch added for
TeleMT's masquerade domain(s); (d) TeleMT's mask/fallback backend
optionally repointed at a UDS-based decoy if a shared decoy design is
wanted later (not required for basic co-location, see TeleMT section
above). This is **not** an in-place upgrade of the standalone mode — because
`proxy_protocol` is process-wide (verified above), a TeleMT instance cannot
serve both direct and co-located clients simultaneously. **Standalone
deployment must remain a fully separate, unmodified code path** — exactly
the constraint the original task set, now with a concrete technical reason
(not just a policy preference) for why breaking it would be actively wrong,
not just undesirable.

## Hysteria2

**CURRENT**: fully standalone, systemd, own UDP (and, unexplained, TCP)
port, own ACME, own UFW rules.

**TARGET**: this document's recommendation is **no change** — Hysteria2
should not be pulled into a co-located deployment model at all, given (a)
no UDS support, (b) no PROXY protocol support, (c) no shared-port
motivation on the UDP side (Hysteria2 is already the sole tenant of its
port), and (d) nginx UDP+PROXY-protocol being an unshipped upstream
feature regardless. If future requirements *do* call for fronting Hysteria2
with something, the honest options are: plain UDP passthrough with no
PROXY protocol (losing real client IPs at Hysteria2), or accepting that
this is presently not solvable cleanly. Neither is explored further here
since no concrete driver for doing so was found in this project.

---

# Routing Constraints

- SNI-based routing (`ssl_preread`) requires every co-located TCP service to
  present *some* SNI value nginx can key on, and requires those values to be
  mutually exclusive across services (REALITY `serverNames`, TeleMT
  `tls_domain`/`mask_hosts`, Panel/Sub domains). This is an **operational
  configuration constraint** (the installer would need to validate no
  overlap at setup time), not a protocol blocker.
- No-SNI and unmatched-SNI traffic both fall to Xray REALITY's default
  branch today; adding TeleMT as a second SNI-keyed branch does not change
  this fallback behavior for traffic that matches neither.
- TeleMT's process-wide PROXY-protocol flag is the sharpest routing
  constraint found in this research: it forces TeleMT co-location to be
  all-or-nothing per TeleMT instance, which in turn forces the "standalone
  vs. co-located" choice to be a deploy-time decision, not a runtime/config
  toggle that could coexist with a direct-connect fallback.
- UDP:443/Hysteria2 has no live routing constraint to solve, because this
  research did not find a second UDP tenant needing to share the port.

---

# Candidate Topologies

## Variant A — TCP-only extension of MODE=F (recommended)

```
Internet
   │
   ├── TCP :443 → nginx stream{} (ssl_preread, extended N-way map)
   │                  │
   │                  ├─ SNI=PANEL/SUB        → 127.0.0.1:7443  (unchanged)
   │                  ├─ SNI=telemt_tls_domain → 127.0.0.1:<telemt_port>  (NEW)
   │                  └─ default               → 127.0.0.1:8443 (Xray REALITY, unchanged)
   │
   └── UDP :443 → Hysteria2 standalone, untouched, own port
```
- **Port ownership**: nginx owns public TCP:443 (as in MODE=F today).
  TeleMT loses its own public bind and moves to loopback. Hysteria2 keeps
  its own UDP port entirely outside nginx.
- **Routing**: SNI map, extended from 2-way to 3-way (or N-way with
  `mask_hosts`).
- **Socket usage**: loopback TCP for nginx→TeleMT (matching the
  already-proven nginx→Xray pattern in MODE=F) — no UDS needed for the new
  leg, consistent with this document's recommendation not to reach for UDS
  where loopback TCP already works.
- **Docker/network model**: TeleMT must join `network_mode: host` (or an
  equivalent shared-loopback arrangement) alongside nginx/remnanode, same as
  Xray already does in MODE=F.
- **Fallback path**: unchanged for Xray. TeleMT's own mask/fallback backend
  unchanged (still whatever it defaults to today) unless a shared-decoy
  design is separately pursued.
- **Advantages**: smallest change surface; reuses a pattern (SNI map +
  loopback backend) already proven in this exact codebase for Xray; doesn't
  touch Hysteria2 or introduce unproven UDP/UDS/PROXY-protocol combinations.
- **Disadvantages**: TeleMT co-location still requires the
  `proxy_protocol=true` process-wide switch, meaning standalone-vs-
  co-located remains a hard deploy-time fork for TeleMT (inherent to
  TeleMT's design, not avoidable by topology choice).
- **Required code changes**: `lib/panel/nginx/config.sh` (extend the `map`,
  add a TeleMT upstream + branch); `lib/telemt/install.sh` (add
  `proxy_protocol=true` + trusted-CIDR to loopback, move bind to
  `127.0.0.1`, new co-located compose/systemd variant); `lib/panel/compose.sh`
  or a new file (co-located TeleMT service definition, `network_mode: host`).
- **Backward compatibility**: MODE=1/2 untouched entirely; MODE=F's existing
  Panel/Sub/Xray branches untouched (additive map entry only); standalone
  TeleMT/Hysteria2 remain fully intact as separate, unmodified code paths.

## Variant B — Full unification incl. UDP (not recommended, included for completeness)

Same as Variant A, plus routing UDP:443 through nginx `stream{}` to
Hysteria2 via loopback UDP (not UDS, since UDS-for-Hysteria2 is unsupported
upstream).
- **Advantages**: single conceptual "everything goes through nginx" story.
- **Disadvantages**: no real-IP preservation at the Hysteria2 leg (PROXY
  protocol for UDP doesn't exist upstream in nginx yet — see UDP section);
  adds a redundant session-tracking layer in front of a protocol (QUIC)
  that already does its own; solves no port-contention problem this
  project's UDP side actually has (Hysteria2 is the only UDP tenant).
- **Required code changes**: everything in Variant A, plus a new UDP
  `stream{}` server block, plus Hysteria2 moved to loopback-only bind, plus
  accepting the real-client-IP loss (or building an out-of-band IP-recovery
  mechanism, itself unproven).
- **Verdict**: **not recommended** — the cost (real client IP loss at
  Hysteria2, plus added complexity) is not offset by a benefit this
  project's actual UDP service set needs.

## Variant C — TCP unification via Unix sockets instead of loopback TCP (not recommended)

Same shape as Variant A, but nginx↔Xray and nginx↔TeleMT both moved from
loopback TCP to Unix sockets, on the theory that UDS is "more correct" for
same-host IPC.
- **Advantages**: marginally lower per-connection overhead than loopback
  TCP; avoids consuming loopback port numbers.
- **Disadvantages**: TeleMT has no listener-side UDS support at all
  (verified above) — this variant is **not achievable for TeleMT** without
  upstream TeleMT changes, which are outside this project's control. For
  Xray, UDS is technically composable (see Unix Socket Analysis) but is not
  an observed, battle-tested combination anywhere found in this research,
  versus loopback TCP which is already proven in this exact codebase
  (MODE=F, today). Introduces `acceptProxyProtocol`-on-REALITY as a new
  dependency for correct client-IP handling, where Variant A doesn't need it
  at all (loopback TCP's `$remote_addr` is nginx's own address either way in
  both cases, so this is actually a wash — noted for completeness, not a
  differentiator).
- **Verdict**: **not recommended**, primarily because it is simply
  infeasible for TeleMT, and offers no compelling advantage for Xray over
  the already-proven loopback-TCP pattern.

---

# Recommendation

**Variant A** — TCP-only, additive extension of the existing MODE=F SNI
router to include TeleMT via loopback TCP, with Hysteria2 left fully
standalone on UDP. Framed as **a new opt-in flag gated on `MODE=F`** (see
MODE Analysis), not a new MODE letter and not a rework of MODE=F's existing
Xray/Panel/Sub behavior.

Reasoning, restated concisely:
1. It reuses a pattern (SNI-based `stream{}` routing to a loopback TCP
   backend) that is *already implemented and running* in this exact
   codebase for Xray — the lowest-risk way to add a second tenant.
2. It does not touch Hysteria2, for which no version of a co-located
   topology survives verification (no UDS, no PROXY protocol, no shared-port
   need).
3. It respects the hard constraint this research surfaced (TeleMT's
   process-wide PROXY-protocol flag) by making co-location an explicit,
   separate deployment path rather than pretending it can coexist with
   direct-connect on the same instance.
4. It keeps MODE=1, MODE=2, and MODE=F's existing routing behavior
   byte-for-byte unchanged, matching the task's non-negotiable backward-
   compatibility requirement.

---

# Open Questions

Carried over from the checkpoint (still open) and new ones surfaced here:

1. Should `sockopt.acceptProxyProtocol` be added to this project's REALITY
   inbound JSON (`api.sh:118-122`) at all, given loopback TCP already works
   without it in MODE=F today? (This research found it's *feasible*, not
   that it's *necessary* for Variant A specifically.)
2. Exact TeleMT co-located deployment shape: systemd co-located with
   Panel's nginx on the same host (mirroring how Hysteria2 is systemd-only
   today), or a new Docker service joining `remnawave-nginx`'s host network?
   Both are plausible; this research did not find a reason in the existing
   codebase to prefer one over the other.
3. Whether `proxy_protocol_trusted_cidrs` should be scoped to only nginx's
   own loopback address, or whether a broader default is safer/simpler for
   this project's installer UX.
4. The unexplained `/tcp` UFW rule opened alongside Hysteria2's `/udp` rule
   (`hy2/install.sh:283-291`) — not explained by anything in Hysteria2's
   masquerade or ACME design found during this research; worth a follow-up
   read of Hysteria2's actual listener code, out of scope here.
5. Whether TeleMT's `mask_unix_sock` fallback-backend option (new finding,
   see TeleMT section) is worth using for a shared-decoy design mirroring
   REALITY's, or whether TeleMT should keep an independent mask backend —
   no driver for either choice was found in this codebase.
6. MODE=2's REALITY fallback pointing at `${SELFSTEAL_DOMAIN}:443` (a
   pre-existing, separately-flagged architectural question per project
   memory) is untouched by everything in this document and remains open
   under ARCHITECTURE.md Stage 4's own deferral — restated here only so a
   future reader doesn't assume this research resolved it.
7. Load-behavior of nginx's UDP session/timeout model against Hysteria2's
   Brutal congestion control was flagged as NOT VERIFIED and, given the
   recommendation against Variant B, is now moot unless that recommendation
   is revisited later.

---

# Evidence / Sources

**Repository (branch `variant-f`, HEAD `c247a5ffb508d7d4771e1517f5de7583a04a9e60`)**
- `lib/panel/nginx/config.sh` (full file read, lines cited throughout)
- `lib/panel/api.sh` (full file read)
- `lib/panel/compose.sh` (grep + targeted read for `network_mode`,
  `container_name`, MODE=F branch)
- `lib/panel/node/compose.sh` (full file read)
- `lib/panel/install.sh` (grep for MODE/WEB_SERVER guard logic)
- `lib/telemt/install.sh`, `lib/telemt/core.sh` (full file reads)
- `lib/hy2/install.sh` (partial, port/listen/UFW logic), `lib/hy2/core.sh`
  (partial)
- `lib/core/config.sh` (`TELEMT_GITHUB_REPO` value)
- `docs/ARCHITECTURE.md` (header, source-reconciliation table — establishes
  that `beta`, not `variant-f`, is canonical; current-architecture map)

**Upstream — Xray-core**
- xtls.github.io/en/config/inbound.html — UDS listen support, protocol/
  transport restrictions
- xtls.github.io/config/transports/sockopt.html — `acceptProxyProtocol`
  definition, security-independence
- xtls.github.io/en/document/level-1/fallbacks-with-sni.html — ReadV/
  acceptProxyProtocol interaction note
- xtls.github.io/en/config/features/fallback.html — fallback `dest`
  supporting TCP or UDS
- github.com/XTLS/Xray-core discussion #5545 — REALITY + `sockopt.
  acceptProxyProtocol: true` working configuration (community, not official
  docs, but a genuine working example)
- github.com/XTLS/Xray-core issue #4832 — REALITY inbound `fallbacks[].dest`
  pointing at Unix sockets
- github.com/XTLS/Xray-examples REALITY.ENG.md — `xver` field definition
- pkg.go.dev/github.com/xtls/xray-core/infra/conf — `SocketConfig` struct
  (Go source, confirms `AcceptProxyProtocol` field shape)
- deepwiki.com/XTLS/Xray-core (5-connection-processing,
  5.2-traffic-sniffing) — Unix socket listener implementation notes
  (secondary source, cross-checked against primary docs above, not relied
  on alone for any load-bearing claim)

**Upstream — nginx**
- nginx.org/en/docs/stream/ngx_stream_core_module.html — `listen unix:...`,
  `ssl_preread`, UDP `listen ... udp`
- nginx.org/en/docs/stream/ngx_stream_proxy_module.html — TCP/UDP/UDS
  proxying support statement and examples
- github.com/nginx/nginx issue #1061 — PROXY protocol v2 for UDP in stream
  module, open/unshipped as of the date checked

**Upstream — TeleMT**
- github.com/telemt/telemt (main repo: `config.toml`, `Cargo.toml`,
  `docs/Config_params/CONFIG_PARAMS.ru.md`, `docs/Quick_start/
  QUICK_START_GUIDE.*.md`, `docs/Architecture/API/API.md`)
- github.com/telemt/telemt issue #777 — process-wide `proxy_protocol` flag,
  canonical nginx-stream-relay pattern shown in the issue's own repro steps
- Community Docker wrappers (4q4r/telemt-docker, An0nX/telemt-docker,
  dev0nizer Docker Hub image) — cross-checked for config-schema consistency
  with the primary repo, not relied on alone for any load-bearing claim

**Upstream — Hysteria2**
- v2.hysteria.network/docs/advanced/Full-Server-Config — `listen` field
  definition (address:port only), masquerade modes
- v2.hysteria.network/docs/advanced/FD-Control — `fdControlUnixSocket`
  (client-side, Android, unrelated to server ingress — confirmed as such)
- v2.hysteria.network/docs/developers/Protocol — protocol-level
  authentication/masquerade behavior, no PROXY-protocol-related content
  found

---

# VERDICT

**PARTIALLY FEASIBLE.**

TCP-side multiplexing of Xray/REALITY and TeleMT behind one nginx
`stream{}` L4 ingress is feasible, low-risk, and directly extends a pattern
already proven in this codebase (MODE=F) — contingent on TeleMT's
process-wide PROXY-protocol constraint being handled as a deploy-time fork
rather than something papered over. UDP-side multiplexing of Hysteria2
behind the same ingress is **not** feasible today in any form that
preserves real client IPs (nginx has no UDP PROXY-protocol support
upstream), and this research found no problem in this project's actual
service set that unifying the UDP path would solve — Hysteria2 should
remain standalone. The originally sketched topology (both TCP and UDP
unified under one router, with UDS backends for everything) was
over-scoped relative to what the components involved actually support;
the corrected, narrower scope (TCP-only, loopback-TCP-backed, MODE=F-gated
flag) is what this document recommends carrying into an actual design/
implementation stage.
