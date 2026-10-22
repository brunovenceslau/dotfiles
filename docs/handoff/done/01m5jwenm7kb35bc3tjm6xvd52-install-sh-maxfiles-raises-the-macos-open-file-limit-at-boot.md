# install.sh maxfiles raises the macOS open-file limit at boot

Session of 2026-10-22.

- New subcommand `install.sh maxfiles [--uninstall | --status]`, logic in
  `lib/host_maxfiles.py` (Python stdlib, plistlib). It installs
  `/Library/LaunchDaemons/local.limits.maxfiles.plist`, root:wheel 0644,
  RunAtLoad, running `sysctl -w kern.maxfiles kern.maxfilesperproc` and
  then `launchctl limit maxfiles`, as was measured by hand on a macOS host
  on 2026-10-22. The value lives once, `MAXFILES` in that module.
- The installer stays unprivileged: the plist is checked with
  `plutil -lint` first, each root step is a printed `/usr/bin/sudo`
  command, and the daemon is loaded only after the installed bytes are read
  back as the checked ones. A host already in place gets no sudo. Any
  other platform: nothing runs, and it says why.
- From review: a readback that fails also removes the installed file
  (launchd would load it at the next boot); `install -S`; the owner check
  needs a single regular file; a plist at the path this step did not
  generate is neither replaced nor removed.
- Tests without privilege: `tests/host_maxfiles_units.py` replaces the
  commands and the host state; `tests/host_maxfiles_test.sh` renders the
  plist into a scratch directory, lints it with plutil on macOS, and
  drives the install.sh arm (on macOS only `--status`, read only).
- The shell's `ulimit -n` of 65536 measured on that host does not come
  from this framework: no zsh file sets `ulimit`. Not traced further from
  the sandbox, which cannot read the host.
- Scope: this host and any Mac of the maintainer that uses this framework.
  It does not change the limits inside a sandbox VM.

Not verified on macOS by this session: the sudo, launchctl and plutil
steps ran only against stubs, and `--status` only on the hosted CI runner.
