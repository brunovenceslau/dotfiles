# host-identity-signal-during-gh-start

Branch `fix/parallel-flakes` keeps one commit that is not in main: 1e04ebd
"fix(identity): end gh when a signal lands while it starts"
(`lib/host_identity.py` and its units test). It touches the `security-model`
surface "The SSH signing setup" of the PR template, so its PR needs the
maintainer's agreement recorded in an issue.

Came from: the parallel-flakes work, recorded in
`done/00000000000000000000000005-parallel-runner-flakes-fixed-intel-ci-made-best-effort.md`;
the other commits of the branch were cherry-picked as #75 and #76.

Why open: the PR cannot open without that agreement.

Fix: open its PR with the surface ticked and the agreement issue linked, or
drop the branch.
