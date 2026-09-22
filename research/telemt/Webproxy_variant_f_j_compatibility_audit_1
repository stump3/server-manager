# WEBPROXY × variant-f-j: Topology Compatibility Audit

*Companion to `research/telemt/webproxy_research_report.md`, closing the
gap that report's §13/§14 explicitly left open. Research-only. No
Server-manager code was modified. No commits, no pushes.*

**Access note, stated up front:** the prior report could only reach the
public `main` branch of `github.com/stump3/server-manager` (single-branch
shallow clone). This session fetched `origin/variant-f-j` directly
(`git fetch origin variant-f-j:variant-f-j`) and inspected it at commit
`e74c74c`. Every claim below tagged **CODE-VERIFIED** was checked against
that checkout in this session. Every claim tagged **REPORT-SOURCED**
carries over unchanged from the prior report's TeleMT/MTProxyL findings
(themselves sourced by cloning `telemt/telemt` and `Liafanx/MTProxyL`
directly). Nothing below is asserted from either document without one of
these two tags or an explicit **DESIGN PROPOSAL** / **UNKNOWN** label.

---

## 0. Correcting the framing this task arrived with

Before the substance: several terms this task's brief treated as already
"established source fact" are not code artifacts in `variant-f-j`. Stating
this plainly avoids building the rest of the audit on a false floor.

| Term | Status |
|---|---|
| `PortAllocation`, `RuntimeComponent`, `Topology`, `Listener`, `Backend`, `Route`, `Capability`, `Domain` contracts | **CODE-VERIFIED, real** — `lib/core/topology.sh`, `lib/core/port_allocation.sh`, `lib/core/runtime_component.sh`, `lib/core/deployment.sh`, `lib/core/adapter_webserver.sh`, `lib/core/adapter_reality.sh`, documented in `docs/edge_contracts.md` and `docs/CORE_RUNTIME_CONTRACTS.md`. |
| `F_XHTTP_ENABLE` | **CODE-VERIFIED, real** — a genuine CLI/config toggle, threaded through `topology.sh`, `runtime_component.sh`, `adapter_webserver.sh`, `deployment.sh`, `nginx/config.sh`, `panel/api.sh`, `panel/cli.sh`, `panel/install.sh`, and six test files. |
| `TELEMT_COLOCATE` | **CODE-VERIFIED, real** — gates co-located bind + PROXY protocol in `lib/telemt/core.sh` / `lib/telemt/install.sh`. |
| `J_XHTTP` (as a flag name) | **Does not exist.** Zero matches anywhere in the tree. J's XHTTP is topology-intrinsic, not a toggle — see §3. The brief's assumption of F/J flag symmetry is wrong; edge_contracts.md says so explicitly and the code confirms it. |
| `Capability Registry`, `Desired State`, `Plan IR` | **Documented target vocabulary, not implemented code.** They appear in `docs/edge_contracts.md`, `docs/CORE_RUNTIME_CONTRACTS.md`, `docs/ARCHITECTURE.md`, and two `research/network/*.md` planning docs / a `poc/network-inspect/` proof-of-concept — never as a sourced `.sh` module. `lib/core/port_allocation.sh:62-64` explicitly states `WEB_SERVER and Plan IR (poc/network-inspect/)` are **out of scope** for Core today. Treat these as "the vocabulary a future Core/Runtime design should target," not as an existing registry to query. |
| "Variant J's existing TeleMT SNI branch" | **True, but not for the WEB carrier.** J (and F) already SNI-route a TeleMT listener at `:443` — but that's TeleMT's classic MTProto/FakeTLS transport (`protocol: mtproto/tls` in the PortAllocation table), wired in 2026-08-31 ("Phase C, XHTTP_ENABLE/TELEMT_COLOCATE"). Nothing about TeleMT's newer `WEB` transport (HTTP/WebSocket carrier, shipped by upstream TeleMT 2026-08-22/23) exists anywhere in `variant-f-j` — confirmed by grepping the whole tree for `carrier`, `[web]`, `web.vhosts`, `WEB_LAYOUT`, `transport = "web"`, `ListenerTransport`: zero hits outside the research report itself. `docs/TELEMT_CONFIG.md` documents only the classic `[censorship]`/FakeTLS schema, no `[web]` section. |
| `xray-architecture.md` (cited repeatedly by the research report as "this project's own document") | **Not present in this repository at any path, on any branch reachable from this session.** It's presumably a document from a prior chat session's attachments. Its Reality/FakeTLS architecture claims are not re-verified here; where this audit needs the same ground (nginx-stream SNI routing, PROXY protocol posture), it cites `docs/edge_contracts.md` and `docs/MULTI_PROTOCOL_L4_INGRESS.md` instead, which **are** in this repo and independently establish the same pattern against real `variant-f-j` code. |

One naming collision worth flagging explicitly: **`WEB_SERVER` already means something in this codebase** — it's the nginx-vs-Caddy selector discussed in `lib/core/topology.sh`'s header comment and `docs/CORE_RUNTIME_CONTRACTS.md` §14. TeleMT's `WEB` transport/carrier is an unrelated concept that happens to share the word "web." This audit uses "WEBPROXY" or "TeleMT WEB" throughout, never bare "WEB_SERVER," to keep the two apart.

---

## 1. Evidence available

- `docs/edge_contracts.md` (492 lines) — the canonical, code-verified Topology/Listener/Route/Backend/Domain/PortAllocation/Capability/Runtime-ownership model for `variant-f-j` today. Its own preface states it was checked against `origin/variant-f-j @ c7d3d3b` by "actually executing `render.sh` and the nginx generators," not just read.
- `lib/core/topology.sh`, `lib/core/port_allocation.sh`, `lib/core/runtime_component.sh`, `lib/core/deployment.sh`, `lib/core/adapter_webserver.sh`, `lib/core/adapter_reality.sh` — the code-side accessors, spot-checked in this session and confirmed to match `edge_contracts.md` line for line (`topology.sh`'s own header: "if this file and `docs/edge_contracts.md` ever disagree, the doc is the source of truth and this file has a bug").
- `lib/panel/nginx/variant_f.sh` / `variant_j.sh` — the actual nginx `stream{}` generators, confirmed in this session to implement exactly the SNI-map-plus-TeleMT-branch pattern `edge_contracts.md` describes (`TELEMT_MAP_LINE`/`TELEMT_UPSTREAM`, appended to the same shared `:443` block Vision and Panel/Sub already use).
- `docs/MULTI_PROTOCOL_L4_INGRESS.md` / `_REVIEW.md` — independent confirmation that `ssl_preread`-based nginx-stream SNI routing is "VERIFIED, already implemented (MODE=F)" and that PROXY protocol is block-wide, not per-branch, scoped.
- `docs/TELEMT_CONFIG.md` — TeleMT's classic config surface as currently documented here; no `[web]` section, confirming no WEB-carrier awareness exists in this repo's docs either.
- `research/telemt/webproxy_research_report.md` (434 lines) — the prior, TeleMT-side research, itself sourced by cloning `telemt/telemt` (935b5a3), `Mekotofeuka/MTPROTO_FIX_By_MEKO` (f809bb9), and `Liafanx/MTProxyL` (8f17410) directly. Its TeleMT/MTProxyL findings are treated here as **REPORT-SOURCED** fact; only its Server-manager-side sections (§13/§14, explicitly marked incomplete there) are being redone here with real evidence.

---

## 2. Verified TeleMT WEB requirements

**Verified (REPORT-SOURCED, from direct inspection of upstream TeleMT/MTProxyL source):**
- TeleMT's `WEB` is a native transport (`ListenerTransport::Web`), never TLS-terminating; an external L7 terminator (nginx or HAProxy) is mandatory.
- The TeleMT-layer discriminator is HTTP **Host header + exact path**, post-TLS-termination — never SNI, never ALPN, at that layer.
- SNI only enters the picture one layer up, *if* the operator chooses to share one public port between WEB and something else (MTProxyL's `WEB_LAYOUT=shared`); a dedicated port (`split`) needs no SNI logic at all.
- WEB always needs its own domain (`[[web.vhosts]].host`); in `shared` layout that domain must differ from whatever else is SNI-routed on the same port.
- Config shape: `[[server.listeners]]` entry with `transport = "web"`, `proxy_protocol = false` (enforced — WEB rejects `proxy_protocol = true` on its own listener), plus a `[web]` block with `carrier`, `[[web.vhosts]]`, `[web.vhosts.decoy]`, `[[web.vhosts.profiles]]`.
- User→WEB-profile linkage is **not automatic** — TeleMT's own control API doesn't create a WEB profile when a user is created; something has to reconcile `[access.users]` against `[[web.vhosts.profiles]]` (MTProxyL does this itself, by direct TOML surgery).
- Engine-version gate: WEB requires TeleMT ≥ 3.5.1; older engines silently ignore `transport = "web"` and turn it into a second plain MTProto listener — a real, documented silent-downgrade failure mode.

**Inferred (REPORT-SOURCED, labeled as inference there too):**
- Three-way SNI sharing (FakeTLS + WEB + Xray REALITY on one port) is architecturally plausible — nginx-stream's `map $ssl_preread_server_name` has no arity limit — but was **not observed** coexisting in any of the three studied repos, and REALITY's ClientHello handling was never cross-checked against `ssl_preread`'s parsing behavior.

**Still requiring upstream/source verification (unchanged from the prior report — this audit adds nothing here since it's TeleMT-side, not Server-manager-side):**
- Depth of MTProxyL's firewall/backup integration with WEB beyond the single call sites observed.
- Telegram Desktop's actual current WEB-client behavior against what TeleMT's docs describe (flagged by TeleMT's own authors as still outstanding).

---

## 3. Current variant-f-j topology compatibility

| Topology | WEB possible in principle | Required frontend | Routing discriminator | Port implications | Reality interaction | Evidence |
|---|---|---|---|---|---|---|
| MODE=1 | Not without adding nginx-stream in front — Xray owns `:443` directly today, no `stream{}` exists in this topology at all | Would need to introduce nginx as a new public-ingress owner, which is a topology change, not a WEB-specific one | n/a today | n/a | n/a — no shared port exists to interact with | `edge_contracts.md` topology matrix: `public_ingress_owner=xray` for MODE=1, no `Listener` other than Vision `:443` |
| MODE=2 | Not applicable — no `stream{}`, `public_ingress_owner=nginx-http` (ordinary `http{}` reverse-proxy for Panel/Sub only); no REALITY/Vision listener exists in this topology at all | n/a | n/a | n/a | n/a — MODE=2 has no Xray/REALITY component | `edge_contracts.md` topology matrix |
| F | Yes, as an additional SNI branch on the existing shared `:443` `stream{}` block | nginx (`stream{}`, already present) | SNI, via the same `map`/`ssl_preread` mechanism already routing Panel/Sub, Vision, and TeleMT(classic) | Public side: none (reuses `:443`, no new public port needed in `shared` layout); or a new dedicated public port if `split` layout is chosen instead | Untested combination (see §2) — F already has REALITY (Vision) sharing this exact port with TeleMT classic today, so the router itself is proven; WEB would be a fourth SNI branch on a mechanism already carrying three | `variant_f.sh`'s `TELEMT_MAP_LINE`/`TELEMT_UPSTREAM` pattern (CODE-VERIFIED); `edge_contracts.md` Listener table row "TeleMT (F or J)" |
| J | Same as F | nginx (`stream{}`, already present) | Same | Same | Same reasoning as F — J already runs Vision + TeleMT(classic) + Panel/Sub on the same shared `:443`, plus its own dedicated XHTTP port | `variant_j.sh` (same pattern, CODE-VERIFIED per edge_contracts.md's cross-reference); `edge_contracts.md` Listener table row "J-XHTTP" (dedicated port, unaffected either way) |

**Do not rank the topologies** (per this audit's own brief) — but one asymmetry is worth naming factually rather than as a ranking: F and J are functionally identical from WEB's point of view. Both already terminate a shared, SNI-routed `:443` `stream{}` block carrying Vision + Panel/Sub + TeleMT(classic). J's only structural difference (its required, dedicated-port XHTTP listener) is orthogonal to WEB, since XHTTP routes by dedicated port, not SNI, and has no domain role to collide with. MODE=1 and MODE=2 would each require introducing a `stream{}` layer that doesn't exist in them today — a bigger, non-WEB-specific change.

---

## 4. Listener model mapping

A future TeleMT-WEB listener maps onto the existing `edge_contracts.md` Listener contract with no new fields required:

```
Listener
  - id                  : "TeleMT-WEB (F or J)"
  - transport           : tcp                         (unchanged — WEB is still TCP+TLS at the edge)
  - bind                : 0.0.0.0 → 127.0.0.1          (same public/loopback split every current listener uses)
  - public_port         : 443 (shared layout, reusing the existing SNI-routed port)
                           or a new dedicated public_port (split layout)
  - internal_port       : a new loopback port, distinct from $TELEMT_PORT (the classic listener) —
                           TeleMT's config schema requires WEB on its own [[server.listeners]] entry,
                           mutually exclusive per-entry with transport="mtproxy"
  - public              : yes
  - protocol            : a NEW value needed here — "telemt" already means the classic transport;
                           this contract's `protocol` enum (vision | xhttp | panel_sub | telemt) would need
                           a fifth value (e.g. "telemt_web") to keep the two TeleMT transports distinguishable,
                           since they are different listener entries with different PROXY-protocol posture (see §6)
  - tls_mode            : passthrough (shared layout — nginx-stream still just peeks at SNI and forwards
                           raw bytes to a SECOND, inner TLS-terminating point, per REPORT-SOURCED §4.2's
                           "who terminates TLS: nginx's inner server block, not the stream{} peek")
                           — this is the one place WEB's mapping is NOT a bare passthrough like every
                           current listener: TeleMT itself never terminates TLS, so *something* in the
                           nginx layer must, one hop after the SNI peek. Today's F/J stream{} config
                           already does this for Panel/Sub (SNI → internal HTTPS listener that DOES
                           terminate TLS) — WEB would follow that existing Panel/Sub pattern, not the
                           Vision/TeleMT-classic pattern (which stays passthrough all the way to the backend).
  - routing_mode        : sni (shared) or dedicated_port (split) — both values already exist in the contract
  - proxy_protocol_in   : yes if shared (inherits the shared :443 block's blanket `proxy_protocol on;`,
                           same block-wide-scoping limitation edge_contracts.md documents for the other four)
  - proxy_protocol_out  : MUST be false — TeleMT's own WEB listener schema explicitly rejects
                           `proxy_protocol = true` on a transport="web" entry (REPORT-SOURCED §2.3/§8).
                           This is a genuine mismatch worth flagging (§10): if WEB shares the same nginx
                           :443 block as Vision/TeleMT-classic (which both need proxy_protocol_in=yes),
                           the inner TLS-terminating hop for WEB must be the thing that drops PROXY
                           protocol before reaching TeleMT — mirroring exactly how Panel/Sub's existing
                           inner HTTPS listener already reads $proxy_protocol_addr itself rather than
                           forwarding the PROXY-wrapped stream onward.
  - backend             : loopback TeleMT WEB listener (127.0.0.1:<new port>)
  - runtime_owner       : lib/telemt/* (unchanged — same engine process, new listener)
  - integration_owner   : Panel (trigger only, unchanged — matches edge_contracts.md's existing
                           "Panel is never TeleMT's runtime_owner" invariant)
```

**DESIGN PROPOSAL, not code**: nothing above required inventing a new field on the Listener contract itself — the *shape* is sufficient. The one real gap is the `protocol` enum needing a fifth value, and the routing detail that WEB's SNI branch (if shared) needs an inner TLS-terminating hop where the other SNI branches sharing this router today are pure TCP passthrough.

---

## 5. PortAllocation mapping

The existing `PortAllocation` shape (`topology, capability, role, public_port, internal_port, protocol, proxy_protocol, owner`) is sufficient as-is. A plausible new row, following the exact shape of the existing TeleMT rows:

| topology | capability | role | public_port | internal_port | protocol | proxy_protocol | owner |
|---|---|---|---|---|---|---|---|
| F | TeleMT-WEB (optional) | telemt_web | 443 (shared) or new dedicated port (split) | new, distinct from `$TELEMT_PORT` | web/tls (http/websocket carrier) | **no** (mismatched with the row above it — see §10) | TeleMT |
| J | TeleMT-WEB (optional) | telemt_web | same pattern | same | same | no | TeleMT |

No new column is needed. The `proxy_protocol=no` value is not an oversight — it's the one place this table would encode a real, upstream-enforced constraint (§2), not a Server-manager design choice.

---

## 6. PROXY protocol flow

Extending `edge_contracts.md`'s own "PROXY protocol invariant" table with a new row, using its exact verified format:

| Listener | `proxy_protocol_in` (nginx `stream{}`) | `proxy_protocol_out` (backend expectation) | Where each side is set |
|---|---|---|---|
| TeleMT-WEB (F or J, shared layout) | `proxy_protocol on;` — **inherited whether wanted or not**, per the same block-wide-scoping limitation already documented for Vision/TeleMT-classic/Panel-Sub on this exact `:443` server | **must be `false`** — TeleMT's WEB listener schema rejects `proxy_protocol=true` outright (REPORT-SOURCED) | nginx side is forced on by the existing shared block; TeleMT's own config must NOT set it, creating the one structural mismatch this audit surfaces |

This is the single clearest **hard architectural fact** (not a soft gap) this audit found: **in `shared` layout, the real client IP cannot reach TeleMT's WEB listener via the PROXY-protocol mechanism the other four listeners on this port already use**, because nginx's blanket `proxy_protocol on;` cannot be scoped per-SNI-branch (documented limitation, confirmed against `docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md`'s own runtime-verified correction on this exact point), and TeleMT's WEB listener refuses PROXY protocol on principle. The only way to preserve real client IPs for WEB is the mechanism TeleMT's own `web_client_ip_source = "x_forwarded_for"` config field exists for: an inner, TLS-terminating HTTP hop (the same shape Panel/Sub already uses) that reads the PROXY-derived address on its nginx-facing side and re-injects it as `X-Forwarded-For` on its TeleMT-facing side. This is not a new capability — it's the identical pattern `variant_f.sh`/`variant_j.sh` already implement for Panel/Sub (`REAL_IP_P="$proxy_protocol_addr"` in `lib/panel.sh`'s pre-split ancestor, and the equivalent in the split generators) — just pointed at a new backend.

---

## 7. TLS/domain ownership

- **New domain role required**: `TELEMT_WEB_DOMAIN`, following the exact pattern of the existing `Domain contract` table (`TELEMT_DOMAIN` → SNI match → TeleMT Backend). Per §2/§4.2's REPORT-SOURCED constraint, this domain **must differ from `TELEMT_DOMAIN`** whenever both share the same `:443` SNI router (shared layout) — the same class of constraint `edge_contracts.md` already states must hold across every domain role sharing a port, not a new invariant type.
- Certificate ownership for the new domain is independent of `SELFSTEAL_DOMAIN`'s (which isn't an edge-routing domain at all, per the existing Domain contract) and independent of `TELEMT_DOMAIN`'s own certificate story (TeleMT-classic's FakeTLS domain doesn't necessarily need a real CA-signed cert the way WEB's inner TLS-terminating hop does, since WEB's frontend must present a real, validated certificate to real browsers/WebViews — REPORT-SOURCED §4.5's preflight list confirms MTProxyL requires DNS resolution + real cert issuance for its WEB domain specifically).
- Nothing here requires generalizing REALITY's identity concept (`edge_contracts.md`'s explicit non-goal) — WEB's TLS identity is an ordinary CA-issued vhost cert, unrelated to REALITY's `serverNames`/decoy mechanism.

---

## 8. Relation to F / F+XHTTP / J

No new MODE is required or implied by anything in this audit. WEBPROXY:
- Does not touch XHTTP's dedicated-port routing at all (different Listener, different routing_mode, no shared domain or port unless deliberately co-located).
- Slots into the **existing optional-capability pattern** F already uses for XHTTP and TeleMT-classic: a real CLI toggle, off by default, adding one Listener + one PortAllocation row + one Domain role — exactly the shape `core_topology_optional_capabilities()` already expresses for `F` → `XHTTP`.
- For J, the same optional-capability shape applies (J today has zero optional capabilities per `topology.sh:93-98` — TeleMT-classic is itself optional-but-not-listed-in-`topology.sh`, per that file's own header note explaining TeleMT is deliberately modeled as a `Deployment` field, not a `Capability`, per `CORE_RUNTIME_CONTRACTS.md §3.2`). WEBPROXY, being TeleMT-owned, should almost certainly follow that same precedent — a `DEPLOYMENT_TELEMT_WEB_*` field alongside the existing `DEPLOYMENT_TELEMT_*` fields, **not** a new entry in `topology.sh`'s capability lists. This is the one placement decision this audit can make with high confidence, precisely because TeleMT-classic already answered the identical question for this codebase.

---

## 9. Architectural placement

| Layer | Status | Placement for WEBPROXY |
|---|---|---|
| Desired State | **Vocabulary only, not implemented** (see §0) | N/A until Desired State itself exists as code — REPORT-SOURCED §16's proposed shape (mode flag, layout, frontend, carrier, domain, profile set, decoy config) remains a reasonable target, unchanged by this audit |
| Plan IR | **Vocabulary only, not implemented**, explicitly out-of-scope per `port_allocation.sh:62-64` | N/A, same reason |
| Topology | **CODE-VERIFIED, implemented** (`topology.sh`) | **No change** — F and J's `required_capabilities`/`optional_capabilities` lists should NOT gain a `TeleMT-WEB` entry, per §8's reasoning (TeleMT-classic's own precedent) |
| Capability Registry | **Vocabulary only** — `edge_contracts.md`'s "Capability model" is a documented shape, not a queryable registry object in code | Would follow TeleMT-classic's precedent of NOT being modeled here (§8) |
| Listener | **CODE-VERIFIED, implemented** (contract in `edge_contracts.md`, consumed by the nginx generators) | New Listener instance per §4 — no contract change needed |
| RuntimeComponent | **CODE-VERIFIED, implemented** (`runtime_component.sh`), fixed 5-value `type` enum: `nginx \| xray \| panel \| telemt \| remote_node` | **No new type needed** — WEB is a new listener/config surface on the *same* running TeleMT process already modeled as `type=telemt`; it doesn't introduce a sixth runtime component, matching this file's own principle of pure declarative inventory over an already-resolved Deployment |
| Provider/frontend (nginx renderer) | **CODE-VERIFIED, implemented** (`variant_f.sh`/`variant_j.sh` already emit the TeleMT-classic SNI branch + inner-HTTPS-terminating pattern for Panel/Sub) | Needs a new template fragment: a WEB SNI branch reusing the *Panel/Sub* inner-TLS-terminating shape (§6), not the Vision/TeleMT-classic passthrough shape |
| TeleMT integration (`lib/telemt/*`) | **CODE-VERIFIED, implemented for classic transport only** | Needs a new config-rendering path for `[web]`/`[[server.listeners]] transport="web"`, following `docs/TELEMT_CONFIG.md`'s existing documentation pattern (this file would need a `[web]` section added, mirroring upstream's schema per REPORT-SOURCED §2.3) |
| Link generation | Not inspected this session (no `lib/telemt/*` link-generation code was read in depth) | **Missing/unknown** — flagged, not guessed |

---

## 10. Hard blockers

Only one genuine protocol-level impossibility surfaced by this audit:

- **PROXY-protocol posture conflict in shared layout** (§6): the shared `:443` `stream{}` block's blanket `proxy_protocol on;` cannot be turned off for a single SNI branch, and TeleMT's WEB listener schema refuses `proxy_protocol=true`. This is not fatal — it's solved by inserting an inner TLS-terminating hop (the same pattern Panel/Sub already uses) rather than passthrough-forwarding to TeleMT directly — but it means WEB **cannot** reuse the Vision/TeleMT-classic passthrough Route shape; it must reuse the Panel/Sub inner-termination shape instead. Getting this wrong (treating WEB like a fourth passthrough branch) would silently break real-client-IP visibility for every WEB connection.

No other hard blocker was found. MODE=1/MODE=2 incompatibility (§3) is an architectural mismatch, not a protocol impossibility — it's solvable by not offering WEB on those topologies, which requires no new invariant.

---

## 11. Soft gaps

- `protocol` enum on the Listener contract needs a fifth value to distinguish TeleMT-classic from TeleMT-WEB (§4) — a small, mechanical extension, not a redesign.
- User↔WEB-profile reconciliation (§2, REPORT-SOURCED §11/§15) has no existing analog anywhere in `lib/telemt/*` today — TeleMT-classic's user model doesn't need this because it has no equivalent secondary profile object.
- Certificate-issuance for a second, independent domain on the same node — not inspected this session whether Panel's existing cert-issuance path (used for `PANEL_DOMAIN`/`SUB_DOMAIN`) generalizes cleanly to an arbitrary additional domain, or is hardcoded to those two roles.
- Firewall interaction: TeleMT's own docs are emphatic that the plaintext WEB listener must never be exposed even when loopback-bound (REPORT-SOURCED §19) — whether `variant-f-j`'s existing UFW-handling code (`test_adapter_ufw_cleanup_ownership.sh`, `test_hy2_ufw_lifecycle.sh` exist as test names, suggesting UFW logic is real elsewhere in this tree) already has a hook point for a new loopback-only port was not inspected this session.

---

## 12. Remaining unknowns

- Whether Xray/REALITY can coexist behind the same SNI router as WEB in *this specific* nginx-stream implementation — architecturally plausible (§2), never tested in either the TeleMT-side research or this Server-manager-side audit.
- Panel's actual cert-issuance code path (not read this session) — needed to confirm whether a third domain is a config-value change or a code change.
- `lib/telemt/*`'s link-generation code (not read this session) — needed to confirm how a `tg://webproxy?...` link would actually get produced and surfaced to users alongside the existing classic-transport link.
- The exact firewall rule surface for a new loopback port (previous bullet) — test files suggest the machinery exists; their content wasn't read this session.

---

## 13. Minimum future implementation boundary

No code. No speculative refactor. No new MODE — none of the evidence gathered in this audit requires one. Stated as the smallest change-shape consistent with everything verified above:

1. One new `DEPLOYMENT_TELEMT_WEB_*` field set, following `DEPLOYMENT_TELEMT_*`'s existing precedent exactly (§8) — not a `topology.sh` capability entry.
2. One new Listener instance + one new PortAllocation row per §4/§5, reusing the existing contract shapes unchanged except for the `protocol` enum's fifth value.
3. One new nginx template fragment reusing the **Panel/Sub inner-TLS-termination shape**, not the Vision/TeleMT-classic passthrough shape (§6/§10 — this is the one place picking the wrong existing pattern to copy would silently break real client IPs).
4. One new `lib/telemt/*` config-rendering path for `[web]`/`transport="web"`, and a `docs/TELEMT_CONFIG.md` addition documenting it.
5. A user↔WEB-profile reconciliation step — genuinely new logic with no existing analog in this codebase (§11) — scoped as narrowly as MTProxyL's own `web_target_sync_profiles()` precedent (REPORT-SOURCED §4.4).

Everything else this audit touched (Topology, RuntimeComponent, Capability Registry, Desired State, Plan IR) requires **no change** — the existing shapes already accommodate WEBPROXY as an additive, TeleMT-owned, optional capability, provided the PROXY-protocol posture in §6/§10 is implemented correctly.
