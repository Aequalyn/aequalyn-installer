# Aequalyn Installer — security notes

The installer runs with full disk access and applies an `install.toml` to a target
system. Treat the config and the environment as trusted only when you control them.

## Findings (from code review)

### High
- **Runs as root / broad privileges.** The wizard and `lib/apply.sh` have full disk
  access. The QML process command array includes the plaintext password, visible in
  the local process list.
- **TOML injection.** `generateToml()` (QML) and the CLI writer interpolate
  hostname/username/timezone/disk/etc. without escaping; crafted values can alter
  `install.toml`. `apply.sh` substitutes these into `/mnt/setup.sh` via `sed` without
  sanitization.
- **`eval` of detection output.** `apply.sh` runs `eval "$det_line"` on lines from
  `aequalyn-detect --shell`.
- **Environment/path injection.** `AEQUALYN_ROOT`, `AEQUALYN_INSTALLER_DIR`, `HOME`,
  `EDITOR`, `PATH` influence script/binary resolution and write locations.
- **Weak/unverified package trust.** Offline mode uses `SigLevel = Never`; bundled repo
  and optional AUR builds are not signature-pinned. `aequalyn-update` hard-resets to
  GitHub `FETCH_HEAD` without verification.
- **Auto-login.** Installed system enables SDDM autologin for the created user. On a disk
  that is not encrypted the session locks itself at once (`aequalyn-session-start`), so
  turning the machine on does not open the desktop.

### Medium
- **Secret handling.** Password hash written to `/mnt/pwhash.env` (default perms);
  should be `0600` and removed promptly.
- **Arbitrary file import as root.** `importProc` runs `tomllib` on any user-supplied
  path.
- **Repair/chroot.** Operates on selected disks; wrong selection can damage data.
- **Debug session.** Launches `opencode` as root with a generated skill; broad command
  capability.

### Recommendations
1. Validate and escape all TOML fields; never interpolate untrusted values into
   `setup.sh`.
2. Replace `eval` with a safe parser/whitelist.
3. Pin and verify update sources; avoid `reset --hard` without review.
4. Re-enable signature verification for offline repos or document the trust model.
5. Pass secrets via files (`chmod 600`), not argv; scrub logs.
6. Restrict environment-derived paths; use absolute, validated locations.
7. Keep autologin only behind full-disk encryption (without it, the session now locks at once).
8. Make repair operations dry-run capable where feasible.
