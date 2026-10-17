# handoff-check-gate

docs/handoff/ is checked only by the sandbox payload's handoff_check.py, which
CI cannot run.

Came from: this move.

Why open: The layout is new, so a repo gate would freeze it early.

Fix: Decide whether a repo gate should check the layout, once the layout
settles.
