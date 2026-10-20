# Handoff items named by a ULID, first scheduled Intel run green

Session of 2026-10-20.

- #80 (docs(handoff): name the handoff items by a ULID and their title
  slug), merged as d019849. The kit's `handoff_ids_migrate.py` renamed the
  38 items of docs/handoff/ to `<id>-<slug>.md` (docker-sbx ADR-0038): done
  5, decisions 7, pending 26, plus 3 rewritten path citations. The legacy
  done records keep their number as id. Two paragraphs were rewrapped by
  hand to keep the 80-column prose rule, the long paths in code spans.
  Before it, `handoff_check.py` reported 39 problems; after it, none.
  Gates: `handoff_ids_migrate.py --verify` exit 0; `make lint` and
  `make local-ci STRICT=1` green locally (Linux); code-reviewer (sonnet)
  approved with two nits left as they are (slug-only mentions in now.md
  and docs/development.md; zero-padded legacy done ids); hosted local-ci
  (macos-arm64) green.
- The first scheduled Intel run (`intel.yml`, run 39249188001, Monday
  2026-10-19 on e6a35f2) passed. It started at 12:04 UTC, not at the
  06:00 UTC the cron names: GitHub delays scheduled runs.

Lesson: `make local-ci STRICT=1` fails in a fresh clone until the plugin
submodules are initialized (`git submodule update --init`); the
check-patterns gate reads the pinned fast-syntax-highlighting source.
