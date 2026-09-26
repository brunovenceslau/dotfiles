#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Integration test for `install.sh upgrade` / do_upgrade - the whole
# fetch -> ff-only merge -> submodules -> relink chain, exercised end to end
# against a scratch A (origin) / B (install) repo pair. Covers the up-to-date and
# merge paths, the refusals (diverged history, dirty tree, a held lock, a failed
# fetch, a malformed object), the non-interactive credential handling, the
# scrubbing of ambient git config (url.insteadOf, GIT_CONFIG_PARAMETERS), the
# post-merge relink running the NEW engine, and that EVERY refusal leaves HEAD
# untouched. There is no signature verification on this path (see
# docs/architecture.md#the-upgrade-path), so no signing key is involved.
# Hermetic: a mktemp origin, clone, and scratch HOME; the real $HOME is never
# touched. Not part of the shellcheck surface.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.
set -euo pipefail

# A privilege skip: install.sh refuses root for every subcommand, so nothing
# below can run as root (tests/root_refusal_test.sh covers that refusal).
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: upgrade_test (running as root: install.sh refuses root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v git >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "git unavailable and STRICT=1 - upgrade integration not run"; fi
  echo "SKIP: git unavailable - upgrade integration not run"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/upgrade_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME"
mkdir -p "$XDG_STATE_HOME/dotfiles"

# --- Build origin A: a minimal but real dotfiles repo ------------------------
A="$work/A"
mkdir -p "$A"
cp "$repo_root/install.sh" "$A/install.sh"
cp -r "$repo_root/lib" "$A/lib"
mkdir -p "$A/zsh"; cp "$repo_root/zsh/zshenv" "$repo_root/zsh/zshrc" "$A/zsh/"
# The fixture MUST carry a config/ tree. lib/link.sh's walker returns early
# on `[ -d "$root/config" ] || return 0`, so without one NO convention link is ever
# placed here and a relink defect is not observable even in principle - the state
# in which this suite passed identically with and without the post-merge-engine fix.
mkdir -p "$A/config/demo"; printf 'demo\n' > "$A/config/demo/conf"
# ...and all FOUR walkers, not just the config one. _link_home_tree and _link_bin_tree
# open with the same `[ -d ... ] || return 0` early return, so a fixture without home/
# and bin/ is exactly as blind to a regression in them as it was to the
# pre-merge-engine defect. The suffix
# rule gets a pair too - a plain dir that must link and an @-suffixed dir that must
# NOT - so both halves are asserted through the real installer.
mkdir -p "$A/home"; printf 'hello\n' > "$A/home/hello"
mkdir -p "$A/bin"; printf '#!/bin/sh\necho tool\n' > "$A/bin/demotool"; chmod u+x "$A/bin/demotool"
mkdir -p "$A/config/anyos"; printf 'a\n' > "$A/config/anyos/conf"
mkdir -p "$A/config/onlymac@darwin"; printf 'm\n' > "$A/config/onlymac@darwin/conf"   # ex-gate: must be skipped now
git init -q "$A"
git -C "$A" config user.name a; git -C "$A" config user.email a@x
git -C "$A" add -A; git -C "$A" commit -q -m c1
c1="$(git -C "$A" rev-parse HEAD)"

# --- Clone B and bootstrap -----------------------------------------------------
B="$work/B"; git clone -q "$A" "$B"
# Canonicalize $B to match install.sh's OWN view of itself: DOTFILES is computed via
# `pwd -P` (install.sh:30), which resolves symlinks. On macOS $TMPDIR sits under
# /var/folders/... and /var is itself a symlink to /private/var, so the child
# `install.sh link` process resolves DOTFILES to the /private/var/... form and every
# link it creates points THERE - while an uncanonicalized $B here still reads
# /var/folders/... Comparing readlink targets against the raw path then fails on
# macOS (not on Linux, where /tmp carries no such symlink) - measured in CI.
B="$(cd "$B" && pwd -P)"
bash "$B/install.sh" install >/dev/null 2>&1 || fail "bootstrap install failed"
# RELINK-FIXTURE GUARD, loud by design: if a walker placed nothing, every relink assertion
# below silently degrades into a no-op. Fail HERE, naming the cause, rather than downstream
# with a confusing symptom. Every walker is covered, and each link's TARGET is asserted -
# `[ -L ]` alone would pass a symlink pointing anywhere at all.
ck_link() {  # $1=dest  $2=expected target  $3=which walker
  [ -L "$1" ] \
    || fail "FIXTURE INERT: $3 placed no link at $1 - the fixture cannot observe a relink defect"
  [ "$(readlink "$1")" = "$2" ] \
    || fail "FIXTURE BROKEN: $1 points at $(readlink "$1"), expected $2 ($3)"
}
ck_link "$XDG_CONFIG_HOME/demo"     "$B/config/demo"  "_link_config_tree"
ck_link "$HOME/.hello"              "$B/home/hello"   "_link_home_tree"
ck_link "$HOME/.local/bin/demotool" "$B/bin/demotool" "_link_bin_tree"
# The suffix rule: an unsuffixed dir links; an @-suffixed one never does, on any
# host. @darwin is the fixture on purpose - it is the suffix that used to link.
ck_link "$XDG_CONFIG_HOME/anyos" "$B/config/anyos" "an unsuffixed config dir"
{ [ ! -e "$XDG_CONFIG_HOME/onlymac" ] && [ ! -L "$XDG_CONFIG_HOME/onlymac" ]; } \
  || fail "an @-suffixed config dir was linked - the OS gate came back"

upg() { bash "$B/install.sh" upgrade </dev/null >/dev/null 2>&1; }   # non-interactive
bhead() { git -C "$B" rev-parse HEAD; }
# Every refusal must leave HEAD, the working tree, AND submodules
# untouched. snap_state captures all three; refuse_clean runs the upgrade, requires
# it to FAIL, and asserts the full state is byte-identical to the pre-run snapshot.
snap_state() { git -C "$B" rev-parse HEAD; echo --; git -C "$B" status --porcelain; echo --; git -C "$B" submodule status 2>/dev/null; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok: $1"; else fail "$1: got [$2] want [$3]"; fi; }
refuse_clean() {   # $1 = label, $2 = optional regex the refusal's stderr must match
  local snap out; snap="$(snap_state)"
  # `if out=$(...)` guards set -e on the (expected) nonzero exit and captures the
  # message so we can pin WHICH gate refused, not just that something did.
  if out="$(bash "$B/install.sh" upgrade </dev/null 2>&1)"; then
    fail "$1: upgrade was accepted (must refuse)"
  fi
  ck "$1: refused, HEAD+tree+submodules untouched" "$(snap_state)" "$snap"
  if [ -n "${2:-}" ]; then
    grep -Eq "$2" <<<"$out" \
      || fail "$1: refused for the WRONG reason (want /$2/), got: $out"
  fi
}

# --- 1. up-to-date is a clean no-op -------------------------------------------
# `upg || fail`, never a bare `upg`: made this path do real work (submodules
# + relink + re-seed), so it CAN now return non-zero - and under `set -e` a bare call would
# abort the whole suite here with an EMPTY log, pointing a maintainer nowhere.
before="$(bhead)"; upg || fail "up-to-date upgrade returned non-zero (the reconcile failed)"
ck "up-to-date no-op (exit 0, HEAD same)" "$(bhead)" "$before"

# --- 2. an update from origin is merged ---------------------------------------
# After this B sits at c2; every refuse case below rewinds A to a known SHA and
# asserts B stays exactly here - so the cases are independent, not chained.
( cd "$A"; echo c2 > f; git add f; git commit -q -m c2 )
c2="$(git -C "$A" rev-parse HEAD)"
upg && merged=ok || merged=fail
ck "an update from origin merges (exit 0)" "$merged" "ok"
ck "HEAD advanced to origin tip" "$(bhead)" "$c2"
b_at="$(bhead)"     # the trusted resting point B must never leave on a refusal

# --- 5. rollback: divergent (non-descendant) history -> ff-only refuses -------
# A rewinds all the way to c1 and commits a history not descended from c2 (B's HEAD).
( cd "$A"; git reset -q --hard "$c1"; echo div > d; git add d; git commit -q -m divergent )
refuse_clean "divergent (rewound) history" "fast-forward merge refused"

# --- 13. dirty tracked tree refuses before fetching ---------------------------
printf 'dirt\n' >> "$B/config/demo/conf"                    # modify a tracked file
before="$(bhead)"; tree_before_dirty="$(git -C "$B" rev-parse HEAD)"
if upg; then fail "dirty-tree: upgrade proceeded with a modified tracked file"; fi
ck "dirty-tree refused, HEAD untouched" "$(bhead)" "$before"
git -C "$B" checkout -q -- config/demo/conf                  # clean up
[ "$(git -C "$B" status --porcelain)" = "" ] || fail "dirty-tree cleanup failed"

# --- 14. single-flight lock: a held lock refuses; the lock is released after ---
# Sync A to B first so the post-release run is a genuine up-to-date no-op (exit 0)
# rather than hitting a pending refused update.
( cd "$A"; git reset -q --hard "$(git -C "$B" rev-parse HEAD)" )
lock="$XDG_STATE_HOME/dotfiles/upgrade.lock"
mkdir -p "$XDG_STATE_HOME/dotfiles"; mkdir "$lock"
# Guard the assignment with `if` so `set -e` does not abort on the (expected)
# nonzero exit of the lock-refused upgrade.
if lout="$(bash "$B/install.sh" upgrade </dev/null 2>&1)"; then lrc=0; else lrc=$?; fi
if [ "$lrc" -eq 0 ] || ! grep -q 'in progress' <<<"$lout"; then
  rmdir "$lock" 2>/dev/null || :; fail "held lock did not refuse the upgrade"
fi
ck "held lock refuses a concurrent upgrade" ok ok
rmdir "$lock"
upg || fail "lock: a normal run after releasing the lock failed (up-to-date)"
ck "lock released -> normal run proceeds" "$([ -e "$lock" ] && echo stuck || echo clear)" "clear"

# --- 16. fetch failure refuses, HEAD untouched --------------------------------
orig_url="$(git -C "$B" remote get-url origin)"
git -C "$B" remote set-url origin "$work/does-not-exist"
before="$(bhead)"
if upg; then fail "fetch failure: upgrade proceeded"; fi
ck "fetch failure refused, HEAD untouched" "$(bhead)" "$before"
git -C "$B" remote set-url origin "$orig_url"

# --- 17. verified fetch is NON-INTERACTIVE + re-injects the credential helper --
# vgit scrubs the global config (kills url.insteadOf / hostile gpg.ssh.program),
# which would also drop the operator's HTTPS credential helper and prompt at login.
# Assert the verified fetch (a) sets GIT_TERMINAL_PROMPT=0 (never prompts) and (b)
# re-injects credential.helper read from the trusted XDG config FILE (the path the
# re-inject pins GIT_CONFIG_GLOBAL to). A fake `git` records the fetch env/args.
xdgcfg="$HOME/.config/git/config"; mkdir -p "$(dirname "$xdgcfg")"
printf '[credential]\n\thelper = SENTINEL-HELPER\n' > "$xdgcfg"
fakebin="$work/fakebin"; mkdir -p "$fakebin"; real_git="$(command -v git)"
fetchlog="$work/fetchlog"; rm -f "$fetchlog"
cat > "$fakebin/git" <<FG
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    helper=""
    for b in "\$@"; do case "\$b" in credential.helper=*) helper="\${b#credential.helper=}";; esac; done
    printf 'TP=%s HELPER=%s\n' "\${GIT_TERMINAL_PROMPT-UNSET}" "\$helper" > "$fetchlog"
    break
  fi
done
exec $real_git "\$@"
FG
chmod +x "$fakebin/git"
# --get-urlmatch needs a real URL scheme; git clone of a local PATH sets a bare
# path remote (no `://`). Point origin at the same A as a file:// URL so the helper
# resolves exactly as it would for a real https:// remote. (A bare-path or SSH
# scp-syntax remote correctly yields no helper - --get-urlmatch fails and `|| true`
# leaves it empty - which is right: SSH authenticates by key, not a helper.)
git -C "$B" remote set-url origin "file://$A"
PATH="$fakebin:$PATH" bash "$B/install.sh" upgrade </dev/null >/dev/null 2>&1 || true
[ -f "$fetchlog" ] || fail "verified fetch was never invoked"
grep -q 'TP=0' "$fetchlog" \
  || fail "verified fetch did not set GIT_TERMINAL_PROMPT=0 (would prompt at login): $(cat "$fetchlog")"
grep -q 'HELPER=SENTINEL-HELPER' "$fetchlog" \
  || fail "verified fetch did not re-inject the config-file credential helper: $(cat "$fetchlog")"
ck "verified fetch: non-interactive + credential helper re-injected" ok ok

# SECURITY (the audit HIGH): the helper READ uses the SAME env discipline as vgit -
# a hostile helper injected via GIT_CONFIG_PARAMETERS (a config-injection env channel;
# a `!cmd` helper is pre-verification RCE) must NOT reach the fetch, and the trusted
# config-FILE helper must still win. Without the env scrub the env value wins outright.
rm -f "$fetchlog"
GIT_CONFIG_PARAMETERS="'credential.helper=!EVIL-INJECTED'" PATH="$fakebin:$PATH" \
  bash "$B/install.sh" upgrade </dev/null >/dev/null 2>&1 || true
grep -q 'EVIL-INJECTED' "$fetchlog" \
  && fail "SECURITY: a GIT_CONFIG_PARAMETERS credential.helper reached the verified fetch (env not scrubbed)"
grep -q 'HELPER=SENTINEL-HELPER' "$fetchlog" \
  || fail "the trusted config-file helper must still win under env injection: $(cat "$fetchlog")"
ck "GIT_CONFIG_PARAMETERS credential.helper scrubbed; config-file helper honored (audit HIGH)" ok ok
rm -f "$xdgcfg"

# --- 18. the single-flight lock auto-releases on interrupt (Ctrl-C) ------------
# The lock is a mkdir dir; a signal must not orphan it. _install_cleanup is the
# EXIT/INT/TERM trap body - assert it releases UPGRADE_LOCK, and that SIGINT is
# routed through EXIT (a bare EXIT trap is skipped by an untrapped fatal signal).
scratch_lock="$work/scratch.lock"; mkdir -p "$scratch_lock"
bash -c ". '$B/install.sh'; UPGRADE_LOCK='$scratch_lock'; _install_cleanup" >/dev/null 2>&1 || true
[ ! -d "$scratch_lock" ] || fail "_install_cleanup did not release a held upgrade lock"
grep -q "trap 'exit 130' INT" "$B/install.sh" \
  || fail "install.sh does not route SIGINT through EXIT - the lock would orphan on Ctrl-C"
ck "upgrade lock auto-releases on interrupt (cleanup + signal-trap wiring)" ok ok

# --- an up-to-date upgrade clears a stale update-available sentinel ------------
# The precmd notice keys off $XDG_STATE_HOME/dotfiles/update-available.
# A past cadence check sets it; a manual `dotfiles-upgrade` that finds nothing to do
# must clear it too, or the notice nags after the user is already current.
( cd "$A"; git reset -q --hard "$c2" )          # A at c2
( cd "$B"; git reset -q --hard "$c2" )          # B at c2 -> definitely up to date
avail="$XDG_STATE_HOME/dotfiles/update-available"
: > "$avail"
upg || fail "up-to-date upgrade returned nonzero"
[ ! -e "$avail" ] || fail "up-to-date upgrade did not clear the stale update-available sentinel"
pass=$((pass + 1)); echo "  ok: up-to-date upgrade clears a stale update-available sentinel"

# === relink regression: the relink must run the POST-MERGE link engine ========

# --- 20. one commit changes a link RULE and adds the config it governs
# - the exact pre-merge-engine-defect commit shape. install.sh sources lib/ at start-up and git swaps a
# modified file by unlink+create, so an IN-PROCESS relink runs the PRE-merge engine
# against the POST-merge tree and creates the link the OLD rule prescribes, silently.
manifest_f="$XDG_STATE_HOME/dotfiles/manifest"
( cd "$A"
  # Insert the new exception into the REAL exceptions table, anchored on the
  # rclone|restic line. awk + mv, not `sed -i` (whose syntax differs between GNU and
  # BSD); and index(), not a regex, because a backslash-escaped `\|` is an UNDEFINED
  # ERE construct in POSIX - it happens to work on gawk/mawk, and macOS ships BWK awk.
  awk '{ print }
       index($0, "rclone|restic) : ;;") {
         print "      widget)        mkdir -p \"$HOME/.widget\"; link \"$dir/conf\" \"$HOME/.widget/conf\" || rc=1 ;;"
       }' lib/link.sh > lib/link.sh.new && mv lib/link.sh.new lib/link.sh
  mkdir -p config/widget; printf 'w\n' > config/widget/conf
  git add -A; git commit -q -m widget-rule-and-config )
# The anchor is real code that a refactor can move; assert the insertion APPLIED, or
# this case silently degrades into "the default rule linked it, as expected".
grep -q 'widget)' "$A/lib/link.sh" \
  || fail "fixture: the widget exception was NOT inserted (the rclone|restic anchor moved) - case 20 would be a silent no-op"
upg || fail "relink: the trusted widget commit should have merged"
ck "relink case 1: HEAD advanced to the widget commit" "$(bhead)" "$(git -C "$A" rev-parse HEAD)"
[ -L "$HOME/.widget/conf" ] \
  || fail "relink case 1: the POST-merge rule's link ~/.widget/conf was NOT created - the relink ran the PRE-merge engine"
pass=$((pass + 1)); echo "  ok: relink case 1: the post-merge rule's link was created"
if [ -e "$XDG_CONFIG_HOME/widget" ] || [ -L "$XDG_CONFIG_HOME/widget" ]; then
  fail "relink case 1: the PRE-merge rule's link \$XDG_CONFIG_HOME/widget was created - the relink ran stale code"
fi
pass=$((pass + 1)); echo "  ok: relink case 1: the pre-merge rule's link was NOT created"
grep -qxF -- "$HOME/.widget/conf" "$manifest_f" \
  || fail "relink case 1: ~/.widget/conf is missing from the manifest"
grep -qxF -- "$XDG_CONFIG_HOME/widget" "$manifest_f" \
  && fail "relink case 1: the stale \$XDG_CONFIG_HOME/widget is recorded in the manifest" || true
pass=$((pass + 1)); echo "  ok: relink case 1: the manifest records the new link and not the stale one"

# --- 21. an UP-TO-DATE upgrade still reconciles ------------------
# A and B sit at the same commit, so this takes the `FETCH_HEAD == HEAD` early
# return - the return that made the pre-merge-engine defect permanent, because the user's natural recovery
# (re-running dotfiles-upgrade) short-circuited there and reported success forever.
( cd "$A"; git reset -q --hard "$(git -C "$B" rev-parse HEAD)" )
rm -f "$XDG_CONFIG_HOME/demo" "$HOME/.zshenv"
[ ! -L "$XDG_CONFIG_HOME/demo" ] && [ ! -L "$HOME/.zshenv" ] || fail "relink case 2: fixture - the links were not removed"
: > "$avail"
uptodate_at="$(bhead)"
# Capture the OUTPUT, not just the exit code. "HEAD did not move" + "links restored" +
# "sentinel cleared" are ALL also true on the MERGE path (a ff-only merge of an identical
# FETCH_HEAD is a no-op success followed by the same _upgrade_apply), so without pinning
# the `already up to date` log line this case passes even with the whole
# branch deleted - measured. The log line is what proves WHICH branch ran.
if uout="$(bash "$B/install.sh" upgrade </dev/null 2>&1)"; then :; else
  fail "relink case 2: an up-to-date upgrade returned nonzero: $uout"
fi
grep -q 'already up to date' <<<"$uout" \
  || fail "relink case 2: the run did NOT take the up-to-date branch (unproven), got: $uout"
pass=$((pass + 1)); echo "  ok: relink case 2: the run took the FETCH_HEAD == HEAD branch"
ck "relink case 2: HEAD did not move" "$(bhead)" "$uptodate_at"
[ -L "$XDG_CONFIG_HOME/demo" ] \
  || fail "relink case 2: \$XDG_CONFIG_HOME/demo was NOT restored - an up-to-date upgrade did not reconcile"
[ -L "$HOME/.zshenv" ] \
  || fail "relink case 2: ~/.zshenv was NOT restored - an up-to-date upgrade did not reconcile"
pass=$((pass + 1)); echo "  ok: relink case 2: an up-to-date upgrade reconciled both deleted links"
[ ! -e "$avail" ] || fail "relink case 2: the reconciling up-to-date upgrade did not clear the update-available sentinel"
pass=$((pass + 1)); echo "  ok: relink case 2: the update-available sentinel was cleared"

# --- 22. a FAILING post-merge child must fail the upgrade ---------------------
# The relink and re-seed now run as separate processes, so their failure has to be
# CARRIED BACK. Swallowing it would be the same shape of defect as the pre-merge-engine
# defect: post-merge work
# silently not applied, every gate green. A real directory where a link belongs is a
# refusal link() cannot resolve, so the child exits non-zero.
mkdir -p "$XDG_CONFIG_HOME/blocked"; : > "$XDG_CONFIG_HOME/blocked/real-file"
( cd "$A"; mkdir -p config/blocked; printf 'b\n' > config/blocked/conf
  git add -A; git commit -q -m adds-a-config-whose-destination-is-blocked )
blocked_tip="$(git -C "$A" rev-parse HEAD)"
if bout="$(bash "$B/install.sh" upgrade </dev/null 2>&1)"; then
  fail "case 22: a failing post-merge relink child was SWALLOWED - the upgrade reported success"
fi
pass=$((pass + 1)); echo "  ok: case 22: a failing relink child makes the upgrade exit non-zero"
grep -q 'relink reported problems' <<<"$bout" \
  || fail "case 22: the failure was not attributed to the relink, got: $bout"
pass=$((pass + 1)); echo "  ok: case 22: the failure is attributed to the relink child"
# The MERGE still happened - the failure is post-merge, and reporting it must not be
# confused with refusing the update.
ck "case 22: the merge still applied (the failure is post-merge)" "$(bhead)" "$blocked_tip"
# Unblock and converge, so the fixture is clean for anything added after this.
rm -rf "$XDG_CONFIG_HOME/blocked"
upg || fail "case 22: the upgrade did not converge after the block was removed"
ck "case 22: converges once the blocking directory is gone" \
  "$([ -L "$XDG_CONFIG_HOME/blocked" ] && echo linked || echo missing)" "linked"

# --- 23. the retired reseed-settings arm is still reachable ------------------
# The arm's BODY is gone (the agent settings surface it re-seeded was removed), but its
# NAME is a cross-version ABI: the PREVIOUS release's installer invokes it on the NEW
# tree. Deleting the arm would send that installer to `*)` -> exit 2, which
# _upgrade_apply reports as a failed upgrade. So exit 0 here is the rename/removal
# discriminator, and the zero-arg guard must still reject arguments.
if rout="$(bash "$B/install.sh" reseed-settings </dev/null 2>&1)"; then :; else
  fail "case 23: 'install.sh reseed-settings' must exit 0 as a retired no-op, got: $rout"
fi
pass=$((pass + 1)); echo "  ok: case 23: the retired reseed-settings arm exists and no-ops cleanly"
rrc=0; bash "$B/install.sh" reseed-settings extra-arg </dev/null >/dev/null 2>&1 || rrc=$?
ck "case 23: reseed-settings rejects arguments with exit 2" "$rrc" "2"

# --- 24. ambient url.insteadOf cannot redirect the upgrade fetch --------------
# A hostile global git config (and the GIT_CONFIG_PARAMETERS env family) rewrites
# origin's URL to an attacker repo E that carries an extra commit. vgit scrubs
# both channels, so the fetch still reads the real origin: A is unchanged, so the
# upgrade is an up-to-date no-op and HEAD never reaches E's commit.
E="$work/E"; git clone -q "$A" "$E"
git -C "$E" -c user.name=e -c user.email=e@x commit -q --allow-empty -m evil
evil="$(git -C "$E" rev-parse HEAD)"
origin_url="$(git -C "$B" config --get remote.origin.url)"
printf '[url "%s"]\n\tinsteadOf = %s\n' "$E" "$origin_url" > "$work/evil.gitconfig"
# Precondition: the rewrite is live for a plain git, or this case proves nothing.
[ "$(GIT_CONFIG_GLOBAL="$work/evil.gitconfig" git -C "$B" ls-remote origin HEAD | awk '$2 == "HEAD" { print $1 }')" = "$evil" ] \
  || fail "case 24 fixture: the hostile insteadOf does not redirect a plain git (case would be vacuous)"
before="$(bhead)"
GIT_CONFIG_GLOBAL="$work/evil.gitconfig" bash "$B/install.sh" upgrade </dev/null >/dev/null 2>&1 \
  || fail "case 24: upgrade under a hostile ~/.gitconfig failed"
ck "case 24: a hostile global url.insteadOf did not redirect the fetch" "$(bhead)" "$before"
GIT_CONFIG_PARAMETERS="'url.$E.insteadof'='$origin_url'" bash "$B/install.sh" upgrade </dev/null >/dev/null 2>&1 \
  || fail "case 24: upgrade under a hostile GIT_CONFIG_PARAMETERS failed"
ck "case 24: a hostile GIT_CONFIG_PARAMETERS insteadOf did not redirect the fetch" "$(bhead)" "$before"

# --- 25. a malformed object on origin is refused at fetch time -----------------
# A commit whose tree carries a duplicate entry (git fsck: duplicateEntries). The
# upgrade forces fetch/transfer.fsckObjects on through vgit, so the fetch fails,
# the upgrade exits 1, and HEAD is untouched - even with an ambient config that
# turns object fsck OFF.
blob="$(printf x | git -C "$A" hash-object -w --stdin)"
raw="$(printf '%s' "$blob" | sed 's/../\\x&/g')"
# shellcheck disable=SC2059  # the format IS the payload: \xHH escapes of the blob id
{ printf '100644 a\0'; printf "$raw"; printf '100644 a\0'; printf "$raw"; } > "$work/duptree"
badtree="$(git -C "$A" hash-object -t tree --literally -w "$work/duptree")"
badc="$(git -C "$A" -c user.name=a -c user.email=a@x commit-tree "$badtree" -p HEAD -m malformed)"
git -C "$A" update-ref HEAD "$badc"
# fsck exits non-zero on the finding, so capture first: under pipefail a
# `fsck | grep` pipeline would fail on fsck's status, not on the match.
fsck_out="$(git -C "$A" fsck 2>&1 || true)"
case "$fsck_out" in
  *duplicateEntries*) : ;;
  *) fail "case 25 fixture: origin's new commit is not malformed (case would be vacuous): $fsck_out" ;;
esac
printf '[fetch]\n\tfsckObjects = false\n[transfer]\n\tfsckObjects = false\n' > "$work/nofsck.gitconfig"
GIT_CONFIG_GLOBAL="$work/nofsck.gitconfig" refuse_clean "case 25: malformed object on origin" 'fetch failed'
git -C "$B" cat-file -e "$badc" 2>/dev/null \
  && fail "case 25: the malformed commit entered the object store"
pass=$((pass + 1)); echo "  ok: case 25: the malformed commit never entered the object store"

echo "PASS: upgrade_test ($pass assertions)"
