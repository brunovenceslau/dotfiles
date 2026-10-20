# gotham-autosuggest-contrast

In gotham-default, `palette = 8` equals the background, so
zsh-autosuggestions' default `fg=8` style would be invisible if this theme
were selected.

Came from: #69 (conf(ghostty): Add new themes), round 3 of the pre-merge ship
gate (reviewer and security personas), a ship round being one run of it.

Why open: It is upstream data, and the theme is not wired into the ghostty
config.

Fix: Decide when the theme is wired in: set the suggestion style or adjust the
slot.
