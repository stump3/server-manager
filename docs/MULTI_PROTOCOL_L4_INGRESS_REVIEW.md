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

### C2 — `proxy_protocol on;` in MODE=F's `stream{}` block is NOT scoped to `panel_and_sub` only — CONFIRMED by local runtime reproduction (byte-level), with one sub-claim left NOT VERIFIED

This is the most significant finding of this review, and neither the
reviewed document nor the repository's own code comment catches it. As
of this update, the mechanism has been **directly reproduced locally**,
not just inferred from documentation. Full method, raw output, and the
one part that remains unverified are below.

**Static analysis (unchanged from the previous pass of this review):**
`lib/panel/nginx/config.sh:347-373` (MODE=F) has **one** `stream {
server { ... } }` block. Both branches of `$f_backend` (`panel_and_sub`
→ `127.0.0.1:7443`, and `xray_reality` → `127.0.0.1:8443`) are reached
through this same single `server{}` block via `proxy_pass $f_backend;`.
`proxy_protocol on;` is set once, at the end of that same block
(`config.sh:371`). The code's own comment (`config.sh:360-370`) asserts:
*"proxy_protocol is enabled toward panel_and_sub ... It is intentionally
NOT enabled toward xray_reality."* The reviewed document repeats this
framing without independently checking it. Checked directly against
`nginx.org/en/docs/stream/ngx_stream_proxy_module.html`
(`proxy_protocol` directive definition): **Context: `stream`, `server`**
— there is no per-`proxy_pass`-destination, per-map-branch, or
per-variable scoping for this directive (unlike `proxy_pass` itself,
which explicitly supports `$variable` values for exactly this kind of
conditional routing — `proxy_protocol` does not).

**Local reproduction — method.** A minimal `nginx.conf` was built,
structurally identical to `config.sh`'s MODE=F `stream{}` block (same
`map $ssl_preread_server_name`, same two-branch `upstream`s, same single
`server { listen; ssl_preread on; proxy_pass $f_backend; proxy_protocol
on; }`), using `nginx/1.24.0` (Ubuntu) with the `ngx_stream_module` and
`ngx_stream_ssl_preread_module` dynamically loaded. In place of real
Panel/Xray backends, two plain Python TCP listeners were bound on
loopback (`127.0.0.1:19001` standing in for `panel_and_sub`,
`127.0.0.1:19002` standing in for `xray_reality`), each dumping every
raw byte it receives to a log file. A real TLS ClientHello was sent to
the `stream{}` listener via `openssl s_client -connect 127.0.0.1:19443
-servername www.microsoft.com`, i.e. an SNI that does **not** match
either `PANEL_DOMAIN`/`SUB_DOMAIN`, so it takes the `default` →
`xray_reality` branch — the branch a genuine REALITY client takes in
production.

**Result (raw bytes, `od -c`):** the `xray_reality`-standin listener
received, as the literal first 43 bytes of the connection:

```
PROXY TCP4 127.0.0.1 127.0.0.1 38602 19443\r\n
```

—immediately followed by the real TLS record header `\x16\x03\x01...`
and the rest of the ClientHello, whose SNI extension payload is visible
verbatim later in the same byte stream (`www.microsoft.com`), confirming
this genuinely was the ClientHello. The `panel_and_sub`-standin listener
received **no connection at all** for this request (correctly — the SNI
didn't match), ruling out both listeners always receiving everything
regardless of the `map`.

**This confirms, at the byte level, not by inference:** nginx's
`proxy_protocol on;` in MODE=F's shared `stream{}` block is applied to
the `xray_reality` branch exactly as it is to `panel_and_sub`, contrary
to the code comment and contrary to how the reviewed document described
it. **CONFIRMED**, upgraded from the prior pass's "strong inference from
nginx's own directive semantics" to a directly observed, reproducible
runtime result.

**What remains NOT VERIFIED: whether this specific byte sequence
actually breaks a live Xray REALITY handshake, end-to-end.** An attempt
was made to confirm this with a real `xray-core 26.3.27` binary
(downloaded from the official GitHub release), using a REALITY inbound
built from this project's exact `api.sh:122` template (no
`sockopt.acceptProxyProtocol`, `xver:1`, real x25519 keypair, real UUID)
and a matching REALITY client outbound. Two obstacles were hit:

1. This sandbox's network egress is transparently intercepted by an
   Anthropic egress gateway that MITMs outbound TLS (confirmed:
   connecting to `github.com:443` from this container returns a
   certificate chain issued by `O=Anthropic, CN=... Egress Gateway CA`,
   not GitHub's real certificate). REALITY's protocol requires
   unmodified, real TLS behavior from its `dest` target — an
   intercepted, re-signed TLS connection is not equivalent, so no
   external domain could be used as `dest` in this test.
2. Substituting a local, loopback `dest` (a self-signed TLS1.3 server
   run via `openssl s_server`, tried both with and without `-alpn h2`)
   did **not** produce a working baseline **even in the control case** —
   a genuine REALITY client talking to this genuine REALITY server, with
   no nginx or PROXY protocol involved at all, still failed with
   `REALITY: processed invalid connection ... target sent incorrect
   server hello or handshake incomplete` / `failed to read client
   hello`. This indicates `openssl s_server` does not sufficiently mimic
   whatever specific TLS1.3 behavior REALITY's auth/mimicry logic
   expects from a real `dest`. Since no passing control case could be
   established, this review cannot isolate and attribute a REALITY
   handshake failure specifically to the PROXY-protocol preamble using
   this method, in this sandbox, in the time available.

Per this task's own instruction (leave the sub-claim NOT VERIFIED if
runtime confirmation isn't possible), this is left explicitly **NOT
VERIFIED by live end-to-end reproduction**. It remains supported only at
the level of documented protocol structure: Xray-core's REALITY inbound
parses the beginning of the raw TCP stream as a TLS record, which
requires the first byte to be `0x16` (handshake content type); the
confirmed byte sequence above puts the ASCII string `PROXY TCP4 ...`
(starting `0x50`) there instead. Whether Xray's TLS record parser
rejects this immediately, waits for more bytes, times out, or has some
other behavior was not observed directly in this review and should be
checked with a real deployment (or a more faithful local `dest`, e.g. a
properly configured nginx/Caddy HTTPS site with HTTP/2) before being
treated as fully confirmed.

**Practical implication, stated at the confidence level actually
earned:** it is **confirmed** that MODE=F's nginx sends a PROXY protocol
v1 preamble to the `xray_reality` backend for every connection, contrary
to the code's own comment. It is **not yet confirmed, but plausible and
worth checking before relying on MODE=F's REALITY path**, that this
preamble causes real client handshakes to fail. A future agent with
either non-MITM'd network egress, or a more faithful local `dest` (a
real nginx HTTPS site with a browser-realistic TLS1.3+ALPN profile)
could close this last gap cheaply.

**Minimal fix, if the handshake-breaking sub-claim is later confirmed**
(unchanged from the previous pass): either split the single `server{}`
block into one per SNI branch so `proxy_protocol` can be set per
backend, or add `sockopt.acceptProxyProtocol: true` to the REALITY
inbound in `api.sh` so Xray consumes the header it is already receiving
instead of choking on it. Neither fix was applied — no `lib/` file was
touched in the course of this review or its verification work.

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
the proposed TeleMT extension.

**Status as of this update: the mechanism is CONFIRMED by direct local
reproduction** — a byte-for-byte capture (`od -c`) shows nginx's
MODE=F-shaped `stream{}` block delivering a literal `PROXY TCP4 ...\r\n`
preamble immediately before the real TLS ClientHello to whatever
listener stands in for the `xray_reality` backend, for a connection
that legitimately took the `default` branch of the SNI map (see C2 for
full method and raw bytes). This is no longer a documentation-only
inference.

**What is still open:** whether Xray's actual REALITY inbound, on
receiving that exact byte sequence, falls back to `dest` gracefully,
errors out, hangs, or does something else. A live-binary test with real
`xray-core 26.3.27` and this project's exact `api.sh` inbound template
was attempted and did not reach a conclusive result — not because the
PROXY-protocol question is unclear, but because this sandbox's egress
network MITMs external TLS (ruling out a real internet `dest`) and a
local `openssl s_server` substitute `dest` could not satisfy REALITY's
own strict TLS1.3 mimicry requirements even in the clean control case
(no PROXY protocol involved at all). This sub-claim is left explicitly
**NOT VERIFIED**, per instruction, rather than asserted from inference.

**This review's recommendation is unchanged and, if anything,
strengthened**: the confirmed byte-level finding alone is reason enough
to resolve or explicitly re-verify this with a live deployment before
any further work is layered on top of MODE=F's `stream{}` block —
extending a map that is already confirmed to deliver unexpected bytes to
the REALITY backend is a bad foundation regardless of whether TeleMT is
added, and regardless of whether the downstream handshake-failure
sub-claim is confirmed later.

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
| nginx stream, TCP, toward backend | Supported | Directive is `stream`/`server` scoped, **not** per-map-branch/variable-scoped | **CONFIRMED by local byte-level reproduction, this review**: MODE=F's own `stream{}` block sends the PROXY v1 preamble to the `xray_reality` branch too, contradicting its own code comment (see C2). Downstream effect on Xray's handshake specifically remains NOT VERIFIED (attempted, blocked by sandbox TLS interception + inability to establish a clean local REALITY control case) |
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
`proxy_protocol` scoping (C2, now CONFIRMED by local byte-level
reproduction — see Xray / REALITY Review) should be resolved, or its
downstream effect on a live REALITY handshake explicitly confirmed or
ruled out, before Variant A is built on top of it**, since Variant A's own
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

# Implementation Readiness

**NOT READY**, but narrowly, and for a more precise reason than in the
previous pass of this review — the mechanism is no longer hypothetical,
only its downstream consequence is still open.

C2 is now **CONFIRMED** at the byte level by direct local reproduction:
MODE=F's shipped `stream{}` block genuinely delivers a PROXY protocol
v1 preamble to the `xray_reality` backend for every connection,
contradicting its own code comment. What is **not yet confirmed** is
whether Xray's real REALITY inbound actually fails its handshake on
that input (attempted directly with a real `xray-core` binary and this
project's exact inbound template; blocked by this sandbox's TLS-MITM'ing
egress and by an inability to build a working local REALITY `dest`
control case — see C2 for the full account). This is exactly the kind
of narrow, cheap-to-close gap that should be resolved with real
infrastructure before implementation, not worked around by assuming an
answer in either direction:

- If a live check shows the handshake **does** fail: MODE=F should be
  fixed *first* (split the `server{}` block per branch, or add
  `sockopt.acceptProxyProtocol: true` to `api.sh`'s REALITY inbound),
  and only *then* should Variant A's TeleMT SNI branch be added on top
  of a `stream{}` block that is known-correct — adding a third branch to
  an already-ambiguous shared block compounds rather than resolves the
  issue.
- If a live check shows Xray tolerates or somehow ignores the preamble
  (less likely given TLS record parsing requires a `0x16` first byte,
  but not ruled out by this review): the confirmed byte-level finding
  becomes a latent risk worth a code-comment fix and a regression test,
  but not a hard blocker for Variant A specifically.

Either way, the check itself is cheap relative to building Variant A on
top of an unverified foundation: a `tcpdump -i lo -A port 8443` or
`openssl s_client` connect through a **real** MODE=F nginx instance,
against a **real** deployed Xray REALITY inbound, watching Xray's own
debug log for a handshake success or a `REALITY: processed invalid
connection` failure — this review's method (see C2) already provides
the nginx-side half of this test; only the Xray-side half (with real
infrastructure or network access instead of this sandbox's constraints)
remains.

Once that is checked (in either direction), this review considers
Variant A's scope, backward-compat guarantees, and MODE-flag framing
sound enough to proceed to an implementation task, subject to the open
questions the reviewed document already correctly identified (exact
TeleMT co-located deployment shape: systemd vs. Docker/host-network;
`proxy_protocol_trusted_cidrs` scoping for the installer; whether to
bother with `acceptProxyProtocol` on REALITY at all given loopback TCP
already carries no PROXY protocol today outside of C2's now-confirmed
accidental case).

**These are the only real remaining blockers** — the deployment-shape,
CIDR-scoping, and `acceptProxyProtocol`-necessity questions are
genuinely open decisions requiring a choice, not things this review
could resolve by reading code or running tests. They are listed, not
re-derived, in Remaining Blockers below.

If an implementation task is opened after C2 is resolved, its scope
should be:

- **Files to change**: `lib/panel/nginx/config.sh` (MODE=F `stream{}`
  map extended to 3-way, plus whatever C2's resolution requires —
  likely a `server{}`-per-branch split); `lib/telemt/install.sh`
  (`proxy_protocol = true` + `proxy_protocol_trusted_cidrs` in generated
  TOML for the co-located path only; bind moved to `127.0.0.1`; this
  must be a **separate code path** from the existing standalone
  `telemt_write_config()`, not a conditional inside it, matching how
  MODE=F is a separate function rather than a branch inside MODE=1/2's);
  `lib/panel/compose.sh` or a new file (co-located TeleMT service
  definition, `network_mode: host`); `lib/panel/api.sh` only if C2's
  resolution is "add `acceptProxyProtocol`" rather than "split the
  server block."
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
  document (§ Candidate Topologies), amended per C2's resolution.
- **Tests/harness**: a byte-diff check that non-opted-in MODE=F output is
  unchanged; a live-connection check (not just a config-syntax check)
  that a genuine REALITY client still completes a handshake through the
  extended `stream{}` block — this is the direct regression test for
  C2 and should exist regardless of whether C2 turns out to be a real
  bug, since it is currently untested either way per this review's
  reading of the existing harness references.
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

1. **C2 — MODE=F `proxy_protocol` scoping.** The mechanism itself is
   **CONFIRMED** (local byte-level reproduction: the PROXY v1 preamble
   is delivered to the `xray_reality` backend for every connection).
   The **remaining, narrower blocker** is only the downstream question —
   whether this actually breaks a live Xray REALITY handshake — which
   this review attempted to check with a real `xray-core` binary and
   could not resolve due to sandbox network constraints (TLS-MITM'ing
   egress; no working local REALITY `dest` control case). A future agent
   with real infrastructure or unrestricted network access should be
   able to close this in well under an hour using the method already
   documented in C2. This is the only blocker this review found through
   its own investigation, as opposed to inheriting from stg-blue.
2. The reviewed document's own Open Questions #1–#5 (whether to add
   `acceptProxyProtocol` to REALITY at all; exact TeleMT co-located
   deployment shape; `proxy_protocol_trusted_cidrs` scope; the
   unexplained Hysteria2 `/tcp` UFW rule; whether to use
   `mask_unix_sock`) remain open and are not resolved by this review —
   they were correctly left as DECISION REQUIRED by stg-blue and nothing
   found here changes that.
3. `docs/ARCHITECTURE.md`'s stale canonicity header (C3) is not this
   document's problem to fix, but a future reader relying on
   `ARCHITECTURE.md` as automatically current should be aware it wasn't,
   as of this review, current relative to `beta`'s own tip.

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

**Local runtime reproduction (this review, added on the follow-up pass)**
- `nginx/1.24.0` (Ubuntu, `apt-get install nginx-light
  libnginx-mod-stream`) with `ngx_stream_module` +
  `ngx_stream_ssl_preread_module`, config structurally identical to
  `lib/panel/nginx/config.sh`'s MODE=F `stream{}` block (`map
  $ssl_preread_server_name` → two-branch `upstream` → single `server {
  listen; ssl_preread on; proxy_pass $f_backend; proxy_protocol on; }`)
- Two raw-byte-dumping Python TCP listeners standing in for
  `panel_and_sub` (`127.0.0.1:19001`) and `xray_reality`
  (`127.0.0.1:19002`)
- `openssl s_client -connect 127.0.0.1:19443 -servername
  www.microsoft.com` used to send a real TLS ClientHello down the
  `default` branch; `od -c` used to inspect the raw bytes received by
  the `xray_reality`-standin listener (binary-safe, since the payload
  contains non-UTF-8 TLS bytes) — result: literal `PROXY TCP4
  127.0.0.1 127.0.0.1 38602 19443\r\n` immediately followed by the real
  TLS record and ClientHello (SNI `www.microsoft.com` visible in the
  captured bytes)
- `xray-core 26.3.27` binary (`github.com/XTLS/Xray-core/releases/latest`,
  official release asset) used to attempt a live REALITY handshake test
  with a server config built from this project's exact `api.sh:122`
  inbound template plus a matching client outbound; result inconclusive
  (see C2) due to this sandbox's TLS-intercepting egress gateway
  (confirmed via `openssl s_client -connect github.com:443`, certificate
  chain issued by `O=Anthropic, CN=... Egress Gateway CA`) and an
  inability to construct a local `openssl s_server`-based REALITY `dest`
  that passes REALITY's own mimicry checks even without any PROXY
  protocol involved
- All reproduction artifacts were created under `/tmp/repro/` (outside
  the repository) and all reproduction processes (`nginx`, `xray`,
  `openssl s_server`, the Python listeners) were killed at the end of
  the session; nothing under `/tmp/repro/` was copied into the
  repository and no repository file was used as a live config target

---

## FINAL VERDICT

**NOT READY FOR IMPLEMENTATION** — narrowly, and not because Variant A's
design is wrong.

The reviewed document's core technical analysis (TeleMT's process-wide
PROXY-protocol constraint, Hysteria2's lack of any co-location benefit,
the SNI-routing feasibility for TCP, the recommendation of Variant A over
B and C) is well-researched and holds up under independent re-verification
against the actual repository and real upstream sources — this was not a
fabricated or hallucinated research pass. Two small factual corrections
(C1: `api.sh` does set `xver` explicitly; D1: issue #4832 is a declined
bug report, not a working example) don't change its conclusions.

The one substantive new finding from this review (C2) is now a
**CONFIRMED, locally-reproduced defect in already-shipped** MODE=F code
— `proxy_protocol on;` in the `stream{}` block is not scoped to the
Panel/Sub backend the way the code's own comment and the reviewed
document both assume nginx's directive semantics allow. A byte-level
local reproduction shows Xray's REALITY backend genuinely receiving an
unrequested PROXY protocol v1 preamble immediately before every real
ClientHello. What is **not yet confirmed** — attempted directly with a
real `xray-core` binary, blocked by sandbox network limitations rather
than by any ambiguity in the question — is whether this specific input
actually breaks Xray's REALITY handshake in practice. That narrower,
well-scoped check is what should happen before Variant A is implemented
on top of that same `stream{}` block, since Variant A's own extension
would add a third branch to the same block rather than resolving the
ambiguity. Once that check is done (in either direction) and, if needed,
fixed or explicitly designed around, this review considers the reviewed
document's scope sound enough to carry into an implementation task as
outlined under Implementation Readiness above.

---

## Final Verdict

- **Current status of MODE=F**: functionally the same TCP L4 ingress
  described by the reviewed document and confirmed by this review
  (nginx `stream{}` SNI-routes Panel/Sub vs. Xray REALITY on loopback
  TCP, `WEB_SERVER=2` correctly rejected under `MODE=F`). Independent of
  TeleMT/Hysteria2, its `stream{}` block has one **confirmed** defect:
  it delivers a PROXY protocol v1 preamble to the Xray REALITY backend
  that the backend has no configured way to expect or strip.
- **Status of the `proxy_protocol` blocker**: the *mechanism* is
  **CONFIRMED** by direct local byte-level reproduction (not inference —
  see C2 for the raw captured bytes). The *consequence* — whether this
  breaks a real Xray REALITY handshake — is **NOT VERIFIED**; a live
  test with a real `xray-core` binary was attempted and left
  inconclusive by this sandbox's TLS-intercepting network egress and by
  an inability to build a working local REALITY `dest` control case, not
  by any remaining doubt about what bytes Xray receives.
- **Status of Variant A**: design and scope are still assessed as sound
  (TCP-only, MODE=F-gated, loopback-TCP TeleMT branch, Hysteria2 left
  standalone). It is gated, not rejected, by the item above — building
  it now would mean layering a third `stream{}` branch onto a block with
  a confirmed-but-unresolved defect in one of its existing two branches.
- **What the next implementation agent must do first**: with real
  infrastructure (or unrestricted network egress), reproduce this
  review's nginx-side method (already fully documented in C2, directly
  reusable) against a **real, deployed** Xray REALITY inbound built from
  `api.sh`'s actual template, and observe Xray's own debug log for a
  handshake success or a `REALITY: processed invalid connection`-style
  failure. This closes C2 completely in either direction. If it fails,
  fix MODE=F's `stream{}` block (per-branch split, or
  `sockopt.acceptProxyProtocol: true` in `api.sh`) before adding TeleMT's
  branch. If it doesn't fail, proceed to Variant A directly, noting the
  now-confirmed-but-harmless preamble in a code comment for future
  readers.
- **Decisions still required before implementation, independent of the
  above**: the reviewed document's own open items remain open and are
  not resolved by this review — exact TeleMT co-located deployment shape
  (systemd vs. Docker/host-network), `proxy_protocol_trusted_cidrs`
  scoping for the installer-generated TOML, whether `acceptProxyProtocol`
  should be added to REALITY regardless of C2's outcome, and the
  unexplained Hysteria2 `/tcp` UFW rule (cosmetic, non-blocking, but
  worth a one-line answer before it's copied into new code by pattern-
  matching).
