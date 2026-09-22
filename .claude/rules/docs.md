---
description: Documentation standard for docs/ and README.md
paths:
  - "docs/**"
  - "README.md"
---

<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Documentation rules for the dotfiles framework

These apply to `README.md` and every page under `docs/` in the `dotfiles`
repository.

## Documentation standards

Before writing or editing a page, name its reader and pick its shape. A page
that tries to serve two readers, or that mixes a walkthrough with a lookup
table, ends up serving neither well.

- **Pick one reader per page before writing.** A newcomer installing the
  framework for the first time needs different words than someone who already
  runs it and is chasing a variable name. Decide which one this page is for,
  and write only to that person.
- **Give each page a single job.** A page either teaches by walking someone
  through a task step by step, gives a recipe for one specific problem, lists
  facts for lookup, or explains why something works the way it does. Pick one
  of those and stay in it; a page that drifts between teaching and reference
  makes both halves harder to scan.
- **Write only what the source backs up.** Read the relevant code before
  describing its behaviour, and cite the file the claim comes from when it
  helps a reader check it themselves. If a sentence cannot be traced back to
  something that runs, cut it rather than leave it as a guess dressed up as
  fact.
- **Say it plainly.** Active voice, short sentences, no adjectives selling the
  project to the reader. A line like "the installer is fast and reliable"
  belongs nowhere in this repository; a line like "the installer exits 1 on a
  failed link and leaves the target untouched" does.
- **No em dash.** Break the sentence into two, or use a comma, a colon, a
  parenthesis, or a plain "-" instead.

This standard governs documentation only. Code comments follow the opposite
economy: a comment explains the CONSTRAINT, never the obvious.

## Write headings a reader would search for

Each page and each major section should stand on its own when it is retrieved
alone, so name things explicitly instead of writing "this", "it", or "the
above". A heading should answer a question someone would actually ask.

## Keep the pages in sync with behaviour

When a change alters something observable (a command, a printed message, a link
rule, a plugin pin, an environment variable), update the matching page in the
same commit.

[docs/README.md](../../docs/README.md) is the map: it lists each page with its
reader and what it covers. Add a new page there.
