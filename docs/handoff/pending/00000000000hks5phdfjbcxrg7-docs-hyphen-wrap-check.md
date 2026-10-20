# docs-hyphen-wrap-check

A Markdown line that ends in a hyphen, as hard-wrapping at a hyphenated word
produces, renders with a stray space ("linux- amd64") and can split a code
span.

Came from: the review of the move of the handoff notes into docs/handoff/,
2026-10-13, which found four such lines.

Why open: only a reviewer caught it; no gate does.

Fix: add a static check in the lint or linkcheck path that refuses a Markdown
line ending in a hyphen anywhere under docs/, as a make target wired into make
local-ci first.
