# Stack docs count a GitHub stack only while its API lists it

Session of 2026-10-22.

- CLAUDE.md, CONTRIBUTING.md, the PR template and docs/stacked-prs.md
  now allow a GitHub stack only while GitHub's stack API lists one open
  stack holding the whole chain, in order. `gh stack view` prints a stack
  number from a local record that `link` never fills, so it no longer
  counts as proof. The Merge button route runs the same check first.
- From gh-stack v0.2.1's source (29a36d3), docs/stacked-prs.md also
  states: the update check retries 15 minutes after a failed check; the
  argument forms of `gh stack link`; both refusal messages of sync and
  rebase, with revert among the operations they wait for; and that
  `rebase --no-trunk` skips the fetch.
- packages/gh-extensions.txt says its attestation check was a one-off on
  the linux-amd64 asset; `gh extension install` verifies none.
- Closes the pending items `stack-condition-api`, `ghstack-doc-nits`,
  `ghstack-notifier-retry`, `ghstack-attestation-scope` and
  `ghstack-web-merge-recheck`. The change is a `security-model` surface,
  so its PR carries an approval line.
