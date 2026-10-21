# Ghostty test names a malformed theme colour as a value

Session of 2026-10-21. Closes pending `00000000007whn81mm0bvvztfv`
("ghostty-test-message").

- `tests/ghostty_test.sh` runs its theme allowlist before its
  inline-comment check. A seven-digit hex such as
  `background = #0c10140` failed the inline-comment check's six-digit
  exemption first and was reported as an inline comment; it is now
  reported by the allowlist as a line that is not a colour key. Neither
  check changed, and a real inline comment in the base config is still
  reported as one (both reproduced before and after the change).
- `ghostty-allowlist-breadth` and `gotham-autosuggest-contrast` stay
  pending: no theme needs a wider form yet, and gotham-default is still not
  selected (config/ghostty/config selects gruvbox-ipe-light and
  ipe-amarelo).
