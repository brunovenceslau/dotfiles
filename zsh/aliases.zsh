# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# zsh/aliases.zsh - interactive aliases. Sourced from zshrc (after lib/os.sh).
#
# All definitions
# here are builtins - `alias`, plus the two builtin loops that assemble
# $LS_COLORS and the directory-stack aliases - so parsing this file adds no
# subprocess to the startup path.
# This file sources its own untracked `.local` pair last.

# --- ls colouring -------------------------------------------------------------
# Stock macOS ships BSD ls: colour is `-G`, the scheme lives in $LSCOLORS. Set
# unconditionally, independent of which branch below wins, so a bare `\ls -G` is
# still coloured on a host that also has GNU ls.
export LSCOLORS='exfxcxdxbxegedabagacad'

# Prefer GNU ls when it is there. On macOS brew's coreutils installs it as `gls`
# (packages/Brewfile) and this framework deliberately does NOT put coreutils'
# gnubin on $PATH the way the old prezto setup did - that shadowed ~100 BSD tools
# to get one better `ls`, so the gain is taken through the `gls` name alone.
# BSD ls has no --group-directories-first and no per-extension colour, so the
# macOS fallback is a genuine downgrade, not an equivalent spelling.
if (( $+commands[gls] )); then
  alias ls='gls --color=auto --group-directories-first'
  alias lx='ll -XB'              # sorted by extension - GNU-only flags
else
  alias ls='ls -G'
fi

# The listing family from prezto's `utility` module. Each builds on the previous
# alias, which zsh resolves recursively at the start of a command - `lc` expands
# through `lt` and `ll` to `ls -lh -tr -c`. That chaining is the point; spelling
# them out independently would drift the moment `ll` changes.
# SPDX-SnippetBegin
# SPDX-SnippetCopyrightText: 2009-2011 Robby Russell and contributors
# SPDX-SnippetCopyrightText: 2011-2017 Sorin Ionescu and contributors
# SPDX-License-Identifier: MIT
# Snippet source: sorin-ionescu/prezto, modules/utility/init.zsh, at commit
# cff2d01871425b1b80710f8ec6a475c5a53145b4. Changes: `la` is respelled
# `ls -lAh` (prezto chains it off `ll` as `ll -A`), and the trailing comments
# are this repo's. The other eight alias definitions are prezto's verbatim.
alias ll='ls -lh'                # human-readable sizes
alias la='ls -lAh'               # ... with hidden files
alias l='ls -1A'                 # one column, hidden files
alias lr='ll -R'                 # recursive
alias lm='la | "$PAGER"'         # paged ($PAGER is exported in zsh/zshenv)
alias lk='ll -Sr'                # sorted by size, largest last
alias lt='ll -tr'                # sorted by mtime, newest last
alias lc='lt -c'                 # ... by ctime
alias lu='lt -u'                 # ... by atime
# SPDX-SnippetEnd

# $LS_COLORS in the GNU format, assembled from an array so the palette stays
# reviewable line by line while the build itself is one builtin join - no fork.
# Exported on EVERY platform, because it has TWO consumers: GNU ls (the branch
# above) and compsys's `list-colors` (zshrc's completion block), which reads this
# format whatever `ls` the host ships - so on a mac without coreutils it still
# colours the Tab list while the BSD `ls` running beside it ignores the variable.
# The values ARE the `dircolors` default database (verified against
# `dircolors -b`, 148 entries): prezto obtained them by RUNNING `dircolors` at
# startup, a fork this path cannot take, so they are inlined and grouped by
# colour instead. The anonymous function keeps the loop variables out of the
# shell namespace.
# SPDX-SnippetBegin
# SPDX-SnippetCopyrightText: 1996-2026 Free Software Foundation, Inc.
# SPDX-License-Identifier: FSFAP
# Snippet source: the default database of GNU coreutils' `dircolors`,
# coreutils/coreutils src/dircolors.hin at commit
# 6bfc90019f070832cce9f11bdecf707ffeead759, whose own notice reads: "Copying
# and distribution of this file, with or without modification, are permitted
# provided the copyright notice and this notice are preserved."
# Changes: all 148 entries are regrouped by colour into the array and the four
# `for` specs below and joined by a builtin instead of being produced by
# running `dircolors`. No colour VALUE is altered: all 148 are byte-identical
# to that file.
() {
  local -a c=(
    'rs=0' 'di=01;34' 'ln=01;36' 'mh=00' 'pi=40;33' 'so=01;35' 'do=01;35'
    'bd=40;33;01' 'cd=40;33;01' 'or=40;31;01' 'mi=00' 'su=37;41' 'sg=30;43'
    'ca=00' 'tw=30;42' 'ow=34;42' 'st=37;44' 'ex=01;32'
    # The two patterns in the backup family that carry no extension dot.
    '*~=00;90' '*#=00;90'
  )
  # One entry per colour family: '<colour>:<ext> <ext> ...'. A colour code never
  # contains a colon, so `%%:*` / `#*:` split each spec unambiguously.
  local spec colour ext
  for spec in \
    '01;31:tar tgz arc arj taz lha lz4 lzh lzma tlz txz tzo t7z zip z dz gz lrz lz lzo xz zst tzst bz2 bz tbz tbz2 tz deb rpm jar war ear sar rar alz ace zoo cpio 7z rz cab wim swm dwm esd' \
    '01;35:avif jpg jpeg mjpg mjpeg gif bmp pbm pgm ppm tga xbm xpm tif tiff png svg svgz mng pcx mov mpg mpeg m2v mkv webm webp ogm mp4 m4v mp4v vob qt nuv wmv asf rm rmvb flc avi fli flv gl dl xcf xwd yuv cgm emf ogv ogx' \
    '00;36:aac au flac m4a mid midi mka mp3 mpc ogg ra wav oga opus spx xspf' \
    '00;90:bak old orig part rej swp tmp dpkg-dist dpkg-old ucf-dist ucf-new ucf-old rpmnew rpmorig rpmsave'
  do
    colour=${spec%%:*}
    for ext in ${=spec#*:}; do c+=( "*.$ext=$colour" ); done
  done
  export LS_COLORS="${(j.:.)c}"
}
# SPDX-SnippetEnd

# --- navigation ---------------------------------------------------------------
# The directory STACK, from prezto's `directory` module. These ten are useless
# without AUTO_PUSHD, which zshrc's interactive-options block sets - the two MUST
# stay together: with an empty stack `d` prints one line and `1`..`9` fail.
alias d='dirs -v'
for _i in {1..9}; do alias "$_i"="cd +$_i"; done
unset _i

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ~='cd ~'
# `--` so zsh reads the alias NAME `-`, not an option. `cd -` is the previous dir.
alias -- -='cd -'

# --- shell / meta -------------------------------------------------------------
# `history` with no argument shows only the last 16; `history 1` shows all of it,
# numbered, which is what you actually want when you reach for the command.
alias history='history 1'
alias zhistory='cat "$HISTFILE"'
# One PATH entry per line. `print -l` is a builtin over the $path array - no fork,
# no tr, and it handles an entry containing a colon correctly.
alias path='print -l $path'
# Re-source the interactive config. $ZDOTDIR, not $HOME: the framework is XDG-only.
alias reload='source "$ZDOTDIR/.zshrc"'

# --- disk / process -----------------------------------------------------------
alias ducks='du -cks -- *(D) | sort -rn | head'
alias suducks='sudo du -cks -- *(D) | sort -rn | head'
alias niceness='ps ax -o pid,ni,command'

# --- git ----------------------------------------------------------------------
alias g='git'
alias gst='git status'
# --branch keeps the "ahead/behind origin" line that --short alone drops - which
# is most of why you run a short status in the first place.
alias gs='git status --short --branch'
alias gd='git diff'
alias gds='git diff --staged'
alias ga='git add'
alias gc='git commit'
alias gco='git checkout'
alias gsw='git switch'
alias gb='git branch'
# --all so a graph shows every branch, not just the one you are on.
alias gl='git log --oneline --graph --decorate --all'
alias gp='git push'
alias gpl='git pull'
alias gru='git remote update'
alias gfa='git fetch --all'
alias greb='git rebase'
alias grebi='git rebase -i'
alias grs='git reset --soft'
alias gsh='git show'
alias gshw='git show -w'          # ignore whitespace
alias gcm='git checkout main'
alias gcmaster='git checkout master'
# Search commit MESSAGES and show what each matching commit touched.
alias gf='git log --pretty="format:%Cgreen%H%n%s%n%n%b" --name-status --grep'

# Stash-then-discard. gss/gssu stash; the grh* family stashes FIRST (-u, so
# untracked files come along) and only then resets --hard, so a reset never
# destroys work outright - it is always recoverable from `git stash list`.
# That ordering is the whole point; do not "simplify" it to a bare reset.
alias gss='git stash save'
alias gssu='gss -u'
alias grh='gssu && git reset --hard'
alias grhom='gssu && git reset --hard origin/main'
alias grhum='gssu && git reset --hard upstream/main'
alias grhomaster='gssu && git reset --hard origin/master'
alias grhumaster='gssu && git reset --hard upstream/master'
# gpf force-pushes with a lease: unlike --force it refuses to overwrite remote
# commits you have not fetched, so a teammate's (or another machine's) push is never
# silently clobbered.
alias gpf='git push --force-with-lease'

# Some distros ship fd as `fd-find` with an `fdfind` binary.
# Alias fd -> fdfind for muscle memory when no real fd is on PATH. Guarded so it
# costs nothing and never shadows a real fd (e.g. a cargo-installed one). Zero
# file created - unlike a ~/.local/bin shim this leaves no framework artifact for
# uninstall to miss.
(( $+commands[fdfind] )) && (( ! $+commands[fd] )) && alias fd='fdfind'

# --- GNU-name fallbacks on macOS ----------------------------------------------
# Stock macOS ships the BSD spellings. Define the GNU name ONLY when the real
# tool is absent, so a brew-installed coreutils always wins.
(( $+commands[hd] ))      || alias hd='hexdump -C'
(( $+commands[md5sum] ))  || alias md5sum='md5'
(( $+commands[sha1sum] )) || alias sha1sum='shasum'

# --- network ------------------------------------------------------------------
# Public IP via DNS, which is faster and less rate-limited than an HTTP echo
# service. Guarded: dig is not installed everywhere.
(( $+commands[dig] )) && \
  alias ip='dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com'
alias ips="ifconfig -a | grep -oE 'inet6? (addr:)?([0-9a-f:.]+)' | awk '{print \$NF}'"
alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'

# --- macOS conveniences -------------------------------------------------------
alias hidedesktop='defaults write com.apple.finder CreateDesktop -bool false && killall Finder'
alias showdesktop='defaults write com.apple.finder CreateDesktop -bool true && killall Finder'
# pmset, not the old CGSession path: same effect, supported spelling.
alias afk='pmset displaysleepnow'
alias tailscale='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
alias stopwatch='echo "Timer started. Stop with Ctrl-D." && date && time \cat && date'
(( $+commands[uuidgen] )) && alias uuid='uuidgen | tr "[:upper:]" "[:lower:]"'

# --- novelties ----------------------------------------------------------------
alias ascii-rainbow='for i in {30..37}; do print -P "%F{$i}color $i%f"; done'

# --- machine-local layer --------------------------------------
# Sourced when present, silent when absent; untracked and never published, so a
# host can add or override aliases without touching the tracked file.
[[ -r $ZDOTDIR/aliases.zsh.local ]] && source "$ZDOTDIR/aliases.zsh.local"
