# server-manager — Core / Runtime Contracts

> Architectural checkpoint, same status as `docs/edge_contracts.md`: a
> **contract**, not an implementation. No shell file, generator, CLI file,
> compose file, TeleMT lifecycle file, or test file was modified to
> produce this document. Nothing here is a refactor plan for *this*
> stage — it defines the minimal Core/Runtime boundary a future
> refactor should be checked against.

---

## 0. Baseline & source-reconciliation findings (read this first)

Before anything else, three discrepancies between the task's stated
inputs and what actually exists in the repository, recorded as findings
rather than silently resolved:

**Finding 1 — filename casing.** The task refers to `docs/EDGE_CONTRACTS.md`.
The file that actually exists is `docs/edge_contracts.md` (lowercase,
confirmed via `git show <commit>:docs/EDGE_CONTRACTS.md` failing at every
candidate commit, `ls docs/` showing the lowercase name only). On the
case-sensitive filesystem this runs on, these are different paths. This
document uses `docs/edge_contracts.md` throughout, treating it as the
same document the task means — but the casing mismatch is real and
unresolved, not a typo I've silently corrected.

**Finding 2 — stated baseline commit is stale by one commit.** The task
states baseline `origin/variant-f-j @ c7d3d3b`. `docs/edge_contracts.md`
itself does not exist at `c7d3d3b` — it is added by the very next commit,
`f46226b` ("Add edge/network contracts documentation"), which is the
actual current tip of `origin/variant-f-j` as of this session
(`git rev-parse origin/variant-f-j` → `f46226bb0cb9107fc92f328cda2837e21216e2df`).
This document is built from `f46226b`, since that is the only commit
where the task's own required input (`docs/edge_contracts.md`) is
readable at all. `c7d3d3b` is one commit behind `f46226b`, and `f46226b`
is docs-only (`486` insertions to `docs/edge_contracts.md`, nothing
else) — so no code fact from the prior sessions' audits changes between
the two commits.

**Finding 3 (the load-bearing one) — four of the five requested source
documents are not scoped to `variant-f-j` at all.** Checked each
document's own stated verification baseline directly:

| Document | Its own stated baseline | Branch |
|---|---|---|
| `docs/edge_contracts.md` | `origin/variant-f-j @ c7d3d3b` | **variant-f-j** — matches this task |
| `docs/CONTRACTS.md` | `beta @ 33135602c5c2e799575b0081cbfd137a40f7527c` | **beta** |
| `docs/ARCHITECTURE.md` | (no independent baseline line; cross-referenced by `CONTRACTS.md`/`LEGACY_AUDIT.md`, both `beta`) | **beta** |
| `docs/LEGACY_AUDIT.md` | `beta @ 33135602c5c2e799575b0081cbfd137a40f7527c` | **beta** |
| `docs/ENGINEER_GUIDELINES.md` | sourced from `origin/btemp`'s `tmp/engineer_guidelines.md`, verified against `beta @ 3313560` | **btemp/beta** |

This is not a paperwork detail. Concrete evidence that `beta` and
`variant-f-j` have diverged in **both directions**, not just that one is
"ahead":
- `docs/ARCHITECTURE.md` §6.1 documents Variant F in detail and **never
  mentions Variant J, `F_XHTTP_ENABLE`, or TeleMT's nginx-SNI
  integration at all** — none of which is a gap in that document, all of
  which exist and are load-bearing in `variant-f-j` today.
- `docs/CONTRACTS.md` contract 13 states `panel_node_register()` does
  "unconditional `POST` on every run, no lookup" as a **current
  violation** on `beta`. Direct inspection of `variant-f-j`'s own
  `lib/panel/node/api.sh` (this session, lines 30-91) shows the
  **opposite** already implemented there: `GET`-before-`POST`
  lookup-by-name for both Node and Host, with rollback on partial
  failure. `variant-f-j` is *more* advanced than `beta` on this specific
  point.

**Consequence for this document**: only `docs/edge_contracts.md` and
direct reading of `variant-f-j`'s actual code are treated as ground
truth below. `ARCHITECTURE.md`/`CONTRACTS.md`/`LEGACY_AUDIT.md`/
`ENGINEER_GUIDELINES.md` are used **only** as a source of reusable
*vocabulary and pattern shape* (state-machine names, ownership-table
shape, contract-table format) — every time one of their concrete claims
is borrowed, it is marked `NOT VERIFIED (beta-branch precedent)` rather
than presented as an established fact about `variant-f-j`. This
distinction is maintained throughout the document, not just here.

**Minor finding 4** — the task's file list includes `lib/panel/mgmt.sh`.
No such file exists; the two files that actually exist are
`lib/panel/mgmt_script.sh` (the *deployed*, on-server management script
template) and `lib/panel/management.sh` (the *installer-side* functions
that generate/invoke it, including the topology fingerprint discussed in
§6). Both are covered below under their real names.

---

## 1. Purpose

Define the minimal internal contract a future Core (desired-state model)
and Runtime (actual-state + reconciliation) layer would need, so that the
current chain

```
CLI positional args → config.sh → variant_f.sh/variant_j.sh → api.sh → render.sh → compose
```

could eventually be replaced by named data and explicit ownership
boundaries — **without** deciding here how or when that replacement
happens. This is a design contract, not a migration plan.

## 2. Relationship to `docs/edge_contracts.md`

`edge_contracts.md` is the **Edge** layer: what a public listener is,
how it routes, what backend it reaches, who owns its config vs its
runtime. It intentionally stopped short of Core/Runtime because its own
non-goals section says so explicitly ("this document does not propose a
Core/Runtime implementation"). This document is that next layer: it
reuses every Edge entity (`Listener`, `Backend`, `Capability`, `Domain`,
`PortAllocation`) as-is — none are redefined — and adds the layer above
them (`Topology`/`Deployment` as a named whole, `RuntimeComponent` as a
lifecycle-bearing unit, `LifecycleIntent` as the verb applied to one) and
the layer below current code (`Legacy compatibility boundary`, formalized
from Edge's own "Legacy MODE compatibility" section).

Where Edge already fully specifies something (Listener, PROXY invariant,
Backend, Domain, Port allocation, Capability required/optional), this
document does not restate it — it cites Edge by section name.

**Explicit ownership split (review addition — answers directly, rather
than leaving it implicit across §3's tree)**:

| Belongs to Edge (`edge_contracts.md`, unchanged) | Belongs to Core/Runtime (this document) |
|---|---|
| `Topology` (id, public_ingress_owner, required_listeners, required/optional capabilities, domain_roles, port_allocation_profile, runtime_components) | `Deployment` (a Topology reference + actually-chosen capabilities + actual domain values + TeleMT config — §2.1, §3.1) |
| `Listener`, `Route`, `Backend` | `RuntimeComponent` (§5 — the lifecycle-bearing unit a Listener's `runtime_owner`/`integration_owner` columns point at, not a redefinition of the Listener itself) |
| `Domain` (roles + contract) | referenced by value inside `Deployment.domains` — no second Domain model |
| `PortAllocation` (topology × capability × role → ports) | referenced, never duplicated — §4 explicitly forbids re-stating port values inside `Deployment` |
| `Capability` (name, applies_to, required/optional, listeners_added, domain_role_added) | `LifecycleIntent`/Reconciler (§6-7) act *on* Capabilities' consequences (which Listeners/RuntimeComponents they imply) but do not redefine what a Capability is |
| — | desired state / actual state / reconciliation / compatibility boundary — all new to this document, none exist in Edge |

There is exactly one source of truth for each entity in the left column
— Edge — and this document does not introduce a second, competing
definition for any of them anywhere below.

### 2.1 — Three distinct terms, disambiguated (review fix)

A prior draft of this document used "topology" loosely enough that
`Deployment.topology`'s exact relationship to Edge's own `Topology`
contract was ambiguous — sometimes read as "a copy of the MODE string,"
sometimes implicitly treated as "the full Edge Topology object." Fixed
here, explicitly, as three distinct terms with one arrow between each:

```text
legacy input          the raw MODE string ("1"|"2"|"F"|"J") and the
                       positional CLI/install-time values as they exist
                       in cli.sh/install.sh today — nothing about this
                       layer is modeled by Core at all
        │
        ▼  compatibility resolver (§8 — unchanged placement, today's
        │  scattered [ "$MODE" = ... ] branches)
        ▼
Topology               Edge's own contract, entirely unchanged by this
                       document, keyed by `id` = the MODE string
                       (public_ingress_owner, required_listeners,
                       required/optional capabilities, domain_roles,
                       port_allocation_profile, runtime_components —
                       see edge_contracts.md's own Topology contract).
                       Core does not add fields to this object and does
                       not define a second version of it.
        │
        ▼
Deployment             Core's own, new (§3.1) — holds a *reference* to
                       exactly one Topology (by `id`), plus the
                       information that only exists once an install is
                       actually being described: which optional
                       capabilities were actually turned on, the actual
                       domain values, and TeleMT's actual config (if
                       any). Deployment is strictly narrower in scope
                       than "everything Topology already says," and
                       strictly additive to it — never a restatement.
```

`Deployment.topology` (§3.1) is this reference — the Topology `id`
string — not a duplicate of Topology's own field set. Every other field
already on Topology (`public_ingress_owner`, `required_listeners`,
`required_capabilities`, ...) is read by looking that Topology up via
`Deployment.topology`, never copied onto `Deployment` itself. This is
the same resolution the task asked for
(`MODE=F → resolver → Topology → Deployment`), made explicit rather than
left implicit in field comments.

---

## 3. Core model

```text
Core
  ├── Deployment          (renamed from the task's "Topology" — see below)
  ├── Edge                (= everything in docs/edge_contracts.md, unchanged)
  ├── Capability           (= Edge's Capability contract, unchanged)
  ├── Domain               (= Edge's Domain contract, unchanged)
  ├── PortAllocation       (= Edge's PortAllocation contract, unchanged)
  ├── RuntimeComponent     (new — §5)
  └── LifecycleIntent      (new — §7; not a separate field-list, see below)
```

**Naming finding, not silently applied**: the task's own outline names
the top-level entity `Topology`. `docs/edge_contracts.md` already defines
`Topology` as a specific, narrower contract (`id`,
`public_ingress_owner`, `required_listeners`, ... — the F/J/1/2 shape
alone). Reusing the same name for a *broader* "everything this install
is" concept would collide with an already-shipped term. This document
calls the broader concept `Deployment` and keeps `Topology` meaning
exactly what Edge already says it means. `Deployment` *contains* a
`Topology` as one of its fields, plus the capabilities/domains/TeleMT
decision layered on top of it — it does not replace or widen Edge's
`Topology`.

### 3.1 — `Deployment`

```text
Deployment
  - topology              (reference to one Edge Topology, by its `id` —
                            "1" | "2" | "F" | "J". Not a copy of that
                            Topology's own fields — see §2.1)
  - capabilities           (Capability[] — which optional capabilities
                            are actually turned on for this install;
                            required capabilities are implied by topology,
                            not listed again here — see Edge's Capability
                            table, "required" row for J's XHTTP)
  - domains                (Domain[] — role → value, e.g. PANEL_DOMAIN=...)
  - telemt                 (TeleMtIntegration | absent)
```

Fields considered and **not** added:
- No `web_server` field — `WEB_SERVER` (nginx vs Caddy) is a real,
  independent axis in current code (`cli.sh`'s `WEB_SERVER=1`
  Caddy-vs-nginx choice, `install.sh`'s `WEB_SERVER=2 ∧ MODE=F/J`
  rejection guard), but Edge's own Topology contract already places
  `public_ingress_owner` as a Topology-level fact
  (`xray | nginx-http | nginx-stream`), and F/J are nginx-`stream{}`-only
  by construction (Caddy's `mholt/caddy-l4` gap is a *topology*
  limitation, not a per-Deployment choice) — so `web_server` belongs on
  `Topology` (Edge's own model), not duplicated onto `Deployment`. Not
  adding it here avoids two fields disagreeing about the same fact.
- No `node_domain` field — confirmed absent from the codebase by Edge's
  own Domain contract (re-verified this session: `grep -rn "NODE_DOMAIN"`
  → zero matches). Not invented here either.

### 3.2 — `TeleMtIntegration`

```text
TeleMtIntegration
  - domain     (= Edge Domain role "TeleMT masquerade", TELEMT_DOMAIN)
  - port       (TeleMT's own loopback listener port, TELEMT_PORT)
```

Deliberately **not** a `RuntimeComponent` field embedded inside
`Deployment` the way Vision/XHTTP listeners are — see §5's ownership
table: TeleMT's runtime is never owned by Panel, so modeling it as "just
another capability the Deployment configures end-to-end" would
misrepresent the one ownership boundary Edge went out of its way to
prove structurally (`edge_contracts.md`, Runtime ownership section:
"Panel is never TeleMT's runtime_owner", confirmed by grep — zero
references to TeleMT's paths in `panel_remove()`/`panel_reinstall()`).
`TeleMtIntegration` is the trigger-payload Panel hands to the TeleMT
subsystem, not a description of TeleMT's own internals.

---

## 4. Desired State — minimal representation

Pseudodata, not a schema. Four examples, exactly the four the task asked
for, each traced against real current behavior. `domains` keys below
(`panel`/`sub`/`selfsteal`) are shorthand for Edge's own Domain contract
roles one-to-one — `panel`→"Panel UI" (`PANEL_DOMAIN`), `sub`→
"Subscription" (`SUB_DOMAIN`), `selfsteal`→"Self-steal / REALITY
identity" (`SELFSTEAL_DOMAIN`) — not a new naming scheme; Panel/Sub and
SELFSTEAL are kept as separate keys specifically because Edge's own
Domain contract already treats them as separate roles with different
routing behavior (Panel/Sub is an SNI-routed edge domain; SELFSTEAL is
consumed directly by Xray's REALITY identity and "never appears in any
SNI map" — Edge's own wording). Collapsing them into one key here would
misrepresent that distinction Edge went out of its way to state.

**F** (XHTTP off, no TeleMT — the default/most common F install):
```text
Deployment:
  topology: "F"
  capabilities: []            # XHTTP is optional-for-F and off here;
                               # nothing to list when off
  domains:
    panel: "panel.example.com"
    sub:   "sub.example.com"
    selfsteal: "cdn.example.com"
  telemt: absent
```

**F + XHTTP**:
```text
Deployment:
  topology: "F"
  capabilities: ["XHTTP"]      # real, off-by-default CLI toggle
                               # (cli.sh's F_XHTTP_ENABLE confirm prompt)
  domains:
    panel: "panel.example.com"
    sub:   "sub.example.com"
    selfsteal: "cdn.example.com"
  telemt: absent
```
Note what does **not** appear: no `xhttp_public_port`/`xhttp_internal_port`
field on `Deployment` itself. Those are `PortAllocation` facts (Edge's
own model, already keyed by `topology` + `capability` + `role`) — listing
them again on `Deployment` would be the exact kind of duplicated literal
Edge's own "Current limitations" section used to flag for `19444` —
defined once in `variant_f.sh:58`, formerly redeclared as a fallback
default in `api.sh:107` until Candidate 1's migration to
`core_port_allocation_internal("F"/"J", "xhttp")` resolved it (see §10's
`F_XRAY_XHTTP_PORT` row and §13, both updated 2026-09-07). Desired State
should *reference* PortAllocation rows by `(topology, capability, role)`,
never re-state their values, exactly as that now-resolved case
illustrates.

**J** (XHTTP is required, not a capability toggle — per Edge's own
explicit warning against modeling it as "capability, defaulted on"):
```text
Deployment:
  topology: "J"
  capabilities: []             # XHTTP does not appear here at all —
                                # it is implied by topology="J", exactly
                                # as Edge's Capability table states
                                # ("required — topology-intrinsic — no
                                # toggle exists")
  domains:
    panel: "panel.example.com"
    sub:   "sub.example.com"
    selfsteal: "cdn.example.com"
  telemt: absent
```

**F + TeleMT**:
```text
Deployment:
  topology: "F"
  capabilities: []              # XHTTP independent of TeleMT; can be
                                 # combined with ["XHTTP"] too — not shown,
                                 # since the task's four examples don't
                                 # ask for F+XHTTP+TeleMT specifically
  domains:
    panel: "panel.example.com"
    sub:   "sub.example.com"
    selfsteal: "cdn.example.com"
  telemt:
    domain: "mtproto.example.com"
    port: 12345
```

**Constraints this model enforces by construction** (all six from the
task's own requirements, each traced to a real current fact rather than
asserted):
- MODE never becomes the internal model's key — `topology` *is* the
  legacy MODE letter, verbatim, exactly as Edge's own Topology contract
  already does (`id` field, "deliberately kept as the literal MODE
  string, not renamed"). This document does not introduce a second
  encoding.
- J's XHTTP is required, not optional-defaulted-on — enforced by simply
  never putting it in `capabilities` for J at all, matching Edge's
  Capability table exactly.
- F's XHTTP is optional — a real list entry, matching `cli.sh`'s actual
  `confirm "Включить XHTTP для Variant F..." "n"` prompt (default "n",
  i.e. off).
- TeleMT is optional and structurally separate (`telemt: absent | {...}`,
  never inside `capabilities`) — because, per §3.2, its runtime is not
  Panel's to own, and folding it into the same list as XHTTP would imply
  a symmetry that does not exist (XHTTP has no independent
  runtime_owner; TeleMT does).
- TeleMT runtime is not part of Xray runtime — enforced structurally:
  `TeleMtIntegration` carries only `domain`/`port` (the trigger payload),
  never a TOML path, systemd unit name, or Docker image reference — those
  belong entirely inside `lib/telemt/*`, which this model never reaches
  into (matching Edge's Runtime ownership table: TeleMT's
  configuration_owner and runtime_owner are both `lib/telemt/*` itself).
- XHTTP gets no domain role — enforced by simply not defining one; Edge's
  own Domain contract already states why ("XHTTP has no domain role
  today, because its route is `dedicated_port`, not `sni`").

---

## 5. Runtime model

### 5.1 — Per-component ownership (reusing, not restating, Edge's table)

Edge's Runtime ownership section already answers "who owns
configuration_owner / runtime_owner / integration_owner" for nginx,
Xray, TeleMT, Panel, and Remote Node, with structural proof (grep-level)
for the TeleMT boundary specifically. That table is the answer to the
task's question 2 in full; it is not reproduced here — see
`edge_contracts.md`, "Runtime ownership".

One clarification this document adds, checked directly against
`variant-f-j`'s actual `lib/panel/management.sh` this session (not
present in Edge, which didn't need it for the Edge-only scope): topology
**detection** (as opposed to topology **generation**) has its own
explicit, machine-readable ownership boundary, added specifically to
avoid re-deriving Deployment state from side-channel evidence. Since
2026-09-05 (confirmed by direct code read, `variant_f.sh:160-161`,
`variant_j.sh:108-109`), `variant_f.sh`/`variant_j.sh` themselves emit
stable marker lines at the top of the generated `nginx.conf`:
```
# SERVER_MANAGER_TOPOLOGY=F|J
# SERVER_MANAGER_XHTTP=0|1
```
and `management.sh` (confirmed, lines ~155-179) reads **these markers
first**, falling back to the old upstream-name heuristic only for
`nginx.conf` files generated before this fix existed. This is real,
already-shipped, and directly answers §7 (the task's "management
fingerprint" question) for the *current* code: detection is already
capability-independent-from-topology at the marker level. It is cited
here as the concrete precedent a future Runtime-state read (§5.2) should
extend, not reinvent.

### 5.2 — `RuntimeComponent` (minimal fields, justified individually)

```text
RuntimeComponent
  - identity              # see justification below — NOT a generic UUID
  - type                  # nginx | xray | panel | telemt | remote_node
  - configuration_owner   # = Edge's configuration_owner, same column
  - runtime_owner         # = Edge's runtime_owner, same column
  - integration_owner     # = Edge's integration_owner, same column
  - lifecycle_state       # see §8 — vocabulary only, not implemented
  - dependencies          # RuntimeComponent[] this one requires up-front
```

Each field checked against whether current code actually needs it,
per the task's own instruction not to accept the outline automatically:

- **`identity`** — **now confirmed directly against `variant-f-j`'s own
  `lib/panel/node/api.sh`** (code audit complete; this replaces the
  earlier `NOT VERIFIED (beta-branch precedent)` wording, which is now
  stale). Remote Node identity is `Nodes.name`, and its value is exactly
  `RemoteNode-${SELFSTEAL_DOMAIN}` — confirmed at `api.sh:275`
  (`--arg name "RemoteNode-${SELFSTEAL_DOMAIN}"`). Lookup is
  `GET /api/nodes` followed by `select(.name==$name)`
  (`api.sh:268-276`) — a plain name-equality filter, nothing else.
  Directly confirmed **not** part of this identity, because none of
  them appear in the lookup filter: address/IP (`NODE_ADDR`, only used
  at creation time, never re-applied to an already-matched Node —
  a changed IP silently leaves the old value in Panel), SSH endpoint
  (`_SSH_IP`/`_SSH_USER`, used only to reach the remote host, never sent
  to the Panel API at all), credentials (`SUPERADMIN_USER`/`PASS`, used
  only to obtain a login token), and hostname (no such field exists
  anywhere in the Node creation payload, `api.sh:283-286`). The
  config-profile that backs this Node uses the identical `name`
  convention (`RemoteNode-${SELFSTEAL_DOMAIN}`, `api.sh:217,235`), so
  both share one identity source: `SELFSTEAL_DOMAIN`.

  **Host identity is a separate, weaker mechanism, not the same as
  Node's** — confirmed at `api.sh:313-315`: a Host is matched by
  `inbound.configProfileInboundUuid == IBD_UUID`, where `IBD_UUID` comes
  from the config-profile step, not from any field on the Host object
  itself. This is convention-level identity, not a DB-enforced unique
  key — the file's own comment (`api.sh:65-72`, `296-304`) states
  neither `remark` nor `address` is unique on the Host model upstream,
  so nothing stops two Hosts pointing at the same inbound except this
  code's own discipline. In this create path, Node and Host are **not**
  linked by a direct foreign key — the relationship is indirect, through
  the shared config-profile inbound UUID (`api.sh:62-64`'s own comment
  confirms the `HostsToNodes` join table is never populated by this
  code). `RuntimeComponent.identity`, as a single field, is therefore
  Node-shaped by default; a Host-typed `RuntimeComponent` would need to
  document this weaker, indirect identity explicitly rather than
  assuming Node's identity strength transfers to it.
- **`type`**: five values, one per row in Edge's Runtime ownership table.
  No sixth value added speculatively (no `hysteria2`, no future
  protocol) — matching Edge's own non-goals section.
- **`configuration_owner`/`runtime_owner`/`integration_owner`**: kept
  verbatim from Edge, not because "three owners is a good pattern in
  general" but because TeleMT's row in that exact table is the concrete
  evidence three distinct values are needed (Panel is
  integration_owner+never runtime_owner for TeleMT, but is all three for
  nginx/Xray).
- **`lifecycle_state`**: kept as a field, but its *value vocabulary* is
  §8's concern, marked `NOT VERIFIED (beta-branch precedent)` throughout,
  since no state-machine code exists in `variant-f-j` for any component
  today (confirmed: `variant-f-j` has no health-check function, no
  RECONCILE/REPAIR distinction anywhere in `lib/panel/node/*.sh` beyond
  the lookup-before-create + rollback already noted in Finding 3 — a
  CREATE-only mechanism, not a full state machine).
- **`dependencies`**: justified by one concrete, current fact: TeleMT's
  co-located nginx wiring (`variant_f.sh`'s `TELEMT_MAP_LINE`/
  `TELEMT_UPSTREAM`) is only emitted `if [ -n "$TELEMT_DOMAIN" ]`
  (confirmed, `variant_f.sh:111`) — meaning nginx's own generated config
  already has a real, encoded dependency on TeleMT's *configuration*
  (the domain/port values) existing before nginx's config can be
  generated correctly, even though TeleMT's *runtime* is never started
  by Panel. This is exactly the kind of dependency this field needs to
  represent: config-time coupling without runtime-ownership coupling.

### 5.3 — Runtime state (what Core needs back from Runtime)

Per-field justification, since the task explicitly warned against typical-
system fields with no basis here:

| Field | Justified by | Status |
|---|---|---|
| `listener_exists` | Edge's own Listener contract is the desired-state half of this; nothing currently reads it back as observed state | future requirement — no current code reads "is this listener actually bound" anywhere |
| `port_occupied` | `cli.sh`'s reserved-port collision check (`_reserved_ports` array, confirmed real and capability-driven per Finding 3's grep) is a **desired-state-time** check against a static list, not an observed-runtime check — it never asks the OS "is this port actually in use" | future requirement, not current — the existing check is closer to a Core-level "would this combination be internally consistent" validation than a Runtime-state read |
| `config_present` | `management.sh`'s marker read (§5.1) is exactly this — "does a config exist, and what does it claim about itself" | **current**, directly cited above |
| `config_hash` | Not found anywhere in current code (no `sha256sum`/`md5sum` of any generated config located this session) | future requirement — not invented as "typical for config-drift systems"; no current consumer would use it |
| `health` | `telemt_menu_status()` (`lib/telemt/menu.sh`) is a real, working, interactive health read for TeleMT specifically — confirmed present in Edge's own citation and independently in this session's `docs/CONTRACTS.md` contract-14 citation of the same function/lines | **current, but TeleMT-only** — no equivalent exists for nginx/Xray/Panel today |
| `identity` | Confirmed, per §5.2's now-verified rewrite — `Nodes.name = "RemoteNode-${SELFSTEAL_DOMAIN}"`, read back via the same `GET /api/nodes` + name-filter lookup used for creation | **current, Node-only** — Host's own identity read (`inbound.configProfileInboundUuid`) is separate and weaker, per §5.2 |
| `running` / `stopped` | Not found as an explicit state read anywhere — `docker compose up -d` calls exist (`api.sh:130`) but nothing polls container state back into a decision | future requirement |

Fields from the task's own example list that are **not** added: no
generic `identity` beyond the one justified above, no speculative
`version` or `checksum` field — none has a current consumer.

---

### 5.4 — Explicit non-claims (review addition)

Stated once, plainly, so no individual field's careful "future
requirement" wording upstream can be misread in isolation: **none of the
following exist anywhere in `variant-f-j` today**, and nothing in this
document should be read as claiming otherwise —

- a generic `health` check for any component other than TeleMT
  (TeleMT's own `telemt_menu_status()` is real; nginx/Xray/Panel have no
  equivalent);
- a `config_hash`/config-drift-detection mechanism, for any component;
- a **desired-state or actual-state store** — no database, file, or
  cache anywhere holds either "what should be running" or "what is
  actually running" outside of the generated config files themselves
  (`nginx.conf`, Xray's rendered JSON) and the Panel API's own live
  state. §6 below describes a conceptual ownership split between Core
  and Runtime; it does not imply a storage layer implementing that split
  exists;
- a reconciliation engine — no code compares desired vs. actual state
  and decides an action for anything except Remote Node's narrow
  lookup-before-create (§7);
- a `repair` operation, for any component;
- a `reinstall` abstraction distinct from a fresh install, for any
  component.

Every one of these is either `Target` or `Future requirement` per §11's
table — this section exists only to collect them in one place so the
distinction can't be missed by reading a single field's entry out of
context.

## 6. Reconciliation boundary

```text
Core                    — owns: desired state, the decision "does actual
                           state match desired state"
  │ desired state
  ▼
Runtime                 — owns: reporting actual state (§5.3's fields),
                           nothing else; does not decide anything
  │ actual state
  ▼
Reconciler               — owns: the diff, and the decision of *which*
                           lifecycle operation (§8) to invoke to close it
  │ actions
  ▼
Adapters / generators / runtime
  ├── config generation  — owned by each component's configuration_owner
  │                        (§5.1's table — e.g. variant_f.sh/variant_j.sh
  │                        for nginx, api.sh/render.sh for Xray)
  ├── runtime start/stop — owned by each component's runtime_owner
  │                        (Panel's docker compose for nginx/Xray/Panel;
  │                        lib/telemt/* for TeleMT — never Panel)
  ├── health checks      — owned by whoever owns health for that
  │                        component today (TeleMT: itself, via
  │                        telemt_menu_status(); everything else: no
  │                        current owner, future requirement)
  └── repair             — NOT VERIFIED as existing anywhere for any
                           component today; §8 names it as vocabulary
                           only
```

**Idempotency** belongs at the Reconciler layer, not inside individual
adapters/generators — the one real precedent for this
(`panel_setup_api()`'s `Default-Profile` lookup, and `variant-f-j`'s own
`lib/panel/node/api.sh` lookup-before-create, per Finding 3) already
places the "does this already exist" check *before* calling the
generator/API-call, not inside it. A future Reconciler should generalize
this placement, not push idempotency checks down into `variant_f.sh`/
`render.sh` themselves, which today are (and should stay) pure functions
of their inputs.

**Compatibility logic** (MODE-string handling, legacy positional
defaults) belongs strictly in the Legacy compatibility boundary (§7),
between raw CLI/legacy input and Core's Desired State — never inside the
Reconciler, and never inside an adapter/generator. This is the same
placement Edge's own "Legacy MODE compatibility" section already
describes for the MODE→Topology mapping specifically; this document
extends the same placement to the newer `F_XHTTP_ENABLE`/
`TELEMT_DOMAIN`/`TELEMT_PORT` positional chain (§10).

---

## 7. Lifecycle contract

**`LifecycleIntent`, defined (review fix — was listed in §3's Core model
tree but never actually given a definition; the cross-reference there
pointed at the wrong section)**: it is not a separately-fielded object
with its own schema. `LifecycleIntent` is simply *one of the verbs below
(`create|install|reconcile|repair|reinstall|remove|health`) applied to
one `RuntimeComponent` identity* — the pairing of "which operation" and
"which component," nothing more. It is named as its own term in the Core
model tree only because the Reconciler (§6) needs to hand *something*
concrete to an adapter/generator, and "a lifecycle verb + a target
identity" is the minimal shape of that something. No new field list is
introduced beyond what §7's vocabulary and §5.2's `identity` field
already provide.

**Currently exists** in `variant-f-j` (verified this session, not
assumed):
- CREATE-with-lookup-before-create-and-rollback, for Remote Node —
  **now fully verified, not just the mechanism's existence**: identity,
  lookup query, and rollback scoping are all confirmed directly against
  `lib/panel/node/api.sh` (see §5.2's rewrite and the bullets below).
- CREATE-with-lookup-before-create (no rollback needed — single resource),
  for the Xray config profile (`panel_setup_api()`'s `Default-Profile`
  lookup).
- A `keep/reconfigure/disable` pattern for TeleMT specifically (cited by
  Edge as "the existing proof this works" for RECONCILE-shaped behavior)
  — confirmed present in `cli.sh`'s TeleMT collection flow (the
  `_cur_domain`/`_cur_port` re-use path, lines ~221-222 region).
- Topology **detection** (read-only, §5.1) via generated-config markers.

**Target contract** (vocabulary only, borrowed from
`docs/ARCHITECTURE.md` §4's Remote Node state machine — marked
`NOT VERIFIED (beta-branch precedent)` as a whole, since no code in
`variant-f-j` implements this full shape today, only the CREATE slice
above — **this status is unchanged by the completed identity audit**:
confirming *identity* does not confirm *reconcile/repair*, which remain
separately and independently absent, per below):
```
create    — first-time provisioning of a component for a given Deployment
install   — apply configuration + bring runtime up
reconcile — detect current state, converge without destroying data that
            should survive (TeleMT's keep/reconfigure is the one
            currently-real proof-of-shape, per above)
repair    — detected-broken state → known-good state
reinstall — full re-provision, at integration_owner's discretion, never
            implicitly becoming a second runtime_owner
health    — read-only status check
remove    — integration_owner withdraws; must not implicitly become
            "runtime_owner deletes the component" unless they are the
            same owner (per §5.1/Edge: true for nginx/Xray/Panel,
            deliberately false for TeleMT)
```

**Future requirement** (named, not designed): a general HEALTHY/DRIFT/
INCOMPLETE classification (the shape `ARCHITECTURE.md` §4.3 describes for
Remote Node) generalized to nginx/Xray/TeleMT — no such classification
exists for any of those three today, only for Remote Node's own
CREATE path, and even that is CREATE-only (no RECONCILE/REPAIR
distinction actually implemented, per §5.2's `lifecycle_state`
justification above).

**Specific answers to the task's Node questions — code audit now
complete, statuses updated accordingly**:
- *What happens to an already-existing Node, how is its identity kept*:
  **CURRENT / VERIFIED** — identity is `Nodes.name =
  "RemoteNode-${SELFSTEAL_DOMAIN}"`, looked up via `GET /api/nodes` +
  `select(.name==...)` (`api.sh:268-276`). A re-run with the same
  `SELFSTEAL_DOMAIN` matches the existing Node and reuses its `uuid`;
  address/IP, SSH endpoint, credentials, and hostname play no part in
  this lookup, per §5.2.
- *How are duplicate Panel resources avoided*: **CURRENT / VERIFIED** —
  the same name-based lookup-before-create is what prevents it, for the
  config-profile, the Node, and (via the weaker inbound-UUID match) the
  Host, checked independently in sequence (`api.sh:234-241`,
  `258-280`, `313-318`) — a Node that exists with no matching Host is
  handled correctly: a new Host is created without re-touching the Node.
- *What does reinstall mean*: `NOT FOUND` — no `reinstall` operation
  distinct from a fresh CREATE exists for the Panel-side Node/Host
  objects. Separately: the *remote-host deployment* half of
  `panel_install_remote_node()` (file copy, `docker compose up -d`)
  unconditionally re-executes on every invocation regardless of whether
  the Panel objects already exist — this is real, but it is not a Panel
  lifecycle abstraction; it's simply the absence of any state check on
  that side, and is called out separately below as a documentation/code
  inconsistency, not modeled here as a "reinstall" operation.
- *What does repair mean*: `NOT FOUND` — no repair operation exists;
  confirmed by the code's own comment (`api.sh:222-225`) that
  diff/repair against a mismatched existing profile "is RECONCILE's
  job... not defined here and not invented here."
- *What does remove mean*: `panel_remove()` (`lib/panel/management.sh`,
  cited by Edge) is confirmed to never touch TeleMT's paths, which
  answers "does remove correctly scope to integration_owner, not
  runtime_owner, for TeleMT" — Remote Node's own remove path was not
  independently re-read even in the completed identity audit, and stays
  open (see Open Questions).
- *Who owns stable identity*: for TeleMT, `lib/telemt/*` unambiguously
  (Edge's structural proof). For Remote Node, **now CURRENT / VERIFIED**
  — `lib/panel/node/api.sh` itself owns it (the `name` convention is
  defined and consumed entirely within that one file; nothing external
  computes or stores it).

**Implementation/documentation debt found during the identity audit
(observation only — source code is unchanged, this is not a contract
change)**: `lib/panel/node/install.sh:28` unconditionally warns the
operator on every run: *"Повторный запуск создаст новую ноду/хост в
Panel (операция не идемпотентна)"* ("re-running will create a new
node/host in Panel — the operation is not idempotent"). This
contradicts the lookup-before-create behavior confirmed above — a
re-run with the same `SELFSTEAL_DOMAIN` reuses the existing Node/Host,
it does not duplicate them. The warning text appears to predate the
lookup-before-create hardening pass and was not updated alongside it.
Recorded here as known debt; fixing the string is out of scope for this
document (per this task's constraints, no source file is touched).

---

## 8. Legacy compatibility boundary

```text
Legacy input
  ("MODE=1"|"2"|"F"|"J", F_XHTTP_ENABLE, TELEMT_DOMAIN, TELEMT_PORT,
   WEB_SERVER, old positional CLI args, old install-path defaults)
        │
        ▼
Compatibility resolver
  (today: the direct string-equality branches already scattered across
   config.sh / api.sh / cli.sh / render.sh / variant_f.sh / variant_j.sh
   — e.g. cli.sh's `[ "${F_XHTTP_ENABLE:-0}" = "1" ] && _reserved_ports+=(...)`,
   render.sh's `[ -z "$XHTTP_ENABLE" ] && [ MODE = J ] → XHTTP_ENABLE=1`
   fallback, config.sh's positional `${13:-0}` default for F_XHTTP_ENABLE)
        │
        ▼
Topology (Edge, looked up by id = the resolved MODE letter — §2.1;
          unchanged, not re-defined here)
        │
        ▼
Deployment (§3.1 — a Topology reference + the actually-chosen
            Capabilities + actual Domain values + TeleMtIntegration)
```

This is the exact three-stage chain the task asked for
(`MODE=F → resolver → Topology → Deployment`) — §2.1's disambiguation
made explicit as this diagram's middle step, which an earlier draft of
this section collapsed directly from resolver to Deployment.

This is Edge's own "Legacy MODE compatibility" section, extended to cover
every positional-argument chain confirmed this session (not just MODE):
`F_XHTTP_ENABLE` threads through `cli.sh` (local var) → `install.sh`
(local var, positional call) → `nginx/config.sh` (`$13` positional, with
its own independent default) → `variant_f.sh` (consumed, not
re-defaulted) → `api.sh` (separately re-derived via
`[ "$MODE" = "F" ] && _api_xhttp_enable="$F_XHTTP_ENABLE"`, confirmed at
`install.sh:304`). `TELEMT_DOMAIN`/`TELEMT_PORT` follow the same shape,
one layer shorter (`cli.sh` → `install.sh` → `nginx/config.sh`'s `$11`/
`$12` → `variant_f.sh`/`variant_j.sh`).

MODE does not "flow deep" into Core/Runtime under this contract by
construction: `Deployment.topology` is the *only* place MODE's literal
value survives past the resolver, exactly mirroring what Edge already
established for its own `Topology.id` field. Every other consumer of
MODE today (the `[ "$MODE" = "F" ]`-style branches in `api.sh`,
`nginx/config.sh`, `cli.sh`'s reserved-port arrays) is, under this
contract, a **resolver-internal** detail — it stays exactly where it is
physically today; this document does not require moving those branches,
only says that a future Core/Runtime layer sitting *above* them should
never re-implement its own `[ MODE = ... ]` check of its own, since the
resolver is defined as the single place that happens.

---

## 9. Capability → Adapter boundary

Current model (`required` | `optional`, per Edge's Capability contract)
is sufficient for XHTTP and TeleMT — both fit the two-value model with
no remainder, confirmed by Edge's own table (`XHTTP`: optional for F,
required for J; `TeleMT`: optional for both). No third value (e.g.
"conditionally required") is needed by any current scenario.

```text
Capability
    ↓  (name, applies_to_topology, required|optional — Edge's model)
Adapter
    ↓  (the thing that knows *how* to turn "on" into concrete config —
        today this is variant_f.sh's/variant_j.sh's own internal
        branching, not a separate named adapter object anywhere in code)
Edge + Runtime components
    (Listener + Backend + RuntimeComponent instances this capability
     adds — e.g. XHTTP "on" adds exactly one Listener + one Backend,
     per Edge's own Listener table)
```

The boundary between Capability and Adapter is **not currently a real
seam in the code** — `variant_f.sh` decides both "is XHTTP on" and "what
exact nginx block does that produce" in the same function, with no
separate adapter abstraction between them. This document names the
seam as a target extension point, not as something already separated.

**Extension point, not a new capability**: a future third capability
(the task's "future adapters") would need exactly the same three things
XHTTP and TeleMT already provide evidence for — a `required|optional`
classification per topology, a defined set of Listeners/Backends it
adds (or none, if it's TeleMT-shaped and owns its own runtime entirely),
and an explicit statement of whether it gets a Domain role (XHTHP:
no, per Edge; TeleMT: yes). No specific future protocol (Hysteria2,
mKCP, etc.) is modeled here — matching both Edge's and this document's
own non-goals.

---

## 10. Named data vs positional arguments — replacement table

| Current positional value | Source | Consumers (confirmed this session) | Semantic meaning | Proposed named field |
|---|---|---|---|---|
| MODE (`"1"\|"2"\|"F"\|"J"`) | `cli.sh:panel_cli_select_mode()` | `api.sh`, `install.sh`, `nginx/config.sh`, `compose.sh`/`compose/*.sh`, `management.sh` (marker fallback), `cli.sh`'s own reserved-port branch | which of the 4 fixed topology shapes | `Deployment.topology` |
| `F_XHTTP_ENABLE` (`"0"\|"1"`) | `cli.sh:100-106`'s confirm prompt | `install.sh:170,223,304` (positional relay + re-derivation), `nginx/config.sh:215` (`$13` positional, own default), `variant_f.sh` (consumed), `api.sh:87,162` (re-derived independently from MODE+the relayed value) | is F's optional XHTTP leg on | `Deployment.capabilities` containing `"XHTTP"` |
| `TELEMT_DOMAIN` | `cli.sh:170,221,243` | `install.sh:168,221,284`, `nginx/config.sh:190` (`$11` positional), `variant_f.sh:76`, `variant_j.sh:92` | SNI value for TeleMT's masquerade domain (Edge's Domain contract) | `Deployment.telemt.domain` |
| `TELEMT_PORT` | `cli.sh:171,222,252` | `install.sh:168,222,284`, `nginx/config.sh:191` (`$12` positional), `variant_f.sh:77`, `variant_j.sh:93` | TeleMT's own loopback listener port | `Deployment.telemt.port` |
| `F_XHTTP_PUBLIC_PORT` (`9443`) | literal constant in `variant_f.sh:57` | **RESOLVED (Candidate 3, 2026-09-07)** — `api.sh` no longer redeclares this as an independent fallback default; the public XHTTP port is now read via `core_port_allocation_public "$MODE" "xhttp"` inside `api.sh`'s `XHTTP_ENABLE` gate. (An earlier revision of this table cited `api.sh:421` for the old `${F_XHTTP_PUBLIC_PORT:-9443}` literal; that line has since moved on to unrelated code and no longer contains it.) `cli.sh` still reads `F_XHTTP_PUBLIC_PORT` directly for its confirm-prompt display text — that is intentional and out of scope (Candidate 4 = NOT NEEDED, single display-only call site, not a duplicated decision point). | Edge's own `PortAllocation` row (topology=F, capability=XHTTP, role=xhttp, public_port) | resolved — kept here for historical traceability, not as an open item |
| `F_XRAY_XHTTP_PORT` (`19444`) | literal constant in `variant_f.sh:58` | **RESOLVED (Candidate 1, 2026-09-07)** — `panel_reality_xhttp_inbound_port()`'s F/J arms now call `core_port_allocation_internal "$MODE" "xhttp"` instead of re-typing the literal. (An earlier revision of this table cited `api.sh:107` for the old `${F_XRAY_XHTTP_PORT:-19444}` literal; that line is now a comment documenting the fix, not the literal itself.) | same PortAllocation row's `internal_port` | resolved — kept here for historical traceability, not as an open item |
| `WEB_SERVER` (`1`\|`2`) | `cli.sh` | `install.sh` (F/J rejection guard), `compose/*.sh`, `nginx/config.sh` vs `caddy/config.sh` dispatch | nginx vs Caddy, and (per §3.1) really a Topology-level fact, not a Deployment-level one | `Topology.public_ingress_owner`'s underlying provider choice — belongs in Edge's model, referenced not duplicated by Deployment |

This table is the direct answer to the task's item 9. No file was
changed to produce it — every "Consumers" cell is a line/region actually
grepped and read this session (line numbers cited above), not inferred.

---

## 11. Current vs Target vs Future — consolidated

| Item | Status |
|---|---|
| Edge model (Listener/Backend/Route/Domain/PortAllocation/Capability) | **Current** — fully specified in `edge_contracts.md`, re-used unmodified here |
| `Deployment`/`TeleMtIntegration` desired-state shapes (§3-4) | **Target** — new to this document, not implemented anywhere |
| Topology-marker-based detection (`SERVER_MANAGER_TOPOLOGY`/`_XHTTP`) | **Current** — real, shipped 2026-09-05, verified this session |
| Remote Node lookup-before-create + rollback | **Current** — verified this session, `lib/panel/node/api.sh` |
| TeleMT keep/reconfigure/disable pattern | **Current** — cited by Edge, re-confirmed this session |
| TeleMT `telemt_menu_status()` health read | **Current, TeleMT-only** |
| Full RECONCILE/REPAIR/REINSTALL state machine (any component) | **Target**, borrowed vocabulary — `NOT VERIFIED` as implemented anywhere in `variant-f-j` |
| `RuntimeComponent`/Runtime-state reads (`config_hash`, `running`, generic `health`) | **Future requirement** — no current consumer, not invented speculatively |
| Reconciler as a distinct component | **Target** — named here, not built |
| Named-field replacement of positional chains (§10) | **Target** — table only, no code changed |
| Capability→Adapter seam as a real code boundary | **Future requirement** — currently collapsed into `variant_f.sh`/`variant_j.sh` internals |

---

## 12. Explicit non-goals

- No new MODE value is introduced or implied (matches Edge's own
  non-goal).
- No speculative capability (Hysteria2, mKCP, or anything from
  `docs/MULTI_PROTOCOL_L4_INGRESS.md`) is added to the real model —
  only the extension point (§9) is described.
- No Python/YAML/JSON runtime model is introduced — every structure
  above is pseudodata for design discussion, not a schema to implement.
- No file under `lib/panel/*`, `lib/telemt/*`, any generator, compose
  file, CLI file, or test file was read-then-modified — all were read
  only.
- This document does not resolve the `19444` duplicated-literal finding
  or the positional-argument chains it documents (§10) — it names the
  target shape those should eventually be checked against, exactly as
  Edge already did for the same two items.
- This document does not decide *when* Core/Runtime work begins, or in
  what order relative to Edge's own still-open migration order
  (contracts → port allocation → capability-threading → adapters →
  generators → management/lifecycle → migration, per Edge's own
  Explicit non-goals section).

---

## 13. Known migration debt (inherited from Edge, not newly introduced)

Both already named in `edge_contracts.md`'s own "Current limitations"
section, re-cited here because this document's Named Data table (§10)
depended on them being fixed eventually — one now is:
- **~~The `19444` duplicated literal (`variant_f.sh:58` / `api.sh:107`)~~
  — RESOLVED (Candidate 1, 2026-09-07).** `api.sh`'s F/J arms now call
  `core_port_allocation_internal("F"/"J", "xhttp")` instead of
  independently re-typing the literal; `api.sh:107` today is a comment
  documenting that fix, not the literal itself. See §10's updated
  `F_XRAY_XHTTP_PORT` row. Kept here for historical traceability.
- The positional-argument chains for `F_XHTTP_ENABLE`/`TELEMT_DOMAIN`/
  `TELEMT_PORT` through `config.sh → variant_f.sh/variant_j.sh → api.sh
  → render.sh` — still open, unaffected by the above.

No new migration debt is identified by this document beyond what §0's
findings already name (the doc-baseline mismatch itself is not code
debt, so it is not listed here).

---

## 14. Open questions

1. **~~Remote Node identity key~~ — CLOSED.** Directly confirmed this
   session against `variant-f-j`'s own `lib/panel/node/api.sh`:
   `Nodes.name = "RemoteNode-${SELFSTEAL_DOMAIN}"`, looked up via
   `GET /api/nodes` + name-equality filter. See §5.2, §7. No longer an
   open question; not replaced by a new one, since nothing about the
   answer left a further gap (address/SSH/credentials/hostname were all
   directly ruled out as identity components in the same pass, not left
   ambiguous).
2. **RECONCILE/REPAIR/REINSTALL for Remote Node — now confirmed absent,
   not merely assumed.** A full read of both `lib/panel/node/api.sh` and
   `lib/panel/node/install.sh` (this session's identity audit) found no
   such operations, and the code's own comment at `api.sh:222-225`
   explicitly disclaims reconcile ("not defined here and not invented
   here"). This is narrower than the general future-requirement already
   named in §7 — it's now a confirmed fact about Remote Node
   specifically, not just an assumption. What remains genuinely open:
   whether the same is true for nginx/Xray/TeleMT's own lifecycles
   (never audited at this level of detail) — that broader question is
   still exactly what §7's "Future requirement" paragraph already
   covers, unchanged.
3. **Should `WEB_SERVER` be folded into Edge's `Topology` model
   explicitly** (as §3.1 suggests it should, structurally), or does it
   deserve its own top-level Core entity? This document takes the
   position it belongs on Topology (a provider-choice, not a
   per-Deployment fact) but does not treat that as settled — no source
   document decides this for `variant-f-j` specifically.
4. **Is `beta` intended to eventually merge into `variant-f-j`, or vice
   versa, or do they stay permanently separate lines?** Not something
   this document can answer from code alone — it directly affects
   whether `docs/ARCHITECTURE.md`'s Remote Node/TeleMT target
   architecture (§4-5 there) is actually the future `variant-f-j` is
   heading toward, or an unrelated design for a different codebase line.
   Flagged because §7 and §5.2 both borrow vocabulary from that document
   under an explicit assumption that it's at least *directionally*
   relevant — if the two branches are not meant to converge, that
   borrowed vocabulary should be treated as inspiration only, not as a
   target this branch is actually converging toward.
5. **`docs/EDGE_CONTRACTS.md` vs `docs/edge_contracts.md`** (Finding 1) —
   should the file be renamed to match the task's/future references'
   casing, or should future references adopt the lowercase name that
   already shipped? Not resolved here — a docs-only rename was
   explicitly out of scope for this stage.

---

## Cross-references

- `docs/edge_contracts.md` — the Edge layer this document builds on;
  every Listener/Backend/Domain/PortAllocation/Capability fact is cited
  from there, not restated.
- `docs/ARCHITECTURE.md` §4-5 (`beta` branch) — source of the
  lifecycle-vocabulary and ownership-table *shape* borrowed in §5/§7,
  explicitly marked `NOT VERIFIED` for `variant-f-j` wherever borrowed.
- `docs/CONTRACTS.md`, `docs/LEGACY_AUDIT.md`,
  `docs/ENGINEER_GUIDELINES.md` (`beta`/`btemp` branches) — read in full
  for this document; found to be out-of-branch-scope per §0's Finding 3;
  not otherwise cited, since none of their specific claims were
  re-verified against `variant-f-j`.
