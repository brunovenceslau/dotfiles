#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for zsh/update-check.zsh - the background
# update sentinel. Drives the zsh module from bash via `zsh -fc` against a local
# A/B git pair (no network): the detached fetch body is a named function
# (_dotfiles_update_fetch) so it can be exercised synchronously; the cadence gate,
# the next-prompt notice, and the freeze warning are checked over the state files.
# Hermetic mktemp workspace; the real $HOME/$DOTFILES are never touched. Not part
# of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
uc="$repo_root/zsh/update-check.zsh"
fail() { echo "FAIL: $*" >&2; exit 1; }
if ! command -v zsh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh/git unavailable and STRICT=1"; fi
  echo "SKIP: zsh/git unavailable - update_check not run"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/update_check_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# local A (remote) + B (clone with a tracking branch), no network
A="$work/A"; git init -q "$A"; ( cd "$A"; git config user.name a; git config user.email a@x
  echo 1 > f; git add f; git commit -qm c1 )
B="$work/B"; git clone -q "$A" "$B"
# The module reads/writes under $XDG_STATE_HOME/dotfiles; point both at the same
# place so the test's files and the module's agree (XDG_STATE_HOME=$work below).
state="$work/dotfiles"; mkdir -p "$state"
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok: $1"; else fail "$1: got [$2] want [$3]"; fi; }

# helper: run a zsh snippet with the module loaded, DOTFILES/XDG pointed at fixtures
zrun() { DOTFILES="$B" XDG_STATE_HOME="$work" zsh -fc "source '$uc'; $1" 2>"$work/err"; }
# DISABLE=1 makes the startup anon return early so _dotfiles_update_fetch is
# exercised alone (the function is defined before the anon).
zfetch() { DOTFILES="$B" DOTFILES_UPDATE_DISABLE=1 zsh -fc "source '$uc'; _dotfiles_update_fetch '$state'"; }

# --- 1. fetch marks update-available when the remote is ahead -----------------
( cd "$A"; echo 2 > f; git commit -qam c2 )         # A now ahead of B's tracking ref
rm -f "$state/update-available"
zfetch
ck "fetch: remote ahead -> update-available created" "$([ -e "$state/update-available" ] && echo yes)" "yes"
ck "fetch: last-fetch timestamp recorded" "$([ -e "$state/update-last-fetch" ] && echo yes)" "yes"

# --- 2. fetch clears update-available when up to date --------------------------
( cd "$B"; git merge -q --ff-only origin/master 2>/dev/null || git merge -q --ff-only origin/main )
zfetch
ck "fetch: up to date -> update-available cleared" "$([ -e "$state/update-available" ] && echo present || echo absent)" "absent"

# --- 3. precmd notice fires (once) when update-available is present ------------
: > "$state/update-available"
out="$(DOTFILES="$B" XDG_STATE_HOME="$work" zsh -fc "source '$uc'; _dotfiles_update_notice; _dotfiles_update_notice" 2>&1 || true)"
ck "notice: printed for update-available" "$(printf '%s' "$out" | grep -c 'updates are available')" "1"
rm -f "$state/update-available"

# --- 4. freeze warning when the last successful fetch is stale -----------------
: > "$state/update-last-fetch"
# backdate it well past the (test) 1-day staleness threshold
touch -d '40 days ago' "$state/update-last-fetch" 2>/dev/null || touch -t 202001010000 "$state/update-last-fetch"
out="$(DOTFILES="$B" XDG_STATE_HOME="$work" DOTFILES_UPDATE_STALENESS_DAYS=1 \
  zsh -fc "source '$uc'; _dotfiles_update_notice" 2>&1 || true)"
ck "freeze: stale last-fetch warns" "$(printf '%s' "$out" | grep -c 'update channel may be stalled')" "1"
: > "$state/update-last-fetch"    # fresh again

# --- 5. DISABLE turns the sentinel off entirely -------------------------------
rm -f "$state/update-check.stamp" "$state/update-available"
DOTFILES="$B" XDG_STATE_HOME="$work" DOTFILES_UPDATE_DISABLE=1 zsh -fc "source '$uc'" 2>/dev/null
ck "disable: no cadence stamp created" "$([ -e "$state/update-check.stamp" ] && echo present || echo absent)" "absent"

# --- 6. non-repo DOTFILES: sentinel is a clean no-op --------------------------
rm -f "$state/update-check.stamp"
DOTFILES="$work/not-a-repo" XDG_STATE_HOME="$work" zsh -fc "source '$uc'" 2>"$work/err"
ck "non-repo: no stamp, no error" "$([ -e "$state/update-check.stamp" ] && echo present || echo absent)$([ -s "$work/err" ] && echo ERR)" "absent"

# --- 7. cadence gate: past cadence resets the stamp; fresh leaves it ----------
rm -f "$state/update-check.stamp"
DOTFILES="$B" XDG_STATE_HOME="$work" zsh -fc "source '$uc'" 2>/dev/null
ck "cadence: past-cadence run creates the stamp" "$([ -e "$state/update-check.stamp" ] && echo yes)" "yes"
# A fresh stamp (well inside the cadence window, but a DISTINCT time - one hour
# ago, not 'now') must not be rewritten by an immediate re-run. Distinct so a
# wrongful reset bumps the mtime to a clearly different second (a 'now' baseline
# would collide with the reset's own 'now' at 1s granularity and false-pass).
touch -t "$(date -d '1 hour ago' +%Y%m%d%H%M 2>/dev/null || date -v-1H +%Y%m%d%H%M)" "$state/update-check.stamp"
before="$(date -r "$state/update-check.stamp" +%s 2>/dev/null || stat -c %Y "$state/update-check.stamp")"
DOTFILES="$B" XDG_STATE_HOME="$work" zsh -fc "source '$uc'" 2>/dev/null
after="$(date -r "$state/update-check.stamp" +%s 2>/dev/null || stat -c %Y "$state/update-check.stamp")"
ck "cadence: fresh stamp not rewritten (no spawn)" "$before" "$after"

# --- 8. startup NEVER BLOCKS on the fetch - the load-bearing test -
# A fake `git` earlier on PATH that SLEEPS on fetch (real git for everything else).
# Past-cadence, the module spawns `_dotfiles_update_fetch &!`; if that spawn is
# truly detached the `source` returns immediately while the 5s fetch runs in the
# background, so the measured wall-clock is ~0s. If someone drops the `&!` (making
# it synchronous) the source blocks the full 5s. We assert the source returns in
# under 3s - impossible unless the fetch is detached. (The old test pointed at a
# fast-FAILING remote and asserted ok==ok - it could not tell async from sync.)
fakebin="$work/fakebin"; mkdir -p "$fakebin"
real_git="$(command -v git)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = fetch ] && { sleep 5; exit 1; }; done\nexec %s "$@"\n' "$real_git" > "$fakebin/git"
chmod +x "$fakebin/git"
rm -f "$state/update-check.stamp"
t0=$(date +%s)
PATH="$fakebin:$PATH" DOTFILES="$B" XDG_STATE_HOME="$work" zsh -fc "source '$uc'" 2>/dev/null
t1=$(date +%s)
elapsed=$(( t1 - t0 ))
[ "$elapsed" -lt 3 ] || fail "startup BLOCKED ${elapsed}s on the fetch - the spawn is not detached"
ck "non-blocking: source returned in ${elapsed}s while a 5s fetch runs detached" "yes" "yes"
( cd "$B"; git remote set-url origin "$A" )

# --- 9. the background fetch is NON-INTERACTIVE - never prompts at login -------
# The bug this guards: an unauthenticated HTTPS remote made the detached fetch open
# /dev/tty and ask `Username for github.com` at shell startup. A fake `git` records
# the env its `fetch` runs under; assert GIT_TERMINAL_PROMPT=0 (git fails instead of
# prompting) and that ssh BatchMode is set (no SSH prompt either).
fakebin2="$work/fakebin2"; mkdir -p "$fakebin2"
envfile="$work/fetchenv"; rm -f "$envfile"
cat > "$fakebin2/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    printf 'TP=%s SSH=%s\n' "\${GIT_TERMINAL_PROMPT-UNSET}" "\${GIT_SSH_COMMAND-UNSET}" > "\$FETCH_ENV_FILE"
    exit 0
  fi
done
exec $real_git "\$@"
EOF
chmod +x "$fakebin2/git"
PATH="$fakebin2:$PATH" FETCH_ENV_FILE="$envfile" DOTFILES="$B" DOTFILES_UPDATE_DISABLE=1 \
  zsh -fc "source '$uc'; _dotfiles_update_fetch '$state'"
grep -q 'TP=0' "$envfile" \
  && ck "fetch runs with GIT_TERMINAL_PROMPT=0 (no login credential prompt)" yes yes \
  || fail "fetch did NOT set GIT_TERMINAL_PROMPT=0 - a mis-authed HTTPS remote would prompt at login"
grep -q 'BatchMode=yes' "$envfile" \
  && ck "fetch sets ssh BatchMode (no SSH passphrase/host-key prompt)" yes yes \
  || fail "fetch did NOT set ssh BatchMode"

echo "PASS: update_check_test ($pass assertions)"
