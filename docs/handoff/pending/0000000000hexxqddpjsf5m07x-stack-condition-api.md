# stack-condition-api

The current house agent guidance (as of 2026-10-13) says a stack counts only
while GitHub's stack API lists it, because `gh stack view` reads a local
cache. CLAUDE.md and docs/stacked-prs.md say "GitHub reports a stack number",
as worded in #70 (chore(packages): pin gh-stack v0.2.1, and say where GitHub
reports a stack).

Came from: a change in the house agent guidance, verified against that
guidance's source on 2026-10-13.

Why open: the two statements should agree on what proves a stack exists.

Fix: align both documents with the API-based condition. This is a
`security-model` surface, so its PR carries an approval line.
