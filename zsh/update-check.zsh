# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# zsh/update-check.zsh - background update-check sentinel.
#
# Sourced LAST from zshrc (after .zshrc.local, so a host can tune the cadence via
# the vars below before this runs). Two halves:
#   * a startup cadence check - a glob, no fork - that, once past the cadence,
#     spawns a FULLY DETACHED `git fetch` (the ONE async spawn
#     sanctions on the sacred startup path). It never waits on the network and
#     never blocks the prompt.
#   * a precmd hook that, on the next prompt, surfaces a one-line notice when the
#     detached fetch found the remote ahead, and a freeze warning when the last
#     SUCCESSFUL fetch is older than the staleness threshold - a best-effort
#     surfacing of an indefinite-freeze/withholding condition.
#
# State (all under $XDG_STATE_HOME/dotfiles/):
#   update-check.stamp   mtime = last time the cadence check ran (gates the fetch)
#   update-last-fetch    mtime = last SUCCESSFUL fetch (gates the freeze warning)
#   update-available     present iff the last fetch saw the remote ahead
#
# Config (set in .zshrc.local, or in the environment, before this file):
#   DOTFILES_UPDATE_CADENCE_DAYS      default 3   - how often to fetch
#   DOTFILES_UPDATE_STALENESS_DAYS    default 30  - freeze-warning threshold
#   DOTFILES_UPDATE_DISABLE           any non-empty value (even 0) turns the
#                                     sentinel off entirely

# Ensure the fork-free mkdir builtin is loaded even if this module is somehow
# sourced before zshrc's zsh/files zmodload at its top. Normally redundant - this
# file is sourced last - but it makes the "mkdir is a builtin, not a fork" claim
# below self-sufficient rather than an implicit load-order dependency. zshrc
# disables the builtin again after sourcing this file.
zmodload -F zsh/files b:mkdir 2>/dev/null

# _dotfiles_update_fetch STATEDIR - the body that runs DETACHED off the startup
# path (so it may fork/network freely). Records the last successful fetch and
# whether the tracking branch is ahead. A named function, not an inline block, so
# the unit test can drive it synchronously against a local remote.
_dotfiles_update_fetch() {
  # Plain zsh semantics whatever .zshrc.local set: with KSH_ARRAYS, for one,
  # arrays are 0-based and ${hs[1]} below would drop the credential helper.
  emulate -L zsh
  local state="$1" ahead
  # NON-INTERACTIVE by construction: a background fetch on the
  # startup path must NEVER prompt - even backgrounded, git opens /dev/tty for a
  # credential prompt, so a mis-authed HTTPS remote would ask `Username for
  # github.com` at login. GIT_TERMINAL_PROMPT=0 turns that into a silent failure;
  # `ssh -oBatchMode=yes` (appended to any existing GIT_SSH_COMMAND) does the same
  # for an SSH remote (no passphrase/host-key prompt). Either way a host that can't
  # authenticate just skips the check.
  #
  # fsckObjects forced ON per-invocation (defense-in-depth): this
  # sentinel writes fetched objects into $DOTFILES's object store, which the later
  # `dotfiles-upgrade` fetch trusts-by-reuse (git will not re-fsck objects already
  # present). A `~/.gitconfig`/`.local` with `fetch.fsckObjects=false` would
  # otherwise let this pre-populate un-fsck'd objects. The `-c` flags beat both
  # config files and the GIT_CONFIG_* env families, so the malformed-object
  # rejection cannot be disabled ambiently.
  #
  # Ambient config is SCRUBBED, the way install.sh's vgit does it for the upgrade:
  # the GLOBAL/SYSTEM files and the GIT_CONFIG_PARAMETERS/COUNT/GIT_CONFIG env
  # families are dropped, so a hostile url.insteadOf cannot point this fetch at
  # another repository and fill the object store from it. Only credential.helper
  # is read back, from the framework's XDG config and for this remote's RAW url
  # (`config --get` is immune to insteadOf), exactly as the upgrade re-injects it.
  # All of this runs in the detached body - never on the prompt's path.
  (
    unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG
    export GIT_CONFIG_SYSTEM=/dev/null
    local url helpers
    url=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$DOTFILES" config --get remote.origin.url 2>/dev/null)
    helpers=$(GIT_CONFIG_GLOBAL="${XDG_CONFIG_HOME:-$HOME/.config}/git/config" \
      git -C "$DOTFILES" config --get-urlmatch credential.helper "$url" 2>/dev/null)
    local -a hs; hs=( ${(f)helpers} )     # unquoted (f): empty lines dropped
    export GIT_CONFIG_GLOBAL=/dev/null
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -oBatchMode=yes" \
      git -C "$DOTFILES" -c credential.helper="${hs[1]-}" \
      -c fetch.fsckObjects=true -c transfer.fsckObjects=true \
      fetch --quiet origin 2>/dev/null
  ) || return 0
  : > "$state/update-last-fetch"
  # @{upstream} needs a tracking branch; a missing/odd count is not "ahead".
  ahead=$(git -C "$DOTFILES" rev-list --count 'HEAD..@{upstream}' 2>/dev/null)
  if [[ $ahead == <1-> ]]; then
    : > "$state/update-available"
  else
    rm -f "$state/update-available"
  fi
}

() {
  # A checkout with a git dir is the only place an update fetch makes sense. Skip
  # in a non-repo (e.g. a published-subset that will re-enable it) or when off.
  [[ -n ${DOTFILES_UPDATE_DISABLE-} ]] && return 0
  [[ -n ${DOTFILES-} && -d $DOTFILES/.git ]] || return 0

  local state="$XDG_STATE_HOME/dotfiles"
  local stamp="$state/update-check.stamp"
  integer cadence_h=$(( ${DOTFILES_UPDATE_CADENCE_DAYS:-3} * 24 ))

  # Past cadence? The stamp is absent, or older than the cadence window. The glob
  # qualifier does the mtime test with no fork; (Nmh-N) = exists AND newer than N
  # hours, so an empty result means "stale or missing" -> time to check again.
  local -a fresh
  fresh=( $stamp(N.mh-${cadence_h}) )
  if (( ! $#fresh )); then
    [[ -d $state ]] || mkdir -p "$state"        # zsh/files builtin mkdir (no fork)
    : > "$stamp"                                 # reset the cadence NOW so concurrent
                                                 # shells don't all spawn a fetch
    # Fully detached (&!): backgrounded AND disowned, so it outlives this shell and
    # never blocks the prompt. The body records its result for the precmd notice.
    _dotfiles_update_fetch "$state" &!
  fi

  # Seed the freeze baseline on first run so a checkout whose fetch NEVER succeeds
  # still surfaces staleness (measured from first sight, not from an absent file).
  [[ -e $state/update-last-fetch ]] || { [[ -d $state ]] || mkdir -p "$state"; : > "$state/update-last-fetch"; }
}

# precmd notice - runs on each prompt (file reads + globs only, no fork/network),
# but prints at most once per shell so it is not nagging. Registered via
# add-zsh-hook so it composes with a host's own precmd hooks.
typeset -g _dotfiles_update_notified=
_dotfiles_update_notice() {
  [[ -n $_dotfiles_update_notified ]] && return 0
  [[ -n ${DOTFILES_UPDATE_DISABLE-} ]] && return 0
  local state="$XDG_STATE_HOME/dotfiles"
  integer staleness_h=$(( ${DOTFILES_UPDATE_STALENESS_DAYS:-30} * 24 ))

  if [[ -e $state/update-available ]]; then
    print -u2 -- "dotfiles: updates are available - run 'dotfiles-upgrade' to apply them."
    _dotfiles_update_notified=1
  fi
  # Freeze warning: the last successful fetch is older than the staleness window.
  local -a stale
  stale=( $state/update-last-fetch(N.mh+${staleness_h}) )
  if (( $#stale )); then
    print -u2 -- "dotfiles: no successful update check in over ${DOTFILES_UPDATE_STALENESS_DAYS:-30} days - the update channel may be stalled (run 'dotfiles-upgrade')."
    _dotfiles_update_notified=1
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _dotfiles_update_notice
