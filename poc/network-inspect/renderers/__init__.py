"""
poc/network-inspect/renderers/
=================================

EXPERIMENTAL / RESEARCH POC — see poc/network-inspect/README.md.

Each module in this package translates an already-valid Plan IR
(plan_ir.py, verified by plan_validator.py) into provider-specific
configuration artifacts for ONE mechanism — nginx.py for `mechanism:
"nginx"` groups, and so on as future providers are added. A renderer
never decides topology, placement, or mechanism selection — that is
already-finished Planner work by the time a renderer sees the plan.
See nginx.py's own module docstring for the render() contract.
"""
