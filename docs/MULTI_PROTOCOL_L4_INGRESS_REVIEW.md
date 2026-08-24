# Multi-Protocol L4 Ingress — Independent Technical Review

> Status: REVIEW ONLY. No `lib/` touched, no compose/nginx config changed,
> no MODE semantics altered, no patch, no commit. This document reviews
> `docs/MULTI_PROTOCOL_L4_INGRESS.md` ("the reviewed document", authored by
> a prior agent referred to below as **stg-blue**) against the repository
> and upstream sources, independently.
>
> **Note on path**: the task instructions referred to
> `docs/research/MULTI_PROTOCOL_L4_INGRESS.md`. The actual file is at
> `docs/MULTI_PROTOCOL_L4_INGRESS.md` (repository root `docs/`, not
> `docs/research/`). This review is written to `docs/research/` as
> instructed; the reviewed document itself was **not** moved.
>
> **Branch reviewed against**: `variant-f`, `git rev-parse HEAD` =
> `942dc9685202dcb82e99d8949f4149d842b9abf8`. The reviewed document's own
> commit adds itself (`942dc96`, "Update print statement from 'Hello' to
> 'Goodbye'" — misleading commit message, see Corrections), so its
> self-reported verification point is the parent commit, `c247a5f`. Both
> are confirmed to exist in this checkout; see Evidence.
>
> **Update (this pass)**: `variant-f` has since advanced to `ba5176a`
> (adds this document itself, no `lib/` changes since `942dc96`). This
> pass adds a **Runtime Verification** section closing out C2 (previously
> an evidence-backed inference) with direct observation against real
> nginx 1.24.0 and real Xray-core v26.7.28, and updates Implementation
> Readiness and the Final Verdict accordingly. Still no `lib/` file in
> this repository was touched — all testing ran against copies of the
> relevant config shapes in an isolated sandbox, not against this
> checkout's own files.

---

# Scope

Verify, file-by-file and claim-by-claim, whether the reviewed document's
findings about MODE=1/MODE=2/MODE=F, TeleMT, Hysteria2, PROXY protocol,
Unix sockets, and Docker/network topology hold up against direct repo
reads and upstream sources, and whether its VERDICT
("PARTIALLY FEASIBLE") and recommended topology (Variant A) are sound
enough to hand to an implementation task. No code was written or changed
in the course of this review; no `lib/` file was modified.

---

# Reviewed Document

`docs/MULTI_PROTOCOL_L4_INGRESS.md`, 898 lines, VERDICT: **PARTIALLY
FEASIBLE**, recommending "Variant A" (TCP-only extension of MODE=F to add
TeleMT via loopback TCP + SNI map, Hysteria2 left fully standalone),
framed as a new opt-in flag gated on `MODE=F`, not a new MODE letter.

---

# Verified Findings

The following load-bearing claims were independently re-derived from the
repository or upstream sources and are confirmed accurate:

1. **MODE=1 / MODE=F code structure** — `panel_generate_nginx_config()`
   (MODE=1/2) and `panel_generate_nginx_config_f()` (MODE=F) are two
   separate functions in `lib/panel/nginx/config.sh`, dispatched by
   `panel_generate_webserver_config()`. MODE=1's `LISTEN_DIR` is
   `listen unix:/dev/shm/nginx.sock ssl proxy_protocol;`
   (`config.sh:17`). MODE=F's public listener is `stream { server {
   listen 443; ssl_preread on; proxy_pass $f_backend; ... } }`
   (`config.sh:347-373`), routing `PANEL_DOMAIN`/`SUB_DOMAIN` →
   `127.0.0.1:7443` and `default` → `127.0.0.1:8443` (Xray REALITY).
   **VERIFIED**, matches the reviewed document's description closely.
2. **`WEB_SERVER=2` (Caddy) + `MODE=F` rejection** —
   `lib/panel/install.sh:208-209` contains exactly the guard described:
   `if [ "$MODE" = "F" ] && [ "$WEB_SERVER" = "2" ]; then err ...`.
   **VERIFIED**.
3. **`network_mode: host` for `remnawave-nginx`/`remnanode`** — confirmed
   at `lib/panel/compose.sh:88,123` (MODE=1) and `:227,262` (MODE=F
   branch, which starts around `:145`), matching the document's
   citations. **VERIFIED**.
4. **TeleMT deployment shape** — `lib/telemt/install.sh` generates
   `[[server.listeners]] ip = "0.0.0.0"` (`:74-75`), no socket-path
   option used by this project's generator; two deploy modes (systemd,
   `TELEMT_GITHUB_REPO="telemt/telemt"` at `lib/core/config.sh:30`; and
   Docker, `ghcr.io/telemt/telemt:latest`, published ports, no
   `network_mode` key, `install.sh:130-148`). **VERIFIED**.
5. **Hysteria2 deployment shape** — `listen_addr="0.0.0.0:${port}"` or a
   port-hopping range (`lib/hy2/install.sh:175,205`), always `ip:port`
   never a socket, systemd-only, own ACME. UFW opens **both**
   `${port}/udp` **and** `${port}/tcp` (`install.sh:291-292`), unexplained
   in this repo — matches the document's flagged open question exactly.
   **VERIFIED**.
6. **`telemt/telemt` is a real project**, Rust/Tokio MTProxy, config
   schema matches what the reviewed document describes: `[server]
   proxy_protocol = false # Enable if behind HAProxy/nginx with PROXY
   protocol` is a **top-level, single, process-wide `[server]` field** in
   the actual upstream `config.toml` — there is no per-listener
   equivalent anywhere in the schema. `censorship.tls_domain`,
   `censorship.mask` also confirmed as real, correctly-named fields.
   **VERIFIED** directly against `github.com/telemt/telemt/blob/main/config.toml`.
7. **TeleMT issue #777 exists and says what the document claims** —
   title "Per-listener proxy_protocol (or per-CIDR fallback) for mixed
   direct + relay setups", reported against telemt 3.4.10, topology "1
   main telemt server + 3 nginx-stream relay nodes", reproduces the
   *exact* pattern quoted in the reviewed document (`stream { server {
   listen 443; ssl_preread on; proxy_pass <main_ip>:443; } }`), and
   independently confirms that even with `proxy_protocol_trusted_cidrs`
   set, connections from IPs **not** in the trusted list are rejected
   with `Invalid PROXY protocol header in logs` rather than falling back
   to raw TCP — i.e., the current shipped behavior is genuinely
   all-or-nothing per process, exactly as the reviewed document states.
   Issue #565 independently corroborates the same failure mode
   ("Connection closed with error ... Invalid proxy protocol header")
   in an unrelated user's HAProxy+TeleMT setup. **VERIFIED, strongly** —
   this is the single most load-bearing claim in the reviewed document
   and it holds up well under independent re-check.
8. **`mask_unix_sock`** — confirmed real in
   `docs/Config_params/CONFIG_PARAMS.ru.md`: "Если задан параметр
   `mask_unix_sock`, `mask_host` не должен быть задан" (mutually
   exclusive with `mask_host`; `mask_host` defaults to `tls_domain` when
   neither is set). **VERIFIED**, matches the document's "new finding"
   description precisely.
9. **nginx UDP + PROXY protocol gap** — `nginx/nginx` issue #1061 ("Add
   PROXY Protocol v2 support for UDP in stream module") is real, open,
   and states verbatim: "NGINX supports PROXY Protocol for TCP in the
   stream module, but UDP proxying does not support PROXY Protocol."
   **VERIFIED**.
10. **Xray `sockopt.acceptProxyProtocol` + `security:"reality"`
    coexistence** — `XTLS/Xray-core` discussion #5545 is real and shows
    exactly the combination cited: `"security": "reality"` with
    `"sockopt": {"acceptProxyProtocol": true}` in the same
    `streamSettings` block, in active (if imperfect — see Disputed
    Findings) use. **VERIFIED**.
11. **Hysteria2 `listen` is address:port only, no UDS, no PROXY
    protocol field** — cross-checked against the official
    `v2.hysteria.network/docs/advanced/Full-Server-Config` content and
    several independent third-party guides/schemas; no UDS or
    PROXY-protocol-shaped field appears anywhere in the server config
    surface. **VERIFIED**.
12. **This project's REALITY inbound does not set `sockopt` /
    `acceptProxyProtocol`** — confirmed by direct grep of
    `lib/panel/api.sh`: no occurrence of `sockopt` anywhere in the file.
    **VERIFIED**.

---

# Corrections

Two concrete, independently-verifiable errors in the reviewed document,
plus one significant finding it should have surfaced but did not:

### C1 — `api.sh` DOES explicitly set `xver`; the document says it doesn't

The reviewed document states (REALITY fallback section): *"`xver` in
`realitySettings` ... matched with `api.sh`'s JSON not explicitly setting
`xver` — defaults apply"*.

This is factually wrong. `lib/panel/api.sh:122` (the `jq -n` REALITY
inbound template) contains, verbatim:

```
realitySettings:{show:false,xver:1,dest:$dest,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$domain]}
```

`xver:1` **is** explicitly set, unconditionally, for every MODE that
calls this code path (it is not gated on `$MODE`). This doesn't change
the document's structural conclusion (xver here governs the
Xray→fallback-socket leg, not the nginx→Xray ingress leg, and that
distinction is still correctly drawn elsewhere in the document) but the
specific factual claim about `api.sh` is wrong and should not be carried
into an implementation task without correction.

### C2 — `proxy_protocol on;` in MODE=F's `stream{}` block is NOT scoped to `panel_and_sub` only — this is a real, unflagged risk in the *existing* MODE=F code, not a new-feature question

This is the most significant finding of this review, and neither the
reviewed document nor the repository's own code comment catches it.

`lib/panel/nginx/config.sh:347-373` (MODE=F) has **one** `stream {
server { ... } }` block. Both branches of `$f_backend` (`panel_and_sub`
→ `127.0.0.1:7443`, and `xray_reality` → `127.0.0.1:8443`) are reached
through this same single `server{}` block via `proxy_pass $f_backend;`.
`proxy_protocol on;` is set once, at the end of that same block
(`config.sh:371`). The code's own comment (`config.sh:360-370`) asserts:
*"proxy_protocol is enabled toward panel_and_sub ... It is intentionally
NOT enabled toward xray_reality."* The reviewed document repeats this
framing without independently checking it (it cites `config.sh:359-371`
and treats the "not enabled toward xray_reality" claim as the repo's own
settled fact, then spends significant analysis on whether Xray *should*
be made to accept PROXY protocol, without ever asking whether it is
already silently receiving one).

Checked directly against `nginx.org/en/docs/stream/ngx_stream_proxy_module.html`
(`proxy_protocol` directive definition): **Context: `stream`, `server`**
— there is no per-`proxy_pass`-destination, per-map-branch, or
per-variable scoping for this directive (unlike `proxy_pass` itself,
`proxy_download_rate`, or `proxy_upload_rate`, all of which explicitly
support `$variable` values for exactly this kind of conditional
behavior — `proxy_protocol` does not). A single `server{}` block has
exactly one PROXY-protocol-toward-backend setting, applied uniformly
regardless of which upstream `$f_backend` resolves to for a given
connection.

**Consequence**: as written today, MODE=F's nginx **does** send a PROXY
protocol v1 header to `127.0.0.1:8443` (Xray REALITY) for every
connection — not just to the Panel/Sub backend. Xray's REALITY inbound
in this project does not set `sockopt.acceptProxyProtocol` (confirmed,
Verified Finding #12), so it has no reason to expect or strip a PROXY
protocol preamble; it will see `PROXY TCP4 ...\r\n` (or the v2 binary
signature) as the first bytes of what it expects to be a TLS
ClientHello. This is very likely to break REALITY's handshake inspection
for every genuine client routed through MODE=F's default branch — not a
"real client IPs show as 127.0.0.1" cosmetic limitation as both the code
comment and the reviewed document frame it, but a functional break of
the primary VLESS/REALITY path.

This review did **not** run nginx to observe the failure directly (out
of scope — read-only review, no service changes), so this is flagged as
a **strong, evidence-backed INFERENCE from nginx's own directive
semantics, not an observed runtime failure**. It should be verified with
an actual `openssl s_client`/`tcpdump` test against a live MODE=F
deployment before being treated as confirmed. But given the specificity
of nginx's own documentation on this directive's context, the burden of
proof should be treated as shifted: **MODE=F should not be assumed
correct here until this is checked**, and this checking is a
prerequisite that sits *ahead of* any TeleMT/Hysteria2 work, because it
concerns MODE=F's existing, already-shipped Xray path, not a new
capability under discussion.

If confirmed, the fix is straightforward (two `server{}` blocks — one
per SNI branch, each with its own `listen`/backend/`proxy_protocol`
setting, since `ssl_preread`+`map` can still select between them via two
separate `server{}` entries keyed differently, or by adding
`sockopt.acceptProxyProtocol: true` to the REALITY inbound so it can
correctly consume the header it's already receiving) — but doing that
fix, or even fully confirming the bug, is out of scope for this review.

### C3 — the "beta vs. variant-f divergence" hedge is more pessimistic than the actual git topology; and `docs/ARCHITECTURE.md`'s own canonicity claim is stale

The reviewed document hedges: *"If `beta` and `variant-f` have diverged
in `lib/panel/nginx/config.sh`, `api.sh`, `compose.sh`, or
`lib/telemt/*`/`lib/hy2/*`, that drift has **not** been checked."*

Checked directly: `git merge-base origin/beta variant-f` =
`6518224ffd0a16d5d01af34197a2bebefa23eda2`, which is **also**
`origin/beta`'s current tip. In other words, `variant-f` is not a
divergent branch — it is `beta`'s current HEAD plus four additional
commits (`5e75991`, `ce04a6c`, `c247a5f`, `942dc96`). There is no
drift to worry about; `variant-f` is a strict linear extension. This is
a **correction in the reviewed document's favor** (less risk than it
assumed), included here for completeness.

Separately, and independent of the above: `docs/ARCHITECTURE.md`'s own
header claims `beta`'s canonical HEAD is `33135602c5c2e799575b0081cbfd137a40f7527c`.
That commit is real (`git cat-file -t` confirms it, dated 2026-08-21
06:26 UTC, "refactor: extract panel selfsteal generation") but it sits
**34 commits behind** `beta`'s actual current tip
(`6518224`, dated 2026-08-24 13:33 +0300). The commit that wrote this
claim into `ARCHITECTURE.md` (`5e75991`, "Document Variant F for nginx
and Xray integration") is itself dated 2026-08-24 15:30 +0300 — **after**
`beta` had already advanced past the hash it cites. So
`ARCHITECTURE.md`'s "verified against `beta` HEAD = `3313560...`" header
was already stale at the moment it was written, by about 2 hours and 34
commits. This does not necessarily mean `ARCHITECTURE.md`'s *content* is
wrong (no content-level drift was checked as part of this review — that
would require diffing `lib/` between `3313560` and `6518224`, out of
scope here), but its self-certification of canonicity should not be
taken at face value by a future reader, and the reviewed document leans
on that self-certification without independently checking it.

---

# Disputed Findings

### D1 — Issue #4832 is weaker evidence than presented

The reviewed document cites `XTLS/Xray-core` issue #4832 as evidence
that "REALITY inbound `fallbacks[].dest` pointing at Unix sockets" is a
real, documented pattern. Checked directly: issue #4832 is titled
**"fallback-by-path does not work properly on xhttp"** and is **closed
as "not planned"** — i.e., it is a bug report describing a
fallback-to-multiple-UDS-destinations-by-path configuration that did
**not** work as the reporter expected, and Xray-core's maintainers
declined to fix it. The reviewed document's own framing ("a REALITY
inbound whose fallback `dest` points at Unix sockets... not the primary
REALITY listener itself") is technically accurate as a description of
what the issue's JSON contains, and the review's own conclusion
("VERIFIED by composition ... not by an observed identical working
example," explicitly flagged as INFERENCE) is appropriately hedged — so
this is a minor rather than a major issue. But citing a "closed as not
planned" bug report as one of two upstream sources for a UDS-related
capability claim overstates its evidentiary weight; a reader skimming
the Evidence section would reasonably assume #4832 shows a *working*
example, not a *failed* one. Recommend downgrading this citation's
framing if this document is carried forward, though it does not change
this review's overall assessment of Unix-socket ingress (still
correctly not recommended in Variant A).

### D2 — "no directly observed example" for REALITY-on-UDS is probably
too strong a caveat given how little this specific composition is used
in practice

Minor, not load-bearing: the reviewed document treats REALITY-inbound-on-UDS
as "VERIFIED by composition of two independently documented
capabilities... not an observed identical working example," which this
review agrees is the honest characterization. No stronger evidence was
found in this review's independent search either. Left as-is — this is
not a dispute so much as a confirmation that the hedge is warranted, and
is used here mainly to inform the Remaining Blockers section: it is not
a proven pattern, and Variant A correctly avoids relying on it.

---

# Xray / REALITY Review

The document's central technical claims about REALITY are sound and
independently reproduced above (Verified Findings #10, #12). The one
genuinely new issue this review surfaces (Correction C2 — `proxy_protocol
on;` scope) is about MODE=F's *existing* code, not about anything
TeleMT- or Hysteria2-related; it should be treated as a pre-existing
defect discovered incidentally during this review, not a consequence of
the proposed TeleMT extension. **This review recommends it be resolved,
or at minimum explicitly confirmed/refuted with a live packet capture,
before any further work is layered on top of MODE=F's `stream{}` block**
— extending a map that may already be silently corrupting the REALITY
handshake for every real client is a bad foundation regardless of
whether TeleMT is added.

# TeleMT Review

The document's TeleMT findings are the strongest part of the reviewed
document and are independently confirmed in detail (Verified Findings
#4, #6, #7, #8). The process-wide `proxy_protocol` constraint, and its
consequence that co-location must be an explicit deploy-time fork rather
than a runtime toggle, is correct and well-evidenced — issue #777's own
repro steps describe the *exact* failure mode ("Invalid PROXY protocol
header in logs and the connection closes" for any non-trusted-CIDR
direct client) that the document predicts would occur. No corrections
needed beyond C1 (the unrelated `xver` slip) above.

# Hysteria2 Review

The document's conclusion — Hysteria2 should remain standalone, UDP
co-location behind nginx buys nothing because Hysteria2 is the sole UDP
tenant and nginx cannot preserve real client IPs for it anyway — is
sound and independently confirmed (Verified Findings #9, #11). No
corrections.

# PROXY Protocol Review

| Component | Accepting | Constraint | This review's independent check |
|---|---|---|---|
| Xray REALITY inbound | Supported (`sockopt.acceptProxyProtocol`), not wired in this repo | Not security-value-restricted | VERIFIED — discussion #5545 real; `api.sh` confirmed to not set it |
| TeleMT | Supported (`[server] proxy_protocol`) | Process-wide, all-or-nothing | VERIFIED strongly — issue #777 + #565 both independently confirm the failure mode |
| Hysteria2 | Not supported | N/A | VERIFIED — no such field anywhere in official docs or third-party schemas checked |
| nginx stream, TCP, toward backend | Supported | Directive is `stream`/`server` scoped, **not** per-map-branch/variable-scoped | **NEW, this review**: MODE=F's own code likely violates this (see C2) |
| nginx stream, UDP, toward backend | Not supported | Open feature request | VERIFIED — issue #1061 real and open |

The added row/column relative to the reviewed document's own table is
the "not per-map-branch-scoped" fact, which is the basis for C2.

# Deployment Review

Confirmed as described: TeleMT (systemd or Docker, both fully standalone,
no `network_mode` key in the Docker path), Hysteria2 (systemd only, own
ACME, own UFW rules including the unexplained `/tcp` open), Remote Node
(separate host, own Caddy, `:443` owned by `remnanode` per
`node/compose.sh:8-11`, not investigated further here as it is correctly
scoped out by the reviewed document). No corrections to this section.

# MODE Decision Review

The reviewed document's recommendation — a new opt-in flag gated on
`MODE=F`, not a new MODE letter — is reasonable and consistent with how
MODE is actually used in this codebase (it selects Xray/REALITY's
ingress exposure model; TeleMT co-location doesn't change that exposure
model, it rides on top of it). This review does not find a reason to
prefer a new MODE letter instead, and confirms the guard precedent
(`WEB_SERVER=2`+`MODE=F` rejection at `install.sh:208-209`, Verified
Finding #2) as a reasonable template for how a `TELEMT_COLOCATE=1`-style
flag would need its own guard against incompatible combinations
(e.g., against `WEB_SERVER=2`, and against `MODE` values other than
`F`).

# Recommended Topology

This review does not dispute Variant A (TCP-only, MODE=F-gated
TeleMT-via-loopback-TCP flag, Hysteria2 untouched) as the right target
**shape**. It adds one precondition: **the MODE=F `stream{}` block's
`proxy_protocol` scoping (C2) should be resolved or explicitly confirmed
safe before Variant A is built on top of it**, since Variant A's own
design (`config.sh:699-703`: "extend the `map`, add a TeleMT upstream +
branch") would add a *third* branch to the same shared `server{}` block,
compounding rather than fixing the ambiguity — a naive implementation
might reasonably assume it can set `proxy_protocol on;` toward the new
TeleMT branch too "the same way Xray's is," not realizing that a
`proxy_protocol` toward TeleMT would hit the *same* all-or-nothing wall
issue #777 describes, immediately and by design (TeleMT's masquerade
domain branch would need `proxy_protocol=true` set process-wide in
TeleMT's own config to make sense of it, which Variant A already
correctly requires — but this only works cleanly if Xray's own branch
isn't ambiguously receiving an unrequested header at the same time,
which is exactly the C2 question).

## Runtime Verification: MODE-F PROXY Protocol

> Performed as a direct follow-up to C2 above, to move it from
> evidence-backed inference to observed runtime behavior. All testing below
> was done in an isolated sandbox against a freshly built nginx 1.24.0
> (Ubuntu package, `--with-stream_ssl_preread_module` confirmed via
> `nginx -V`) and a real `Xray-core v26.7.28` binary (official release,
> `github.com/XTLS/Xray-core/releases/download/v26.7.28/Xray-linux-64.zip`).
> No files in this repository were touched to run these tests; the nginx
> config used is a byte-for-byte copy of `lib/panel/nginx/config.sh:347-373`
> with only ports/domains substituted for test values, and the Xray REALITY
> inbound JSON is a direct copy of the `realitySettings` shape produced by
> `lib/panel/api.sh:118-122`, with a freshly generated keypair.

### Test 1 — nginx byte-forwarding, does `proxy_protocol on;` leak into the `xray_reality` branch?

**Setup**: nginx `stream{}` block identical in structure to
`config.sh:347-373` (`map $ssl_preread_server_name`, two `upstream{}`
blocks, one `server{}` with `ssl_preread on; proxy_pass $f_backend;
proxy_protocol on;`), backed by two Python TCP listeners that capture and
hex-dump every byte they receive, standing in for `panel_and_sub` and
`xray_reality`.

**Input**: a real TLS 1.3 ClientHello, sent via `openssl s_client -connect
127.0.0.1:19443 -servername <SNI>`, once with an SNI matching neither
`PANEL_DOMAIN` nor `SUB_DOMAIN` (routes to `xray_reality` via the `default`
map branch — this is the exact branch Xray/REALITY sits behind in
production), once with an SNI matching the panel branch.

**Captured bytes, `xray_reality` backend** (default/REALITY branch):
```
50 52 4f 58 59 20 54 43 50 34 20 31 32 37 2e 30 2e 30 2e 31 20 31 32 37
2e 30 2e 30 2e 31 20 35 34 39 39 34 20 31 39 34 34 33 0d 0a 16 03 01 01
42 01 00 01 3e 03 03 fc 59 da 59 ...
```
Printable decode: `PROXY TCP4 127.0.0.1 127.0.0.1 54994 19443\r\n` followed
immediately by `16 03 01 01 42 01 00 01 3e 03 03 ...` — a well-formed TLS
record (content type `0x16` = Handshake, version `0301`, length `0x0142`,
handshake type `0x01` = ClientHello), with the SNI extension correctly
containing the test hostname later in the same record. The genuine
ClientHello is intact and byte-complete — nginx's `proxy_pass` truly does
not touch payload — but it is **preceded by a PROXY protocol v1 header**.

**Captured bytes, `panel_and_sub` backend**: same shape —
`PROXY TCP4 127.0.0.1 127.0.0.1 <port> 19443\r\n` followed by the intact
ClientHello. Byte-for-byte the same treatment as the `xray_reality`
branch.

**Control test** (same config, `proxy_protocol on;` line removed, fresh
port 19444, fresh backend): the same ClientHello arrives at the backend
starting directly with `16 03 01 01 44 01 00 01 40 03 03 ...` — no PROXY
preamble, byte 0 is the TLS record type. This is the isolated,
byte-level difference the `proxy_protocol` directive makes.

**Verdict on nginx behavior**: **CONFIRMED, not inferred.** `proxy_protocol
on;` in `config.sh`'s single `server{}` block applies uniformly to every
connection routed through that block regardless of which `$f_backend`
value `proxy_pass` resolves to. The code comment at `config.sh:360-370`
(*"It is intentionally NOT enabled toward xray_reality"*) describes
behavior nginx does not have a mechanism to produce — there is no
per-`proxy_pass`-destination or per-map-branch scoping for the
`proxy_protocol` directive (`stream`/`server` context only, confirmed
against `nginx.org/en/docs/stream/ngx_stream_proxy_module.html`, and now
against this observed byte capture). Both branches receive an identical
PROXY v1 preamble.

### Test 2 — does an unrequested PROXY protocol preamble actually break REALITY's handshake?

**Setup**: real `Xray-core v26.7.28` server with a REALITY inbound whose
`realitySettings` block is a direct copy of what `api.sh:118-122`
generates (`xver:1`, no `sockopt` — this project's shipped shape),
`dest` pointed at a local `openssl s_server -tls1_3` stand-in (chosen to
avoid this sandbox's own TLS-intercepting egress proxy interfering with
a real internet `dest`; this local stand-in is good enough to observe
REALITY's own ClientHello-parsing/auth-key stage, which is the stage in
question — it is not good enough to complete a full external handshake,
see Known Test Limitation below). A matching real Xray-core REALITY
**client** (same version, correct public key/short ID/UUID) drove the
connection through a small Python TCP relay that prepends a PROXY
protocol v1 header to the first bytes it forwards — reproducing exactly
what Test 1 showed nginx doing to the `xray_reality` branch, byte for
byte, with real Xray-core on both ends instead of a fake capture
backend.

**Result — direct connection, no relay (baseline)**:
```
REALITY remoteAddr: 127.0.0.1:38406
REALITY remoteAddr: 127.0.0.1:38406  hs.c.AuthKey[:16]: [151 5 220 246 ...]  AEAD: *gcm.GCM
REALITY remoteAddr: 127.0.0.1:38406  hs.c.ClientVer: [26 7 28]
REALITY remoteAddr: 127.0.0.1:38406  hs.c.ClientTime: 2026-08-24 19:08:27 +0000 UTC
REALITY remoteAddr: 127.0.0.1:38406  hs.c.ClientShortId: [1 35 69 103 137 171 205 239]
```
REALITY's auth-key derivation, client-version parse, and short-ID match
all succeed — this is what a genuine, correctly authenticated REALITY
client handshake looks like at this stage, immediately after the raw
ClientHello is read.

**Result — through the PROXY-injecting relay, `sockopt` absent (this
project's current shipped shape)**:
```
REALITY remoteAddr: 127.0.0.1:38416
REALITY remoteAddr: 127.0.0.1:38416  hs.c.isHandshakeComplete.Load(): false
[Info] transport/internet/tcp: REALITY: processed invalid connection from 127.0.0.1:38416: failed to read client hello
```
No `AuthKey` line at all — REALITY never reaches the auth-key stage.
`failed to read client hello` fires immediately, because the first bytes
Xray reads are the ASCII `PROXY TCP4 ...` string, not a TLS record
(`0x16 0x03 0x01 ...`). This is the exact, observed, live failure C2
predicted from directive semantics alone; it is now confirmed against
real Xray-core, not just inferred from nginx's documentation.

**Result — through the same PROXY-injecting relay, with
`sockopt.acceptProxyProtocol: true` added to the REALITY inbound**:
```
[Warning] transport/internet/tcp: accepting PROXY protocol
...
REALITY remoteAddr: 127.0.0.1:48710
REALITY remoteAddr: 127.0.0.1:48710  hs.c.AuthKey[:16]: [178 96 121 202 ...]  AEAD: *gcm.GCM
REALITY remoteAddr: 127.0.0.1:48710  hs.c.ClientVer: [26 7 28]
REALITY remoteAddr: 127.0.0.1:48710  hs.c.ClientTime: 2026-08-24 19:09:40 +0000 UTC
REALITY remoteAddr: 127.0.0.1:48710  hs.c.ClientShortId: [1 35 69 103 137 171 205 239]
```
With `acceptProxyProtocol: true`, Xray itself logs `accepting PROXY
protocol` at startup (confirming the option is recognized and applied on
a `security:"reality"` inbound — it is not silently ignored or rejected
for this security type), and the same PROXY-prefixed stream that failed
in the previous test now reaches the identical successful auth-key stage
as the clean baseline. This directly confirms, by observed behavior
rather than by citing `XTLS/Xray-core` discussion #5545, that
`sockopt.acceptProxyProtocol` and `security:"reality"` are compatible.

**Known test limitation**: none of the three runs completed a *full*
external REALITY session (all eventually hit `target sent incorrect
server hello or handshake incomplete` or an EOF from the vision-flow
outbound's retry logic). This is attributable to the minimal
`openssl s_server -tls1_3 -www` standing in for `dest` — REALITY's real
site-splicing step has requirements (exact extension/curve behavior on
replay) a bare-bones test server does not fully satisfy, and this
sandbox's own egress network performs TLS interception on real internet
domains, which made using an actual public site as `dest` unusable for
this test. This limitation affects **all three** runs equally and
symmetrically (baseline included), so it does not weaken the
auth-key-stage comparison above, which is the stage the PROXY-protocol
question actually concerns — but it does mean this review still has not
observed a fully completed proxied REALITY session end-to-end in this
sandbox. That would additionally require either a real internet `dest`
reachable without interception, or a more complete local TLS 1.3 stand-in
than `openssl s_server` provides — flagged as an open item, not
papered over.

**Verdict — Xray/REALITY compatibility**: **CONFIRMED by direct runtime
observation.** An unrequested PROXY protocol v1 preamble ahead of the
ClientHello reliably prevents REALITY's handshake from reaching its
auth-key stage when `sockopt.acceptProxyProtocol` is absent (this
project's current shipped state) — and reliably succeeds at that same
stage when the option is added. This is a stronger evidentiary basis
than the previous review pass had (which relied on nginx's own directive
documentation plus a third-party discussion thread); it is now this
review's own observed, reproducible result against the actual software
in the actual configuration shape this project generates.

## Consequence for Variant A

### CASE 2 — `proxy_protocol on;` breaks the current REALITY flow in MODE=F

This is now **CONFIRMED, not just flagged as a risk**: MODE=F's shipped
`lib/panel/nginx/config.sh:347-373`, as it exists on `variant-f` today,
sends every connection routed to the `xray_reality` branch — i.e. every
genuine REALITY client using MODE=F, not merely a hypothetical future
TeleMT branch — through nginx with a PROXY protocol v1 preamble ahead of
its ClientHello, into a Xray REALITY inbound (`api.sh:118-122`) that does
not set `sockopt.acceptProxyProtocol` and therefore cannot parse that
preamble. Test 2 shows this reliably prevents REALITY from reaching its
authentication stage at all — the connection is rejected as
`failed to read client hello` before Xray can tell a genuine client from
a probe.

**This is a live defect in MODE=F as currently written, independent of
anything to do with TeleMT, Hysteria2, or Variant A.** Any operator
running MODE=F today, with an unmodified `variant-f` checkout, should be
unable to complete a REALITY connection through the `stream{}` block's
`default` branch — the Panel/Sub branch, which also inherits the same
`proxy_protocol on;` line, is comparatively unaffected because
`config.sh:240,286`'s internal HTTPS listener (`127.0.0.1:${F_NGINX_HTTPS_PORT}
ssl proxy_protocol`) is nginx-to-nginx and both ends already expect and
consume a PROXY header, so that leg is symmetrically configured whether
or not the `stream{}` block's directive is "intended" for it.

**Minimal fix, ranked by this review** (implementation still out of
scope for this pass — this is a recommendation, not a patch):

1. **Add `sockopt.acceptProxyProtocol: true` to the REALITY inbound in
   `api.sh`'s `jq -n` template (line 122), scoped to `MODE=F` only** —
   Test 2's third run confirms this closes the gap with no other change
   needed on the nginx side. This keeps `config.sh`'s single `server{}`
   block exactly as it is (one block, one `proxy_protocol on;`, both
   branches receive it — which Test 1 shows is unavoidable given nginx's
   directive scoping) and instead makes Xray correctly consume what it is
   already receiving. Smallest diff, and it also gives MODE=F's REALITY
   leg real client IPs (`xver` governs the *outbound* fallback direction,
   per Correction C1 in the previous review pass — a separate mechanism;
   `acceptProxyProtocol` is what lets Xray itself see the real client IP
   on its *inbound* side, which today it cannot, PROXY header or not).
   Must be gated on `MODE=F` specifically — MODE=1's REALITY inbound
   listens on public `0.0.0.0:443` directly, receives no nginx-injected
   PROXY header at all, and must not have this added (adding it there
   would require every direct client to also start sending a PROXY
   header, which no VLESS/REALITY client does — this would be a
   regression, not neutral, for MODE=1).
2. **Alternative: split the single `server{}` block into two, one per
   SNI branch**, each with its own `proxy_protocol on|off` — technically
   possible (`ssl_preread` + a second `map`-driven `server{}` selection
   is a documented nginx pattern) but a larger, more invasive change to
   `config.sh`'s structure than (1), for the same end result. Not
   recommended unless (1) turns out to have a downside this review did
   not find.

Either fix is a **pre-existing-defect fix**, not new-feature work, and
per this review's earlier recommendation should land *before* Variant A
adds a third (TeleMT) branch to the same `stream{}` block — extending a
map with a known, now-confirmed corruption already present in the
`default` branch would compound rather than clarify the picture for
whoever implements Variant A next.

# Implementation Readiness

**READY WITH EXPLICIT PRECONDITIONS.** C2 is no longer a suspected risk —
Runtime Verification above confirms it against real nginx and real
Xray-core, and identifies a minimal, ranked fix (§ Consequence for
Variant A, fix (1): add `sockopt.acceptProxyProtocol: true` to the
REALITY inbound in `api.sh`, gated on `MODE=F`). This is a precondition
to implementing Variant A, not an open research question anymore — the
remaining work on this specific point is applying the fix and adding a
regression test, not further investigation.

An implementation task for Variant A should **first** apply the
`api.sh` fix identified above (or the `server{}`-block-split
alternative, if a future implementer finds a reason to prefer it — this
review still ranks the `sockopt` addition higher, see reasoning in
Consequence for Variant A), confirm with a live REALITY handshake test
that the fix actually restores a working connection through MODE=F's
`stream{}` block (Test 2's methodology above is directly reusable as
that regression test), and **only then** layer the TeleMT SNI branch on
top of a `stream{}` block now known-correct end-to-end. Doing the fix and
the TeleMT extension in the same change is fine implementation-wise; the
precondition is doing the fix (and its regression test) first, not as an
afterthought once TeleMT's branch is already added on top.

This review's scope, backward-compat guarantees, and MODE-flag framing
(from the previous pass) remain sound and are not revisited here — this
pass only closes the one open verification gate. The open questions the
reviewed document already correctly identified remain genuinely open
(exact TeleMT co-located deployment shape: systemd vs. Docker/host-network;
`proxy_protocol_trusted_cidrs` scoping for the installer) — these are
policy/UX decisions, not technical blockers, and can be made during
implementation rather than ahead of it.

The implementation task's scope should be:

- **Files to change**: `lib/panel/api.sh` (add `sockopt:{acceptProxyProtocol:true}`
  to the REALITY inbound JSON at line 122, gated so it applies only when
  `MODE=F` — MODE=1's direct-public REALITY inbound must not receive
  this, see Consequence for Variant A); `lib/panel/nginx/config.sh`
  (MODE=F `stream{}` map extended to 3-way for TeleMT); `lib/telemt/install.sh`
  (`proxy_protocol = true` + `proxy_protocol_trusted_cidrs` in generated
  TOML for the co-located path only; bind moved to `127.0.0.1`; this
  must be a **separate code path** from the existing standalone
  `telemt_write_config()`, not a conditional inside it, matching how
  MODE=F is a separate function rather than a branch inside MODE=1/2's);
  `lib/panel/compose.sh` or a new file (co-located TeleMT service
  definition, `network_mode: host`).
- **New parameters/flags**: something like `TELEMT_COLOCATE=1`, gated on
  `MODE=F`, with an explicit guard rejecting it under `MODE=1`/`MODE=2`
  and (if the existing Caddy-under-F rejection precedent is followed)
  under `WEB_SERVER=2`.
- **Contracts that must not break**: MODE=1/MODE=2 byte-identical
  (`panel_generate_nginx_config()` body untouched); MODE=F's existing
  Panel/Sub/Xray branches functionally unchanged for installs that don't
  opt into the new flag; standalone TeleMT and Hysteria2 remain fully
  intact, separate, unmodified code paths.
- **Topology to result**: Variant A as diagrammed in the reviewed
  document (§ Candidate Topologies), amended with the `sockopt` fix
  confirmed under Runtime Verification above.
- **Tests/harness**: a byte-diff check that non-opted-in MODE=F output is
  unchanged; a live-connection check (not just a config-syntax check)
  that a genuine REALITY client completes a handshake through the
  extended `stream{}` block — this is the direct regression test for C2,
  and this review's Test 2 methodology (real Xray-core client/server
  pair, PROXY-injecting relay standing in for nginx, checked for the
  `AuthKey` log line as the pass/fail signal) is directly reusable as
  that test rather than needing to be designed from scratch.
- **Edge cases**: SNI collision between TeleMT's `tls_domain`/`mask_hosts`
  and `PANEL_DOMAIN`/`SUB_DOMAIN`/REALITY `serverNames` (installer-time
  validation, per the reviewed document's Routing Constraints section);
  a TeleMT co-located instance losing its `proxy_protocol_trusted_cidrs`
  entry after an nginx IP change (loopback should be stable, but worth a
  named constant rather than a hardcoded literal); rollback/uninstall
  path for the co-located flag needing to also revert TeleMT to its
  standalone bind — not discussed in the reviewed document at all and
  worth adding to its Open Questions if this proceeds.

# Remaining Blockers

1. **C2 — MODE=F `proxy_protocol` scoping — RESOLVED as a confirmed
   defect with an identified minimal fix**, per Runtime Verification
   above. No longer a blocker to *starting* Variant A implementation;
   it is now a required first step *within* that implementation (apply
   `sockopt.acceptProxyProtocol: true` to `api.sh`'s REALITY inbound,
   gated on `MODE=F`, plus a live-handshake regression test), not a
   standing question that needs further research before work begins.
2. The reviewed document's own Open Questions #2–#5 (exact TeleMT
   co-located deployment shape; `proxy_protocol_trusted_cidrs` scope;
   the unexplained Hysteria2 `/tcp` UFW rule; whether to use
   `mask_unix_sock`) remain open and are not resolved by this pass —
   these are policy/UX decisions that can be made during implementation,
   not technical blockers to starting it. Open Question #1 ("should
   `acceptProxyProtocol` be added to REALITY at all") is answered by
   this pass for MODE=F specifically: yes, it must be, to fix the
   confirmed defect — it remains an open question only for whether it's
   *also* worth adding anywhere else (e.g. MODE=1), which nothing in
   this pass required or investigated.
3. `docs/ARCHITECTURE.md`'s stale canonicity header (C3, previous pass)
   is not this document's problem to fix, but a future reader relying on
   `ARCHITECTURE.md` as automatically current should be aware it wasn't,
   as of the previous review, current relative to `beta`'s own tip.

---

# Evidence

**Repository** (`variant-f`, `git rev-parse HEAD` =
`942dc9685202dcb82e99d8949f4149d842b9abf8`; cloned fresh via
`git clone --branch variant-f https://github.com/stump3/server-manager.git`)

- `docs/MULTI_PROTOCOL_L4_INGRESS.md` — full 898-line read
- `lib/panel/nginx/config.sh` — full file read (413 lines); confirms
  MODE=1 `LISTEN_DIR` (:17), MODE=F stream block (:347-373),
  `proxy_protocol on;` (:371), dispatcher (:380-412)
- `lib/panel/api.sh` — full file read (149 lines); confirms
  `panel_reality_dest_val()` (:20-27), `panel_reality_inbound_port()`
  (:29-35), REALITY inbound JSON incl. `xver:1` (:122), no `sockopt`
  anywhere (grep, zero matches)
- `lib/panel/compose.sh` — grep for `network_mode`, confirms lines
  88,123,145,225,227,256,262,357,359,471,513,519,618
- `lib/panel/install.sh` — grep confirms MODE/WEB_SERVER guard at
  :172,175,208-209,261
- `lib/telemt/install.sh` — grep confirms `[[server.listeners]]`/`ip =`
  (:74-75), `tls_domain` (:78), `ghcr.io/telemt/telemt:latest` (:130),
  `ports:` (:140), `docker compose` (:175)
- `lib/hy2/install.sh` — grep confirms `listen_addr` (:165,175,205,222,224),
  UFW rules incl. unexplained `/tcp` open (:283-296)
- `lib/core/config.sh` — grep confirms `TELEMT_GITHUB_REPO="telemt/telemt"`
  (:30)
- `docs/ARCHITECTURE.md` — header read; canonicity claim checked against
  actual git history (see C3)
- `git log`, `git merge-base`, `git cat-file -t`, `git rev-list --count`
  against `origin/beta` and `variant-f` — used to establish branch
  topology and to check both HEAD-hash claims in the reviewed document's
  header and in `ARCHITECTURE.md`'s header

**Upstream — TeleMT**
- `github.com/telemt/telemt` (README, exists, MTProxy for Telegram on
  Rust + Tokio) — fetched
- `github.com/telemt/telemt/blob/main/config.toml` — fetched directly;
  confirms `[server] proxy_protocol = false # Enable if behind
  HAProxy/nginx with PROXY protocol` as a single top-level field, and
  `[[server.listeners]] ip = "0.0.0.0"` with no socket-path form
- `github.com/telemt/telemt/blob/main/docs/Config_params/CONFIG_PARAMS.ru.md`
  — searched; confirms `mask_unix_sock` mutual exclusivity with
  `mask_host`
- `github.com/telemt/telemt/issues/777` — searched and read via search
  snippets; confirms process-wide all-or-nothing behavior, the exact
  nginx-stream relay topology quoted in the reviewed document, and the
  reporter's `proxy_protocol_trusted_cidrs` config attempt failing with
  "Invalid PROXY protocol header"
- `github.com/telemt/telemt/issues/565` — independent corroboration of
  the same failure class in an unrelated HAProxy setup
- `github.com/telemt/telemt/issues/713` — unrelated but confirms
  `mask_proxy_protocol` as a real separate (outbound-mask-direction)
  field, cross-checking the project's general PROXY-protocol config
  surface

**Upstream — Xray-core**
- `xtls.github.io` / `deepwiki.com/XTLS/Xray-docs-next` —
  `acceptProxyProtocol` definition, "Only for inbound," no
  security-value restriction, confirmed
- `github.com/XTLS/Xray-core/discussions/5545` — fetched via search;
  confirms `"security": "reality"` + `"sockopt": {"acceptProxyProtocol":
  true}` in one working (if imperfect re: fallback xver passthrough)
  config
- `github.com/XTLS/Xray-core/issues/4832` — fetched via search; **is
  closed as "not planned,"** weaker evidence than the reviewed document's
  framing suggests (see D1)
- `github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/REALITY.ENG.md`
  — fetched; confirms `xver` field definition, "format similar to VLESS
  fallbacks' xver"
- `henrywithu.com` (third-party guide) — independent worked example of
  nginx `stream{}` SNI-mapping to two separate loopback-TCP Xray REALITY
  inbounds, corroborating that the general SNI-router-to-loopback-Xray
  pattern (the basis of Variant A) is a real, documented, working
  pattern beyond this repo's own MODE=F

**Upstream — nginx**
- `nginx.org/en/docs/stream/ngx_stream_proxy_module.html` — fetched in
  full; confirms `proxy_protocol on | off | v2;` **Context: `stream`,
  `server`** only, no variable/per-branch support (basis for C2)
- `github.com/nginx/nginx/issues/1061` — fetched via search; confirms
  UDP PROXY protocol gap, open as of the date checked

**Upstream — Hysteria2**
- `v2.hysteria.network/docs/advanced/Full-Server-Config`,
  `v2.hysteria.network/docs/getting-started/Server` — fetched via
  search; confirm `listen` is address:port only, no UDS, no
  PROXY-protocol-shaped field; masquerade modes as described
- Several independent third-party guides/schemas (SamNet, sing-box docs,
  a Python config dataclass mirroring the schema) — cross-checked, none
  show a UDS or PROXY-protocol field, consistent with official docs

**This pass — Runtime Verification (sandbox, not this repository)**
- `nginx -V` on a freshly installed `nginx/1.24.0 (Ubuntu)` package
  confirmed `--with-stream_ssl_preread_module` and `--with-stream=dynamic`
  present, matching what MODE=F's own code comment
  (`config.sh:343-346`) claims is available in `nginxinc/docker-nginx`'s
  `nginx:1.28` build — same module, adjacent version, sufficient to
  reproduce the directive-scoping question at issue.
- A config file structurally identical to `config.sh:347-373` (same
  `map`, same two `upstream{}` blocks, same single `server{}` with
  `ssl_preread on; proxy_pass $f_backend; proxy_protocol on;`), run
  against two Python raw-socket capture backends standing in for
  `panel_and_sub`/`xray_reality`, fed real `openssl s_client` TLS 1.3
  ClientHellos — produced the byte captures quoted under Runtime
  Verification / Test 1 above.
- `github.com/XTLS/Xray-core/releases/download/v26.7.28/Xray-linux-64.zip`
  — official release binary, fetched directly, `xray version` confirmed
  `Xray 26.7.28 ... 5ca6f4b`. Used for both the REALITY server (config
  shape copied from `api.sh:118-122`) and a matching REALITY client, per
  Test 2 above. Log lines quoted verbatim (`AuthKey[:16]`, `ClientVer`,
  `ClientShortId`, `failed to read client hello`, `accepting PROXY
  protocol`) are direct `stdout`/log captures from this binary, not
  paraphrased or reconstructed from documentation.
- A minimal Python TCP relay (source retained, not part of this
  repository) used to prepend a PROXY protocol v1 header to a live
  TCP stream ahead of a real REALITY client's traffic, reproducing what
  Test 1 showed nginx doing, with real Xray-core on both ends instead of
  a byte-capture stand-in.

---

## FINAL VERDICT

**READY WITH EXPLICIT PRECONDITIONS** (updated by this pass's Runtime
Verification — see that section and Consequence for Variant A above for
the full evidence; this supersedes the previous pass's "NOT READY FOR
IMPLEMENTATION" verdict, which was correct given what was known at the
time but is now resolved rather than merely re-affirmed).

The reviewed document's core technical analysis (TeleMT's process-wide
PROXY-protocol constraint, Hysteria2's lack of any co-location benefit,
the SNI-routing feasibility for TCP, the recommendation of Variant A over
B and C) is well-researched and holds up under independent re-verification
against the actual repository and real upstream sources — this was not a
fabricated or hallucinated research pass. Two small factual corrections
from the previous review pass (C1: `api.sh` does set `xver` explicitly;
D1: issue #4832 is a declined bug report, not a working example) don't
change its conclusions.

C2 — the previous pass's one substantive new finding, a plausible,
evidence-backed defect in **already-shipped** MODE=F code — is now
**CONFIRMED by direct runtime observation against real nginx 1.24 and
real Xray-core v26.7.28**, not left as an inference from directive
documentation. `proxy_protocol on;` in the `stream{}` block genuinely
sends a PROXY protocol v1 preamble to the `xray_reality` branch (proven
by byte capture), and that preamble genuinely prevents Xray's REALITY
inbound from reaching its authentication stage when `sockopt.acceptProxyProtocol`
is absent — this project's current shipped state (proven by comparing
real Xray-core log output with and without the preamble, and with and
without the fix). Adding `sockopt.acceptProxyProtocol: true` to the
REALITY inbound, gated on `MODE=F`, closes the gap — proven by the same
methodology showing successful auth-key derivation resume once the
option is enabled.

**The precondition for implementing Variant A is therefore concrete and
already resolved in direction, not open-ended**: apply the `sockopt` fix
to `api.sh` (gated on `MODE=F`, must not affect MODE=1), add a live
regression test using this pass's Test 2 methodology, confirm it, then
proceed with the TeleMT SNI branch addition as previously scoped. There
is no remaining technical unknown blocking the start of that work — what
remains (exact TeleMT co-located deployment shape, `proxy_protocol_trusted_cidrs`
scoping) is policy/UX, listed separately under Remaining Blockers above,
and does not gate starting implementation the way C2 did before this
pass.
