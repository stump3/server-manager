# Smart Network/Deployment Configurator — Shared UDP & TCP/UDP Topology Planner

> Status: **RESEARCH / DESIGN ONLY.** No `lib/` touched, no MODE=1/2/F
> semantics changed, no production `network/` code, no renderer, no
> firewall mutation, no apply logic. `poc/network-inspect` remains
> experimental and is not extended here beyond what's needed to define
> its consumer contract (§17).
>
> Builds on, and does not re-litigate, `docs/MULTI_PROTOCOL_L4_INGRESS.md`
> (verdict: **PARTIALLY FEASIBLE**, TCP-side SNI multiplexing of
> Xray/REALITY + TeleMT recommended as "Variant A") and its independent
> review `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md`. Where this document
> repeats a finding from those two, it is cited, not re-derived. This
> document's job is the **new** question: UDP multiplexing as a
> first-class planner concern, and the Discovery → Desired State →
> Capabilities → Planner → Plan pipeline that has to sit on top of all of
> it, TCP and UDP together.

---

## 1. Current project constraints (recap)

- MODE=1: Xray owns public `:443` directly; nginx lives on
  `/dev/shm/nginx.sock` only. MODE=2: Panel-only, nginx public, no
  co-located Node. MODE=F: nginx `stream{}` owns public `:443`,
  `ssl_preread` SNI-routes to Panel/Sub (loopback `:7443`) or default →
  Xray REALITY (loopback `:8443`). All three are **TCP-only** ingress
  strategies today — none of them touch UDP.
- TeleMT and Hysteria2 are **fully standalone** in this repo today: own
  public bind, own UFW rules, zero code intersection with `lib/panel/*`.
- `docs/MULTI_PROTOCOL_L4_INGRESS.md` already verified, independently
  re-reviewed, and is treated here as settled fact:
  - TCP SNI-multiplexing of REALITY + TeleMT via nginx `stream{}` is
    feasible (Variant A), contingent on non-colliding SNI/mask domains
    and TeleMT's **process-wide** `proxy_protocol` flag forcing
    standalone-vs-co-located to be a deploy-time fork, not a runtime
    toggle.
  - nginx `stream{}` UDP proxying is real (`ngx_stream_proxy_module`,
    1.9.13+) but has **no PROXY protocol support for UDP**
    (`nginx/nginx` issue #1061, open) and **no protocol/SNI inspection
    for UDP** — nginx's UDP session model is a `hash $remote_addr`
    keyed pool pointing at **one** upstream group per `listen` block,
    not a per-packet routing decision between multiple distinct
    backends. This document independently re-confirms both facts
    (§9, §10) and treats them as the load-bearing reason nginx cannot
    be a `SHARED_UDP_QUIC_SNI` provider.
  - Recommendation in that document: Hysteria2 stays standalone on its
    own UDP port; no version of nginx-fronted Hysteria2 survived
    verification.

This document's new mandate is to check whether **any** provider
(not just nginx) can do better for UDP, and to build the planner-facing
model regardless of the answer.

---

## 2. Previous Discovery findings (recap)

`poc/network-inspect` (read-only, experimental, unregistered — see its
own README) already proves the chain

```
port → socket → PID → process → systemd/docker ownership → public exposure
```

is buildable today from `ss`/`ip -j`/`/proc`/Docker Engine API/`systemctl
show`/firewall tooling alone, and — critically — that it can distinguish

- `permission_denied` (couldn't check — non-root run against a
  root-owned socket), from
- `not_found_or_cross_namespace` (PID resolved to nothing this
  container's PID namespace can see)

rather than collapsing both into a false "unowned" verdict. This
distinction is **structural** for the planner (§16, safety constraints):
a planner that cannot tell "I don't have permission to know" from
"nothing is there" cannot safely decide whether a port is free.

The PoC also does a crude `nginx -T` `stream {` block count (not a full
AST parse) sufficient to confirm the "exactly one `stream{}` block"
invariant this project already relies on in `variant_j.sh`. It does
**not** attempt Caddy admin-API capability probing or HAProxy Data Plane
API probing — those are new Inventory sources this document has to
specify (§17), not ones the PoC already covers.

---

## 3. The Shared UDP problem, restated

The temptation is to reason: *"Hysteria2 is QUIC. QUIC has an SNI-like
mechanism in its TLS ClientHello. Therefore a QUIC-aware L4 router can
multiplex Hysteria2 with another UDP service on `:443`, the same way
`ssl_preread` multiplexes TCP TLS today."*

Every step in that sentence needs independent verification, and two of
them turn out to depend on **operator configuration choices that already
exist in this project**, not on protocol theory:

1. QUIC's Initial-packet ClientHello is only extractable **in the clear**
   when the QUIC Initial packet is unobfuscated. Hysteria2 supports an
   optional obfuscation layer (Salamander / Gecko) that XORs/fragments
   every UDP datagram with a keyed hash **before** it is a recognizable
   QUIC packet at all (§7). This repo's Hysteria2 integration
   (`lib/hy2/install.sh`, `docs/hysteria-traffic-research.md`) does
   **not** configure `obfs:` today — verified by grep, zero hits for
   `obfs`/`salamander` anywhere under `lib/hy2/`. So *for this project as
   currently built*, Hysteria2's QUIC Initial packets are standard,
   unobfuscated QUIC — inspectable in principle. This is a **fragile
   fact**, not a permanent one: turning on Salamander/Gecko obfuscation
   (a legitimate, documented Hysteria2 feature aimed at exactly the kind
   of DPI resistance this project cares about for REALITY/TeleMT) would
   silently and completely break any QUIC-SNI-based shared-UDP topology,
   with no error at config time from the L4 router — it would simply
   stop matching and fall through to a default/drop rule. **This
   dependency must be encoded as an explicit capability precondition,
   not assumed.**
2. Even with unobfuscated QUIC, "inspectable" only holds for the *first*
   Initial packet of *each* path. QUIC's whole raison d'être includes
   connection migration and NAT-rebinding robustness specifically
   *because* real-world UDP paths change mid-session — and a migrated
   path's post-migration packets are short-header, encrypted with
   session keys the router does not have, carry no SNI, and are
   correlated only by Connection ID, not by the 4-tuple / `hash
   $remote_addr` mechanism every UDP L4 proxy surveyed here actually
   uses (§14, §15). This is not a Hysteria2-specific problem; it's a
   general property of any non-CID-aware L4 UDP proxy in front of any
   QUIC-based protocol.

Both facts move the "is shared UDP possible" question from "yes/no" to
"under which specific, checkable preconditions, and with which specific
residual risk."

---

## 4. Linux UDP mechanisms — what's actually available

| Mechanism | What it does | What it does NOT do |
|---|---|---|
| Bare `bind()` to `0.0.0.0:P/udp` | One process owns the port | Nothing else can bind the same `ip:port` without `SO_REUSEPORT` |
| `SO_REUSEPORT` | Kernel lets **N sockets** bind the identical `ip:port`; incoming datagrams are load-spread across them by a kernel-side hash of the packet's own source `(addr, port)` (consistent per-flow, so retransmits/replies of one flow land on the same socket as long as the socket set is stable) | **Zero protocol awareness.** The kernel cannot tell a Hysteria2 datagram from a WireGuard datagram from a game-server datagram — it only ever asks "which socket in this reuseport group does this packet's 4-tuple hash to," never "what backend does this decrypted SNI want." Using `SO_REUSEPORT` to "share" a UDP port between two *different services* only works if you can tolerate an arbitrary fraction of each service's traffic being handed to the other service's socket — which breaks both. It is a **scale-out** primitive (N workers of the *same* service), not a **multi-tenant** primitive (N different services). |
| UDP proxying (generic, e.g. nginx `stream`, HAProxy `dgram-bind`-adjacent, custom) | Terminates the client-facing UDP socket in a proxy process, re-sends payload to a backend, tracks a session table keyed by 4-tuple + timeout | Doesn't imply protocol awareness by itself — see next row |
| UDP session affinity | Some table (in-kernel conntrack, or in-process, e.g. nginx's `hash $remote_addr consistent`) that pins a given client 4-tuple to a given backend for the session's lifetime | Doesn't survive NAT rebinding / QUIC connection migration unless the affinity key is something more durable than the 4-tuple (e.g., QUIC Connection ID) — **no software surveyed in this document implements CID-based affinity** (§15) |
| UDP protocol inspection | Peeking at the first bytes of a datagram to classify protocol (e.g., "looks like QUIC": long-header form, version field, etc.) | Classification ≠ content extraction. "Looks like QUIC" is a cheap byte-pattern check; extracting the SNI requires actually AEAD-decrypting the Initial packet's CRYPTO frame using the **publicly-known** Initial secret derivation (RFC 9001 §5.2 — anyone, not just the true endpoint, can do this, because Initial keys are derived from the connection ID + a public per-QUIC-version salt, not from anything secret) |
| QUIC inspection specifically | The above AEAD-decrypt-and-parse-ClientHello step, done by a small number of real projects (see §8) | Only ever sees the *first* Initial packet of a *given* path. Says nothing about subsequent short-header packets or about a migrated path's new Initial (there usually isn't a new Initial on migration — see §15) |
| UDP load balancing | Spreading many backend instances of the *same* service (health-checked, round-robin/hash) | Not multiplexing of *different* services |
| UDP multiplexing (the actual target concept) | Multiple *distinct* services sharing one `ip:port`, disambiguated per-connection by protocol/SNI content, each connection's *entire* subsequent lifetime correctly steered to the same backend despite path changes | This is the union of "protocol/QUIC inspection" + "routing decision" + "session affinity that survives migration" + "backend forwarding" — no single Linux primitive gives you this for free; it is entirely userspace application logic, and as shown in §15, the "survives migration" part is the piece nothing surveyed here actually has |

**Conclusion of this section, stated per the task's own framing**: `A.
SO_REUSEPORT` is a scale-out mechanism for **one** protocol's own
workers; it is not, and cannot be made into, evidence for `B.
Protocol-aware routing` between **different** protocols. This document
does not conflate them anywhere below.

---

## 5. QUIC inspection and SNI extraction — the actual mechanism

RFC 9001 §5.2 fixes the "Initial Salt" per QUIC version as a public
constant. Anyone holding a QUIC Initial packet's Destination Connection
ID can derive the Initial AEAD keys and decrypt the CRYPTO frame inside
— which, for the client's first Initial packet, is the start of (or all
of, for a short enough ClientHello) the TLS 1.3 ClientHello, including
SNI and ALPN. This is **not** "breaking encryption" in any meaningful
sense — the Initial-level encryption exists to prevent tampering and
casual on-path fingerprinting resistance, not confidentiality against a
router that's about to forward the packet on the server's behalf anyway.
This is exactly the property that lets:

- Envoy's QUIC listener do `filter_chain_match: server_names` on a
  `quic_options` listener (but see §11 — Envoy's implementation requires
  **terminating** the QUIC/TLS session at that point, i.e., it needs the
  actual certificate/key, not passthrough)
- caddy-l4's `layer4.matchers.quic` ("matches connections that look like
  QUIC") combined with the generic `tls` SNI matcher (which, per its own
  docs, also applies to "any `tls.handshake_match` modules" — i.e., the
  same SNI-matching code path TLS-over-TCP uses) do the same thing
  **without** terminating the session — verified from a real, posted
  working config (caddy-l4 issue #118: a `udp/0.0.0.0:443` server with
  `match: tls: sni:` routes to different `upstreams: dial: udp/...`
  backends per SNI value, with **no** certificate/key configured on that
  route — passthrough, not termination)

This distinction — **passthrough SNI-routing of QUIC** (caddy-l4) vs.
**QUIC/HTTP-3 termination with SNI-selected TLS context** (Envoy,
HAProxy) — is the single most load-bearing technical fact in this whole
research block, because Hysteria2 (like REALITY) needs to own its own
QUIC session end-to-end (it does its own auth inside the tunnel, and its
own masquerade camouflage); a router that terminates QUIC on Hysteria2's
behalf would break Hysteria2 outright, the same way a TLS-terminating
proxy in front of REALITY would break REALITY's whole security model.
**Only passthrough SNI-routing is architecturally usable here.**

---

## 6. Hysteria2 traffic/transport analysis

- Built on IETF QUIC (RFC 9000) + the Unreliable Datagram Extension
  (RFC 9221); TCP relay = new QUIC bidirectional stream per connection,
  UDP relay = QUIC unreliable datagrams. Confirmed from upstream
  protocol docs and this project's own traffic-research doc (Traffic
  Stats API operates on already-established QUIC connections, consistent
  with this).
- Default mode: **HTTP/3 masquerade** — an unauthenticated probe gets a
  real HTTP/3 response from a configured upstream site
  (`masquerade: {type: proxy, ...}`), i.e., the QUIC Initial/ClientHello
  is **not disguised or obfuscated** in this mode; it looks like an
  ordinary QUIC ClientHello with SNI = the ACME domain the operator
  configured. **This is what this project currently deploys**, per §3.
- Optional obfuscation: **Salamander** — every UDP datagram (Initial
  packets included) is XORed with `BLAKE2b-256(pre-shared-key ||
  random-8-byte-salt)` before being put on the wire. A passive/on-path
  observer without the pre-shared key **cannot even recognize the
  datagram as QUIC**, let alone parse a ClientHello out of it. **Gecko**
  (newer, builds on Salamander) additionally fragments long-header
  (handshake) packets into 2–8 randomly-sized, randomly-padded chunks
  specifically to defeat statistical/size-based DPI, on top of the same
  Salamander wrap. Neither obfuscation mode has any known,
  publicly-documented "obfuscation-aware QUIC matcher" in any L4 proxy
  surveyed in this document (caddy-l4, nginx, HAProxy, Envoy) — a router
  would need the Salamander password itself to de-obfuscate before it
  could even attempt QUIC detection, which no generic L4 proxy config
  surface here exposes as a feature.
- **Full path required by the task (§ "критически важно"), evaluated for
  this project's *current, unobfuscated* deployment**:

  ```
  UDP listener                    → real (any UDP-capable proxy)
  → protocol/QUIC inspection      → real, IF unobfuscated (caddy-l4 quic matcher)
  → routing decision (SNI)        → real, IF unobfuscated (caddy-l4 tls/sni matcher, passthrough)
  → session affinity              → real for the *initial* 4-tuple (caddy-l4 tracks
                                     the UDP "connection" like any stateful L4 proxy)
  → backend forwarding            → real (caddy-l4 udp upstream dial)
  → subsequent datagrms           → real AS LONG AS the 4-tuple doesn't change
  → NAT rebinding / migration     → **NOT SOLVED** — no CID-based re-association
                                     found in caddy-l4 or any other surveyed proxy;
                                     a migrated path is, from the proxy's point of
                                     view, a brand-new UDP "connection" that either
                                     (a) doesn't carry a fresh Initial/ClientHello to
                                     re-match on (typical case — QUIC does not resend
                                     the ClientHello on migration, RFC 9000 §9), in
                                     which case the proxy's `on_no_match` default
                                     action decides its fate (drop, or a wrong
                                     backend), or (b) if the proxy has no independent
                                     memory of "this Connection ID belongs to
                                     Hysteria2," the datagrams are misrouted or
                                     dropped until/unless something else recovers
                                     the session (Hysteria2 itself may reconnect from
                                     scratch, which the *user* experiences as a
                                     dropped-and-reconnected proxy session, not a
                                     seamless migration — defeating one of QUIC's own
                                     headline benefits)
  ```

  **Verdict for Hysteria2 specifically: the path is provably complete up
  to and including "backend forwarding," and provably incomplete at "NAT
  rebinding / connection migration."** This is a genuine, named
  capability gap — `quic_migration_safe: false` for every surveyed
  provider — not a hand-wave.

- Can Hysteria2 be sent to a backend `127.0.0.1:<port>` behind such a
  router? Yes, mechanically — it's just another UDP proxy_pass target,
  same as any other backend in this document's IR. Nothing about
  Hysteria2 itself objects to being fronted this way (it already
  survives being fronted by NAT/CDN edges in the wild, e.g., some
  users run it behind cloud LBs).
- Session-affinity requirement Hysteria2 places on a fronting proxy: at
  minimum, 4-tuple stability for the session's duration; QUIC's own
  application-layer semantics (streams, unreliable datagrams) are
  layered *inside* the already-established path and place no additional
  requirement on the L4 proxy beyond "don't reorder/drop/misdirect
  datagrams belonging to one path."

---

## 7. Caddy L4 (`mholt/caddy-l4`) — detailed capability read

Verified from the project's own `docs/servers.md`, `docs/matchers.md`,
`docs/routes.md`, and multiple real-world issue threads showing working
configs (not just docs prose):

| Capability | Status | Evidence |
|---|---|---|
| UDP listener | **Supported** | `docs/servers.md`: `packet_conn_wrappers` section explicitly documents `udp/:443` server addresses; multiple working configs (issues #118, #348) show `udp: { listen: ["udp/0.0.0.0:443"], routes: [...] }` |
| UDP proxy / UDP upstream | **Supported** | Same configs show `handle: [{handler: proxy, upstreams: [{dial: ["udp/backend:port"]}]}]` |
| Protocol matchers (generic) | **Supported, extensive** | `layer4.matchers.*`: `tls`, `quic`, `ssh`, `socks4/5`, `rdp`, `dns`, `regexp`, `remote_ip`, and more, per `docs/matchers.md` and the pkg.go.dev module listing |
| QUIC matcher | **Supported** | `layer4.matchers.quic` — "matches connections that look like QUIC," explicitly documented as composable with `tls.handshake_match` modules "such as ServerName (SNI)" |
| SNI extraction / routing inside QUIC | **Supported, passthrough, real working example found** | Issue #118's full config: `udp/0.0.0.0:443` with `match: [{tls: {sni: [...]}}]` routing to distinct `udp/...` upstreams per SNI, with **no** TLS termination configured on that route (the `handler: tls` step is used only on a *different* route in the same config, for a service that explicitly wants termination) |
| Multiple UDP upstreams / multiplexing on one port | **Supported, directly demonstrated** | Same config routes `turn.grundstil.de` → `signaling_coturn:3389`, `vpn.*` → `wireguard:51820`, `dot.*` → (terminate TLS then) `dnsproxy:583`, all on the same `udp/0.0.0.0:443` listener |
| Session tracking / affinity | **Present, generic (4-tuple + `matching_timeout`)** | `matching_timeout` (default 3s) governs how long a connection has to complete the *matching* phase; the underlying `net.PacketConn`-based session concept is 4-tuple keyed, same limitation class as nginx's `hash $remote_addr` — **not** CID-based (no evidence found of QUIC-LB-style CID routing in this codebase) |
| Runtime API / dynamic config | **Supported** — Caddy's native admin API (`POST /load`) does atomic config reloads; this is a **Caddy** platform feature, not caddy-l4-specific, and caddy-l4 rides on it like any other Caddy app |
| Module detection (three distinct states) | Must be checked explicitly, not assumed — see Capability Registry (§13). `caddy list-modules` (or `caddy list-modules --versions`) shows whether `layer4` app modules are compiled in at all; **a `caddy` binary existing on the host is not evidence `caddy-l4` is compiled into it** — this is a custom-build-time (`xcaddy`) dependency, not a plugin loaded at runtime. This project must never infer "Caddy L4 capability available" from "Caddy is installed." |
| Maturity / stability caveat | caddy-l4's own README: "This app is very capable and flexible, but is still in development. Please expect breaking changes." — **not a criticism to ignore**; this is the project's own stated stability posture and should be reflected as a lower confidence weight in planner scoring (§20), not a hard capability gate |

**Net finding**: Caddy L4 is the **only** surveyed provider that
demonstrably does real, passthrough, multi-backend QUIC SNI routing on
one shared UDP port, backed by an actual observed working configuration
— not composition-by-inference the way REALITY's own UDS story required
in the prior research document. Its gap is exactly the general QUIC
NAT-rebinding/migration gap from §6, which is not specific to Caddy L4 —
no surveyed alternative does better.

---

## 8. Nginx — UDP capability re-confirmation

Independently re-verified directly against `nginx.org` docs (not just
citing the prior research document, though it agrees):

- `listen ... udp [reuseport]` — real, `ngx_stream_core_module`, 1.9.13+.
  `reuseport` note in the docs itself: *"In order to handle packets from
  the same address and port in the same session, the `reuseport`
  parameter should also be specified"* — i.e., nginx's own docs frame
  `reuseport` here purely as a **multi-worker scale-out** mechanism for
  *nginx's own* UDP listener replicas, exactly matching this document's
  §4 distinction (A vs. B) — nginx does not claim protocol-aware routing
  from `reuseport` and neither does this document.
- `ngx_stream_proxy_module` UDP proxying — real, with worked examples
  (DNS, SIP, game-server patterns using `hash $remote_addr[:$remote_port]
  consistent` for session pinning).
- **No SNI/QUIC inspection module for UDP exists in nginx.** `ssl_preread`
  is TCP-only (it reads a TLS ClientHello over a TCP stream before the
  handshake proceeds — there's no `udp_preread`/`quic_preread` module in
  stock nginx or in the documented third-party module list). This means
  nginx's UDP `proxy_pass` can point at exactly **one** upstream pool per
  `listen` block, selected by session hash — not by protocol content. It
  is a load-balancer for **one** UDP service's replicas, not a
  multiplexer for **several different** UDP services.
- **No PROXY protocol for UDP** — `nginx/nginx` issue #1061, open,
  confirmed directly. Independently re-confirms the finding already in
  `docs/MULTI_PROTOCOL_L4_INGRESS.md`.
- OpenResty/Lua: OpenResty extends the **HTTP** and (separately) the
  **stream** modules with Lua scripting hooks (`stream_lua` directives),
  but this only gives you programmability *around* the same underlying
  `ngx_stream_core_module` UDP session model — it does not add QUIC
  packet parsing as a built-in primitive. Writing a QUIC ClientHello
  parser in Lua inside `content_by_lua_block` is theoretically possible
  (nothing prevents arbitrary byte parsing in Lua) but is **build-your-
  own QUIC-SNI-router-from-scratch**, not a documented, community-
  supported nginx capability — this document does not count "someone
  could write this in Lua" as an existing capability, consistent with
  not crediting hypothetical/unbuilt work anywhere else in this report.

**Direct answer to the task's specific question**: *"Может ли stock
Nginx stream быть UDP multiplexer для Hysteria2 + другого UDP-протокола
на одном `IP:port`?"* — **No.** Stock nginx stream can share a UDP
`ip:port` across multiple *replicas of the same backend pool*
(load-balancing), but has no mechanism to inspect QUIC/SNI and therefore
cannot disambiguate *two different UDP services* on one port. This is a
structural absence of a `udp_preread`/QUIC-matcher module, not a
configuration gap.

---

## 9. HAProxy — OSS vs. Enterprise, and why neither fits this use case

- **HAProxy's QUIC support (2.6+ experimental, more complete from
  2.7/3.x) is HTTP/3 *termination*.** Every working config found (own
  blog examples, community gists, forum threads) uses `bind quic4@:443
  ssl crt ... alpn h3` — i.e., HAProxy holds the TLS certificate/key and
  terminates the QUIC/TLS session itself, then either serves HTTP/3
  directly or re-proxies as HTTP to a backend. This is the Envoy-style
  "termination for SNI-selected cert" pattern from §5, not the
  passthrough pattern Hysteria2 needs.
- **No generic UDP passthrough L4 proxy capability was found in HAProxy
  OSS** comparable to `ngx_stream_proxy_module` or caddy-l4's
  `proxy`/`udp` handler. `dgram-bind` exists (`log-forward` sections,
  HAProxy 2.3+) but is scoped specifically to **syslog message
  forwarding** — it is not a general-purpose UDP reverse proxy primitive
  and has no protocol-matching/SNI-routing capability at all; conflating
  it with a general UDP proxy would be exactly the kind of "UDP proxy
  exists therefore UDP multiplexing is proven" error the task explicitly
  warns against (§ "Не считать A доказательством возможности B" applies
  here by the same logic, one layer up: *dgram-bind exists* is not
  evidence of *protocol-aware UDP multiplexing exists*).
- **HAProxy Enterprise / HAProxy One / ALOHA** are referenced in
  HAProxy's own marketing as "a flexible data plane... for TCP, UDP,
  QUIC and HTTP traffic," but the concrete, checkable capability
  (QUIC=HTTP/3 termination) is the same shape as OSS's — this document
  found no Enterprise-only feature that changes the termination-vs-
  passthrough answer for a non-HTTP protocol like Hysteria2. The
  Enterprise/OSS distinction that *does* matter for this project's
  broader TCP story (Data Plane API for dynamic reloads, more mature
  Runtime API) is a real capability-registry distinction (§13) but not
  one that unlocks shared-UDP-for-Hysteria2 specifically.
- **Verdict: HAProxy (OSS or Enterprise) is not a viable
  `SHARED_UDP_QUIC_SNI` provider for this project's actual need**
  (passthrough routing of an opaque, self-authenticating QUIC-based proxy
  protocol) — its UDP/QUIC story solves a different problem
  (HTTP/3-terminating reverse proxy), and its only generic UDP forwarding
  primitive (`dgram-bind`) is syslog-scoped, not protocol-routing-scoped.

---

## 10. Envoy / Envoy Gateway — reference only, not a candidate

Not proposed for adoption (task explicitly frames this as reference-only
research), but useful for its architectural ideas:

- `udp_proxy` listener filter — a generic, protocol-agnostic UDP session
  proxy (hash-based backend selection), same capability class as nginx's
  UDP `proxy_pass` — confirmed from Envoy's own listener-filter docs.
- QUIC support (`udp_listener_config: quic_options: {}` +
  `filter_chains: [{filter_chain_match: {server_names: [...]}, transport_socket:
  {name: envoy.transport_sockets.quic, ...}}]`) requires a
  `QuicDownstreamTransport` with an actual certificate/key on the
  matched filter chain — this is SNI-selected **termination**, the same
  category as HAProxy's, not passthrough. A GitHub issue on Envoy's own
  tracker (#23857) asks essentially this project's exact question — "can
  I use QUIC support with an upstream that itself speaks QUIC, and does
  TLS Inspector work for SNI-based upstream selection under QUIC" — and
  the reported behavior is an error requiring exactly one HTTP
  Connection Manager filter, i.e., **QUIC listeners in Envoy are built
  around HTTP/3 termination, not generic passthrough L4 QUIC routing.**
  The **SNI dynamic forward proxy** filter (`TLS inspector` + `sni_
  dynamic_forward_proxy` + `tcp_proxy`) that *does* do genuine TCP-SNI
  passthrough (no cert needed, "the TLS handshake is passed through by
  Envoy") is explicitly **TCP-only** in every example found, and is
  itself flagged upstream as "alpha and not production ready."
- **Architectural idea worth carrying into this project's own IR/planner
  (§16), independent of adopting Envoy itself**: Envoy's `xDS`
  separation of *listener* (where/how bytes arrive) from *filter chain
  match* (which criteria select a handler) from *cluster* (where
  validated traffic actually goes) is a clean three-layer decomposition
  this document's own Plan IR should mirror (`listeners` / `routes[].match`
  / `routes[].action`+`backend`), rather than nginx's or Caddy's more
  monolithic per-`server{}`-block shape. This is taken as a design
  influence in §16, not as a dependency on Envoy.

**Verdict: Envoy is not usable for this project's passthrough-QUIC need
either**, for the identical structural reason as HAProxy — its QUIC path
requires termination.

---

## 11. Other UDP multiplexers surveyed and rejected

Per the task's own filter (reject anything abandoned, Kubernetes-only,
experimental-only, or unsuited to a single VPS):

| Project | Verdict | Reason |
|---|---|---|
| Traefik | **Rejected for this need** | Traefik's UDP router (`entryPoints` with UDP + `udp.routers`) does generic UDP load-balancing/forwarding, same class as nginx/Envoy's `udp_proxy` — no QUIC-SNI passthrough matcher found in its documented router-rule vocabulary (`HostSNI` rules in Traefik are documented specifically for its **TCP** router, mirroring the TCP-SNI-passthrough pattern, not UDP) |
| OpenResty (standalone, beyond the nginx note in §8) | **Rejected** | Same underlying stream module; no additional QUIC capability beyond what's noted in §8 |
| Kubernetes-native L4 gateways (e.g., Gateway API implementations with UDPRoute) | **Rejected per task's own exclusion criteria** | Require a Kubernetes control plane; out of scope for single-VPS deployment |
| `sing-box` / `Xray-core`'s own inbound-side routing | **Different problem** | These are proxy-*software* protocol implementations (they can host a Hysteria2 or QUIC-based inbound *themselves*, and some, like sing-box, support multiple protocols on one process), not a general-purpose L4 router in front of independently-running Hysteria2/other binaries. Relevant as a **future alternative topology** (see §26 MVP framing: "run Hysteria2 and the other UDP service as inbounds of the same multi-protocol proxy binary" sidesteps the whole shared-port-routing problem by not needing a separate router at all) but out of scope for this document's provider survey, which is specifically about *fronting independently-deployed* services |
| `clienthellod` / `modcaddy` clienthellod module | **Reference-only** | Exists specifically to reflect/inspect ClientHello and QUIC Initial packets for fingerprinting/telemetry purposes — confirms the RFC 9001 §5.2 public-Initial-Salt mechanism is real and already exploited by real tooling (corroborates §5), but is not itself a routing/proxying product |

No abandoned or purely-experimental UDP multiplexer was found that beats
Caddy L4's demonstrated capability for this specific need.

---

## 12. Shared IP+port vs. shared IP different port vs. different IP

Three genuinely different problems, worth keeping textually separate
because the planner has to choose among them, not just among providers:

```
(a) same IP + same UDP port     → requires real protocol-aware multiplexing (§3–§11)
(b) same IP + different UDP port → trivial: two independent bind()s, zero multiplexing needed
(c) different IP + same UDP port → trivial: two independent bind()s (different IP = different socket
                                     identity to the kernel), zero multiplexing needed
```

(b) and (c) are **not** "lesser" solutions — for this project's actual
service set (Hysteria2 + at most one hypothetical second UDP tenant),
either one **fully solves** the stated goal ("one public IP, several UDP
services reachable") **without** taking on the QUIC-migration gap from
§6/§15 at all, as long as the operator has either a spare port or a
spare IP to allocate. The planner's scoring model (§20) must treat (b)/(c)
as **strictly preferred** over (a) whenever available, precisely because
they carry none of (a)'s residual risk. This mirrors, on the UDP side,
exactly the same "don't reach for the fancy mechanism when a boring
allocation solves it" instinct that the TCP-side research (`MULTI_PROTOCOL_
L4_INGRESS.md`, Variant B rejection) already applied to "should Hysteria2
be pulled behind nginx at all."

---

## 13. Desired State Model

Extending the sketch from the task brief into something the planner can
actually consume. Each service declares its **transport needs**, not a
topology — topology is the planner's output, never an input.

```yaml
schema_version: "desired-state-1"

services:
  - id: xray-reality
    role: proxy-inbound
    transport: tcp
    tls:
      mode: reality           # reality | terminate | passthrough-opaque | none
      sni_values: [reality.example.com]
    proxy_protocol:
      accept: optional         # none | optional | required
    backend_hint:
      loopback_port: 8443      # this project's existing MODE=F pattern

  - id: telemt
    role: proxy-inbound
    transport: tcp
    tls:
      mode: passthrough-opaque  # TLS-mimicry; router must not care about content beyond SNI
      sni_values: [telemt-mask.example.com]
    proxy_protocol:
      accept: required          # per docs/MULTI_PROTOCOL_L4_INGRESS.md: process-wide, all-or-nothing
    exclusivity: single_ingress_path   # cannot ALSO be reachable direct-public; deploy-time fork

  - id: hysteria2
    role: proxy-inbound
    transport: udp
    quic:
      is_quic: true
      obfuscation: none          # none | salamander | gecko  — MUST be explicit, default none
      sni_values: [hy2.example.com]
      migration_tolerant_required: false   # operator-declared risk acceptance, see §19/§20
    proxy_protocol:
      accept: not_supported       # protocol fact, not a policy choice
    backend_hint:
      loopback_port: 9443

  - id: web
    role: http-decoy-or-real-site
    transport: tcp
    tls:
      mode: terminate
    backend_hint:
      loopback_port: 7443

network:
  public_ipv4_count: 1            # planner must ask/discover; never assume 1
  public_ipv6_count: 0
  tcp:
    port_443:
      requested_sharing: shared    # shared | dedicated | dont_care
  udp:
    port_443:
      requested_sharing: dont_care # shared | dedicated | dont_care — dont_care lets planner
                                    # prefer (b)/(c) from §12 over (a) automatically
```

Fields this model deliberately keeps **separate** because they map to
different capability checks downstream:

- `tls.mode` vs `proxy_protocol.accept` — orthogonal (REALITY needs the
  first to stay `reality`/passthrough and can independently opt in or
  out of the second, per the prior research's PROXY-protocol findings).
- `quic.obfuscation` as its own explicit, defaulted-to-`none` field —
  because §3/§6 showed this single field silently determines whether
  *any* shared-UDP topology is even attemptable. This must never be
  inferred; it must be read from the actual Hysteria2 config the
  Discovery layer finds on disk (§17 dependency table), or asked of the
  operator if Discovery cannot see it.
- `exclusivity: single_ingress_path` — a first-class desired-state flag
  (not just a planner side-effect) for TeleMT, because the process-wide
  PROXY-protocol constraint from the prior research makes "co-located
  AND still directly reachable" not a valid state at all, ever, for this
  specific service. Modeling it as a service-level exclusivity
  constraint (rather than leaving it implicit in the planner) means a
  future different service with the same limitation doesn't need new
  planner code — just the same flag.
- `migration_tolerant_required` — lets an operator explicitly say "yes, I
  understand shared-UDP-QUIC-SNI has a NAT-rebinding gap, and I accept
  the risk for this service" rather than the planner silently deciding
  for them. Default `false` means the planner will *not* offer
  `SHARED_UDP_QUIC_SNI` as a candidate unless this is flipped, per the
  Safety Constraints in §19.

---

## 14. Capability vocabulary

### TCP

```yaml
tcp:
  listen: true
  proxy: true
  sni_inspection: true          # ssl_preread-class capability
  tls_passthrough: true
  tls_termination: true
  http_proxy: true
  proxy_protocol_in: true
  proxy_protocol_out: true
  n_way_sni_routing: true        # can route by SNI to MORE than 2 backends (not just binary)
  unix_socket_backend: true
  unix_socket_listener: false    # per prior research: not all backends support UDS listen
```

### UDP

Reworked from the task's sketch after the research above — several of
the originally-sketched fields turned out to conflate distinct concerns,
and one critical field was missing entirely:

```yaml
udp:
  listen: true
  reuseport: true                 # scale-out ONLY — never treated as multiplexing evidence
  proxy: true                     # generic 4-tuple/session-hash forwarding to ONE backend pool
  session_affinity: true          # 4-tuple-keyed, survives normal operation
  protocol_inspection: false      # can classify first-packet protocol at all (byte-pattern level)
  quic_inspection: false          # can AEAD-decrypt QUIC Initial + parse ClientHello (RFC9001 §5.2)
  quic_sni_routing: false         # quic_inspection ABOVE + route to N distinct backends by SNI,
                                   # WITHOUT terminating the session (passthrough — see §5)
  quic_sni_termination: false     # separate flag: CAN select cert/backend by SNI but ONLY by
                                   # terminating the QUIC/TLS session itself (Envoy/HAProxy pattern) —
                                   # this is a DIFFERENT, NOT INTERCHANGEABLE capability from the one above,
                                   # and is USELESS for self-authenticating opaque protocols like
                                   # Hysteria2/REALITY-equivalents, which must own their own handshake
  quic_migration_safe: false      # CID-based re-association across a 4-tuple change — no surveyed
                                   # provider has this; kept as an explicit field so the day one does,
                                   # the registry has somewhere to record it, rather than needing a
                                   # schema change
  multi_backend_same_port: false  # can this SPECIFIC capability set (quic_sni_routing, or a non-QUIC
                                   # equivalent protocol matcher) actually place ≥2 DIFFERENT services'
                                   # traffic on one port — this is the field the planner's UDP-sharing
                                   # decision ultimately keys on, and it must be false unless
                                   # quic_sni_routing (or an equivalent inspection+route capability
                                   # for a non-QUIC UDP protocol) is independently true; it is NOT
                                   # implied by proxy+reuseport alone (§4's core distinction)
  proxy_protocol_in: false        # per §8/§9, false for nginx AND for Hysteria2 itself regardless of proxy
  obfuscation_transparent: false  # can this provider route traffic that uses Salamander/Gecko-class
                                   # obfuscation at all — always false for every provider surveyed;
                                   # kept explicit so a desired-state with obfuscation:salamander
                                   # is REJECTED at the capability-matching stage with a clear reason,
                                   # not silently mis-routed
```

`multi_backend_same_port` is the field this document adds beyond the
task's own sketch, because without it the planner has no single boolean
to gate the "is `SHARED_UDP_QUIC_SNI` even a candidate" decision on — it
would otherwise have to re-derive "quic_sni_routing AND NOT
quic_sni_termination-only" inline in planner logic every time, which is
exactly the kind of implicit reasoning §4 warns against baking into code
instead of into the capability model.

---

## 15. UDP session semantics — what actually determines backend affinity

Per provider, concretely (not hypothetically):

| Provider | Affinity key | Timeout model | Migration-safe? |
|---|---|---|---|
| nginx stream UDP | `$remote_addr[:$remote_port]` via `hash ... consistent` on the upstream block | `proxy_timeout` (fixed idle timeout per session) | No — new 4-tuple = new session = re-hashed, possibly to a *different* backend replica (fine for load-balanced replicas of the *same* service; would silently reshuffle a *stateful* single-instance backend if one were ever put behind a multi-replica hash by mistake) |
| caddy-l4 UDP | Underlying `net.PacketConn` session, effectively 4-tuple-scoped per Go's UDP semantics, gated by `matching_timeout` for the initial matching phase | `matching_timeout` (default 3s) for match phase; ongoing session lifetime governed by the handler/upstream's own idle behavior | No — same limitation; no QUIC-LB CID table found in the codebase or docs |
| Envoy `udp_proxy` | 4-tuple session table (`session_filters` can customize routing per Envoy's own architecture docs, but the underlying session key is still the datagram's source 4-tuple by default) | Configurable idle timeout | No, for the same structural reason |

**What would actually be migration-safe**: an implementation of the
`QUIC-LB` draft (`draft-ietf-quic-load-balancers`), where the **server**
(Hysteria2, in this case) is configured to embed a
routing-identifiable, load-balancer-coordinated pattern into the
Connection IDs it issues, and the **load balancer** decodes that pattern
instead of relying on the 4-tuple. **No evidence was found that
Hysteria2 supports configurable/QUIC-LB-compatible Connection ID
generation**, and no evidence was found that any of the surveyed L4
proxies implement the load-balancer side of QUIC-LB either. This is a
"neither side of the project's actual stack has this" gap, not a
one-sided limitation — closing it would require upstream changes to
Hysteria2 itself, which is outside this project's control, exactly the
same category of constraint the prior research found for TeleMT's
process-wide PROXY-protocol flag.

**Practical consequence for the planner**: `SHARED_UDP_QUIC_SNI` should
be modeled as *"works correctly until the client's network path changes
mid-session, at which point the client experiences it as a dropped
connection that Hysteria2's client will silently retry/reconnect
(new handshake, fresh Initial packet, correctly re-matched — this part
recovers cleanly) rather than a seamless QUIC migration."* For a typical
Hysteria2 client on a stable connection (desktop, server-to-server), this
is a non-issue. For mobile clients that roam between Wi-Fi and cellular
mid-session, it is a real, user-visible degradation relative to running
Hysteria2 on its own dedicated port with no fronting proxy at all (where
migration works exactly as QUIC intends, because the datagrams go
straight to Hysteria2's own socket, which *is* CID-aware since it's the
actual QUIC endpoint).

---

## 16. Provider model — why Topology ≠ Provider

Restating the task's own framing with this project's actual candidates
filled in, because this is the piece that keeps the planner extensible
without a code change every time a new tool shows up:

```
Topology:  SHARED_TCP_SNI          Provider: nginx-stream   (ALREADY IMPLEMENTED, MODE=F)
Topology:  SHARED_TCP_SNI          Provider: caddy-l4        (possible, not implemented, WEB_SERVER=2 rejected today)
Topology:  SHARED_TCP_SNI          Provider: haproxy         (possible in principle — TCP SNI
                                                               passthrough via `req.ssl_sni` + `use_backend`
                                                               is a real, mature HAProxy OSS feature,
                                                               NOT investigated in depth in this document
                                                               since TCP-side is already settled by the
                                                               prior research; flagged as an open provider
                                                               option for TCP only, not UDP)
Topology:  SHARED_UDP_QUIC_SNI     Provider: caddy-l4        (possible — the ONLY provider this
                                                               document found real evidence for)
Topology:  SHARED_UDP_QUIC_SNI     Provider: nginx-stream    (NOT POSSIBLE — no QUIC/SNI inspection module)
Topology:  SHARED_UDP_QUIC_SNI     Provider: haproxy         (NOT POSSIBLE for passthrough — QUIC path is
                                                               termination-only)
Topology:  SHARED_UDP_QUIC_SNI     Provider: envoy           (NOT POSSIBLE for passthrough, same reason)
Topology:  DIRECT_UDP              Provider: none (kernel)   (Hysteria2 standalone, current/recommended default)
Topology:  SEPARATE_PORTS          Provider: none (kernel)   (§12(b) — no proxy needed at all)
Topology:  SEPARATE_IPS            Provider: none (kernel)   (§12(c) — no proxy needed at all)
```

The provider column is genuinely swappable per topology — the planner's
job (§18) is to enumerate every `(topology, provider)` pair whose
provider's capability row satisfies the topology's requirement
predicate, not to hardcode "shared UDP means caddy-l4" anywhere in logic.

---

## 17. Topology primitives

Refining the task's initial list into ones that actually earn their
keep as distinct planner-visible states (merging/dropping a few that
turned out to be provider details, not topology facts):

```
DIRECT_TCP              — one service, one dedicated TCP port, no L4 router in front
DIRECT_UDP              — one service, one dedicated UDP port, no L4 router in front
SHARED_TCP_SNI          — ≥2 TCP/TLS services share one TCP ip:port, disambiguated by SNI
                           (passthrough; this project's existing MODE=F pattern)
SHARED_UDP_QUIC_SNI     — ≥2 UDP/QUIC services share one UDP ip:port, disambiguated by
                           QUIC-Initial-SNI (passthrough; NOT yet implemented anywhere
                           in this project; conditional on obfuscation:none, see §13/§19)
SEPARATE_PORTS          — ≥2 services on the same IP, each on its own dedicated port
                           (no multiplexing; §12(b))
SEPARATE_IPS            — ≥2 services, each on its own IP, same or different ports
                           (no multiplexing; §12(c))
COLOCATED               — service and its fronting router share a network namespace /
                           host (loopback-reachable) — this project's `network_mode: host`
                           pattern for MODE=F
REMOTE_NODE             — service lives on a separate host from the router; UDS options
                           are structurally unavailable (kernel/filesystem property,
                           already established in the prior research), loopback options
                           are unavailable too — only real network (TCP/UDP over the
                           actual interface) is possible between router and backend
```

Dropped from the task's initial sketch, with reasons:

- `TCP_L4_INGRESS` / `UDP_L4_INGRESS` as separate primitives — these
  turned out to just be "any topology where a router is present," which
  is already implied by `SHARED_TCP_SNI`/`SHARED_UDP_QUIC_SNI` vs.
  `DIRECT_*`; keeping them as separate top-level primitives would have
  meant every topology needed two tags instead of one, with no
  additional planner-relevant information carried.
- `TCP_SNI_ROUTER` / `QUIC_SNI_ROUTER` as topology-level primitives — these
  are **provider mechanism names**, not topology facts (a `TCP_SNI_ROUTER`
  is just *how* `SHARED_TCP_SNI` gets implemented) — conflating them
  would violate the task's own "Topology ≠ Provider" principle, so they
  were folded into the provider capability row (`sni_inspection`,
  `quic_sni_routing`) instead of kept as topology enum values.

---

## 18. Planner

```
Current Inventory (Discovery output, §21)
        +
Desired State (§13)
        +
Available Providers (what's actually installed/buildable on THIS host)
        +
Capability Registry rows for those providers (§14, keyed by
        provider+version+module, per §20's registry shape)
        +
Safety constraints (§19)
        ↓
Candidate topologies  — every (topology, provider) pair from §16 whose
                         capability row's relevant fields are all true
                         AND whose desired-state preconditions
                         (obfuscation:none, migration_tolerant_required
                         if choosing a QUIC-passthrough topology, etc.)
                         are satisfied
        ↓
Rejected candidates + reasons — every pair that failed a capability
                         check or a safety constraint, with the SPECIFIC
                         field that failed named explicitly (never a
                         generic "not supported")
        ↓
Scoring / deterministic preference (§20)
        ↓
Selected topology
        ↓
Concrete Plan (Plan IR, §22)
```

Worked example, filled in with this document's actual findings (not the
task's placeholder example, which assumed capabilities this research did
not confirm):

```
Desired:
  Hysteria2 (obfuscation: none) + a second hypothetical UDP service
  one public IPv4
  requested_sharing: dont_care  (operator has NOT asked for shared :443
                                  specifically — they asked to run both
                                  services)

Candidate:
  SEPARATE_PORTS  (Hysteria2 :443/udp, other service :8443/udp)
  ACCEPTED (top-scored)
  reason:
    ✓ zero new capability dependency
    ✓ zero QUIC-migration risk (§15) — both services keep native,
      CID-aware, fully QUIC-compliant behavior on their own sockets
    ✓ zero new provider to install/maintain
    − minor operational cost: consumers must know/discover the
      non-standard port for the second service (acceptable trade,
      scored below)

Candidate:
  SEPARATE_IPS
  ACCEPTED only if a second public IPv4 is actually available
  (Inventory-dependent — not offered at all if the host has one IPv4)

Candidate:
  DIRECT_UDP × 2 on the SAME port
  REJECTED
  reason: UDP port collision (both bind() calls would fail; not a
          policy rejection, a kernel-level impossibility)

Candidate:
  SO_REUSEPORT-based sharing on the same port
  REJECTED
  reason: SO_REUSEPORT provides no protocol-aware routing guarantee —
          traffic would be split between the two services' sockets by
          kernel hash, not by which service the packet is actually FOR
          (§4) — this is not a scoring-based rejection, it's a
          hard capability mismatch, listed first among rejections
          per the explainability requirement (§23)

Candidate:
  nginx UDP stream
  REJECTED
  reason: capability row quic_sni_routing=false, multi_backend_same_port=false
          for this provider — no QUIC/SNI inspection module exists (§8)

Candidate:
  HAProxy (OSS or Enterprise)
  REJECTED
  reason: capability row quic_sni_routing=false — QUIC path is
          termination-only, unsuited to a self-authenticating opaque
          protocol like Hysteria2 (§9)

Candidate:
  Caddy L4, SHARED_UDP_QUIC_SNI
  ACCEPTED AS A CANDIDATE (capability-satisfying) but SCORED BELOW
  SEPARATE_PORTS/SEPARATE_IPS by default, because:
    ✓ udp listener
    ✓ quic inspection
    ✓ quic sni routing (passthrough, not termination)
    ✓ session affinity (4-tuple, for the session's initial path)
    ✗ migration-safe = false — and desired-state's
      migration_tolerant_required defaulted to false, meaning this
      topology is NOT EVEN OFFERED unless the operator explicitly
      opts in by setting migration_tolerant_required: true — see §19
      Safety Constraints for why this is a hard gate, not a scoring
      penalty

Selected: SEPARATE_PORTS (assuming operator did not opt into
          migration_tolerant_required, and did not specifically request
          shared_443 for UDP)
```

This worked example differs from the task's own illustrative example
(which pre-supposed Caddy L4 would simply be `ACCEPTED`) precisely
because this document's job was to check that assumption rather than
inherit it — and the check surfaced the migration-safety gate as a
genuine, previously-unstated precondition.

---

## 19. Safety Constraints (P0)

Restating and completing the task's own minimal list, with the two new
ones this research specifically surfaced added at the end:

```
443/TCP occupied by unknown owner
    → STOP  (Inventory could not attribute the socket to a known,
             managed service — never assume it's safe to share/replace)

443/UDP occupied by unknown owner
    → STOP  (identical reasoning, UDP side)

PID unresolved because permission_denied
    → STOP  (per §2 — "couldn't check" must never be silently treated
             as "confirmed free")

PID unresolved because not_found_or_cross_namespace
    → STOP  (equally — a PID namespace boundary hiding the true owner
             is not evidence of absence)

UDP sharing requested but no protocol-aware routing capability present
    → REJECT topology (not a soft preference — no provider found in
      this research can honestly claim otherwise for the general case)

QUIC routing required but provider capability row's quic_sni_routing
(passthrough) is false, even if quic_sni_termination (§14) is true
    → REJECT topology — termination-only QUIC capability must NEVER be
      silently substituted for passthrough capability; a planner that
      did so would be routing Hysteria2 into a topology that breaks its
      end-to-end authentication, which is a correctness bug, not a
      degraded-but-working state

Provider can proxy UDP but session affinity does not survive path
change, AND desired-state's migration_tolerant_required is false/unset
    → REJECT topology as a DEFAULT-safe gate — per §15/§18, this is the
      new, most important safety constraint this document adds beyond
      the task's own list, because it's the one gap every surveyed
      provider shares and none of them advertise clearly in their own docs

Existing ingress config unmanaged
    → never overwrite automatically (matches this project's existing
      "no automatic apply" posture, restated here for UDP too)

Firewall authority unknown
    → never mutate automatically (same)

Desired state declares quic.obfuscation != none for a service being
routed through ANY protocol/SNI-inspecting UDP topology
    → REJECT topology, unconditionally, regardless of provider — this
      is a protocol-level impossibility (§3/§6), not a capability gap
      that a "better" provider could ever close without the
      obfuscation pre-shared key itself becoming part of the router's
      own trusted config (a materially different, much riskier design
      not evaluated in this document because no driver for it exists
      in this project's current requirements)
```

---

## 20. Capability Registry — provider/version/module granularity

Per the task's own §12 requirement, the registry entry shape (not
frozen — this is the minimum viable shape found necessary while working
through §7–§11 above):

```yaml
capability_registry_entry:
  provider: caddy
  version: "2.x"                 # Caddy core version, from `caddy version`
  module: caddy-l4                # from `caddy list-modules --versions`;
                                   # ABSENCE of this line for a given host's
                                   # `caddy` binary means the registry MUST
                                   # record capabilities as "provider present,
                                   # module absent" — never silently assume
                                   # a stock `caddy` binary has layer4 compiled in
  module_version: "<commit/tag if resolvable>"
  confidence: "verified_by_probe"  # verified_by_probe | verified_by_docs |
                                    # inferred_by_composition | unverified
  capabilities:
    udp: { listen: true, proxy: true, quic_inspection: true,
           quic_sni_routing: true, quic_migration_safe: false,
           multi_backend_same_port: true, obfuscation_transparent: false }
    tcp: { listen: true, proxy: true, sni_inspection: true,
           tls_passthrough: true, n_way_sni_routing: true }
  stability_note: "upstream project self-describes as still in
                    development, breaking changes possible — reflect as
                    a scoring penalty (§ scoring below), not a hard gate"
```

**Why `provider`/`version`/`module`/`feature` as four distinct fields,
not fewer**: the task's own §12 example (`Caddy` ≠ `Caddy + caddy-l4`;
`HAProxy OSS` ≠ `HAProxy Enterprise + UDP module`; `Nginx` ≠ `nginx
stream module available`) is not hypothetical for this exact research —
§9's HAProxy finding (`dgram-bind` exists but is syslog-scoped, not a
general UDP proxy feature) is a **real, concrete instance** of exactly
this trap: naive capability detection ("does haproxy have a UDP bind
directive? yes → assume general UDP proxying") would have produced a
wrong answer. `feature` as its own granularity level (not just `module`)
is what lets the registry say "yes, `haproll dgram-bind` exists" while
still correctly recording "general UDP proxy: no" as a separate,
independently-false field.

**Scoring model** (deterministic, not ML/heuristic-fuzzy):

1. Hard-reject anything failing a §19 safety constraint (no score at
   all — never enters the ranked list).
2. Among remaining candidates, prefer strictly by: (a) fewest new
   capability dependencies introduced (favors `DIRECT_*`/`SEPARATE_*`
   over any `SHARED_*` topology when both satisfy the desired state);
   (b) fewest new components to install/maintain; (c) reuses an
   already-proven-in-this-exact-project pattern over a novel one (this
   is why `SHARED_TCP_SNI` via nginx-stream — already running in
   MODE=F — is preferred over introducing caddy-l4 for the TCP side even
   though caddy-l4 could theoretically also do it); (d) among otherwise
   tied candidates, prefer the provider with `confidence:
   verified_by_probe` over `verified_by_docs` over
   `inferred_by_composition`.
3. `stability_note`-flagged providers (like caddy-l4's own "expect
   breaking changes" self-description) get a scoring penalty, not a
   rejection — they can still win if nothing else clears the safety gate
   at all (this is exactly the shared-UDP case: caddy-l4 is the only
   provider that clears §19's capability gates in the first place, so
   it wins by elimination whenever `migration_tolerant_required: true`
   is set, penalty notwithstanding).

---

## 21. Plan IR

Provider-independent, per the task's hard requirement. Extending the
task's own sketch with the fields this research showed are load-bearing
(obfuscation precondition, migration-safety acknowledgment, PROXY
protocol per-listener vs. process-wide distinction):

```yaml
schema_version: "plan-ir-1"

listeners:
  - id: l_tcp_443
    transport: tcp
    address: 0.0.0.0
    port: 443
    role: ingress

  - id: l_udp_443
    transport: udp
    address: 0.0.0.0
    port: 8443          # example: SEPARATE_PORTS selected — Hysteria2 keeps
                          # its own dedicated port, no shared listener at all
    role: ingress

routes:
  - id: r_reality
    transport: tcp
    match: { sni: [reality.example.com] }
    action: tls_passthrough
    backend: { kind: loopback_tcp, address: 127.0.0.1, port: 8443 }
    proxy_protocol: { direction: out, required_by_backend: optional }

  - id: r_web
    transport: tcp
    match: { sni: [web.example.com, sub.example.com] }
    action: tls_terminate
    backend: { kind: loopback_tcp, address: 127.0.0.1, port: 7443 }

  - id: r_hysteria2
    transport: udp
    match: { any: true }        # DIRECT_UDP / dedicated-port case — no
                                  # content matching needed, whole
                                  # listener belongs to one service
    action: proxy
    backend: { kind: loopback_udp, address: 127.0.0.1, port: 9443 }
    preconditions:
      quic_obfuscation: none    # recorded even for the DIRECT_UDP case,
                                  # so a future re-plan that considers
                                  # SHARED_UDP_QUIC_SNI knows immediately
                                  # whether that door is even open
    migration_safety: native     # native | proxied_best_effort — "native"
                                  # here because there's no proxy in the
                                  # path at all; would read
                                  # "proxied_best_effort" for a
                                  # SHARED_UDP_QUIC_SNI route instead

safety:
  requires_manual_apply: true
  overwrites_unmanaged_config: false
```

**Critical requirement restated and honored**: nothing above is an
nginx/Caddy/HAProxy-specific directive — a renderer for any provider
consumes the same IR and emits its own config syntax. The `migration_
safety` and `preconditions.quic_obfuscation` fields exist specifically
so that a renderer (or a human reading the Plan before manually applying
it, per this project's existing patch-delivery convention) can see the
residual risk without re-deriving it from the capability registry every
time.

---

## 22. Inventory → Planner dependency matrix

| Planner needs | Discovery source | Status in this project today |
|---|---|---|
| TCP listeners | `ss`/`/proc` | Implemented in `poc/network-inspect` (experimental) |
| UDP listeners | `ss`/`/proc` | Same |
| PID | `/proc`/`ss` | Same, with honest `permission_denied` / `not_found_or_cross_namespace` split |
| process | `/proc` | Same |
| container | Docker Engine API (read-only) | Same |
| systemd | `systemctl show` | Same |
| firewall (authoritative frontend) | `nft`/`firewalld`/`ufw`/`iptables-save` | Same (PoC explicitly does NOT do full nftables ruleset semantics — only enough to say which tool, if any, is authoritative) |
| nginx capabilities | binary presence + `nginx -V` (compiled modules) + `nginx -T` (crude `stream{}` block count only, per PoC's own stated scope) | **New Inventory need, not yet built**: `nginx -V` module list (does this binary even have `--with-stream`, `--with-stream_ssl_preread_module`?) is not currently probed anywhere in this repo or the PoC — a real gap this document surfaces, since §8's whole nginx UDP analysis assumes the module is compiled in |
| Caddy capabilities | `caddy version`; `caddy list-modules --versions` (or admin API `/config/` introspection if the process is already running) | **New Inventory need.** Per §7/§13, this MUST distinguish "Caddy binary present" from "layer4 app compiled in" — never inferred from binary presence alone |
| Caddy L4 specifically | Same `caddy list-modules --versions` output, checked for the `layer4` app and its `layer4.matchers.quic` / `layer4.matchers.tls` sub-modules specifically (a custom build could in principle include `layer4` without every matcher — worth recording at feature granularity per §20's registry shape, even though no evidence was found of matchers being separately excludable in practice) | New, same as above |
| HAProxy capabilities | `haproxy -vv` (feature list, e.g. `+QUIC` — per §9 example) | New Inventory need |
| Data Plane API (HAProxy) | process/socket/API probe (is the Data Plane API service actually running and reachable, separate from whether the `haproxy` binary supports it) | New Inventory need |
| interfaces | `ip -j addr` | Already in PoC scope conceptually (public-exposure classification depends on it) |
| public IPs (count, v4/v6) | `ip -j addr` + a routability check (not just "is this address in a private range") | Partially covered — the PoC's `public_exposure` classification is the right shape; **counting distinct public IPv4 addresses specifically** (needed for §12(c) `SEPARATE_IPS` to even be offered as a candidate) is a new, small extension of the same data the PoC already gathers, not a new discovery mechanism |
| certificates | filesystem paths / ACME state | Not yet covered by the PoC; relevant mainly for TLS-terminating routes, out of this document's core UDP focus but named for completeness per the task's own matrix template |
| Hysteria2's own `obfs:` config | reading `/etc/hysteria/config.yaml` (already a known path in this repo, per `docs/hysteria-traffic-research.md`) for the `obfs.type` key | **New, small, and the single most safety-critical new Inventory read this document identifies** — per §13/§19, a planner that cannot see this field cannot safely offer or reject `SHARED_UDP_QUIC_SNI` at all, and must instead ask the operator explicitly rather than guess |

**Minimal Inventory this planner actually needs, restated**: everything
the PoC already does, **plus** three small additions — (1) nginx compiled-
module list, (2) Caddy/caddy-l4 module list via `list-modules
--versions`, (3) the Hysteria2 `obfs.type` config value. Notably, this
document does **not** find a need for full HAProxy Data Plane API
integration or full nftables ruleset parsing to answer this document's
own central questions — those remain legitimately out of scope per the
PoC's own stated boundaries, not because they're unimportant in general,
but because nothing in this document's findings depended on them.

---

## 23. Scenario matrix

| # | Scenario | Outcome under this document's model |
|---|---|---|
| A | MODE=1 (Xray owns :443 direct, nginx UDS-only) | No change — Discovery sees Xray as the known, managed owner of :443/tcp; UDP side untouched since Hysteria2 co-location was never in scope for MODE=1 |
| B | MODE=F (nginx stream :443 → Xray/TeleMT/Web) | TCP side: already-settled `SHARED_TCP_SNI`/nginx-stream, per prior research — this document adds nothing new here except confirming it stays untouched by any UDP-side decision |
| C | Hysteria2 on its own dedicated UDP port | `DIRECT_UDP`, no provider needed — this is this project's actual current, working state, and (per §12/§20 scoring) the planner's **default recommendation** even after this research, absent an explicit operator ask for shared UDP |
| D | Hypothetical shared UDP (Hysteria2 + another UDP protocol, same port) | `SHARED_UDP_QUIC_SNI` via caddy-l4 is the only technically-real candidate, **gated** on (i) Hysteria2 `obfs.type: none` and (ii) operator opting into `migration_tolerant_required: true` per §19 |
| E | Caddy L4 as TCP+UDP unified ingress | Technically possible for both legs (TCP: yes, matches `SHARED_TCP_SNI` capability row; UDP: yes, per D) — **not recommended as a wholesale nginx replacement** by this document, since it would mean re-deriving and re-verifying MODE=F's entire already-working TCP behavior on a different, admittedly-still-in-development provider, for a UDP benefit that itself requires an explicit risk opt-in; if ever pursued, should be scoped as "Caddy L4 for the NEW shared-UDP need only, nginx-stream stays as-is for TCP" rather than a full swap |
| F | Nginx, TCP and UDP capabilities checked separately | TCP: `sni_inspection: true` (already proven, MODE=F). UDP: `quic_sni_routing: false` (§8) — this asymmetry is exactly why this document insists on separate TCP/UDP capability rows rather than one combined "nginx capability" score |
| G | HAProxy OSS, TCP and UDP checked separately | TCP: SNI-passthrough via `req.ssl_sni`/`use_backend` is real and mature (flagged, not deeply investigated here since TCP is settled territory) — a legitimate future `SHARED_TCP_SNI` provider alternative to nginx-stream, not evaluated further in this UDP-focused document. UDP: `quic_sni_routing: false` (§9) |
| H | Unknown UDP owner on the target port | Planner **STOPs**, per §19 — no candidate topology is even generated |
| I | `permission_denied` resolving a listener's PID | Planner **STOPs**, per §19 — treated identically to scenario H, never silently downgraded to "probably fine" |
| J | Multiple public IPv4 addresses available | `SEPARATE_IPS` (§12c) becomes an available, typically top-scored candidate the moment Inventory reports `public_ipv4_count > 1` — no multiplexing provider needed at all in this case, which the planner should surface as the simplest safe option before even mentioning caddy-l4 |
| K | QUIC NAT rebinding / connection migration relevance check | Relevant **only** if `SHARED_UDP_QUIC_SNI` is even a live candidate (i.e., scenario D territory) — for scenarios C/E's `DIRECT_UDP` legs and for J's `SEPARATE_IPS`, Hysteria2's own native QUIC stack (not any L4 proxy) handles migration correctly on its own, so this scenario's risk is specifically and only a `SHARED_UDP_QUIC_SNI`-topology concern, never a general Hysteria2 concern |

---

## 24. Separate-IP alternative, elaborated

Worth restating plainly because it's the single biggest complexity/risk
reducer this whole research surfaced, and it costs nothing to prefer it
when available:

```
IP #1
  TCP :443 → Xray REALITY (+ TeleMT via SHARED_TCP_SNI, already settled)
  UDP :443 → Hysteria2 (DIRECT_UDP, its own native QUIC stack, fully
              migration-safe, zero new provider)

IP #2 (only needed if/when a second UDP tenant actually exists)
  UDP :443 → the other UDP service (DIRECT_UDP again, same guarantees)
```

This has **zero** overlap with any of this document's identified gaps
(obfuscation blindness, migration unsafety, provider-maturity caveats) —
every one of those gaps is specific to the *shared-port* topology, not
to running two independent UDP services on two independent addresses.
The planner should always check `public_ipv4_count` before offering
`SHARED_UDP_QUIC_SNI` as anything other than a fallback for the specific
case where the operator has confirmed exactly one public IPv4 and no
path to a second one (most single-VPS deployments, realistically — which
is exactly why `SHARED_UDP_QUIC_SNI` is still worth having designed,
just not worth defaulting to).

---

## 25. Explainability

Restating §18's worked example in the exact reporting shape the task
requires, as the canonical example the planner's actual output format
should match:

```
Selected topology:
    SEPARATE_PORTS

Provider:
    none (kernel-level port allocation only)

Why:
    ✓ satisfies desired state (both services reachable on one public IP)
    ✓ zero new capability dependency
    ✓ zero QUIC-migration risk — both services keep their own native,
      fully QUIC-compliant, CID-aware socket
    ✓ zero new component to install or maintain
    ✓ operator did not set migration_tolerant_required, so any
      shared-port topology is excluded by a P0 safety gate anyway (see
      Rejected Alternatives)

Rejected alternatives:
    SO_REUSEPORT-based sharing
      - HARD REJECTED (kernel capability mismatch, not a scoring loss):
        no protocol-aware routing guarantee

    nginx-stream UDP
      - capability gap: quic_sni_routing = false (no QUIC/SNI
        inspection module exists in nginx)

    HAProxy (OSS/Enterprise)
      - capability gap: quic_sni_routing = false (QUIC support is
        HTTP/3-termination only, unsuited to a self-authenticating
        opaque protocol)

    Caddy L4, SHARED_UDP_QUIC_SNI
      - capability-satisfying (only provider that clears the technical
        bar) but SAFETY-GATED: migration_tolerant_required was not set
        by the operator, and this topology's session affinity does not
        survive QUIC connection migration / NAT rebinding — see
        Safety Constraints
```

---

## 26. Recommended architecture

- **TCP side**: no change to this document's own recommendation beyond
  restating the prior research's — extend MODE=F's existing nginx
  `stream{}` SNI map to a co-located TeleMT branch (Variant A), keep
  Hysteria2 entirely outside the TCP story (it always was).
- **UDP side, MVP**: `DIRECT_UDP` (current state) remains the default
  recommendation. Do **not** build `SHARED_UDP_QUIC_SNI` support into
  the installer's default path.
- **UDP side, advanced/opt-in**: design (this document) but do not yet
  implement a `SHARED_UDP_QUIC_SNI` path via caddy-l4, gated behind an
  explicit, loudly-worded operator opt-in that names the migration-safety
  trade-off in the prompt itself (not buried in docs) — matching this
  project's existing pattern of surfacing DECISION REQUIRED items rather
  than silently choosing for the operator.
- **Multi-IP case**: when Discovery reports more than one public IPv4,
  the installer should offer `SEPARATE_IPS` ahead of any shared-port
  discussion entirely — this is a pure win with no new research-surfaced
  caveats.

---

## 27. MVP

1. Extend Discovery (`poc/network-inspect`, still kept experimental) to
   read: nginx compiled-module list, Caddy/caddy-l4 module list (only if
   a `caddy` binary is found at all — don't add a new dependency),
   Hysteria2's own `obfs.type`, and public IPv4 count.
2. Implement the Desired State schema (§13) and Capability Registry
   shape (§20) as data structures only — no renderer yet.
3. Implement the Planner's rejection logic for the **already-fully-
   understood** cases first: unknown-owner STOP, permission-denied STOP,
   `SO_REUSEPORT`-is-not-multiplexing hard-reject, obfuscation-not-none
   hard-reject. These require zero new provider integration and
   immediately make the planner honest about what it can't do.
4. Implement `SEPARATE_PORTS`/`SEPARATE_IPS` topology generation +
   Plan IR emission for the TCP+UDP combined case — this is the
   overwhelming majority of real-world value or this project's actual
   needs, and needs zero new provider capability work.
5. Only after the above is solid: prototype the caddy-l4
   `SHARED_UDP_QUIC_SNI` provider capability probe (module detection) and
   Plan IR renderer, still gated behind the explicit opt-in, still
   labeled experimental in whatever CLI surfaces it.

## 28. What NOT to build yet

- Any renderer that assumes `SHARED_UDP_QUIC_SNI` is safe by default.
- Any HAProxy or Envoy UDP integration — this research found no path for
  either to do what this project actually needs on the UDP side; time
  spent building either integration would be spent on a dead end.
- Full HAProxy Data Plane API integration, full nftables AST parsing —
  named in the task's own dependency matrix template, but nothing in
  this document's findings created a concrete need for either yet.
- Any attempt to build "obfuscation-aware" QUIC inspection (e.g.,
  brute-forcing a configured Salamander password against captured
  Initial packets to enable routing) — this would be a materially
  different, much higher-risk feature (the router would need to hold a
  secret currently scoped only to the Hysteria2 process) with no
  operator request driving it.
- Automatic/implicit apply of any topology — stays consistent with this
  project's existing "STG applies patches manually" convention.

## 29. Open questions

1. Is there operator appetite, at all, for a second UDP-based protocol
   in this project's actual service catalog? Everything in §3–§20 was
   research to answer "could we," not "should we" — no concrete second
   UDP tenant exists in this repo today (Hysteria2 is the only one).
   Absent one, §27's MVP steps 1–4 are still valuable (they make the
   planner honest and TCP-side-complete), but step 5 has no immediate
   consumer.
2. Should the Capability Registry be populated by a live probe
   (`caddy list-modules`, `nginx -V`, `haproxy -vv`, run at plan-time)
   or a maintained static table per pinned installer version, with the
   live probe as a cross-check? This document assumes live probe
   (matches this project's existing "trust the running binary, not a
   changelog" instinct from `docs/CONTRACTS.md`) but does not settle it.
3. Whether the `n_way_sni_routing` TCP field (added in §14 beyond the
   task's own TCP sketch) needs a numeric cap or just a boolean — no
   concrete driver found for a cap in this project's current 3-4-branch
   SNI map size.
4. Whether HAProxy's TCP-side SNI-passthrough (`req.ssl_sni`, flagged
   but not investigated in §16/§23G) is worth a follow-up research pass
   as an alternative `SHARED_TCP_SNI` provider — no driver found for
   *needing* an alternative to nginx-stream today, since MODE=F already
   works, but it's a legitimate future provider-registry entry.
5. Whether this project would ever want to explore the "single
   multi-protocol proxy binary" alternative noted in §11 (e.g., sing-box
   hosting both a Hysteria2-compatible inbound and another UDP protocol
   inbound in one process, sidestepping L4 multiplexing entirely) — a
   fundamentally different architecture direction, not evaluated in
   depth here since it wasn't the task's framing, but named so a future
   reader doesn't assume it was considered and rejected.

## 30. Concrete next implementation step

Extend `poc/network-inspect`'s `inventory_build.py` (still experimental,
still read-only, still not wired into `server-manager.sh`) with the four
new read-only discovery calls named in §22/§27 step 1 (nginx `-V` module
parse, Caddy `list-modules --versions` parse guarded by "only if a
`caddy` binary exists," Hysteria2 config `obfs.type` read, public IPv4
count from already-gathered interface data) — each with its own
`*_unresolved_reason` honesty field mirroring the existing
`pid_unresolved_reason` pattern, so a missing binary or an unreadable
config file is recorded as "couldn't check," never silently folded into
a false-negative capability row. This is additive to the existing PoC,
touches nothing under `lib/`, and produces exactly the Inventory shape
§13's Desired State / §20's Capability Registry need to be hand-verified
against a real host before any planner code is written.

## 31. Sources

**Repository** (`variant-f-j`, this session's clone) — `docs/
MULTI_PROTOCOL_L4_INGRESS.md`, `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md`,
`docs/hysteria-traffic-research.md`, `docs/CONTRACTS.md`, `docs/
ARCHITECTURE.md`, `poc/network-inspect/README.md`, `lib/hy2/*` (grepped,
not fully re-read, for `obfs`/`salamander` absence).

**Upstream — Caddy L4** — `github.com/mholt/caddy-l4` `docs/servers.md`,
`docs/matchers.md`, `docs/routes.md`, README; issues #10, #23, #118, #348
(real, posted working/attempted configs); `pkg.go.dev/github.com/
cruizba/caddy-l4` module listing.

**Upstream — QUIC/TLS mechanics** — RFC 9001 §5.2 (Initial Secrets,
public salt), RFC 9000 (connection migration, Connection IDs), RFC 9308
(applicability — NAT-rebinding caveat), `quicwg/base-drafts` issue #1271,
`draft-ietf-quic-load-balancers` (QUIC-LB), `quic-go.net` connection-
migration docs, `gaukas/clienthellod`.

**Upstream — Hysteria2** — `v2.hysteria.network/docs/advanced/
Full-Server-Config`, `.../developers/Protocol` (Salamander spec, Gecko
addition), `.../Changelog`; `manual.nssurge.com` Hysteria2 client-config
reference (obfuscation mutual-exclusivity confirmation).

**Upstream — nginx** — `nginx.org/en/docs/stream/
ngx_stream_core_module.html`, `.../ngx_stream_proxy_module.html`;
`github.com/nginx/nginx` issue #1061 (UDP PROXY protocol gap, already
cited in prior repo research, independently re-confirmed here).

**Upstream — HAProxy** — `haproxy.com` QUIC/HTTP3 configuration guides
and glossary entry, HAProxy 2.3/2.6/3.2 announcement posts (`dgram-bind`
scoped to `log-forward`; QUIC = HTTP/3 termination), FreeBSD forum thread
showing a real HAProxy+QUIC troubleshooting session (corroborates the
termination-oriented bind syntax in practice, not just docs).

**Upstream — Envoy** — `envoyproxy.io` listener/listener-filter docs,
SNI dynamic forward proxy docs (TCP-only, alpha), GitHub issue #23857
(direct confirmation that QUIC+SNI-based upstream selection without
termination is not how Envoy's QUIC listener works).

**Other** — `arxiv.org/abs/2304.01073` (QUICstep, connection-migration-
based circumvention — corroborates migration's real-world relevance to
this exact threat model); `docsearch.algolia.com` mirrors of the above
GitHub repos (used only to cross-check phrasing already sourced from the
primary GitHub docs/issues above, never relied on alone).

---

# Bottom line — direct answers to the task's five questions

### 1. Can `ONE IPv4, UDP :443, Hysteria2 + another UDP protocol` work?

**Conditionally yes, one mechanism, with a named residual risk.**
Mechanism: **caddy-l4**, using its `layer4.matchers.quic` +
`tls`/SNI-handshake matcher, in **passthrough** mode (no certificate
configured on that route), routing to distinct UDP upstreams per SNI —
this is a real, independently-observed working pattern (caddy-l4 issue
#118), not a theoretical composition. Conditions that must hold: (a)
Hysteria2 must run with `obfs.type: none` (no Salamander/Gecko — if
obfuscation is ever turned on, this whole path silently stops working,
with no config-time error); (b) the operator must accept that QUIC
connection migration / NAT rebinding is **not** correctly handled by any
surveyed provider (client experiences a reconnect, not a seamless
migration, if their network path changes mid-session). No mechanism
based on `SO_REUSEPORT` alone provides this — that primitive has zero
protocol awareness and was not mistaken for evidence anywhere in this
analysis.

### 2. Can `TCP :443 {REALITY, TeleMT, HTTPS} + UDP :443 {Hysteria2}` coexist without conflict, on one IPv4?

**Yes, unconditionally, and for a much simpler reason than #1**: TCP and
UDP are separate protocol/port namespaces at the kernel level — a TCP
socket bound to `0.0.0.0:443/tcp` and a UDP socket bound to
`0.0.0.0:443/udp` never contend with each other regardless of what
either one does internally. The TCP side's own internal sharing (REALITY
+ TeleMT + HTTPS via nginx-stream SNI routing) is already independently
verified feasible by the prior research this document builds on. The UDP
side needs no multiplexing at all here since Hysteria2 is the only UDP
tenant in this specific combination — it's `DIRECT_UDP`, not
`SHARED_UDP_QUIC_SNI`, and therefore carries none of #1's residual risk.

### 3. Which of `nginx-stream / caddy-l4 / haproxy / envoy / other` can implement each topology?

| Topology | nginx-stream | caddy-l4 | haproxy | envoy |
|---|---|---|---|---|
| `SHARED_TCP_SNI` | **Yes** (proven, MODE=F) | Yes (not implemented here) | Yes, plausible (not deeply investigated — TCP-side SNI passthrough is a real, separate HAProxy OSS feature) | Yes, via SNI dynamic forward proxy (TCP-only, upstream-flagged alpha) |
| `SHARED_UDP_QUIC_SNI` | **No** (no QUIC/SNI inspection module) | **Yes** (only provider with real evidence; migration-unsafe, self-described as still-in-development) | **No** (QUIC path is HTTP/3-termination only, wrong shape for an opaque self-authenticating protocol) | **No** (same reason as HAProxy) |
| `DIRECT_TCP`/`DIRECT_UDP`/`SEPARATE_*` | n/a — no provider needed | n/a | n/a | n/a |

### 4. Which capabilities are actually needed for `{REALITY, TeleMT, Hysteria2, HTTPS, shared TCP, shared UDP, QUIC SNI routing}`?

- REALITY: `tcp.sni_inspection` (to be routed) + REALITY's own inbound
  `sockopt.acceptProxyProtocol` support (already verified feasible by
  prior research, not this document's focus) — no UDP capability needed.
- TeleMT: `tcp.sni_inspection` + `tcp.proxy_protocol_in` **at the
  process level** (its own process-wide, not per-listener, constraint —
  already established) — no UDP capability needed.
- Hysteria2: needs **nothing** from a router in the recommended
  (`DIRECT_UDP`) topology. In the opt-in shared topology, needs the
  router to have `udp.quic_inspection` + `udp.quic_sni_routing` (true
  passthrough, not `quic_sni_termination`) + explicitly `udp.
  obfuscation_transparent` is irrelevant only because Hysteria2's own
  `obfs.type` must be `none` for this to work at all — the capability
  requirement and the desired-state precondition are two sides of the
  same fact.
- HTTPS (Panel/Sub decoy): `tcp.tls_termination` — already implemented,
  unaffected by anything in this document.
- Shared TCP: `tcp.sni_inspection` + `tcp.n_way_sni_routing` (more than
  2 branches) — a small, real extension of what MODE=F's nginx already
  has, per prior research.
- Shared UDP: the **conjunction** `udp.quic_inspection AND
  udp.quic_sni_routing AND NOT relying on udp.quic_migration_safe` (since
  no provider has that) — this conjunction, not any single field alone,
  is what the Capability Registry (§14/§20) exists to check explicitly
  rather than leave to inference.
- QUIC SNI routing specifically: exactly `udp.quic_sni_routing = true`,
  which this document found is a genuinely rare capability — one real
  provider (caddy-l4), not a commodity feature the way TCP SNI-routing
  effectively is across nginx/HAProxy/Envoy/Caddy alike.

### 5. Is shared UDP worth supporting in the MVP, or should shared TCP + dedicated UDP ports ship first, with shared UDP as an advanced/later capability?

**Shared TCP + dedicated UDP ports first, unconditionally.** This
document's own findings are the argument: shared UDP's only real
provider (caddy-l4) carries a self-described development-stability
caveat, a proven migration-safety gap with no fix on either side of this
project's stack (neither Hysteria2 nor any surveyed proxy implements
QUIC-LB), and a silent, hard-to-diagnose failure mode the moment
Hysteria2's own obfuscation is ever turned on. None of that risk exists
for `SEPARATE_PORTS`/`SEPARATE_IPS`, and this project doesn't currently
have a second UDP tenant driving urgency either (§29, Open Question 1).
Shared UDP belongs exactly where the task's own framing put it: a named,
designed, capability-gated **advanced** option — not an MVP default.

```
DO NEXT
────────
1. Extend poc/network-inspect (still experimental) with the 4 new
   read-only discovery reads: nginx -V modules, Caddy/caddy-l4
   list-modules (only if caddy binary present), Hysteria2 obfs.type,
   public IPv4 count.
2. Implement Desired State schema (§13) + Capability Registry shape
   (§20) as pure data structures.
3. Implement the "already fully understood" P0 safety rejections
   (unknown owner, permission_denied, SO_REUSEPORT-is-not-multiplexing,
   obfuscation-not-none) — no new provider integration required.
4. Implement SEPARATE_PORTS / SEPARATE_IPS topology generation + Plan
   IR emission for combined TCP+UDP desired states.

DO NOT DO YET
─────────────
- Any renderer or installer default that offers SHARED_UDP_QUIC_SNI
  without an explicit, loudly-worded operator opt-in.
- Any HAProxy or Envoy UDP/QUIC integration (dead end for this need).
- Full HAProxy Data Plane API or full nftables AST parsing (no driver).
- Any obfuscation-aware QUIC inspection (materially different, much
  higher-risk feature; no operator request driving it).
- Automatic/implicit apply of any topology.

MVP TOPOLOGIES
──────────────
1. DIRECT_TCP / DIRECT_UDP (today's actual state — always available)
2. SHARED_TCP_SNI via nginx-stream (already proven, MODE=F; extend for
   TeleMT per prior research's Variant A)
3. SEPARATE_PORTS / SEPARATE_IPS for any additional UDP tenant

ADVANCED TOPOLOGIES
───────────────────
1. SHARED_UDP_QUIC_SNI via caddy-l4 — capability-gated on
   obfs.type:none, safety-gated on explicit migration_tolerant_required
   opt-in, scoring-penalized for provider stability caveats
2. SHARED_TCP_SNI via haproxy as an nginx-stream alternative (not
   researched in depth here — flagged as a future provider-registry
   entry only, no driver to build it now)

SHARED UDP
──────────
CONDITIONAL

Best current implementation:
  caddy-l4, layer4.matchers.quic + tls/SNI handshake matcher, UDP
  passthrough proxy to per-SNI backends — the only provider in this
  survey with a real, observed working configuration for this exact
  shape, at the cost of a self-described development-stability caveat
  and an unresolved QUIC-migration gap shared by every surveyed
  alternative (i.e., not a caddy-l4-specific weakness).

Smallest implementation boundary:
  A single new Discovery read (Hysteria2's obfs.type) plus a single new
  Capability Registry field (multi_backend_same_port, gated by
  quic_sni_routing) plus one new Safety Constraint (reject unless
  migration_tolerant_required is explicitly true) are sufficient to let
  the planner honestly refuse or honestly offer SHARED_UDP_QUIC_SNI —
  no new production rendering code is required to reach that honest
  "yes, conditionally, here's exactly why" state, which is this
  document's actual deliverable: not proof that shared UDP exists, but
  a checkable boundary around when it's safe to plan.
```
