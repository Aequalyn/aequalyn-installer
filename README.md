# aequalyn-installer

The Aequalyn installer: a guided installer written in QML (Quickshell) that
writes an `install.toml`, shows it for review, and applies it only after you
approve.

| | |
| --- | --- |
| `aequalyn-install` | QML wizard + applier (`--config install.toml` for unattended installs) |
| `aequalyn-detect` | Hardware detection and a proposed profile (`aequalyn-install --detect`) |
| `aequalyn-repair` | Chroot into an existing install from the live ISO |
| `lib/apply.sh` | Partitioning (full wipe, dual boot, manual), LUKS2, Btrfs subvolumes, Limine, snapper |
| `install.toml.example` | Every option, documented |

The interactive UI lives in `shell.qml` / `Installer.qml` and runs under
Quickshell. `aequalyn-install` launches it; the legacy command-line flags are
delegated to `aequalyn-install-cli`.

On the live ISO it lives in `/opt/aequalyn/installer` next to the core tree
and the package lists ([aequalyn-iso](https://github.com/Aequalyn/aequalyn-iso)
assembles them). Everything works without AI.

## Credits

[nightdevil00](https://github.com/nightdevil00) contributed to the code here.
