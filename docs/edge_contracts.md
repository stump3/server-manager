# server-manager — Edge / Network Contracts

> Canonical, minimal model of the network edge (public ingress → routing →
> backend) as it **actually exists today** in `variant-f-j`. This document
> does not invent a general-purpose network framework — every entity and
> field below is present because a currently-shipping, tested scenario
> (MODE=1/2/F/J, `F_XHTTP_ENABLE`, TeleMT integration) requires it. Where
> a future extension is plausible but not evidenced by current code, it is
> called out explicitly as a **future extension**, never modeled as if it
> already existed.
>
> **Verified baseline**: `origin/variant-f-j @ c7d3d3b`. Every claim below
> was established by direct reading of the code at this commit (and, for
> the topology/listener/PROXY/render facts, by actually executing
> `render.sh` and the nginx generators and inspecting the output) across
> three prior read-only audit sessions on this branch — not asserted from
> a design document without checking.
>
> **Purpose**: this is the contract a future Core/Runtime design should be
> built against. It intentionally stops at "what is true today, and what
> is explicitly out of scope" — it does not propose Core/Runtime itself.

---

## Scope

In scope: the public network edge for MODE=1, MODE=2, MODE=F,
MODE=F+`F_XHTTP_ENABLE`, and MODE=J, plus the TeleMT co-located
integration available under MODE=F/J. This covers nginx `stream{}`
routing, the Xray Vision/XHTTP (Steal/StealXHTTP) inbounds, and TeleMT's
nginx-mediated integration.

Out of scope (see **Explicit non-goals**): Xray's internal REALITY
handshake mechanics beyond what the edge needs to know (PROXY posture,
identity sharing), Panel's application-level API, TeleMT's own
TOML/systemd/Docker internals beyond its listener contract, and any
protocol not currently implemented (Hysteria2, mKCP, generic future L4
integrations).

---

## Current topology matrix

| Topology | Selector | Public ingress owner | Required listeners | Required capabilities | Optional capabilities |
|---|---|---|---|---|---|
| MODE=1 | `MODE=1` | Xray (direct) | Vision `:443` | Vision | none |
| MODE=2 | `MODE=2` | nginx (`http{}` only, no `stream{}`) | Panel/Sub `:443` | Panel/Sub | none |
| MODE=F | `MODE=F` | nginx (`stream{}`) | Panel/Sub via SNI, Vision via SNI | Vision | XHTTP (`F_XHTTP_ENABLE`), TeleMT |
| MODE=J | `MODE=J` | nginx (`stream{}`) | Panel/Sub via SNI, Vision via SNI, XHTTP dedicated port | Vision, XHTTP | TeleMT |

Every row above is independently verified: MODE=1/2 by code inspection
(`lib/panel/nginx/config.sh`), F/J by actual execution of the generators
and `render.sh` and inspection of the resulting nginx config and Xray
JSON in prior sessions on this branch.

---

## Topology contract

```
Topology
  - id                      (one of: "1", "2", "F", "J" — the current MODE values)
  - public_ingress_owner    (xray | nginx-http | nginx-stream)
  - required_listeners      (Listener[])
  - required_capabilities   (Capability[])
  - optional_capabilities   (Capability[])
  - domain_roles            (which Domain roles this topology consumes)
  - port_allocation_profile (which Port Allocation rows apply)
  - runtime_components      (which subsystems this topology brings up)
```

`id` is deliberately kept as the literal MODE string, not renamed or
reinterpreted — see **Legacy MODE compatibility** below for why MODE
stays a compatibility input rather than becoming the model's own primary
key.

**J's XHTTP is a required capability of the J topology, not an optional
one with a default of "on".** There is no `J_XHTTP_ENABLE` anywhere in
the code, no CLI path to decline it, and no config path that produces a
J install without the StealXHTTP inbound and its dedicated public port.
Modeling it as "capability, defaulted on" would misrepresent today's
system as one control-toggle away from something it cannot currently do.
If J's XHTTP is ever made optional, that is a topology change to J
itself, not a flip of an existing flag.

---

## Listener contract

```
Listener
  - id
  - transport            (tcp)                — udp is a future extension, see Current limitations
  - bind                 (0.0.0.0 | 127.0.0.1)
  - public_port
  - internal_port        (only when public != internal)
  - public                (bool)
  - protocol             (vision | xhttp | panel_sub | telemt)
  - tls_mode              (passthrough)         — every current listener is TLS-passthrough at the nginx layer
  - routing_mode          (sni | dedicated_port)
  - proxy_protocol_in     (bool)  — does nginx send PROXY into this leg
  - proxy_protocol_out    (bool)  — does the backend expect/accept PROXY
  - backend               (Backend)
  - runtime_owner
  - integration_owner
```

Every field above was kept only after confirming a real listener needs
it — `transport` has only one observed value (`tcp`) but is still a
field because a topology-level property must exist to say so explicitly
rather than by omission (see UDP in **Current limitations**). No field
for HTTP path, ALPN, or ciphersuite selection was added: none of the five
current listeners route on any of those.

Instantiated for the five listeners verified across prior sessions:

| id | transport | bind | public_port | internal_port | public | protocol | routing_mode | proxy_protocol_in | proxy_protocol_out | backend | runtime_owner | integration_owner |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F-Vision | tcp | 0.0.0.0→127.0.0.1 | 443 | 8443 | yes | vision | sni | yes | yes | Xray:8443 | Xray (`api.sh`) | Panel |
| F-XHTTP | tcp | 0.0.0.0→127.0.0.1 | 9443 | 19444 | yes | xhttp | dedicated_port | no | no | Xray:19444 | Xray (`api.sh`) | Panel |
| J-Vision | tcp | 0.0.0.0→127.0.0.1 | 443 | 18443 | yes | vision | sni | yes | yes | Xray:18443 | Xray (`api.sh`) | Panel |
| J-XHTTP | tcp | 0.0.0.0→127.0.0.1 | 8443 | 18444 | yes | xhttp | dedicated_port | no | no | Xray:18444 | Xray (`api.sh`) | Panel |
| TeleMT (F or J) | tcp | 0.0.0.0→127.0.0.1 | 443 | `$TELEMT_PORT` | yes | telemt | sni | yes | yes | TeleMT:`$TELEMT_PORT` | `lib/telemt/*` | Panel (trigger only) |

All five instantiate cleanly with the same field set and no `null`/N/A
fields required — this is the concrete evidence the Listener contract is
sized correctly for the current system, not over- or under-specified.

---

## Route contract

```
Listener
  └── Route[]
        └── Backend
```

Only two routing mechanisms exist in the current code, and the contract
supports exactly those two — nothing more:

**SNI route** (used by Panel/Sub, Vision, and TeleMT, all sharing the
same public `:443` listener in F/J):
```
ssl_preread → SNI match → Backend
```
One Listener (`:443`) carries multiple Routes here — this is why Route
is a distinct concept from Listener, not folded into it: the `:443`
Listener's `routing_mode=sni` field says *how* it decides, but the
decision table itself (which SNI maps to which Backend) is a separate,
per-topology list, not a Listener property.

**Dedicated-port route** (used by both F-XHTTP and J-XHTTP):
```
public port → single Backend
```
Here the Listener *is* the Route — no decision is made, no map is
consulted. Modeled as a Route with exactly one member for consistency
with the SNI case, not because a decision mechanism exists.

Path-based routing, HTTP-header routing, and ALPN-based routing are not
modeled because no current scenario uses them — see **Explicit
non-goals**.

---

## Backend contract

```
Backend
  - address
  - port
  - protocol
  - runtime_owner
```

**Every backend observed today is `127.0.0.1`** (loopback) — Xray's
Vision/XHTTP inbounds and TeleMT's listener are all bound loopback-only
when reached via nginx (F/J), confirmed by the loopback-bind fix audited
and executed in a prior session (`api.sh:panel_reality_listen_addr()`).
This is recorded as **current behavior**, not hardcoded into the
contract as a universal invariant — `address` remains a field, not a
constant, because MODE=1/2's Vision backend is *not* loopback (Xray binds
public `:443` directly there, no nginx in front of it, no loopback hop
exists). A future topology that legitimately needs a non-loopback backend
is not precluded by this contract; it simply hasn't been observed yet.

---

## PROXY protocol invariant

**PROXY protocol is a property of the (Listener, Backend) connection,
not two independently-configured flags that happen to agree.**

Verified pair-by-pair:

| Listener | `proxy_protocol_in` (nginx `stream{}`) | `proxy_protocol_out` (backend expectation) | Where each side is set |
|---|---|---|---|
| F Vision | `proxy_protocol on;` (`variant_f.sh`, block-wide on the shared `:443` server) | `sockopt.acceptProxyProtocol=true` (`api.sh:panel_reality_accept_proxy_protocol`, Steal inbound only) | nginx side + Xray side, same connection |
| F XHTTP | absent (`variant_f.sh`'s dedicated `:9443` server, no directive) | absent (StealXHTTP inbound never receives `accept_pp`) | both sides agree by omission |
| J Vision | `proxy_protocol on;` (same shared `:443` server as F Vision) | `sockopt.acceptProxyProtocol=true` (same function, same gating) | nginx + Xray |
| J XHTTP | absent (`variant_j.sh`'s dedicated `:8443` server — confirmed by direct inspection excluding an unrelated explanatory comment that merely mentions the word) | absent | both sides agree by omission |
| TeleMT (F or J) | `proxy_protocol on;` (inherited from the same shared `:443` server as Vision — nginx `stream{}` cannot scope this per-SNI-branch) | `proxy_protocol = true` in TeleMT's own `[[server.listeners]]` TOML (`lib/telemt/core.sh`/`install.sh`) — a structurally independent setting, not Xray's `sockopt` | nginx side (shared with Vision) + TeleMT's own, separate side |
| Panel/Sub | `proxy_protocol on;` (same shared `:443` server) | nginx's own internal HTTPS listener reads `$proxy_protocol_addr` (`variant_f.sh`/`variant_j.sh` `location` blocks) | nginx + nginx (both legs are nginx) |

Two structural facts worth stating explicitly as part of the invariant:

1. **Nginx `stream{}` has no per-branch PROXY scoping** — a single
   `proxy_protocol on;` on the shared `:443` server applies to every SNI
   branch behind it. This is why Vision, TeleMT, and Panel/Sub *must*
   agree on PROXY posture whenever they share a listener — it is not a
   design choice per backend, it is a hard nginx limitation the code
   works within, confirmed against
   `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md`'s own runtime-verified
   correction on this exact point.
2. **TeleMT's PROXY acceptance is not inherited from Xray.** It is set
   independently in TeleMT's own config format, by TeleMT's own installer
   code, with zero code path connecting it to `sockopt.acceptProxyProtocol`
   or any other Xray-specific mechanism. The two happen to need the same
   value only because they happen to share the same upstream nginx
   listener — not because one derives from the other.

This invariant is **not** generalized to "every future protocol must
accept PROXY the same way" — it is stated only as a description of the
six pairs above, which is what current evidence supports.

---

## Domain contract

| Role | Variable | Contract |
|---|---|---|
| Panel UI | `PANEL_DOMAIN` | SNI match on `:443` → Panel/Sub Backend |
| Subscription | `SUB_DOMAIN` | SNI match on `:443` → Panel/Sub Backend |
| Self-steal / REALITY identity | `SELFSTEAL_DOMAIN` | **Not** an edge routing domain — never appears in any SNI map. Consumed directly by Xray as REALITY's `serverNames`/decoy identity (`api.sh:panel_reality_dest_val`). It answers "what does REALITY pretend to be," not "where does this connection get routed" |
| TeleMT masquerade | `TELEMT_DOMAIN` | SNI match on `:443` → TeleMT Backend, **and independently** TeleMT's own `tls_domain` in its TOML — same value, two independent consumers, confirmed same source (`lib/panel/cli.sh`'s single collection point), not re-derived twice |
| XHTTP | *(none)* | XHTTP has no domain role today, because its route is `dedicated_port`, not `sni` — there is nothing for a domain variable to feed |

No `NODE_DOMAIN` exists or is introduced by this document — confirmed
absent from the codebase (`grep -rn "NODE_DOMAIN"` → zero matches,
re-checked this session).

---

## Port allocation model (conceptual shape only — values unchanged)

```
PortAllocation
  - topology
  - capability       (required | optional-name | "-" for topology-intrinsic)
  - role             (vision | xhttp | panel_sub | telemt)
  - public_port
  - internal_port
  - protocol
  - proxy_protocol
  - owner
```

Current values (unchanged, sourced from `variant_f.sh`, `variant_j.sh`,
`api.sh`, `cli.sh`'s reserved-port arrays — not modified by this
document):

| topology | capability | role | public_port | internal_port | protocol | proxy_protocol | owner |
|---|---|---|---|---|---|---|---|
| F | - | vision | 443 | 8443 | reality/tcp | yes | Xray |
| F | - | panel_sub | 443 | 7443 | http/tls | yes (in) | nginx |
| F | XHTTP (optional) | xhttp | 9443 | 19444 | reality/xhttp | no | Xray |
| F | TeleMT (optional) | telemt | 443 | `$TELEMT_PORT` | mtproto/tls | yes | TeleMT |
| J | - | vision | 443 | 18443 | reality/tcp | yes | Xray |
| J | - | panel_sub | 443 | 7444 | http/tls | yes (in) | nginx |
| J | XHTTP (required) | xhttp | 8443 | 18444 | reality/xhttp | no | Xray |
| J | TeleMT (optional) | telemt | 443 | `$TELEMT_PORT` | mtproto/tls | yes | TeleMT |

**No values were changed to produce this table** — it is a direct
transcription of the constants already verified in code across prior
sessions.

**`19444` is explicitly flagged as a duplicated literal, not a new
finding**: it is defined once in `variant_f.sh:58` and independently
redeclared as a fallback default in `api.sh`
(`${F_XRAY_XHTTP_PORT:-19444}`). This table's `internal_port` column for
F/XHTTP is the intended single source of truth this duplication should
eventually resolve against — this document does not perform that
resolution; it only names the target shape. Same status for the
positional-argument chains that currently thread `F_XHTTP_ENABLE`,
`TELEMT_DOMAIN`, `TELEMT_PORT` through `config.sh → variant_f.sh → api.sh
→ render.sh` — this table's `topology`/`capability`/`role` keys are the
shape a future named-parameter or lookup-based version of that threading
would key off of. **Both are migration targets recorded here for
traceability, not bugs this stage fixes.**

---

## Capability model

```
Capability
  - name
  - applies_to_topology
  - required | optional
  - listeners_added     (Listener[])
  - domain_role_added    (Domain role, if any)
  - port_allocation_rows (PortAllocation[])
```

| Capability | Applies to | Required/Optional | Adds |
|---|---|---|---|
| XHTTP | F | optional (`F_XHTTP_ENABLE`, real CLI toggle, default off) | F-XHTTP listener, no new domain role |
| XHTTP | J | **required** (topology-intrinsic — no toggle exists) | J-XHTTP listener, no new domain role |
| TeleMT | F, J | optional (real CLI toggle, keep/reconfigure/disable states) | TeleMT listener, `TELEMT_DOMAIN` role |

The distinction the task specifically asked to preserve is encoded
directly in this table via the `required`/`optional` column rather than
a boolean flag with a fixed default — this avoids the exact
misrepresentation flagged in the Topology contract section above (J's
XHTTP is not "enabled by default," it is a fixed part of what J *is*).

---

## Runtime ownership

Three distinct roles, kept separate because TeleMT already demonstrates
why collapsing them would be wrong:

```
configuration_owner  — who generates this component's config
runtime_owner         — who starts/stops/persists the running process
integration_owner     — who decides this component participates at all
```

| Component | configuration_owner | runtime_owner | integration_owner |
|---|---|---|---|
| nginx | Panel (`variant_f.sh`/`variant_j.sh`) | Panel's docker compose | Panel |
| Xray | Panel (`api.sh`/`render.sh`) | Panel's docker compose | Panel |
| TeleMT | `lib/telemt/*` (itself) | `lib/telemt/*` (itself — systemd or its own compose) | Panel (**trigger only**) |
| Panel | itself | its own compose | — |
| Remote Node (MODE=2) | Panel (remote) | remote host, outside this repo | Panel |

```
Panel
  │
  │ integration decision only
  ▼
TeleMT subsystem
  │
  ├── owns runtime
  ├── owns users/state
  └── owns lifecycle
```

**Panel is never TeleMT's runtime_owner.** Confirmed structurally, not
just by convention: `panel_remove()`/`panel_reinstall()`
(`lib/panel/management.sh`) reference only `/opt/remnawave`; zero
references anywhere to `/etc/telemt`, `/opt/telemt`, `~/mtproxy`, or
TeleMT's compose file. This is the pattern any future capability's
runtime ownership should follow if it needs its own subsystem the way
TeleMT does — not a pattern unique to TeleMT that a new protocol would
need to reinvent.

---

## Lifecycle contract (conceptual only — no implementation here)

```
create    — first-time provisioning of a component for a given topology
install   — apply configuration + bring runtime up
reconcile — detect current state, converge to desired state without
            destroying data that should survive (TeleMT's
            keep/reconfigure pattern is the existing proof this works)
repair    — detected-broken state → restore to a known-good state
reinstall — full re-provision, at the discretion of integration_owner,
            without becoming a second runtime_owner in the process
health    — read-only status check
remove    — integration_owner withdraws; must not implicitly become
            "runtime_owner deletes the component" unless they are the
            same owner (they are, for nginx/Xray/Panel; they are
            deliberately not, for TeleMT)
```

Remote Node's future lifecycle needs, stated as a target this contract
should support without redesign:

```
absent    → create + install
existing  → reconcile / reinstall
broken    → repair
(anytime) → health
```

No operation above is implemented by this document — this section exists
so a future Core/Runtime design has a fixed vocabulary to target, derived
from the one lifecycle pattern (TeleMT's) that is already proven in
production code today.

---

## Legacy MODE compatibility

```
legacy MODE input ("1" | "2" | "F" | "J")
        │
        ▼
compatibility resolver   (today: the direct string-equality branches
                           in config.sh / api.sh / cli.sh / render.sh)
        │
        ▼
Topology + required/optional Capabilities
```

MODE is retained as the **selector**, not redefined as the model's
primary key — the model's `Topology.id` field is literally the MODE
string today specifically so this resolver step can stay a no-op
mapping for as long as MODE remains the only selector in use. Current
MODE=1/2/F/J behavior is unchanged by this document: no generator, no
dispatcher, no CLI branch was modified to produce this contract.

---

## Current limitations (explicit, not silently absorbed)

- **UDP routing is not currently part of the nginx `ssl_preread` model.**
  No UDP listener exists anywhere in the current code (confirmed: the
  only "quic" string in the tree is Xray's `sniffing.destOverride`, a
  TCP-stream content hint, not a UDP listener). SNI-based routing is a
  TCP-ClientHello-inspection technique with no UDP equivalent in this
  codebase today.
- **XHTTP currently uses a dedicated port**, not SNI routing, for both F
  and J — this is why XHTTP has no Domain role.
- **J's XHTTP is required by the current J topology** — there is no
  toggle, no CLI path, and no config state that produces a J install
  without it.
- **F's XHTTP is an optional capability**, with a real, tested,
  off-by-default CLI toggle (`F_XHTTP_ENABLE`).
- **REALITY identity (privateKey/shortIds/serverNames) is Xray-specific**
  — this contract does not generalize it into a protocol-agnostic "TLS
  identity" concept, because no non-REALITY protocol in the current
  system needs one.
- **The current implementation still has positional-argument chains**
  threading `F_XHTTP_ENABLE`/`TELEMT_DOMAIN`/`TELEMT_PORT` through
  `config.sh → variant_f.sh → api.sh → render.sh`.
- **The current port allocation still has a duplicated literal**
  (`19444`, in both `variant_f.sh` and `api.sh`).
- **Both of the above are migration targets this document names a shape
  for — they are not bugs this stage fixes, and this stage made no code
  changes toward fixing them.**

---

## Explicit non-goals

- No new MODE is introduced or implied.
- No speculative capability is modeled "for the future" without a
  currently-shipping scenario requiring it (Hysteria2, mKCP, and other
  L4/TLS protocols are discussed only in `docs/MULTI_PROTOCOL_L4_INGRESS.md`
  as candidates — not modeled here as capabilities, since none exist in
  code).
- No path-based, HTTP-header-based, or ALPN-based routing is modeled —
  none exists in the current code.
- No attempt is made to generalize the PROXY protocol invariant to
  protocols not yet implemented.
- No generator (`variant_f.sh`, `variant_j.sh`, `render.sh`, `api.sh`,
  `install.sh`), no CLI file, no TeleMT lifecycle file, and no test file
  was modified to produce this document.
- This document does not propose a Core/Runtime implementation — it is
  the input a future Core/Runtime design should be checked against, per
  the migration order recorded in the prior Edge/Network Architecture
  Design Checkpoint (contracts → port allocation → capability-threading
  → adapters → generators → management/lifecycle → migration).

---

## Cross-references

- `docs/ARCHITECTURE.md` §6 — MODE=1/2/F web/TLS/nginx decision record
  (does not cover MODE=J or TeleMT integration — see prior architecture
  checkpoint's Documentation Drift findings).
- `docs/MULTI_PROTOCOL_L4_INGRESS.md` / `..._REVIEW.md` — original F/J
  candidate-topology research and its runtime-verified corrections
  (Correction C2, cited above for the PROXY-protocol block-wide-scoping
  fact).
- `docs/CONTRACTS.md` — a separate, differently-scoped contracts document
  (stdout/stderr discipline, exit codes, secrets, single-writer
  ownership, tracked against the `beta` baseline) — not extended by this
  document, since its scope does not cover network/edge topology.
- `docs/TELEMT_CONFIG.md` — TeleMT's own configuration surface, referenced
  here only for the listener/PROXY facts relevant to the edge contract.
