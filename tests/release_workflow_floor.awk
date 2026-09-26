# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# The PyYAML-free floor for .github/workflows/release.yml, run by
# tests/release_workflow_test.sh (release_run_check) as
#
#   LC_ALL=C awk -v nonl=0|1 -f tests/release_workflow_floor.awk release.yml
#
# with the pinned literals in the environment: RELEASE_RUN_EXPECTED (the
# release step's run: block), RELEASE_STEP_EXPECTED (the rest of that step)
# and NOTES_STEP_EXPECTED (the git-cliff step outside its run: block).
# It is the ONLY layer when PyYAML is missing, so it stands on its own. It reads
# the RAW file, never a comment-filtered copy (dropping comment lines first
# would change what a block holds), and does no shell parsing at all:
#   - every byte is printable ASCII (space to `~`), read under LC_ALL=C so a
#     multibyte character is bytes, not one character. awk splits lines on LF
#     only; YAML also breaks lines on CR, NEL, LS and PS, so a bare CR could
#     hide a whole key (`timeout-minutes: 15<CR>    env:`) inside what this
#     floor reads as one line. A tab is rejected too (YAML forbids it in
#     indentation). Measured: the real release.yml has no such byte;
#   - every line outside run: text that is not blank or a YAML comment must be
#     a single-line plain `key:` line - a bare key, optionally after `- `.
#     Rejected ON PURPOSE, because every rule below matches keys by their
#     literal spelling and reads one line at a time: a multi-line value (a
#     block scalar other than run: |, a continued plain scalar), a document
#     marker (`...`, a second `---`, or a `---` after the first key), and a key
#     that is quoted, tagged (`!!str env:`), anchored (`&u uses:`), escaped
#     (`"e\x6ev":`), explicit (`? key`), a merge key or a flow step. A value
#     must not start with an anchor, alias or tag either. ONE `---` before
#     the first key is accepted: it only opens the one document and adds no
#     key, so no rule reads less. A second one would open a second document,
#     which PyYAML's safe_load refuses and this floor could not tell apart;
#   - every `run:` key must be a plain literal block (`run: |`, nothing after
#     the `|`), so each block's text is exactly the more-indented lines under
#     it, dedented by its first line's indentation (YAML's own rule) with
#     trailing blank lines clipped (what `|` does) - no folding, no escapes. A
#     whitespace-only line with more spaces than that indentation is content
#     to YAML, not a blank line, so it is kept like any other content line;
#   - `gh` as a word outside every run: block is allowed only on a YAML comment
#     line;
#   - each step holds at most ONE `run:` key (PyYAML keeps the last of a
#     duplicate, so a gh-free second block would otherwise replace the one
#     this floor checked);
#   - exactly ONE block mentions `gh` as a word, found by content, not by the
#     step's name, so a rename cannot empty the check. A comment cannot hide a
#     second `gh` from this count; a deliberately obfuscated spelling (`g\h`,
#     `"g"h`, a `g\`-newline-`h` split) can, since bash runs each as gh. This
#     whole floor is a tripwire for accidental edits, not an adversarial
#     boundary - review and commit signing are the control there;
#   - that block equals RELEASE_RUN_EXPECTED byte for byte, and the rest of
#     its step equals RELEASE_STEP_EXPECTED. A file with no final newline
#     leaves YAML's `|` nothing to keep at EOF, so a block ending there has no
#     trailing newline (Python sees exactly that); awk cannot tell a missing
#     final newline apart, so the caller measures it and passes it as `nonl`;
#   - the context around that step: the workflow's top-level keys and the
#     job's keys are exactly the ones the Python layer pins (TOP_KEYS,
#     JOB_KEYS), and there is one job; an `env:` key sits
#     only at a step's key column (never workflow- or job-level, where it
#     reaches the release step untouched); no `GH_*` key outside the release
#     step's pinned env; no `defaults:` (it swaps the shell); exactly one
#     `uses:` and it is actions/checkout at a 40-hex SHA (any other action can
#     be handed the token without spelling gh); on every line that is not a
#     YAML comment - run: text included - no GITHUB_ENV and no GITHUB_PATH;
#     git-cliff is called exactly twice, both times by its absolute path
#     "$RUNNER_TEMP/bin/git-cliff", never by a bare name that a PATH entry
#     could resolve, and both from one step whose keys and env equal
#     NOTES_STEP_EXPECTED (env exactly TAG: a GIT_CLIFF__* variable
#     overrides cliff.toml, postprocessors included).
# POSIX awk only (match/RLENGTH, index, split, sub, ENVIRON, dynamic regexes;
# no `{n}` intervals, which older mawk lacks, and no GNU regex escapes, which
# bin/check-patterns arm 8 rejects here): the macOS legs run BSD awk. On
# failure it prints every problem it found, one per line, and exits 1 - all of
# them, not the first, so a fixture greps its own check's message even when a
# broader check also fires. The run: difference message matches the Python
# layer's, so a fixture can grep the same text from both.

function lead(s) { match(s, /^ */); return RLENGTH }
function isgh(s) { return s ~ /(^|[^A-Za-z0-9_])gh([^A-Za-z0-9_]|$)/ }
function err(m) { bad = bad m "\n" }
# Every line that is not a YAML comment, run: text included, raw: a shell
# comment inside a block is still text this rule reads. $GITHUB_ENV sets env
# for every later step; a $GITHUB_PATH entry comes before /usr/bin in every
# later step, so a gh planted there would run in the release step.
function scan(s, n) {
  if (index(s, "GITHUB_ENV"))
    err("line " n " mentions GITHUB_ENV - env written there reaches the release step")
  if (index(s, "GITHUB_PATH"))
    err("line " n " mentions GITHUB_PATH - a PATH entry there reaches the release step")
  # A GIT_CLIFF__* variable overrides cliff.toml; the notes step's pinned env
  # does not stop an `export` inside its own run: text.
  if (index(s, "GIT_CLIFF__"))
    err("line " n " mentions GIT_CLIFF__ - it overrides cliff.toml")
}
# First difference between two newline-joined texts, in the Python layer's
# message shape.
function firstdiff(got, want, what,   g, w, ng, nw, m, k) {
  ng = split(got, g, "\n"); nw = split(want, w, "\n")
  m = (ng < nw) ? ng : nw
  for (k = 1; k <= m; k++) if (g[k] != w[k]) break
  err(what " at line " k ": got: " (k <= ng ? g[k] : "<end>") " | expected: " (k <= nw ? w[k] : "<end>"))
}
# The step that opens at line st, outside its run: text, blank and comment
# lines dropped, dedented to its `-`; only the name's value is free. The step
# runs to the first later line outside run: text that is neither blank nor a
# comment and sits no deeper than its dash. mark records the lines in inhead.
function stephead(st, mark,   dash, n, i, h, head) {
  dash = lead(line_[st])
  for (n = st + 1; n <= NR; n++) {
    if (inrun[n] || line_[n] ~ /^ *$/ || line_[n] ~ /^ *#/) continue
    if (lead(line_[n]) <= dash) break
  }
  head = ""
  for (i = st; i < n; i++) {
    if (inrun[i] || line_[i] ~ /^ *$/ || line_[i] ~ /^ *#/) continue
    if (mark) inhead[i] = 1
    h = substr(line_[i], dash + 1)
    if (i == st && h ~ /^- name: [^ ]/) h = "- name: <any>"
    head = head h "\n"
  }
  return head
}
function close_block() {
  if (!inblk) return
  inblk = 0
  if (hasgh) {
    ngh++; ghbody = body; ghseen = ghseen " [" firstgh "]"
    ghstep = blkstep
  }
}
BEGIN {
  q = "\047"
  # A block or flow key, bare or quoted: kept for GH_* keys inside a flow
  # mapping, which the shape rule does not look into.
  kpost = "[\"" q "]? *:"
  ghkre = "(^|[^A-Za-z0-9_])[\"" q "]?GH_[A-Za-z0-9_]*" kpost
  # Mirrors JOB_KEYS in tests/release_workflow_check.py.
  jobkeys = " name permissions runs-on steps timeout-minutes "
  # Mirrors TOP_KEYS: a workflow-level `container:`, `if:`, `env:` or
  # `defaults:` reaches every job, the release job included.
  topkeys = " jobs name on permissions "
  stepkey = -1; jobcol = -1; jobkeycol = -1
}
{
  if ($0 ~ /[^ -~]/)
    err("line " NR " holds a byte outside printable ASCII (a tab, a CR or a Unicode line break YAML would split on)")
  line_[NR] = $0
  if (inblk) {
    if ($0 ~ /^ *$/) {
      inrun[NR] = 1
      # More spaces than the block indentation: YAML content (a line of
      # spaces), kept even at the end of the block. Otherwise a blank line,
      # held back so trailing ones are clipped.
      if (cont >= 0 && length($0) > cont) { body = body pend substr($0, cont + 1) "\n"; pend = "" }
      else pend = pend "\n"
      next
    }
    ind = lead($0)
    if (ind > key) {
      inrun[NR] = 1
      scan($0, NR)
      if (cont < 0) cont = ind
      if (ind < cont) { err("line " NR " is under-indented inside a run: block"); next }
      line = substr($0, cont + 1)
      body = body pend line "\n"; pend = ""
      if (!hasgh && isgh(line)) { hasgh = 1; firstgh = line }
      # By absolute path only: a bare name resolves through a PATH that an
      # earlier step could have extended.
      cmd = substr($0, ind + 1)
      if (cmd ~ /^git-cliff( |$)/) err("line " NR " calls git-cliff by a bare name - call \"$RUNNER_TEMP/bin/git-cliff\"")
      if (index(cmd, "\"$RUNNER_TEMP/bin/git-cliff\" ") == 1) {
        ncliff++
        if (cliffstep == "") cliffstep = blkstep
        else if (cliffstep != blkstep) err("line " NR " calls git-cliff from a second step")
      }
      next
    }
    close_block()
  }
  if ($0 ~ /^ *$/ || $0 ~ /^ *#/) next
  if (!seenkey && $0 == "---" && !ndoc++) next
  seenkey = 1
  scan($0, NR)
  # The shape rule. The key is what match() leaves before the colon.
  plain = match($0, /^ *(- +)?[A-Za-z_][A-Za-z0-9_-]* *:( |$)/)
  if (!plain) err("line " NR " is not a single-line plain key: line (a multi-line value, a document marker, or a quoted/tagged/anchored/explicit/flow key) - " substr($0, lead($0) + 1))
  else {
    k_ = substr($0, 1, RLENGTH); v_ = substr($0, RLENGTH + 1)
    sub(/^ *(- +)?/, "", k_); sub(/ *: ?$/, "", k_)
    if (v_ ~ /^ *[&*!]/) err("line " NR " has a value starting with an anchor, alias or tag - " substr($0, lead($0) + 1))
  }
  ind = lead($0)
  if (ind == 0 && plain) {
    if (index(topkeys, " " k_ " ") == 0)
      err("line " NR " is top-level key " k_ " - the workflow\047s keys must be exactly" topkeys)
    else if (tseen[k_]++) err("line " NR " repeats top-level key " k_)
  }
  # The job region: the first line after `jobs:` names the one job, the first
  # line after that sets the column of the job's own keys. No `next` here: the
  # `jobs:` line itself still goes through every rule below.
  if (ind == 0) injobs = (plain && k_ == "jobs")
  else if (injobs) {
    if (jobcol < 0) jobcol = ind
    else if (jobkeycol < 0 && ind > jobcol) jobkeycol = ind
    if (ind == jobcol && ++njobs > 1) err("line " NR " is a second job - release.yml holds exactly one")
    if (ind == jobkeycol) {
      if ($0 ~ /^ *- /) err("line " NR " is a sequence entry at the job\047s key column")
      else if (plain) {
        if (index(jobkeys, " " k_ " ") == 0)
          err("line " NR " is job key " k_ " - the job\047s keys must be exactly" jobkeys)
        else if (jseen[k_]++) err("line " NR " repeats job key " k_)
      }
    }
  }
  # A `- ` sequence entry opens a new mapping whose keys sit at the column
  # after the dash; remember which entry owns each key column, so a second
  # run: key in the SAME step is told apart from one in the next step. The
  # first entry after `steps:` fixes the step key column, the only column
  # where an env: key may sit.
  if (match($0, /^ *- +/)) {
    item[RLENGTH] = NR
    if (insteps && stepkey < 0) stepkey = RLENGTH
  }
  if (plain && k_ == "steps") insteps = 1
  if (plain && k_ == "env") {
    k = ind; if (match($0, /^ *- +/)) k = RLENGTH
    if (k != stepkey) err("line " NR " is an env: key outside a step - a workflow or job env reaches the release step")
  }
  # Judged in END, once the release step (and so its pinned env) is known.
  if ($0 ~ ghkre) ghkey[NR] = 1
  if (plain && k_ == "defaults") err("line " NR " sets defaults: - it can swap the shell that runs the release block")
  if (plain && k_ == "uses") {
    nuses++
    sha = $0
    if (sub(/^ *(- +)?uses: actions\/checkout@/, "", sha)) sub(/ +#.*$/, "", sha)
    if (length(sha) != 40 || sha !~ /^[0-9a-f]+$/)
      err("line " NR " is not actions/checkout pinned to a 40-hex SHA: " substr($0, lead($0) + 1))
  }
  if (plain && k_ == "run") {
    if ($0 !~ /^ *(- +)?run: \|$/) {
      err("line " NR " is a run: key that is not a plain literal block (run: |)")
      next
    }
    key = index($0, "run:") - 1
    if (nrun[key SUBSEP item[key]]++) err("line " NR " is a second run: key in the same step")
    inblk = 1; cont = -1; body = ""; pend = ""; hasgh = 0; firstgh = ""
    blkstep = item[key] + 0
    next
  }
  if (isgh($0)) err("line " NR " mentions gh outside any run: block")
}
END {
  # Clip keeps the last content line break only if the file has one.
  if (inblk && nonl && pend == "") body = substr(body, 1, length(body) - 1)
  close_block()
  n_ = split(topkeys, jk, " ")
  for (i = 1; i <= n_; i++) if (!(jk[i] in tseen)) err("the workflow lacks its top-level " jk[i] ": key")
  n_ = split(jobkeys, jk, " ")
  for (i = 1; i <= n_; i++) if (!(jk[i] in jseen)) err("the job lacks its " jk[i] ": key")
  if (nuses != 1) err("expected exactly one uses: key, found " (nuses + 0) " - only the pinned actions/checkout")
  if (ncliff != 2) err("expected exactly 2 git-cliff calls by absolute path (\"$RUNNER_TEMP/bin/git-cliff\" ...), found " (ncliff + 0))
  if (ngh != 1) err("expected exactly one run: block mentioning gh, found " (ngh + 0) ":" ghseen)
  else {
    if (ghbody != ENVIRON["RELEASE_RUN_EXPECTED"])
      firstdiff(ghbody, ENVIRON["RELEASE_RUN_EXPECTED"], "the release step\047s run: differs from the pinned literal")
    if (!ghstep) err("the release step is not a block sequence entry (- ...)")
    else {
      head = stephead(ghstep, 1)
      if (head != ENVIRON["RELEASE_STEP_EXPECTED"])
        firstdiff(head, ENVIRON["RELEASE_STEP_EXPECTED"], "the release step differs from the pinned step")
    }
  }
  if (cliffstep != "") {
    if (!cliffstep) err("the git-cliff step is not a block sequence entry (- ...)")
    else {
      head = stephead(cliffstep, 0)
      if (head != ENVIRON["NOTES_STEP_EXPECTED"])
        firstdiff(head, ENVIRON["NOTES_STEP_EXPECTED"], "the notes step differs from the pinned step")
    }
  }
  for (n = 1; n <= NR; n++)
    if ((n in ghkey) && !(n in inhead))
      err("line " n " sets a GH_* key outside the release step\047s env - gh reads it: " substr(line_[n], lead(line_[n]) + 1))
  if (bad != "") { printf "%s", bad; exit 1 }
}
