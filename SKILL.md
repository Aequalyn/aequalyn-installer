---
name: aequalyn-installer
description: Work on the Aequalyn guided installer (QML wizard, install.toml, apply.sh, repair, update, detect).
---

# Aequalyn Installer — skill

## Overview

Guided installer that collects hardware/identity/disk/package/desktop choices, writes a
single `install.toml`, shows it for review, and applies it only after approval. Works
fully offline via a bundled repo.

## Entry points

- `aequalyn-install` — graphical wizard (Quickshell), handles `--gate`, Wayland socket recovery, delegates special modes.
- `aequalyn-install-cli` — unattended/interactive CLI (`--config`, `--detect`, `--repair`, `--dry-run`).
- `aequalyn-detect` — L1 hardware detection + profile proposal (`--shell/--toml/--json`).
- `aequalyn-repair` — repair an existing install (keyring/kernel/bootloader/manual).
- `aequalyn-update` — git-sync `/usr/share/aequalyn` + shell, re-apply to home.

## Flow

Start page (Install/Repair/Read manual) → Welcome (hardware + connectivity + import row) →
Identity → Disk → Packages → Aequalyn → Review → (locked) apply → Finish → Reboot Now →
"Enjoy Your Distro!" splash → reboot. Close disabled while writing/applying. On failure:
unlock, Discord QR, Debug (online, `opencode --auto` with generated `aequalyn-debug` skill)
or apology (offline), Retry.

## Data contract

Single source of truth: `install.toml` (version 1; sections `[system]`, `[disk]`, `[boot]`,
`[packages]`, `[agent]`, `[aequalyn]`). Password never stored; `password_set = true` only.
`lib/apply.sh` parses TOML via Python `tomllib`, emits shell-safe `KEY=value` lines, hashes
password with `openssl passwd -6`, feeds hash into chroot. Partitioning (full wipe, dual
boot, manual), LUKS2, Btrfs subvolumes (`@ @home @log @pkg @.snapshots @var @root`),
pacstrap, chroot config, Limine, snapper, Aequalyn desktop.

## Key files

- `shell.qml` — Quickshell entry; loads `Installer.qml`.
- `harness.qml` — scripted UI self-test driver (`--test`).
- `Installer.qml` — whole wizard UI, state machine, process orchestration.
- `aequalyn-install` — launcher.
- `aequalyn-install-cli` — CLI wizard + apply.
- `aequalyn-detect` — hardware detection.
- `aequalyn-repair` — repair.
- `aequalyn-update` — git-sync + re-apply.
- `lib/apply.sh` — deterministic executor.
- `install.toml.example` — documented contract.
- Profiles: `profileDefs` in `Installer.qml`, one list each in aequalyn-pkgs `lists/profiles/`; `minimal` is always in.
- `tests/e2e.sh`, `tests/mock-apply.sh`, `tests/mock-detect.sh` — offline UI self-test.

## Connectivity

Probed like apply.sh: `ping -c 1 -W 2 archlinux.org`; with no internet package source
defaults to bundled offline repository.

## Qt5 dialog hook

`lib/apply.sh` plants pacman hook `/etc/pacman.d/hooks/aequalyn-qt5-dialogs.hook`
running core's `bin/aequalyn-qt5-dialogs` when vlc installed/upgraded/removed, so
Qt5 apps use Aequalyn FM's Open/Save dialogs.

## Security

See `SECURITY.md`. Key concerns: root privileges, TOML injection, `eval` of detection
output, environment/path injection, weak/unverified package trust (`SigLevel = Never`
offline), auto-login, password in argv/process list, password hash in `/mnt/pwhash.env`,
arbitrary file import as root, repair/chroot destructive ops, debug session as root.

## Testing

- `tests/e2e.sh`, `tests/mock-apply.sh`, `tests/mock-detect.sh`.
- `harness.qml` drives UI self-tests (`--test`).
- Close button disabled while writing/applying; harness asserts end-to-end.

## References

- Aequalyn core: https://github.com/Aequalyn/aequalyn
- Aequalyn installer: https://github.com/Aequalyn/aequalyn-installer
- Aequalyn ISO: https://github.com/Aequalyn/aequalyn-iso
- Aequalyn packages: https://github.com/Aequalyn/aequalyn-pkgs
