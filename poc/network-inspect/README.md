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

```bash
./poc/network-inspect/network-inspect.sh --capabilities          # Capability Registry instead of Inventory
./poc/network-inspect/network-inspect.sh --pretty --capabilities # same, indented
```

## Architecture

### Current structure

```
poc/network-inspect/
├── network-inspect.sh        CLI wrapper — locate python3, decide
│                              whether interactive progress text can
│                              be shown, exec Python, pass stdout
│                              through byte-for-byte (Contract 9:
│                              "Bash decides where/when, Python
│                              decides what")
├── inventory_build.py         orchestration + the socket/PID/process/
│                              ownership/docker/systemd/firewall
│                              CORRELATION PIPELINE, plus
│                              detect_ingress() (ties nginx/caddy/
│                              haproxy presence together using
│                              correlation-pipeline data) and
│                              build_inventory()/main() (final
│                              assembly + CLI arg handling)
├── run_command.py              shared subprocess-safety primitive
│                              (RunResult/run()/which()) — used by
│                              inventory_build.py's own pipeline AND
│                              every module below
├── net_facts.py                 public IPv4 counting — a host/network
│                              fact, not tied to any specific proxy
│                              software
├── hysteria2_config.py           Hysteria2 obfs.type discovery — a
│                              config-file fact about the protocol
│                              BEING ROUTED, not about a candidate
│                              router
├── providers/
│   ├── __init__.py             (empty beyond a docstring — no
│   │                            plugin registry, see below)
│   ├── nginx.py                 nginx capability probing — candidate
│   │                            L4 router #1
│   └── caddy.py                  Caddy/caddy-l4 capability probing —
│                              candidate L4 router #2
│                              (HAProxy stays inline in
│                              inventory_build.py's detect_ingress() —
│                              see "Why these boundaries" below for
│                              why it did NOT get its own file this
│                              round)
├── capabilities.py            Capability Registry — a SEPARATE layer
│                              that interprets Inventory facts into
│                              named capabilities (FACT vs CAPABILITY,
│                              see capabilities.py's own module
│                              docstring). Never chooses a topology.
└── tests/
    ├── _loader.py               shared test bootstrap (sys.path
    │                            setup only — not a framework)
    ├── test_run_command.py
    ├── test_net_facts.py
    ├── test_hysteria2_config.py
    ├── test_providers_nginx.py
    ├── test_providers_caddy.py
    ├── test_capabilities.py
    └── test_inventory_build.py  correlation pipeline + orchestration
                                 + regression suite
```

### Data flow

```
CLI (network-inspect.sh)
        ↓
main() (inventory_build.py) — arg parsing, root-check warning
        ↓
build_inventory() (inventory_build.py) — orchestration
        │
        ├─→ collect_interfaces() / collect_listeners() /
        │   build_inode_to_pid_map() / process_info() /
        │   classify_ownership() / docker_container_info() /
        │   systemd_unit_info() / detect_firewall()
        │       — the CORRELATION PIPELINE: port → socket → PID →
        │         process → docker/systemd ownership. Stays as one
        │         cohesive block in inventory_build.py (see "Why
        │         these boundaries" below for why this did NOT get
        │         split further).
        │
        ├─→ detect_ingress() (inventory_build.py)
        │       ├─→ providers.nginx.stream_capabilities()
        │       ├─→ providers.caddy.layer4_capabilities()
        │       └─→ (haproxy handled inline)
        │
        ├─→ hysteria2_config.obfuscation()
        │
        └─→ net_facts.public_ipv4_summary()
        ↓
   Inventory (JSON, schema "poc-2", UNCHANGED by this round)
        ↓
   [default: printed to stdout]
   [--capabilities: passed to...]
        ↓
capabilities.build_capability_registry(inventory)
        ↓
   Capability Registry (JSON, schema "capabilities-1", NEW artifact)
        ↓
   printed to stdout
```

Every arrow points strictly downward — no module below
`inventory_build.py` ever imports it back, and `capabilities.py` never
calls anything that makes a subprocess call or touches the filesystem
(pure function of the Inventory dict it's handed). This is the
dependency direction the task brief's own §27 asks for, and it now
holds structurally, not just by convention: `providers/*.py`,
`net_facts.py`, and `hysteria2_config.py` don't import
`inventory_build`, don't import `capabilities`, and don't import each
other.

### Why these boundaries

**Correlation pipeline stayed in `inventory_build.py`, not split
further.** Socket discovery, PID resolution, process/ownership
classification, Docker/systemd lookups, and firewall detection are
tightly data-coupled — each step's output is the next step's input
(inode → PID → process → owner), and every step shares the same
`listeners`/`iface_block` working set. This is high cohesion by any
definition: splitting it into five files would mean either passing
five small objects between them for no benefit, or introducing an
intermediate "correlation context" object purely to satisfy a file
boundary — the "20 files × 70 lines" anti-pattern this round's task
brief explicitly warns against (§26). This part of the file has also
been essentially the same size since poc-1 (poc-1's version of this
pipeline was ~700 of its ~855 lines; poc-2's equivalent portion is
~700 of the current 987) — it is not where the growth this round's
task brief flagged (1441 lines) actually came from.

**Provider capability probing (nginx/caddy) DID get split out, into
`providers/`.** This is where the actual growth was: poc-1's
`detect_ingress()` was ~40 lines total for all three providers
combined; by poc-2 it had grown to ~300 lines, almost entirely nginx
and Caddy compiled-module parsing. This is also the part of the
codebase with a clear, stated trajectory to keep growing (the "Shared
UDP & TCP/UDP Topology Planner" research document names several more
providers and facts a future round might add: HAProxy `-vv`
feature-flag parsing, TeleMT config inspection, more Caddy matcher
granularity). Splitting each provider into its own file means adding
provider #4 is "add `providers/haproxy.py`, add one call in
`detect_ingress()`" — not "find the right spot in an 1000+-line file
and hope not to disturb the correlation pipeline above it."

**`net_facts.py` and `hysteria2_config.py` got their own files, but
are NOT under `providers/`.** Both are independent of the correlation
pipeline (no data dependency on `listeners`/PID resolution) and
independent of each other, so folding either into `inventory_build.py`
would just be re-growing the same file for no cohesion benefit. But
neither is a "provider" in the sense `providers/` means here
(candidate L4 router software) — `net_facts.py` is a host/network-level
fact with no software identity at all, and `hysteria2_config.py`
describes the protocol BEING ROUTED, not a router being evaluated.
This distinction matters concretely for `capabilities.py`: nginx/caddy
get their own Capability Registry provider entries; Hysteria2's
`obfs.type` instead feeds the Registry's future PLANNER consumer as an
input *constraint*, never as a provider-capability row of its own (see
`test_capabilities.py::test_hysteria2_obfs_state_ne_provider_capability`).
Grouping it with the L4-router providers would have blurred that
distinction in the file layout, not just in prose.

**HAProxy stayed inline in `detect_ingress()`, did NOT get its own
`providers/haproxy.py` this round.** Its entire detection is ~10 lines
(binary/version/running/dataplaneapi_detected) with zero parsing
complexity — extracting a 10-line block into its own file would be
exactly the fragmentation the task brief warns against (§26). When
HAProxy capability probing grows (e.g. `haproxy -vv` feature-flag
parsing gets added in a future round, matching what nginx/caddy
already have), it should move to `providers/haproxy.py` at that point,
mirroring nginx.py/caddy.py's shape — not before there's real
complexity to justify the file.

**Capability Registry is a separate module (`capabilities.py`), not a
function added to `inventory_build.py`.** This is the one boundary the
task brief itself insists on architecturally, not just as a style
preference: Inventory answers "what did I observe," Capability
Registry answers "what does that mean" — different questions, +
different update cadence (Inventory changes when a new discovery
source is added; the Registry's static knowledge table changes when
research about a provider's general behavior changes, which has
nothing to do with what any given host looks like). Keeping them in
one file would make it structurally easy to accidentally leak
interpretation into discovery (e.g. writing `"stream": True` as if it
were an observed fact when it's actually a capability judgment) —
exactly the FACT vs CAPABILITY conflation the task brief's §4
identifies as the most important invariant to protect.

**No generic adapter framework was built**, per the task brief's
explicit §8 instruction. `providers/__init__.py` has no base class, no
registry, no plugin-discovery mechanism — `detect_ingress()` imports
`providers.nginx` and `providers.caddy` by name and calls their one
public function each, directly. Adding provider #4 means writing a new
sibling module and one new explicit call — never "registering"
anything with anything.

### Public/internal boundaries

| Module | Public API | Internal helpers | Input | Output |
|---|---|---|---|---|
| `run_command.py` | `run(cmd, timeout=...)`, `which(binname)`, `RunResult` | — | argv list | `RunResult` (ok/returncode/stdout/stderr/reason) |
| `providers/nginx.py` | `stream_capabilities(nginx_bin)` | `_parse_configure_output(text)` (pure) | nginx binary path (unused directly — kept for signature symmetry, see docstring) | dict, `status ∈ {available, unresolved}` |
| `providers/caddy.py` | `layer4_capabilities(caddy_bin)` | `_parse_module_list_output(text)` (pure) | caddy binary path | dict, `status ∈ {available, unresolved}` |
| `hysteria2_config.py` | `obfuscation(config_path)` | `_parse_obfs_block(text)` (pure) | config file path | dict, `status ∈ {resolved, unresolved}` |
| `net_facts.py` | `public_ipv4_summary(interfaces_block)` | `_is_globally_routable_ipv4(addr)` (pure) | `collect_interfaces()`'s output | dict, `status ∈ {available, unresolved}` |
| `capabilities.py` | `build_capability_registry(inventory)` | `_nginx_entry`, `_caddy_entry`, `_haproxy_entry`, `_envoy_entry` (each pure) | the full Inventory dict | Capability Registry dict, per-dimension `status ∈ {available, unsupported, absent, unresolved}` |
| `inventory_build.py` | `build_inventory()`, `main()`, plus the correlation-pipeline functions (`collect_listeners`, `process_info`, `classify_ownership`, `docker_container_info`, `systemd_unit_info`, `detect_firewall`, `detect_ingress`) | many small `_`-prefixed helpers | — | Inventory dict (schema `poc-2`) / exit code |

No adapter or parser module imports `json`, writes to stdout, or knows
anything about `sys.argv` — only `inventory_build.py`'s `main()` does
CLI-facing I/O, preserving Contract 1 (stdout = pure machine-readable
data) structurally, not just by convention.

### Where to add things (the actual test of this section)

- **New discovery source** (a new provider, or a new host/network
  fact): add a new sibling module — `providers/<name>.py` if it's
  candidate L4-router software, a new top-level `<name>.py` if it's a
  host-level fact or a routed-protocol's own config (matching
  `net_facts.py`/`hysteria2_config.py`'s precedent) — then one new call
  in `inventory_build.py`'s `detect_ingress()` or `build_inventory()`.
  Never touch the correlation pipeline for this.
- **New/changed capability interpretation** (e.g. refining
  `udp.quic_sni_routing`'s logic, or adding a new capability
  dimension): edit `capabilities.py` only — its
  `_STATIC_CAPABILITY_FACTS` table and the relevant `_<provider>_entry()`
  override function. Never touch `inventory_build.py` or any
  `providers/*.py` file for this — they only ever produce raw facts.
- **New planner rule**: **not in `network-inspect` at all.** This PoC
  stops at the Capability Registry, per this round's task brief §20 —
  see "Next step" at the end of this README for the interface a future
  Planner module will need from here.

## Schema changelog

### capabilities-1 (new artifact, this round)

The Inventory schema itself is **unchanged** — still `"poc-2"`, zero
JSON impact from this round's architecture split or from adding the
Capability Registry (see "Schema impact" further down, and
`test_build_inventory_produces_valid_schema_poc2` /
`test_public_ipv4_still_diverges_from_legacy_is_public_ip`, which
assert this directly). What's new is a completely separate artifact,
produced by `--capabilities`: the Capability Registry, `schema_version
"capabilities-1"`. See `capabilities.py`'s own module docstring for
the full model (provider/capabilities/status/confidence/evidence/
module/module_version) and the Architecture section above for why
this is a distinct layer rather than a new Inventory field.

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

Automated tests, as of the previous round (nginx/Caddy/Hysteria2/
public-IPv4 discovery): 38 tests, covering every scenario named in
that round's task brief (nginx: absent/stream-absent/stream-present/
stream+ssl_preread-present; Caddy: absent/stock/layer4/layer4+QUIC-
matcher; Hysteria2: none/salamander/gecko/obfs-absent/config-missing/
config-unreadable/malformed-YAML, plus flow-style and type-missing
edge cases; public IPv4: 0/1/2/mixed/IPv6-only/Docker-bridge/CGNAT),
all via mocked `run()`/`which()` and temp-file fixtures — **no real
nginx/Caddy/HAProxy package was installed anywhere in this process**,
per that round's explicit constraint. See "Architecture-split
verification" below for the current, post-split test count and
layout.

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

## Architecture-split verification (this round)

**80 tests total** (up from 38 — 42 new: `test_run_command.py` (7),
`test_net_facts.py` (13, unchanged in content from the previous
round's `TestPublicIpv4Summary`, just relocated + a new
`TestIsGloballyRoutableIpv4` group testing the pure helper directly),
`test_hysteria2_config.py` (18, including 10 new pure-parser tests
against `_parse_obfs_block()` directly — no tempfile — alongside the
6 relocated I/O-wrapper tests), `test_providers_nginx.py` (9),
`test_providers_caddy.py` (9), `test_capabilities.py` (16, new — see
"Semantic invariants" below), all passing.

**Zero-behavior-change verification**: before touching any code, the
pre-refactor `inventory_build.py` (1441 lines) was run once and its
full JSON output saved. After every extraction stage, the same command
was re-run and the two JSON documents compared field-by-field
(`generated_at` normalized, since that legitimately differs run to
run) — confirmed byte-identical after every stage, including after
fixing one real bug the extraction surfaced (see "Refactoring
performed"). This is a stronger guarantee than "tests still pass": it
confirms the split changed zero observable behavior, not just that the
specific cases this suite happens to cover still work.

**Semantic invariants** (task brief §18) — each directly asserted by a
named test in `test_capabilities.py::TestSemanticInvariants`, against
real registry output, not just inspected by hand:
  - `test_nginx_udp_proxy_ne_quic_sni_routing`
  - `test_so_reuseport_ne_multi_backend_same_port`
  - `test_quic_sni_termination_ne_passthrough`
  - `test_caddy_installed_ne_caddy_l4_available`
  - `test_unresolved_ne_unsupported`
  - `test_hysteria2_obfs_state_ne_provider_capability`
  - `test_quic_sni_routing_ne_migration_safe`

All seven pass. `TestNeverChoosesTopology` additionally does a
structural check (§19) — the Registry's serialized JSON output is
searched for topology/recommendation/installation language
("recommend", "should use", "install ", "therefore use",
"selected_topology", "topology") across every present/absent/
available combination exercised by the suite, and none is found.

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

## Next step: Desired State schema + Planner input contract

Not implemented here, per this round's task brief §20/§29 — this
section only names the interface shape a future Planner will need,
matching the "Shared UDP & TCP/UDP Topology Planner" research
document's own §13/§18 Desired State and Planner design.

A future Planner module (living OUTSIDE `poc/network-inspect/`
entirely — see "Where to add things" above) will need:

1. **A Desired State parser/schema** — not part of this PoC's output
   at all; a separate input the operator (or a future `sm` GUI layer)
   provides, describing what they want (`services: [...]`,
   `network.tcp.shared_443`, etc., per the research document's own
   §13 sketch). `network-inspect` produces none of this.
2. **This round's Capability Registry as one Planner input**, read via
   `capabilities.build_capability_registry(inventory)` — a pure
   function, already safe to call from a Planner module without any
   subprocess/file-I/O surprises, since all the I/O already happened
   when `inventory` was built.
3. **The Inventory itself as a second Planner input** (for facts the
   Registry doesn't carry — e.g. `public_ipv4.count` for the `SEPARATE_
   IPS` topology preference, or `listeners[]` for the "unknown owner on
   :443 → STOP" safety constraint) — both artifacts from one
   `build_inventory()` call, so a Planner never needs to reconcile two
   separately-timed snapshots of the host.
4. **A scoring/candidate-generation function** that takes (Desired
   State, Capability Registry, Inventory) and produces ranked
   `(topology, provider)` candidates with named rejection reasons —
   this is the Planner's own core logic, no part of which exists in
   `network-inspect` today, and none of which should be added here.

This PoC's job stops at step 2/3's inputs being available and honest.
