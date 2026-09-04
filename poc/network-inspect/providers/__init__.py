"""
poc/network-inspect/providers/
================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md.

Each module in this package probes ONE piece of software this project
considers as a *candidate L4 router* (something that could potentially
front traffic for someone else — nginx, Caddy; HAProxy stays inline in
inventory_build.py's detect_ingress() for now, see README.md
"Architecture" section for why). Deliberately NOT a plugin system —
there is no registry, no discovery-by-introspection, no base class.
inventory_build.py's detect_ingress() imports each provider module by
name and calls its narrow, specific public function directly. Adding a
new provider means adding a new sibling module here and one new
explicit call in detect_ingress() — not registering anything.

This __init__.py is intentionally empty beyond this docstring — no
re-exports, no package-level state.
"""
