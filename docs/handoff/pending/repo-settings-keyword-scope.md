# repo-settings-keyword-scope

tests/repo_settings_test.sh flags words about GitHub's repository settings
(the `kw` assignment) in any tracked Markdown file (the `docs` list) that has
no anchor row. The check sits under the heading "A5. no unanchored settings
talk"; its failure message calls it A3.

Came from: the move of the handoff notes into docs/handoff/, 2026-10-13. A
Done record that named how a PR was merged failed make local-ci, so ordinary
handoff prose trips the gate. This item avoids the words on purpose.

Why open: the check is file-level and deliberately broad (its comment says a
false hit costs one anchor), so every new note that uses one of these words
needs an anchor or a rewording.

Fix: scope the check to the files that state settings (CONTRIBUTING.md,
README.md and the docs that already have anchors), or add an allow-marker for
files that only mention the words in passing, such as docs/handoff/. The test
is not changed by this item.
