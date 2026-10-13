# Identity, stack docs, linkcheck and gates, merged as one stack

Four PRs merged together as one GitHub stack on 2026-10-12, as e789fa8, with
the first at the bottom: #64 (fix(identity): hold gh's reap, flag write scope,
pass git's helper list); #65 (docs: allow a GitHub stack merged as a stack,
keep main the default); #66 (fix(linkcheck): follow GitHub's slugs and fail
closed on backticks); and #67 (fix(gates): read STRICT from the env, symlink
TMPDIR, pin surface ids).

Gates: seven ship rounds (the ship gate is the pre-merge review by reviewer
and security personas, and a ship round is one run of it; rounds 4 to 7 were
targeted re-audits, on #65), local-ci on the stack top, hosted CI green.
Before the merge, #65's branch-name fill-ins were fixed: its step 3 and 4
blocks take a PR number, read the branch names with `gh pr view` and refuse
names outside `A-Za-z0-9._/-`.
