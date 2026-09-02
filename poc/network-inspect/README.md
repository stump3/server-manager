# `network inspect` — read-only inventory PoC

**Status: experimental research PoC. Not part of the product.**

- Not sourced by `server-manager.sh`.
- Not registered in `lib/cli/router.sh`.
- Does not read, write, or import anything under `lib/`, except an
  optional read-only `source` of `lib/ui/output.sh` purely for
  stderr-formatted progress messages (falls back to a plain-text
  stderr equivalent if that file isn't found — see the top of
  `network-inspect.sh`).
- Introduces **zero** MODE=1/2/F changes and **zero** behavioral
  changes to any existing installer/panel/nginx/compose code path.
- Purely additive: deleting the whole `poc/` directory returns the
  repo to its exact prior state.

This exists to validate one specific technical claim from the
accompanying research report (`smart-configurator-research.md`,
delivered earlier in the same design conversation): that the full

```
port -> socket -> PID -> process -> systemd/docker ownership -> public exposure -> firewall -> detected ingress
```

chain is buildable today, on a real Linux host, using only Linux-native
tools (`ss`, `ip -j`, `/proc`, the Docker Engine API over its unix
socket, `systemctl show`, `firewall-cmd`/`ufw`/`nft`/`iptables-save`) —
with **no new discovery algorithm, no netlink/eBPF code, no third-party
inventory library** — and that this can be done while correctly
distinguishing "couldn't check" from "genuinely has no owner" at every
step (the risk the research report calls out most strongly in §3/§19).

## What it is

Two files:

- `inventory_build.py` — all of the actual discovery/correlation/
  normalization logic. Every external call it makes is read-only
  (see the exhaustive list in its own module docstring). No file is
  ever written by this script other than its own stdout.
- `network-inspect.sh` — a thin orchestration wrapper (tool-presence
  check, root check, argument parsing, `exec python3 ...`). It
  contains no discovery/parsing logic of its own, per this repo's own
  Contract 9 (`docs/CONTRACTS.md` §9 — "Bash decides where/when,
  Python decides what").

Both files follow this repo's Contract 1 (`docs/CONTRACTS.md` §1):
stdout is the single normalized JSON Inventory document and nothing
else; every diagnostic/progress message goes to stderr.

## Usage

```bash
./poc/network-inspect/network-inspect.sh            # compact JSON to stdout
./poc/network-inspect/network-inspect.sh --pretty    # indented JSON to stdout
```

Run as root for full PID/process resolution. Running as a non-root
user still produces a complete, valid Inventory — listeners whose
owning process couldn't be read will carry
`"pid_unresolved_reason": "permission_denied"` rather than being
silently reported as unowned (verified in this PoC's own test run,
see below).

## Schema changelog

### poc-2 (current)

Additive over poc-1 — implements the "Concrete next implementation
step" (§30) from the `Smart Network/Deployment Configurator — Shared
UDP & TCP/UDP Topology Planner` research document: four new read-only
Discovery facts a future Capability Registry / Planner will need.
Every new field follows this PoC's own honest-unknown convention
(`status: available|resolved|unresolved` + a specific
`unresolved_reason`, never a bare `false`/`null` standing in for
"couldn't check").

New top-level keys:

- `hysteria2.obfuscation` — reads this project's own Hysteria2 config
  path (`lib/core/config.sh`'s `HYSTERIA_CONFIG`, verified by direct
  read, not assumed — default `/etc/hysteria/config.yaml`, overridable
  for tests via `SM_NETWORK_INSPECT_HYSTERIA_CONFIG`) and determines
  `obfs.type`. This is the single most safety-critical new fact: per
  the research document, Salamander/Gecko obfuscation silently defeats
  every QUIC-aware L4 router surveyed, so a planner that cannot see
  this value cannot safely evaluate a shared-UDP topology at all.
  Uses a deliberately minimal, targeted block-style extractor (see
  `hysteria2_obfuscation()`'s own docstring) — NOT a general YAML
  parser, and does not add a PyYAML dependency, matching this
  project's own existing convention of regex/line-based config editing
  for this exact file (`lib/hy2/install.sh`, `lib/hy2/integration.sh`).
  Distinguishes the field being *physically absent* from the config
  (in which case `effective_value: "none"` is recorded with
  `effective_value_basis: "default_when_absent"`, per upstream
  Hysteria2/sing-box documentation confirming omission = unobfuscated)
  from it being *explicitly* set to any value, from the file being
  missing/unreadable/malformed (each a distinct `unresolved_reason`).

- `public_ipv4` — reuses `collect_interfaces()`'s already-gathered
  `ip -j addr` data (no new network call) to count globally-routable
  IPv4 addresses. Uses a **stricter** test
  (`_is_globally_routable_ipv4()`, based on `ipaddress.IPv4Address.
  is_global`) than the pre-existing `_is_public_ip()` helper used for
  per-listener `public_exposure` classification — see "Research
  findings requiring correction" below for the concrete discrepancy
  this surfaced (RFC 6598 CGNAT space).

Extended existing keys (both remain optional-shaped — absence of the
underlying tool is never an error):

- `detected_ingress.nginx.stream_capabilities` — parses `nginx -V`'s
  `configure arguments:` line (nginx writes this to stderr; both
  streams are read, matching the existing `_version_of()` convention)
  for whole-token `--with-stream` / `--with-stream_ssl_preread_module`
  presence. Whole-token matching matters: a naive substring check
  would falsely detect bare `--with-stream` inside
  `--with-stream_ssl_preread_module`, since one is a prefix of the
  other — guarded against explicitly (see
  `test_substring_collision_guard` in the new test suite). Also
  records whether the module was compiled `static` or `dynamic` (a
  dynamic module additionally needs a `load_module` directive in
  `nginx.conf` to be active at runtime — a fact this shallow-by-design
  PoC does not check, and says so explicitly via
  `dynamic_module_caveat` rather than silently assuming it's loaded).

- `detected_ingress.caddy.layer4_capabilities` — parses
  `caddy list-modules --versions` output into a raw module-name list
  and checks for `layer4`, `layer4.matchers.quic`,
  `layer4.matchers.tls` specifically. Per the task's own explicit
  warning and the research document's §7 principle: **"Caddy
  installed" is never treated as evidence "caddy-l4 available" is
  true**, and **"layer4 present" is never treated as evidence the QUIC
  matcher specifically is present** — these are three independently-
  recorded raw facts, not one inferred capability. The pre-existing
  `layer4_module_compiled_in` boolean field is kept for shape
  continuity but is now correctly derived from this same parsed module
  list instead of poc-1's original crude `"layer4." in raw_text`
  substring check.

One narrow, deliberate restructuring: `detected_ingress.nginx` /
`.caddy` / `.haproxy` are now **always** present as keys (each with an
explicit `"present": bool` field) instead of being omitted entirely
when the corresponding binary is absent. poc-1's original convention
(key omitted = tool absent) worked but was inconsistent with this same
PoC's own PID-resolution convention (explicit `pid_unresolved_reason`
field, never a silently-missing key). This PoC has zero registered
consumers anywhere in the codebase today (still true as of this
round — verified), so the compatibility cost of tightening this is
zero in practice.

## Research findings requiring correction

One concrete discrepancy was found between the research document's
implicit assumption and this project's actual existing code, surfaced
while implementing `public_ipv4`:

| | |
|---|---|
| **Claim** | The research document's Discovery/Capability model assumes "public IPv4" can be determined by reusing this PoC's existing public-exposure classification. |
| **Evidence** | `_is_public_ip()` (poc-1, unchanged) classifies an address as public if it is not `ipaddress`-module `is_loopback`/`is_link_local`/`is_private`. Directly verified in this Python version: `ipaddress.ip_address("100.64.0.1").is_private` is `False` — RFC 6598 Carrier-Grade NAT shared address space (100.64.0.0/10) is **not** covered by `is_private`, so `_is_public_ip()` would classify a CGNAT-assigned interface address as "public." |
| **Impact** | A host whose only "public-looking" address is actually CGNAT space is not reachable from the internet on that address — reusing `_is_public_ip()` verbatim for `public_ipv4` counting would have produced a real false positive (`public_ipv4_count` off by one, potentially steering a future planner toward `SEPARATE_IPS` on an address that doesn't actually work), directly contradicting the research document's own repeatedly-stated "don't output false precision" principle. |
| **Recommended correction** | `public_ipv4_summary()` (this round) uses `ipaddress.IPv4Address.is_global` instead — the stdlib's own maintained "is this actually IANA-globally-routable" property, which correctly excludes CGNAT (verified: `is_global` is `False` for `100.64.0.1`) along with everything `is_private` already excluded. The existing `_is_public_ip()` / `classify_bind_address()` pair used for per-listener `public_exposure` was **left unchanged** — fixing it was out of scope for this round (it's an existing, separately-consumed poc-1 field, and changing its semantics is a larger, separate decision), but is flagged here as a real, still-open discrepancy between the two "is this public" tests now living side by side in this same file. A future round should decide whether `public_exposure`'s CGNAT handling needs the same fix, or whether the two fields are allowed to answer genuinely different questions ("what does this listener's bind address look like" vs. "is this address safe to hand a planner as a usable public endpoint") — not resolved here. |

No other research-document claim was found to be contradicted by
actual repo/environment behavior in this round.

## Output shape — poc-1 base fields (still current in `"poc-2"`)

Everything below this point describes the fields introduced in poc-1,
all of which are unchanged in meaning, type, and presence under
`"poc-2"` — see the Schema changelog above for what poc-2 adds on top.

See the docstring above `build_inventory()` in `inventory_build.py`
for the authoritative, field-by-field shape. Top level:

```
schema_version, generated_at, privilege,
interfaces, listeners[], firewall, detected_ingress, warnings[]
```

Each entry in `listeners[]` carries the full correlation result for
one bound TCP/UDP socket: `proto`, `bind_address`, `bind_port`,
`state`, `inode`, `pid`, `pid_unresolved_reason`, `process`, `owner`
(`kind: docker|systemd|process|unknown`, plus container ID or unit
name), `docker` (full container/compose-project/published-ports block
when `owner.kind == "docker"`), `systemd` (unit state when
`owner.kind == "systemd"`), and `public_exposure` (classified against
the host's actual configured interface addresses, not just a bare
`0.0.0.0` check).

## What this deliberately does NOT do

Per the research report's own MVP/SHOULD-HAVE/DON'T-BUILD split
(§17–19) and per the explicit brief for this PoC — no capability
matching, no topology planning, no config rendering, no apply/rollback,
no full nginx AST parsing via `nginxinc/crossplane` (this PoC only
does a crude `stream {` count from `nginx -T` output, enough to
sanity-check the "exactly one `stream{}` block" invariant already
enforced by `lib/panel/nginx/variant_j.sh`, not a structural diff), no
HAProxy Data Plane API integration, no IPv6 parsing in the
`/proc/net/*` fallback path (only reached when `ss` itself is
missing). These are named, not silently skipped — see the
`detected_ingress` section and the module docstring in
`inventory_build.py` for exactly where the line was drawn.

## Verification performed

Run directly against this sandbox (a real, if unusually stripped,
Linux 24.04 container) during development, not just read for syntax:

- `bash -n` + `shellcheck` clean on `network-inspect.sh`.
- Positive path: started a real `python3 -m http.server` listener,
  confirmed the full `inode -> pid -> process -> owner` chain resolves
  correctly end-to-end, including exact `cmdline` and `public_exposure:
  "loopback"`.
- Negative/degraded paths, confirmed to fail *honestly* rather than
  silently:
  - Non-root invocation against a root-owned listener socket →
    `pid_unresolved_reason: "permission_denied"` (not "unowned").
  - A listener whose owning PID lives outside this container's PID
    namespace → `pid_unresolved_reason: "not_found_or_cross_namespace"`
    (distinct code path from the permission case).
  - No systemd as PID 1 (this sandbox's actual condition) → clean
    single warning, `systemd` lookups return `None` throughout, no
    exception.
  - No firewall tooling installed → `authoritative_frontend:
    "none-detected"`, not a crash or a false "unprotected" claim.
  - Piping output into a truncating consumer (`head`) → clean exit 0
    on both ends of the pipe, no Python traceback on stderr.
- The `stream {` -block counting regex was run against the actual
  `lib/panel/nginx/variant_j.sh` template source in this repo and
  correctly counts exactly 1 — matching the project's own documented
  invariant ("nginx does not support two top-level `stream{}` blocks
  — consolidated to one with two `server{}` blocks").

Not verified here (would require a real target VPS, out of scope for
a sandboxed PoC): live Docker Engine API correlation against a real
`remnawave`/`xray` container, live `firewalld`/`ufw` detection, live
Caddy admin-API reachability check.

## poc-2 verification

Automated tests: `poc/network-inspect/tests/test_inventory_build.py`
(stdlib `unittest`, no new dependency — run with `python3 -m unittest
discover -s poc/network-inspect/tests -v`), covering every nginx/
Caddy/Hysteria2/public-IPv4 scenario named in this round's task brief
(nginx: absent/stream-absent/stream-present/stream+ssl_preread-present;
Caddy: absent/stock/layer4/layer4+QUIC-matcher; Hysteria2:
none/salamander/gecko/obfs-absent/config-missing/config-unreadable/
malformed-YAML, plus flow-style and type-missing edge cases; public
IPv4: 0/1/2/mixed/IPv6-only/Docker-bridge/CGNAT), all via mocked
`run()`/`which()` and temp-file fixtures — **no real nginx/Caddy/
HAProxy package was installed anywhere in this process**, per the
task's explicit constraint.

Real-host verification (this same sandbox container, unchanged from
the base PoC's own environment — `nginx`, `caddy`, and `ip` are all
genuinely absent here, and `/etc/hysteria` does not exist):

- **Verified on real host**: the absent/unresolved branch of all four
  new discovery points — `detected_ingress.nginx.present == false`,
  `detected_ingress.caddy.present == false`,
  `hysteria2.obfuscation.unresolved_reason == "config_missing"`,
  `public_ipv4.unresolved_reason == "ip_not_found"` — running the real,
  unmodified `network-inspect.sh` end to end, plus the SIGPIPE/`head`-
  truncation regression check re-run against both entry points after
  this round's changes.
- **Verified only with fixtures/mocks**: every *positive* capability
  path (stream compiled in, layer4 + QUIC matcher present, any
  explicit `obfs.type` value, any nonzero public IPv4 count) — this
  sandbox has none of the underlying tools installed and none were
  installed to test this, per the task's constraint.

## Schema sufficiency review (for a future Planner)

Answering the ten questions this round's task brief asked, based only
on what `poc-2`'s Inventory now actually contains:

1. **Can TCP :443 be safely claimed?** — PARTIAL. The existing
   `listeners[]`/`pid_unresolved_reason`/`public_exposure` chain
   answers "is something already there and whose is it," honestly,
   including the permission/namespace distinction. What's still
   missing for a *safe claim* decision (not added this round, and not
   in scope per the task brief) is firewall-rule-level reachability
   confirmation beyond "which tool is authoritative" — `firewall`
   currently names the tool, not the actual rule state for port 443
   specifically.
2. **Can UDP :443 be safely claimed?** — Same PARTIAL, for the same
   reason, symmetric to TCP.
3. **Is there a second public IPv4?** — YES. `public_ipv4.count` now
   answers this directly and honestly (with `unresolved`/
   `unresolved_reason` when `ip` itself is unavailable, never a false
   `0`).
4. **Is there nginx stream?** — YES.
   `detected_ingress.nginx.stream_capabilities.compiled_with_stream`,
   with an explicit `unresolved` state (never silently `false`) when
   `nginx -V` can't be run or its output doesn't match the expected
   shape.
5. **Is there nginx stream SSL preread?** — YES, same mechanism,
   `compiled_with_stream_ssl_preread`.
6. **Is there Caddy?** — YES.
   `detected_ingress.caddy.present`.
7. **Is there caddy-l4?** — YES.
   `detected_ingress.caddy.layer4_capabilities.layer4_present`, with
   the "Caddy present ≠ caddy-l4 present" distinction enforced
   structurally (two separate fields, never conflated).
8. **Is there a QUIC matcher?** — PARTIAL, and specifically because of
   real-host coverage, not mechanism doubt: `layer4_matchers_quic_present`
   reflects whatever `caddy list-modules --versions` actually
   enumerates, and Caddy's own module system registers every module
   (including individual matchers, not just top-level apps) under its
   own dotted ID — `pkg.go.dev`'s module listing for caddy-l4 does show
   `layer4.matchers.quic` as its own individually-registered entry,
   consistent with this — so the mechanism this field relies on is
   architecturally sound. What's genuinely unverified is real-host
   confirmation against an actual compiled caddy-l4 binary, which this
   round deliberately did not install, per the task's explicit
   constraint. Marked PARTIAL for that reason alone, not for any doubt
   about the parsing logic itself (covered by the mocked-output test
   suite instead).
9. **Is it known whether Hysteria2 uses obfuscation?** — YES.
   `hysteria2.obfuscation`, with the physically-absent-vs-explicitly-
   none distinction the task specifically required, and a `confidence`
   field for the `"unknown"` (non-standard type string) case.
10. **Can an honestly-unknown state be expressed?** — YES, uniformly:
    every one of the four new discovery points uses the same
    `status: unresolved` + specific `unresolved_reason` shape the
    original PID-resolution code already established, with no new,
    inconsistent "unknown" convention introduced anywhere in this
    round's additions.

Net: 7 YES, 3 PARTIAL (two for the identical, already-scoped-out
reason — firewall rule-level reachability for TCP/UDP :443, not
anything this round's four new discovery points were meant to cover —
and one, the QUIC-matcher question, for lack of real-host confirmation
against an actual caddy-l4 binary, not for any doubt about the parsing
mechanism itself), 0 NO. No question this round could not at least
honestly answer with either a real fact or an explicit `unresolved`
state.
