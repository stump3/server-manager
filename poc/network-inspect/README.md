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

## Output shape (schema_version `"poc-1"`)

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
