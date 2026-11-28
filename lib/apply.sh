#!/usr/bin/env bash
SIMULATE="${AEQUALYN_SIMULATE:-false}"
# aequalyn-install :: apply -- deterministic executor for install.toml.
# Called by aequalyn-install after the user has approved the config. Never asks
# interactive questions; everything comes from the config + the password arg.
set -euo pipefail
# whatever mask this was started under: what it writes is for every user to read
umask 022

CONFIG=$1
PASSWORD=$2
LOGFILE=${3:-/root/aequalyn-install.log}
# When driven by the QML installer, mirror everything we print to LOGFILE so
# the "Log: ..." path shown in the UI actually contains the install log. The
# CLI already tees to its own log, so it leaves this off to avoid duplicates.
if [[ "${AEQUALYN_TEE_LOG:-0}" == "1" && -n "$LOGFILE" ]]; then
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    exec > >(tee -a "$LOGFILE") 2>&1
fi
AEQUALYN_ROOT=${AEQUALYN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
export AEQUALYN_ROOT

info() { printf '\033[0;34m  INFO\033[0m    %s\n' "$*"; }
ok()   { printf '\033[0;32m  OK\033[0m      %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN\033[0m    %s\n' "$*"; }
abort(){ printf '\033[0;31m  ABORT\033[0m   %s\n' "$*"; exit 1; }
trap 'printf "\n\033[0;31m  INSTALL FAILED\033[0m  lib/apply.sh line %s: %s\n  The system is NOT bootable. Log: %s\n" "$LINENO" "$BASH_COMMAND" "$LOGFILE"' ERR

# --------------------------------------------------------------- config ------
ENV_FILE=$(mktemp)
python3 - "$CONFIG" > "$ENV_FILE" <<'PY'
import sys, tomllib, shlex
with open(sys.argv[1], "rb") as f: d = tomllib.load(f)
def emit(p, o):
    for k, v in o.items():
        key = (p + k.upper())
        if isinstance(v, dict): emit(p + k.upper() + "_", v)
        elif isinstance(v, bool): print(f"{key}={'true' if v else 'false'}")
        elif isinstance(v, list): print(f"{key}={shlex.quote(' '.join(map(str,v)))}")
        else: print(f"{key}={shlex.quote(str(v))}")
emit("", d)
PY
set -a; . "$ENV_FILE"; set +a
rm -f "$ENV_FILE"

HOSTNAME=${SYSTEM_HOSTNAME:-aequalyn}
USERNAME=${SYSTEM_USERNAME:-user}
LOCALE=${SYSTEM_LOCALE:-en_US.UTF-8}
KEYMAP=${SYSTEM_KEYMAP:-us}
TIMEZONE=${SYSTEM_TIMEZONE:-UTC}
DISK=${DISK_DEVICE:-}
MODE=${DISK_MODE:-fullwipe}
FS=${DISK_FILESYSTEM:-btrfs}
ENCRYPT=${DISK_ENCRYPT:-false}
EFI_MB=${DISK_EFI_SIZE_MB:-2048}
EFI_DEV_MANUAL=${DISK_EFI_DEVICE:-}
ROOT_DEV_MANUAL=${DISK_ROOT_DEVICE:-}
BOOTLOADER=${BOOT_BOOTLOADER:-limine}
CHAINLOAD_WINDOWS=${BOOT_CHAINLOAD_WINDOWS:-true}
SOURCE=${PACKAGES_SOURCE:-auto}
PROFILES=${PACKAGES_PROFILES:-minimal}
BROWSER=${PACKAGES_BROWSER:-chromium}
SEED_WEBAPPS=${PACKAGES_SEED_WEBAPPS:-${PACKAGES_SEEDWEBAPPS:-true}}
FLATPAK=${PACKAGES_FLATPAK:-false}
AUR=${PACKAGES_AUR:-false}
EXTRA=${PACKAGES_EXTRA:-}
EDITOR=${PACKAGES_EDITOR:-nano}
SNAPSHOT_BEFORE=${AGENT_SNAPSHOT_BEFORE:-true}
COMPOSITOR=${AEQUALYN_COMPOSITOR:-hyprland}
[[ $COMPOSITOR == hyprland || $COMPOSITOR == niri || $COMPOSITOR == both ]] || COMPOSITOR=hyprland
THEME_MODE=${AEQUALYN_THEME_MODE:-wallpaper}
THEME_APPS=${AEQUALYN_THEME_APPS:-true}
BAR_HEIGHT=${AEQUALYN_BAR_HEIGHT:-32}
BAR_OPACITY=${AEQUALYN_BAR_OPACITY:-100}
# Top bar widget layout (space-separated ids per region). The TOML parser above
# emits [aequalyn].bar_left/center/right as space-separated strings; the defaults
# match the reference layout shipped in config/aequalyn/settings.json so older
# install.toml files without these keys still install the intended positions.
BAR_LEFT=${AEQUALYN_BAR_LEFT:-"appsmenu workspaces layouts network atelier"}
BAR_CENTER=${AEQUALYN_BAR_CENTER:-"clock calendar media title battery volume"}
BAR_RIGHT=${AEQUALYN_BAR_RIGHT:-"brightness cpu bluetooth temperature caffeine tray screenrecorder screenshot power clipscape settingsbutton plume altscape"}

[[ $EUID -eq 0 ]] || abort "must run as root"
# UEFI is the main target; legacy BIOS (VMs that default to it, such as GNOME
# Boxes, older PCs) gets Limine's BIOS stage on a full-disk GPT install.
if [[ -d /sys/firmware/efi ]]; then FIRMWARE=uefi; else FIRMWARE=bios; fi
if [[ $FIRMWARE == bios && "$MODE" != fullwipe ]]; then
    abort "booted in legacy BIOS mode: only a full-disk install is supported (boot in UEFI mode for dual boot)"
fi
info "firmware: $FIRMWARE"
[[ -n "$DISK" && -b "$DISK" ]] || abort "invalid or missing [disk].device: $DISK"

# Never touch the device the ISO booted from. Ventoy and other device-mapper
# live media have no PKNAME, so resolve the whole chain with lsblk -s
# (ventoy -> sda1 -> sda) instead of walking parents.
BOOT_DISK=""
BOOT_SRC=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
if [[ -n "$BOOT_SRC" ]]; then
    boot_name=$(lsblk -srno NAME "$BOOT_SRC" 2>/dev/null | tail -1 || true)
    [[ -n "$boot_name" ]] && BOOT_DISK="/dev/$boot_name"
    [[ -n "$BOOT_DISK" && "$DISK" == "$BOOT_DISK" ]] && \
        abort "refusing to install onto the live USB ($BOOT_DISK)"
fi

# A full wipe makes Aequalyn the only OS on the target disk. Never copy a
# Windows ESP from another disk into it, even if install.toml still carries
# chainload_windows = true from an earlier dualboot proposal.
if [[ "$MODE" == "fullwipe" && "$CHAINLOAD_WINDOWS" == "true" ]]; then
    CHAINLOAD_WINDOWS=false
    info "fullwipe selected: Windows chainload disabled (the whole $DISK is erased)"
fi
[[ "$MODE" == "fullwipe" || "$MODE" == "dualboot" || "$MODE" == "manual" ]] || \
    abort "unknown [disk].mode '$MODE' (expected fullwipe, dualboot or manual)"

# ---------------------------------------------------------- package source ---
OFFLINE_REPO="/var/cache/offline-repo"
OFFLINE=0
# pacstrap copies the live keyring into the new root, and pacman refuses
# every mirror package while that keyring is missing or untrusted:
#   error: ... invalid or corrupted package (PGP signature)
# which reads like a checksum failure. Make sure the Arch keys exist before
# pacstrap runs; `--init` is idempotent (it only mints the local signing
# key when none is available) and `--populate` re-imports the keys shipped
# by archlinux-keyring.
online_ready() {
    ping -c 1 -W 2 archlinux.org >/dev/null 2>&1 || { WHY="no internet and no offline repo"; return 1; }
    info "initialising the pacman keyring ..."
    pacman-key --init >/dev/null 2>&1 || { WHY="pacman-key --init failed"; return 1; }
    pacman-key --populate archlinux >/dev/null 2>&1 || { WHY="pacman-key --populate archlinux failed"; return 1; }
}
if [[ "$SOURCE" == "offline" || "$SOURCE" == "auto" ]]; then
    [[ -f "$OFFLINE_REPO/offline.db" ]] && OFFLINE=1
fi
if [[ "$SOURCE" == "offline" && $OFFLINE -eq 0 ]]; then
    abort "offline install requested but no bundled repo at $OFFLINE_REPO"
fi
if [[ $OFFLINE -eq 1 ]]; then
    PACMAN_CONF=$(mktemp /tmp/aequalyn-pacman-XXXX.conf)
    cat > "$PACMAN_CONF" <<'EOF'
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Optional
ParallelDownloads = 8
[offline]
SigLevel = Never
Server = file:///var/cache/offline-repo/
EOF
    ok "using bundled offline repository"
else
    PACMAN_CONF="/etc/pacman.conf"
    online_ready || abort "$WHY"
    ok "using online Arch mirrors"
fi

# ---------------------------------------------------------- package list -----
read_list() { # read_list <file> -> package names
    [[ -f "$1" ]] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

PKGS=()
LATER=()       # chosen, and not to be had now: aequalyn-add-packages gets them later
PKGS+=($(read_list "$AEQUALYN_ROOT/packages/base.packages"))
# Common desktop packages, plus BOTH compositor sets. Every install carries
# both session entries and both shell trees, so a user can switch runners at
# the greeter on a later boot without reinstalling or missing niri,
# xwayland-satellite or its portal backends. `compositor` only picks the
# default session / autologin value. Older bundles without the split lists
# fall back to the combined desktop.packages.
if [[ -f "$AEQUALYN_ROOT/packages/desktop-common.packages" ]]; then
    PKGS+=($(read_list "$AEQUALYN_ROOT/packages/desktop-common.packages"))
    PKGS+=($(read_list "$AEQUALYN_ROOT/packages/compositor-hyprland.packages"))
    PKGS+=($(read_list "$AEQUALYN_ROOT/packages/compositor-niri.packages"))
else
    PKGS+=($(read_list "$AEQUALYN_ROOT/packages/desktop.packages"))
fi

# Hardware conditionals (L1 detection, no AI).
# aequalyn-detect --shell also emits MODE/ENCRYPT/PROFILES/BROWSER/FLATPAK
# proposals. Sourcing the whole file silently overwrote the user's approved
# install.toml (a fullwipe became a dualboot). Read only the three keys this
# script actually needs; everything else comes from the config.
UCODE=""; GPU_PKGS=""; BATTERY="no"
DET_ENV=$(mktemp)
bash "$AEQUALYN_ROOT/installer/aequalyn-detect" --shell > "$DET_ENV"
while IFS= read -r det_line; do
    case "$det_line" in
        UCODE=*|GPU_PKGS=*|BATTERY=*) eval "$det_line" ;;
    esac
done < "$DET_ENV"
rm -f "$DET_ENV"
[[ -n "$UCODE" ]] && PKGS+=($UCODE)
[[ -n "$GPU_PKGS" ]] && PKGS+=($GPU_PKGS)
[[ "$BATTERY" == "yes" ]] && PKGS+=(tlp)

# Profiles (cumulative, deduplicated later)
PKGS+=($(read_list "$AEQUALYN_ROOT/packages/profiles/minimal.packages"))
for p in $PROFILES; do
    [[ "$p" == "minimal" ]] && continue
    f="$AEQUALYN_ROOT/packages/profiles/$p.packages"
    [[ -f "$f" ]] && PKGS+=($(read_list "$f")) || warn "unknown profile: $p"
done
# Steam and Wine draw through the 32-bit Vulkan driver of this machine's card: without it
# pacman takes the first one there is, for another maker's card.
if [[ " ${PKGS[*]} " == *" steam "* || " ${PKGS[*]} " == *" wine "* ]]; then
    PKGS+=(lib32-mesa)
    case "$GPU_PKGS" in
        *nvidia*) PKGS+=(lib32-nvidia-utils) ;;
        *radeon*) PKGS+=(lib32-vulkan-radeon) ;;
        *intel*)  PKGS+=(lib32-vulkan-intel) ;;
    esac
fi

# Automatic: the ISO's own packages, unless something was chosen that they do not have (what
# a profile adds, Firefox) and there is internet to get it from. All of it then comes from the
# mirrors, so nothing is of two ages.
in_offline() { compgen -G "$OFFLINE_REPO/$1-[0-9]*.pkg.tar.zst" >/dev/null; }
if [[ $OFFLINE -eq 1 && "$SOURCE" == "auto" ]]; then
    NEEDS=()
    for p in "${PKGS[@]}" $EXTRA $([[ "$BROWSER" == firefox ]] && echo firefox) $([[ "$FLATPAK" == true ]] && echo flatpak); do
        in_offline "$p" || NEEDS+=("$p")
    done
    if (( ${#NEEDS[@]} )); then
        info "not on the ISO: ${NEEDS[*]}"
        if online_ready && pacman -Sy >/dev/null 2>&1; then
            OFFLINE=0
            PACMAN_CONF="/etc/pacman.conf"
            ok "using online Arch mirrors, which have all of it"
        else
            warn "no usable internet connection: they are added at the first start that has one"
        fi
    fi
fi

case "$BROWSER" in
    firefox) PKGS+=(firefox) ;;
    zen)     PKGS+=(chromium); warn "Zen Browser is an AUR package; installed post-boot when online" ;;
    *)       PKGS+=(chromium) ;;
esac
# Do not ship two browsers: the base list's Chromium goes when Firefox was chosen. By its
# whole name, and never when this source has no Firefox, which would leave no browser.
if [[ "$BROWSER" == "firefox" ]]; then
    if [[ $OFFLINE -eq 1 ]] && ! compgen -G "$OFFLINE_REPO/firefox-[0-9]*.pkg.tar.zst" >/dev/null; then
        warn "Firefox is not in the offline repo: Chromium is installed instead"
    else
        KEPT=()
        for p in "${PKGS[@]}"; do [[ "$p" == chromium ]] || KEPT+=("$p"); done
        PKGS=("${KEPT[@]}")
    fi
fi
[[ "$FLATPAK" == "true" ]] && PKGS+=(flatpak)
[[ -n "$EXTRA" ]] && PKGS+=($EXTRA)
# One editor only, chosen at install time (nano or vim).
case "$EDITOR" in
    vim)  PKGS+=(vim) ;;
    nano) PKGS+=(nano) ;;
    *)    PKGS+=(nano) ;;
esac

# Drop packages not resolvable from the chosen source (offline repo may omit
# some optional profile packages). Online installs let pacman report errors.
if [[ $OFFLINE -eq 1 ]]; then
    # `pacman -Si` would query the host's sync db, not the ISO's file:// repo.
    # Check the bundled package files directly instead.
    FILTERED=()
    for p in $(printf '%s\n' "${PKGS[@]}" | grep -v '^$' | sort -u); do
        if in_offline "$p"; then
            FILTERED+=("$p")
        else
            LATER+=("$p")
        fi
    done
    PKGS=("${FILTERED[@]}")
else
    # one name the mirrors do not know (renamed, gone) must not end the whole install
    FILTERED=()
    pacman -Sy >/dev/null 2>&1 || abort "the Arch mirrors could not be reached"
    for p in $(printf '%s\n' "${PKGS[@]}" | grep -v '^$' | sort -u); do
        if pacman -Sp --print-format '%n' "$p" >/dev/null 2>&1; then
            FILTERED+=("$p")
        else
            warn "$p is not in the Arch repositories"
            LATER+=("$p")
        fi
    done
    PKGS=("${FILTERED[@]}")
fi
(( ${#LATER[@]} )) && warn "added at the first start with internet: ${LATER[*]}"
ok "packages to install: ${#PKGS[@]}"

# ---------------------------------------------------------- snapshot ---------
if [[ "$SNAPSHOT_BEFORE" == "true" ]]; then
    bash "$AEQUALYN_ROOT/bin/aequalyn-snapshot" "$DISK" || warn "pre-install snapshot skipped"
fi

# ---------------------------------------------------------- partitioning -----
part_num() { # part_num <device> <n> -> nvme/mmcblk/loop need a 'p'
    local dev=$1 n=$2
    [[ "$dev" == *nvme* || "$dev" == *mmcblk* || "$dev" == *loop* ]] \
        && printf '%sp%s' "$dev" "$n" || printf '%s%s' "$dev" "$n"
}

# Windows can only be chainloaded from the disk we install to: a Microsoft
# folder on another disk is not a dual boot. Skip old Aequalyn ESPs even when
# they contain a copied EFI/Microsoft tree, and require the real boot manager.
WIN_EFI=""
if [[ "$CHAINLOAD_WINDOWS" == "true" && "$MODE" != "fullwipe" ]]; then
    for p in $(blkid -t TYPE=vfat -o device 2>/dev/null || true); do
        lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null || true)
        [[ "$lbl" == AEQUALYN* ]] && continue
        [[ "$p" == "$DISK"* ]] || continue
        mp=$(mktemp -d)
        if mount -o ro "$p" "$mp" 2>/dev/null; then
            [[ -f "$mp/EFI/Microsoft/Boot/bootmgfw.efi" ]] && WIN_EFI="$p"
            umount "$mp" 2>/dev/null || true
        fi
        rmdir "$mp" 2>/dev/null || true
        [[ -n "$WIN_EFI" ]] && break
    done
fi

ALIGN=$((1048576))
if [[ "$MODE" == "manual" ]]; then
    [[ -n "$EFI_DEV_MANUAL" && -b "$EFI_DEV_MANUAL" ]] || abort "manual mode needs [disk].efi_device"
    [[ -n "$ROOT_DEV_MANUAL" && -b "$ROOT_DEV_MANUAL" ]] || abort "manual mode needs [disk].root_device"
    EFI_DEV="$EFI_DEV_MANUAL"; ROOT_DEV="$ROOT_DEV_MANUAL"
    EFI_NUM=$(lsblk -no PARTN "$EFI_DEV" | head -1)
    ok "manual layout: EFI=$EFI_DEV root=$ROOT_DEV"
elif [[ "$MODE" == "fullwipe" ]]; then
    warn "ERASING ALL DATA ON $DISK"
    # release the disk first: a previous, interrupted run may still have it mounted
    umount -R /mnt 2>/dev/null || true
    cryptsetup close aequalyn_root 2>/dev/null || true
    for part in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
        swapoff "$part" 2>/dev/null || true
        umount -R "$part" 2>/dev/null || true
        # Remove partition payload signatures (LUKS, btrfs, vfat, swap) too:
        # wiping only the disk-level header can leave stale LUKS/btrfs ids.
        wipefs -a "$part" >/dev/null 2>&1 || true
    done
    wipefs -a "$DISK" >/dev/null 2>&1 || true
    partprobe "$DISK" 2>/dev/null || true; udevadm settle
    parted --script "$DISK" mklabel gpt
    parted --script "$DISK" mkpart primary fat32 1MiB "${EFI_MB}MiB"
    parted --script "$DISK" set 1 esp on
    parted --script "$DISK" name 1 "AEQUALYN_EFI"
    parted --script "$DISK" mkpart primary btrfs "${EFI_MB}MiB" 100%
    parted --script "$DISK" name 2 "AEQUALYN_ROOT"
    EFI_NUM=1; ROOT_NUM=2
    EFI_DEV=$(part_num "$DISK" 1); ROOT_DEV=$(part_num "$DISK" 2)
elif [[ "$MODE" == "dualboot" ]]; then
    FREE=$(parted -m "$DISK" unit B print free 2>/dev/null | \
        awk -F: '$NF ~ /free/ {gsub(/B/,"",$2);gsub(/B/,"",$3);gsub(/B/,"",$4); if($4+0>m+0){m=$4+0;s=$2;e=$3}} END{if(m>0) printf "%s %s %s",s,e,m}' || true)
    START_B=$(awk '{print $1}' <<<"$FREE")
    END_B=$(awk '{print $2}' <<<"$FREE")
    SIZE_B=$(awk '{print $3}' <<<"$FREE")
    [[ -n "$FREE" && "$SIZE_B" -ge $((12*1073741824)) ]] || \
        abort "no free region >= 12 GiB on $DISK (shrink a partition first)"
    # grep exits 1 when the disk has no partitions yet, which under
    # set -euo pipefail used to abort before ${LAST:-0} could run.
    LAST=$(lsblk -n -o PARTN "$DISK" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
    [[ -n "$LAST" ]] || \
        abort "dualboot needs an existing partition table on $DISK (use mode=\"fullwipe\" for an empty disk)"
    EFI_NUM=$(( ${LAST:-0} + 1 )); ROOT_NUM=$(( EFI_NUM + 1 ))
    EFI_START=$(( (START_B + ALIGN - 1) / ALIGN * ALIGN ))
    EFI_END=$(( EFI_START + EFI_MB*1048576 ))
    ROOT_START=$(( (EFI_END + 1 + ALIGN - 1) / ALIGN * ALIGN ))
    ROOT_END=$(( END_B / ALIGN * ALIGN - ALIGN ))
    (( ROOT_END > ROOT_START )) || abort "not enough aligned free space"
    parted --script "$DISK" mkpart primary fat32 "${EFI_START}B" "${EFI_END}B"
    parted --script "$DISK" set "$EFI_NUM" esp on
    parted --script "$DISK" name "$EFI_NUM" "AEQUALYN_EFI"
    parted --script "$DISK" mkpart primary btrfs "${ROOT_START}B" "${ROOT_END}B"
    parted --script "$DISK" name "$ROOT_NUM" "AEQUALYN_ROOT"
    EFI_DEV=$(part_num "$DISK" "$EFI_NUM"); ROOT_DEV=$(part_num "$DISK" "$ROOT_NUM")
    ok "dualboot: $(( SIZE_B/1073741824 )) GiB free region reused"
else
    abort "unknown [disk].mode '$MODE' (expected fullwipe, dualboot or manual)"
fi

partprobe "$DISK" 2>/dev/null || true; sync; sleep 2
[[ -b "$EFI_DEV" && -b "$ROOT_DEV" ]] || abort "partitions not found: $EFI_DEV / $ROOT_DEV"

# ---------------------------------------------------------- filesystems ------
LUKS_UUID=""
wipefs -a "$ROOT_DEV" 2>/dev/null || true
if [[ "$ENCRYPT" == "true" ]]; then
    info "LUKS2 on $ROOT_DEV"
    printf '%s' "$PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$ROOT_DEV" -
    printf '%s' "$PASSWORD" | cryptsetup open "$ROOT_DEV" aequalyn_root
    ROOT_MAP="/dev/mapper/aequalyn_root"
    LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")
else
    ROOT_MAP="$ROOT_DEV"
fi

mkfs.btrfs -f "$ROOT_MAP" >/dev/null
udevadm settle
mount "$ROOT_MAP" /mnt
SUBVOLS=(@ @home @log @pkg @.snapshots @var @root)
for s in "${SUBVOLS[@]}"; do btrfs subvolume create "/mnt/$s" >/dev/null; done
umount /mnt

MOPTS="noatime,compress=zstd"
mount -o "$MOPTS,subvol=@" "$ROOT_MAP" /mnt
mkdir -p /mnt/{home,.snapshots,var,root,boot}
mount -o "$MOPTS,subvol=@home" "$ROOT_MAP" /mnt/home
mount -o "$MOPTS,subvol=@var"  "$ROOT_MAP" /mnt/var
mount -o "$MOPTS,subvol=@root" "$ROOT_MAP" /mnt/root
mkdir -p /mnt/var/log /mnt/var/cache/pacman/pkg
mount -o "$MOPTS,subvol=@log" "$ROOT_MAP" /mnt/var/log
mount -o "$MOPTS,subvol=@pkg" "$ROOT_MAP" /mnt/var/cache/pacman/pkg
mount -o "$MOPTS,subvol=@.snapshots" "$ROOT_MAP" /mnt/.snapshots

# Ensure traversable permissions on the subvolume roots and mount points,
# regardless of the live environment's umask.
chmod 755 /mnt 2>/dev/null || true
chmod 755 /mnt/home /mnt/var /mnt/boot 2>/dev/null || true
chmod 700 /mnt/root 2>/dev/null || true
chmod 1777 /mnt/tmp 2>/dev/null || true
chmod 750 /mnt/.snapshots 2>/dev/null || true

mkfs.fat -F32 -n AEQUALYN "$EFI_DEV" >/dev/null
udevadm settle
mount "$EFI_DEV" /mnt/boot
ok "filesystems ready (btrfs: ${SUBVOLS[*]})"
if [[ "$SIMULATE" == "true" ]]; then
    info "SIMULATE: skipping pacstrap/chroot; filesystems created on $ROOT_DEV"
    exit 0
fi

# Chainload Windows bootloader into our ESP (dualboot only). A fullwipe is a
# single-OS disk and must never inherit another disk's Microsoft EFI tree.
if [[ "$MODE" == "dualboot" && "$CHAINLOAD_WINDOWS" == "true" \
      && -n "$WIN_EFI" && "$WIN_EFI" != "$EFI_DEV" ]]; then
    WIN_MP=$(mktemp -d)
    if mount -o ro "$WIN_EFI" "$WIN_MP" 2>/dev/null; then
        mkdir -p /mnt/boot/EFI
        cp -r "$WIN_MP/EFI/Microsoft" /mnt/boot/EFI/ 2>/dev/null && ok "Windows bootloader copied" || warn "could not copy Windows bootloader"
        umount "$WIN_MP"
    fi
    rmdir "$WIN_MP" 2>/dev/null || true
fi

# ---------------------------------------------------------- kernel cmdline ---
if [[ "$ENCRYPT" == "true" ]]; then
    CMDLINE="quiet splash cryptdevice=UUID=${LUKS_UUID}:aequalyn_root root=/dev/mapper/aequalyn_root rw rootflags=subvol=@ rootfstype=btrfs"
else
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_MAP")
    CMDLINE="quiet splash root=UUID=${ROOT_UUID} rw rootflags=subvol=@ rootfstype=btrfs"
fi
CMDLINE_FB=${CMDLINE/quiet splash /quiet }

# ---------------------------------------------------------- pacstrap ---------
info "installing base system (${#PKGS[@]} packages) ..."
pacstrap -C "$PACMAN_CONF" /mnt "${PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab
ok "base system installed"

# Fix directory permissions: pacstrap may inherit a restrictive umask from the
# live environment, leaving /, /etc, /var, /home, /boot unreadable by non-root
# users (dbus, sddm, systemd services). That breaks D-Bus and SDDM autologin.
chmod 755 /mnt 2>/dev/null || true
for d in etc var home boot usr opt srv mnt tmp; do
    [[ -e /mnt/$d ]] || continue
    case "$d" in
        root) chmod 700 /mnt/$d 2>/dev/null || true ;;
        tmp) chmod 1777 /mnt/$d 2>/dev/null || true ;;
        *) chmod 755 /mnt/$d 2>/dev/null || true ;;
    esac
done
# Mount-point dirs for the btrfs subvolumes must also be traversable.
chmod 755 /mnt/home /mnt/var /mnt/boot 2>/dev/null || true
chmod 700 /mnt/root 2>/dev/null || true
# pacstrap creates the nested pacman dirs under the live environment's umask.
# Keep the local database and package cache world-traversable (a+rx) too.
for d in /mnt/var/lib/pacman /mnt/var/lib/pacman/local /mnt/var/lib/pacman/sync \
         /mnt/var/cache/pacman /mnt/var/cache/pacman/pkg; do
    [[ -d $d ]] && chmod 755 "$d" 2>/dev/null || true
done

if [[ "$ENCRYPT" == "true" ]]; then
    printf 'aequalyn_root UUID=%s none luks,discard\n' "$LUKS_UUID" >> /mnt/etc/crypttab
fi

# ---------------------------------------------------------- plymouth ---------
# The plymouth mkinitcpio hook embeds the default theme and the theme's
# BOOT_SECONDS, so the theme must be staged before the chroot picks it as
# default and builds the initramfs. START_BAR_ON_SPLASH follows the install
# type, and the calibrate helper measures this machine before the image is
# built.
info "staging the Aequalyn boot splash ..."
if [[ -d "$AEQUALYN_ROOT/plymouth/aequalyn" ]]; then
    install -d -m 0755 /mnt/usr/share/plymouth/themes/aequalyn
    cp -a "$AEQUALYN_ROOT/plymouth/aequalyn/." /mnt/usr/share/plymouth/themes/aequalyn/
    # Encrypted installs start the bar at the passphrase answer; plain ones
    # have no prompt to start from, so the bar runs with the splash instead.
    if [[ "$ENCRYPT" == "true" ]]; then
        START_BAR=0
    else
        START_BAR=1
    fi
    sed -i "s/^START_BAR_ON_SPLASH = .*/START_BAR_ON_SPLASH = $START_BAR;/" \
        /mnt/usr/share/plymouth/themes/aequalyn/aequalyn.script
else
    warn "plymouth/aequalyn missing from the source tree; the target gets no splash"
fi
if [[ -f "$AEQUALYN_ROOT/bin/aequalyn-plymouth-calibrate" ]]; then
    install -Dm 0755 "$AEQUALYN_ROOT/bin/aequalyn-plymouth-calibrate" \
        /mnt/usr/local/bin/aequalyn-plymouth-calibrate
fi
if [[ $OFFLINE -eq 1 ]]; then
    # Keep the offline pacman.conf for reproducibility, but do not copy the
    # multi-gigabyte repo into the installed system -- it has online mirrors.
    cp "$PACMAN_CONF" /mnt/etc/pacman-offline.conf
fi

# Pre-built AUR packages (Limine snapshot stack) baked into the ISO's offline
# repo: stage them in the target so the chroot can install them with pacman -U,
# giving offline installs working snapshot boot entries. They are installed
# after mkinitcpio so their hooks reuse the finished initramfs.
mkdir -p /mnt/var/cache/aequalyn-aur
AUR_BAKED=0
for p in limine-mkinitcpio-hook limine-snapper-sync; do
    for f in "$OFFLINE_REPO/$p"-*.pkg.tar.zst; do
        [[ -f "$f" ]] || continue
        cp -f "$f" /mnt/var/cache/aequalyn-aur/
        AUR_BAKED=1
    done
done
(( AUR_BAKED )) && ok "staged Limine snapshot packages for the chroot" \
    || info "Limine snapshot packages will be built from AUR on first boot"

# Aequalyn's own packages (packages/local.packages: mpvpaper, ddwriter, nudu) are
# not in the Arch repositories: the ISO carries them prebuilt in its offline
# repository, online installs included. Staged here, installed in the chroot.
mkdir -p /mnt/var/cache/aequalyn-local
LOCAL_STAGED=0
if [[ -f "$AEQUALYN_ROOT/packages/local.packages" ]]; then
    for p in $(sed -e 's/#.*//' "$AEQUALYN_ROOT/packages/local.packages"); do
        f=$(compgen -G "$OFFLINE_REPO/$p-[0-9]*.pkg.tar.zst" | sort -V | tail -n1 || true)
        if [[ -n "$f" ]]; then
            cp -f "$f" /mnt/var/cache/aequalyn-local/
            LOCAL_STAGED=$((LOCAL_STAGED + 1))
        else
            warn "$p is not in the offline repository; skipping it"
        fi
    done
fi
(( LOCAL_STAGED )) && ok "staged $LOCAL_STAGED of Aequalyn's own packages for the chroot"

# ---------------------------------------------------------- chroot -----------
info "configuring system in chroot ..."
cat > /mnt/setup.sh <<'CHROOT'
#!/usr/bin/bash
set -euo pipefail
trap 'echo "setup.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR
source /pwhash.env
rm -f /pwhash.env

info() { printf '\033[0;34m  INFO\033[0m    %s\n' "$*"; }
ok()   { printf '\033[0;32m  OK\033[0m      %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN\033[0m    %s\n' "$*"; }

TIMEZONE="__TIMEZONE__"
HOSTNAME="__HOSTNAME__"
KEYMAP="__KEYMAP__"
USERNAME="__USERNAME__"
ENCRYPT="__ENCRYPT__"
EFINUM="__EFINUM__"
FIRMWARE="__FIRMWARE__"
DISK="__DISK__"
CHAINLOAD="__CHAINLOAD__"
CMDLINE="__CMDLINE__"
CMDLINE_FB="__CMDLINE_FB__"
FLATPAK="__FLATPAK__"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true
printf '%s UTF-8\n' "${LANG_BASE:-en_US}" > /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
H
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf

# Aequalyn branding. limine-entry-tool names auto-generated boot entries after
# PRETTY_NAME, and limine-snapper-sync hangs the snapshot submenu under that
# name, so keep this in sync with TARGET_OS_NAME below.
rm -f /etc/os-release
cat > /usr/lib/os-release <<'OSR'
NAME="Aequalyn"
PRETTY_NAME="Aequalyn Linux"
ID=aequalyn
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/Aequalyn"
DOCUMENTATION_URL="https://wiki.archlinux.org"
SUPPORT_URL="https://github.com/Aequalyn/issues"
BUG_REPORT_URL="https://github.com/Aequalyn/issues"
LOGO=archlinux-logo
OSR
ln -sf ../usr/lib/os-release /etc/os-release

echo "root:$PWHASH" | chpasswd -e
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PWHASH" | chpasswd -e
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

# Raise the pam_faillock retry limit from the default 3 to 10 for the
# installed user (system-auth is shared by sudo), mirroring
# increase-lockout-limit.sh.
sed -i 's|^\(auth\s\+required\s\+pam_faillock.so\)\s\+preauth.*$|\1 preauth silent deny=10 unlock_time=120|' /etc/pam.d/system-auth
sed -i 's|^\(auth\s\+\[default=die\]\s\+pam_faillock.so\)\s\+authfail.*$|\1 authfail deny=10 unlock_time=120|' /etc/pam.d/system-auth
if [[ -f /etc/pam.d/sddm-autologin ]]; then
    sed -i '/pam_faillock\.so preauth/d'  /etc/pam.d/sddm-autologin
    sed -i '/pam_faillock\.so authsucc/d' /etc/pam.d/sddm-autologin
    sed -i '/auth.*pam_permit\.so/a auth        required    pam_faillock.so authsucc' /etc/pam.d/sddm-autologin
fi

cat > /etc/pacman.conf <<'PAC'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist
PAC

sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
if [[ "$ENCRYPT" == "true" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block plymouth encrypt filesystems fsck)/' /etc/mkinitcpio.conf
else
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
fi
printf 'COMPRESSION="zstd"\n' >> /etc/mkinitcpio.conf
# Select the Aequalyn Plymouth theme and size its bar to this machine before
# the initramfs is built: the plymouth hook embeds both the default theme
# (from /etc/plymouth/plymouthd.conf) and the theme's BOOT_SECONDS.
if [[ -d /usr/share/plymouth/themes/aequalyn ]]; then
    if plymouth-set-default-theme aequalyn >/dev/null 2>&1; then
        ok "Plymouth theme aequalyn selected"
    else
        warn "could not select the aequalyn Plymouth theme"
    fi
    if [[ -x /usr/local/bin/aequalyn-plymouth-calibrate ]]; then
        if ! /usr/local/bin/aequalyn-plymouth-calibrate; then
            warn "Plymouth calibration failed; keeping the theme default"
        fi
    fi
else
    warn "aequalyn Plymouth theme not staged; the splash stays on the default"
fi
# mkinitcpio is CPU-bound and runs inside the chroot on the live system, so a
# full-priority run can starve the QML installer's event loop (Quickshell shows
# "Application Not Responding"). Run it at a low CPU/IO priority so the UI
# keeps repainting; it takes slightly longer but the install is unattended.
info "building initramfs (low priority, keeps the installer responsive) ..."
if command -v ionice >/dev/null 2>&1; then
    ionice -c2 -n7 nice -n 10 mkinitcpio -P
else
    nice -n 10 mkinitcpio -P
fi

cat > /etc/systemd/zram-generator.conf <<'Z'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
Z

# ---- Btrfs snapshots -------------------------------------------------------
# Written by hand (like Ryoku): `snapper create-config` needs snapperd over
# D-Bus, which does not exist inside the chroot, and it refuses to create
# .snapshots because the installer already made that subvolume. The AUR stack
# installed below reads /etc/snapper/configs/root and /etc/conf.d/snapper.
mkdir -p /etc/snapper/configs /etc/conf.d /etc/default /boot
cat > /etc/snapper/configs/root <<'SNAPCONF'
# Aequalyn snapper config for the root filesystem.
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="10"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPCONF
printf 'SNAPPER_CONFIGS="root"\n' > /etc/conf.d/snapper
chmod 750 /.snapshots 2>/dev/null || true
chown root:root /.snapshots 2>/dev/null || true

# Limine (UEFI). Seed the ESP with the named and fallback EFI binaries so the
# firmware can boot this system even without an NVRAM entry.
mkdir -p /boot/EFI/limine /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
if [[ "$FIRMWARE" == uefi ]]; then
  efibootmgr --create --disk "$DISK" --part "$EFINUM" \
    --label "Aequalyn (Limine)" --loader '\EFI\limine\BOOTX64.EFI' --unicode || true
else
  # Legacy BIOS: stage 1 in the MBR, stage 2 in the GPT gap before partition 1
  # (it starts at 1 MiB), limine-bios.sys next to limine.conf on /boot.
  cp /usr/share/limine/limine-bios.sys /boot/
  limine bios-install "$DISK"
fi

# Install the pre-built Limine snapshot stack from the ISO's offline repo. Its
# hooks generate /boot/limine.conf and the kernel entries themselves; the entry
# name comes from PRETTY_NAME ("Aequalyn Linux"), matching TARGET_OS_NAME below.
if compgen -G '/var/cache/aequalyn-aur/*.pkg.tar.zst' >/dev/null; then
  pacman -U --noconfirm /var/cache/aequalyn-aur/*.pkg.tar.zst >/dev/null 2>&1 || true
fi
# Aequalyn's own packages (mpvpaper, ddwriter, nudu), one at a time so one that
# cannot install does not keep the others out.
for f in /var/cache/aequalyn-local/*.pkg.tar.zst; do
  [[ -f "$f" ]] || continue
  if pacman -U --noconfirm --needed "$f" >/dev/null 2>&1; then
    ok "installed $(basename "$f" .pkg.tar.zst)"
  else
    warn "could not install $(basename "$f")"
  fi
done
rm -rf /var/cache/aequalyn-local
# Configure the tools after installing them so pacman cannot clobber the files.
printf 'TARGET_OS_NAME="Aequalyn Linux"\nESP_PATH="/boot"\n' > /etc/default/limine
if [[ -f /etc/limine-snapper-sync.conf ]]; then
  sed -i 's|^#\?TARGET_OS_NAME=.*|TARGET_OS_NAME="Aequalyn Linux"|' /etc/limine-snapper-sync.conf
  sed -i 's|^#\?ESP_PATH=.*|ESP_PATH="/boot"|' /etc/limine-snapper-sync.conf
else
  printf 'TARGET_OS_NAME="Aequalyn Linux"\nESP_PATH="/boot"\n' > /etc/limine-snapper-sync.conf
fi

# limine-entry-tool cannot create kernel entries without a command line, and
# the chroot has no usable /proc/cmdline. Without this file it only adds the
# "EFI fallback" chainload entry, which is what used to force the flat menu
# below. Write it before asking the tool to regenerate the boot entries.
install -d -m 755 /etc/kernel
printf '%s\n' "$CMDLINE" > /etc/kernel/cmdline
chmod 644 /etc/kernel/cmdline

# Do not keep limine.conf under EFI/limine or EFI/BOOT: Limine's search order
# can prefer those copies, while limine-entry-tool only updates
# /boot/limine.conf, leaving stale kernel entries after every update.
rm -f /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf

# The stack's mkinitcpio hook writes the kernel entries, but mkinitcpio already
# ran above, so run limine-update once more now that the hook and the cmdline
# are in place. This also refreshes the EFI binary and its fallback copy.
if command -v limine-update >/dev/null 2>&1; then
  limine-update >/dev/null 2>&1 || true
fi

# Own menu whenever no kernel entry exists: the AUR stack was unavailable
# (online installs build it on first boot), so keep the machine bootable.
if ! grep -q 'protocol: linux' /boot/limine.conf 2>/dev/null; then
  warn "limine-entry-tool did not create a kernel entry; writing a fallback menu"
  FB_IMG=initramfs-linux-fallback.img
  [[ -f /boot/$FB_IMG ]] || FB_IMG=initramfs-linux.img
  cat > /boot/limine.conf <<LIMEOF
timeout: 3

/Aequalyn Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

/Aequalyn Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE_FB
    module_path: boot():/$FB_IMG
LIMEOF
fi

if [[ -d /boot/EFI/Microsoft && "$CHAINLOAD" == "true" ]] \
   && ! grep -qi 'Microsoft' /boot/limine.conf; then
  cat >> /boot/limine.conf <<'WEOF'

/Windows Boot Manager
    protocol: chainload
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
WEOF
fi

# limine-update writes the OS and kernel entries but not the snapshot submenu:
# that block is owned by limine-snapper-sync. Run it once so the installed
# system offers its snapshots on the very first boot, and so later
# limine-update runs keep the block (they preserve an existing //Snapshots).
if command -v limine-snapper-sync >/dev/null 2>&1; then
  limine-snapper-sync >/dev/null 2>&1 \
    || warn "limine-snapper-sync failed; snapshot entries may be missing"
fi

systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable systemd-timesyncd.service
systemctl enable fstrim.timer
[[ "$FLATPAK" == "true" ]] && systemctl enable --now flatpak.service 2>/dev/null || true

systemctl enable snapper-cleanup.timer 2>/dev/null || true
# Timeline snapshots stay off (TIMELINE_CREATE="no"); snap-pac creates pre/post
# snapshots around every pacman transaction, and limine-snapper-sync publishes
# them to the boot menu.
if [[ -f /usr/lib/systemd/system/limine-snapper-sync.service ]]; then
  systemctl enable limine-snapper-sync.service 2>/dev/null || true
fi

# Start gnome-keyring for every user (needed so secrets are available on
# autologin, where no password is typed to unlock it).
mkdir -p /mnt/etc/systemd/user/default.target.wants /mnt/etc/systemd/user/sockets.target.wants
ln -sf /usr/lib/systemd/user/gnome-keyring-daemon.service /mnt/etc/systemd/user/default.target.wants/gnome-keyring-daemon.service 2>/dev/null || true
ln -sf /usr/lib/systemd/user/gnome-keyring-daemon.socket /mnt/etc/systemd/user/sockets.target.wants/gnome-keyring-daemon.socket 2>/dev/null || true

# Don't let Nextcloud autostart on every boot (issue 5).
if [[ -f /usr/share/applications/com.nextcloud.desktopclient.nextcloud.desktop ]]; then
  sed -i '/^\[Desktop Entry\]/a Hidden=true' /usr/share/applications/com.nextcloud.desktopclient.nextcloud.desktop
fi

mkdir -p /etc/aequalyn
CHROOT

LOCALE_BASE=${LOCALE%%.*}
PWHASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)
printf "PWHASH='%s'\nLOCALE='%s'\nLANG_BASE='%s'\n" "$PWHASH" "$LOCALE" "$LOCALE_BASE" > /mnt/pwhash.env
for kv in "TIMEZONE:$TIMEZONE" "HOSTNAME:$HOSTNAME" "KEYMAP:$KEYMAP" "USERNAME:$USERNAME" \
          "ENCRYPT:$ENCRYPT" "EFINUM:$EFI_NUM" "FIRMWARE:$FIRMWARE" "DISK:$DISK" "CHAINLOAD:$CHAINLOAD_WINDOWS" \
          "CMDLINE:$CMDLINE" "CMDLINE_FB:$CMDLINE_FB" "FLATPAK:$FLATPAK"; do
    k=${kv%%:*}; v=${kv#*:}
    sed -i "s|__${k}__|${v}|g" /mnt/setup.sh
done
chmod +x /mnt/setup.sh
arch-chroot /mnt /setup.sh
rm -f /mnt/setup.sh
ok "system configured"

# ---------------------------------------------------------- Aequalyn files -------
info "installing the Aequalyn desktop ..."
UID_T=$(arch-chroot /mnt id -u "$USERNAME" 2>/dev/null || awk -F: -v u="$USERNAME" '$1==u{print $3; exit}' /mnt/etc/passwd 2>/dev/null || echo 1000)
GID_T=$(arch-chroot /mnt id -g "$USERNAME" 2>/dev/null || awk -F: -v u="$USERNAME" '$1==u{print $4; exit}' /mnt/etc/passwd 2>/dev/null || echo 1000)
mkdir -p "/mnt/home/$USERNAME"
AEQUALYN_SEED_WEBAPPS="$SEED_WEBAPPS" AEQUALYN_WEBAPP_BROWSER="$BROWSER" \
    bash "$AEQUALYN_ROOT/install.sh" --target "/mnt/home/$USERNAME" --owner "$UID_T:$GID_T"
# The supervisor is the shell's own command, not one in bin/. A fresh install
# must not depend on which install.sh happens to be bundled on the ISO: older
# ones copied the shell with stripped modes and never linked the watchdog (or
# linked it to /mnt/home/... which is gone after the reboot). Do both here,
# with a relative link that survives the chroot, whatever install.sh did.
WD_REL=".config/quickshell/tools/watchdog/aequalyn-watchdog"
WD_ABS="/mnt/home/$USERNAME/$WD_REL"
if [[ -f "$WD_ABS" ]]; then
    chmod 755 "$WD_ABS"
    mkdir -p "/mnt/home/$USERNAME/.local/bin"
    ln -sfn "../../$WD_REL" "/mnt/home/$USERNAME/.local/bin/aequalyn-watchdog"
    chown -h "$UID_T:$GID_T" "/mnt/home/$USERNAME/.local/bin/aequalyn-watchdog" 2>/dev/null || true
    ok "watchdog supervisor linked on PATH"
else
    warn "watchdog supervisor missing from the shell tree; the desktop will be unsupervised"
fi
# Same for the enterprise Wi-Fi helper used by Settings -> Wi-Fi. Older ISOs
# won't have it in bin/, so link it from the installed shell tree here too.
EAP_REL=".config/quickshell/tools/wifi/aequalyn-wifi-eap"
EAP_ABS="/mnt/home/$USERNAME/$EAP_REL"
if [[ -f "$EAP_ABS" ]]; then
    chmod 755 "$EAP_ABS"
    mkdir -p "/mnt/home/$USERNAME/.local/bin"
    ln -sfn "../../$EAP_REL" "/mnt/home/$USERNAME/.local/bin/aequalyn-wifi-eap"
    chown -h "$UID_T:$GID_T" "/mnt/home/$USERNAME/.local/bin/aequalyn-wifi-eap" 2>/dev/null || true
    ok "enterprise Wi-Fi helper linked on PATH"
fi
SPD_REL=".config/quickshell/tools/wifi/aequalyn-wifi-speed"
SPD_ABS="/mnt/home/$USERNAME/$SPD_REL"
if [[ -f "$SPD_ABS" ]]; then
    chmod 755 "$SPD_ABS"
    mkdir -p "/mnt/home/$USERNAME/.local/bin"
    ln -sfn "../../$SPD_REL" "/mnt/home/$USERNAME/.local/bin/aequalyn-wifi-speed"
    chown -h "$UID_T:$GID_T" "/mnt/home/$USERNAME/.local/bin/aequalyn-wifi-speed" 2>/dev/null || true
    ok "fast.com Wi-Fi speed helper linked on PATH"
fi
# The Quickshell lock plugin will not lock without its root-owned PAM services.
# Fresh installs stamp the migrations that would install them as done below, so
# call the one-shot helper directly inside the target. SUDO_USER tells it whose
# ~/.config/quickshell templates to use (root's HOME has none).
LOCK_APPLY="/home/$USERNAME/.local/bin/aequalyn-apply-lock"
if [[ -x "/mnt$LOCK_APPLY" ]]; then
    arch-chroot /mnt env SUDO_USER="$USERNAME" "$LOCK_APPLY" >/dev/null 2>&1 \
        || warn "could not install Aequalyn lock PAM stacks; run: sudo ~/.local/bin/aequalyn-apply-lock"
fi
# install.sh sees the live-ISO mount path; rewrite it for the installed system.
# Start on the Aequalyn theme's night wallpaper when the tree ships it (it lands
# in /usr/share/aequalyn just below), else on the sample one.
if [[ -f "$AEQUALYN_ROOT/themes/aequalyn/backgrounds/1-night-aequalyn.jpg" ]]; then
    printf '%s' /usr/share/aequalyn/themes/aequalyn/backgrounds/1-night-aequalyn.jpg
else
    printf '/home/%s/Pictures/Wallpapers/beach.jpg' "$USERNAME"
fi > "/mnt/home/$USERNAME/.config/quickshell/wallpaper.conf"
if [[ -f "$AEQUALYN_ROOT/themes/aequalyn/theme.json" ]]; then
    for _qs in quickshell quickshell-niri; do
        mkdir -p "/mnt/home/$USERNAME/.config/$_qs/theme-switcher"
        printf '%s' "$(cat /mnt/home/$USERNAME/.config/quickshell/wallpaper.conf)" \
            > "/mnt/home/$USERNAME/.config/$_qs/wallpaper.conf"
        printf 'theme:aequalyn' > "/mnt/home/$USERNAME/.config/$_qs/theme.conf"
        chown "$UID_T:$GID_T" "/mnt/home/$USERNAME/.config/$_qs/theme.conf" \
            "/mnt/home/$USERNAME/.config/$_qs/wallpaper.conf"
    done
fi
chown "$UID_T:$GID_T" "/mnt/home/$USERNAME/.config/quickshell/wallpaper.conf"
 
# Make sure the installed user actually has the shipped themes (light and dark
# variants included) available, and that the active theme link points at the
# one this install starts on.
if [[ -d "$AEQUALYN_ROOT/themes" ]]; then
    mkdir -p "/mnt/home/$USERNAME/.local/share/aequalyn/themes"
    cp -r "$AEQUALYN_ROOT/themes/." "/mnt/home/$USERNAME/.local/share/aequalyn/themes/"
    chown -R "$UID_T:$GID_T" "/mnt/home/$USERNAME/.local/share/aequalyn/themes" 2>/dev/null || true
    mkdir -p "/mnt/home/$USERNAME/.config/aequalyn/current"
    ln -sfn /usr/share/aequalyn/themes/aequalyn "/mnt/home/$USERNAME/.config/aequalyn/current/theme"
    chown -h "$UID_T:$GID_T" "/mnt/home/$USERNAME/.config/aequalyn/current/theme" 2>/dev/null || true
fi
 
mkdir -p /mnt/usr/share/aequalyn /mnt/etc/aequalyn
chmod 755 /mnt/usr/share/aequalyn /mnt/etc/aequalyn 2>/dev/null || true
cp -r "$AEQUALYN_ROOT/." /mnt/usr/share/aequalyn/
# Make /usr/share/aequalyn a git repo tracking GitHub so aequalyn-update can
# pull updates later. remote add is local (no network), so offline installs
# still work; aequalyn-update fetches when the user runs it online.
if command -v git >/dev/null 2>&1 && [[ ! -d /mnt/usr/share/aequalyn/.git ]]; then
    git -C /mnt/usr/share/aequalyn init -q
    git -C /mnt/usr/share/aequalyn remote add origin https://github.com/Aequalyn/aequalyn.git
fi

# This machine starts at the ISO's own revision, which every migration in the
# tree already brought older systems to: running them here could only move it
# backwards (20261117-2, say, pins the shell revision that introduced
# Clipscape, and would roll a newer tree back to it). Mark them done so the
# first aequalyn-update runs none of them; a migration added to the tree
# after this ISO was built still runs, as it should.
MIGRATIONS_DONE=/mnt/var/lib/aequalyn/migrations.done
if [[ -d "$AEQUALYN_ROOT/migrations" ]]; then
    mkdir -p "$(dirname "$MIGRATIONS_DONE")"
    for m in "$AEQUALYN_ROOT"/migrations/*.sh; do
        [[ -e "$m" ]] || continue
        name=$(basename "$m")
        grep -qx "$name" "$MIGRATIONS_DONE" 2>/dev/null || printf '%s\n' "$name" >> "$MIGRATIONS_DONE"
    done
fi

# Console apps shipped on every install (btop, nudu) need a launcher entry
# that opens them in a terminal: their packages' own .desktop files either
# assume Terminal=true (btop) or are too old, so plant Aequalyn's versions
# that go through xdg-terminal-exec (foot/kitty/alacritty/ghostty, ...).
mkdir -p /mnt/usr/share/applications
cat > /mnt/usr/share/applications/btop.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Version=1.0
Name=btop++
GenericName=System Monitor
Comment=Resource monitor that shows usage and stats for processor, memory, disks, network and processes
Icon=btop
Exec=xdg-terminal-exec btop
Terminal=false
Categories=System;Monitor;ConsoleOnly;
Keywords=system;process;task;monitor;btop;
StartupNotify=false
DESKTOP
cat > /mnt/usr/share/applications/nudu.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=nudu
GenericName=Disk Usage Analyzer
Comment=See what is using your disk, in the terminal
Icon=nudu
Exec=xdg-terminal-exec nudu
Terminal=false
Categories=System;Utility;ConsoleOnly;
Keywords=disk;usage;du;space;storage;
StartupNotify=false
DESKTOP
chmod 644 /mnt/usr/share/applications/btop.desktop /mnt/usr/share/applications/nudu.desktop

# Provision agent skill folders (.agents, .claude, ...) for the new user so AI
# assistants can load Aequalyn's SKILL.md out of the box. Must run after the
# tree above has been copied into /usr/share/aequalyn.
if [[ -x /mnt/usr/share/aequalyn/bin/aequalyn-provision-user ]]; then
    arch-chroot /mnt runuser -u "$USERNAME" -- /usr/share/aequalyn/bin/aequalyn-provision-user >/dev/null 2>&1 || true
fi

# The qt5 dialog patch: plant its pacman hook, so a vlc installed any day
# after this one gets the fm's open/save dialogs the moment pacman finishes
# (the migration brings the same hook to installs made before it existed,
# but this machine is fresh, so here it is planted outright).
if [[ -x /mnt/usr/share/aequalyn/bin/aequalyn-qt5-dialogs ]]; then
    arch-chroot /mnt /usr/share/aequalyn/bin/aequalyn-qt5-dialogs --install-hook >/dev/null 2>&1 || true
fi

# Aequalyn FM is this desktop's file manager: give the new user the full
# registration -- its menu entry and icon, folders opening with it, and its
# own open/save dialogs behind the portal for every app that asks. The
# registrations are the launcher's own, run as the user so they land in
# their home (runuser keeps the caller's environment, so HOME goes along);
# a user who prefers another file manager switches in Settings, and the hook
# above keeps a qt5 vlc on the fm portal either way.
FM_REL="/home/$USERNAME/.config/quickshell/plugins/aequalynfm/bin/aequalyn-fm"
if [[ -x "/mnt$FM_REL" ]]; then
    arch-chroot /mnt runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" "$FM_REL" --default >/dev/null 2>&1 || true
    arch-chroot /mnt runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" "$FM_REL" --portal  >/dev/null 2>&1 || true
fi

cp "$CONFIG" /mnt/etc/aequalyn/install.toml
printf 'Aequalyn %s\n' "$(cat "$AEQUALYN_ROOT/VERSION" 2>/dev/null || echo 0.1.0)" > /mnt/etc/aequalyn/release

# Installer tools live in /usr/local/bin on the target so the installed user can
# run aequalyn-install / aequalyn-update / aequalyn-detect / aequalyn-repair
# after the system is installed. (aequalyn-update pulls /usr/share/aequalyn and
# re-applies dotfiles; see aequalyn-update --help.)
mkdir -p /mnt/usr/local/bin
for s in aequalyn-install aequalyn-update aequalyn-detect aequalyn-repair aequalyn-live-session; do
    [[ -f "$AEQUALYN_ROOT/installer/$s" ]] && cp "$AEQUALYN_ROOT/installer/$s" "/mnt/usr/local/bin/$s"
done
# aequalyn-provision-user lives in bin/, not installer/.
if [[ -f "$AEQUALYN_ROOT/bin/aequalyn-provision-user" ]]; then
    cp "$AEQUALYN_ROOT/bin/aequalyn-provision-user" "/mnt/usr/local/bin/aequalyn-provision-user"
fi
# aequalyn-ai-tool lives in bin/ too.
if [[ -f "$AEQUALYN_ROOT/bin/aequalyn-ai-tool" ]]; then
    cp "$AEQUALYN_ROOT/bin/aequalyn-ai-tool" "/mnt/usr/local/bin/aequalyn-ai-tool"
    chmod 755 "/mnt/usr/local/bin/aequalyn-ai-tool"
fi
# The root halves of the desktop's own commands, and what finishes the install later.
for s in aequalyn-browser-theme aequalyn-store aequalyn-gate-rules aequalyn-add-packages; do
    [[ -f "$AEQUALYN_ROOT/bin/$s" ]] && install -m 0755 "$AEQUALYN_ROOT/bin/$s" "/mnt/usr/local/bin/$s"
done
# The root half of Settings > Wi-Fi > Reveal password is pinned in Plugins.js
# at an absolute path; its source travels with the shell tree installed above.
AES_WIFI_SECRETS="/mnt/home/$USERNAME/.config/quickshell/tools/wifi/aequalyn-wifi-secrets"
if [[ -f "$AES_WIFI_SECRETS" ]]; then
    install -m 0755 "$AES_WIFI_SECRETS" /mnt/usr/local/bin/aequalyn-wifi-secrets
fi
# No password for what a theme change does as root (the rules name three checked commands).
arch-chroot /mnt /usr/local/bin/aequalyn-gate-rules || warn "theme changes will ask for the password"
# SDDM lock-screen themes + helper (live ISO ships a few in /usr/share/sddm/themes).
if [[ -f "$AEQUALYN_ROOT/bin/aequalyn-sddm" ]]; then
    cp "$AEQUALYN_ROOT/bin/aequalyn-sddm" "/mnt/usr/local/bin/aequalyn-sddm"
fi
if [[ -d /usr/share/sddm/themes ]]; then
    mkdir -p /mnt/usr/share/sddm/themes
    cp -r /usr/share/sddm/themes/. /mnt/usr/share/sddm/themes/ 2>/dev/null || true
fi
# The default SDDM theme ships with Aequalyn (assets/sddm/aequalyn); copy it
# from the bundled tree as well, so a fresh install always has the theme that
# /etc/sddm.conf.d/aequalyn-theme.conf points at even when the live image's
# /usr/share/sddm/themes is missing or incomplete.
if [[ -d "$AEQUALYN_ROOT/assets/sddm" ]]; then
    mkdir -p /mnt/usr/share/sddm/themes
    cp -r "$AEQUALYN_ROOT/assets/sddm/." /mnt/usr/share/sddm/themes/ 2>/dev/null || true
fi
# Make sure the default theme is actually present and readable.
if [[ -d "$AEQUALYN_ROOT/assets/sddm/aequalyn" ]]; then
    rm -rf /mnt/usr/share/sddm/themes/aequalyn
    mkdir -p /mnt/usr/share/sddm/themes/aequalyn
    cp -r "$AEQUALYN_ROOT/assets/sddm/aequalyn/." /mnt/usr/share/sddm/themes/aequalyn/ 2>/dev/null || true
    chmod -R 755 /mnt/usr/share/sddm/themes/aequalyn 2>/dev/null || true
fi
# SDDM theme fonts (qylock themes ship their own).
if [[ -d /usr/share/fonts/qylock ]]; then
    mkdir -p /mnt/usr/share/fonts/qylock
    cp -r /usr/share/fonts/qylock/. /mnt/usr/share/fonts/qylock/ 2>/dev/null || true
fi
# The default theme's own font.
if [[ -f "$AEQUALYN_ROOT/assets/sddm/aequalyn/Aequalyn-Regular.ttf" ]]; then
    mkdir -p /mnt/usr/share/fonts/aequalyn
    cp -f "$AEQUALYN_ROOT/assets/sddm/aequalyn/Aequalyn-Regular.ttf" /mnt/usr/share/fonts/aequalyn/ 2>/dev/null || true
    cp -f "$AEQUALYN_ROOT/assets/fonts/"*.ttf /mnt/usr/share/fonts/aequalyn/ 2>/dev/null || true
    fc-cache -f /mnt/usr/share/fonts 2>/dev/null || true
fi
# Plymouth boot splash theme is staged before the chroot, so the initramfs
# carries it and the calibrated bar; re-copying it here would reset the
# per-machine BOOT_SECONDS.
# Default SDDM theme: Aequalyn.
mkdir -p /mnt/etc/sddm.conf.d
chmod 755 /mnt/etc/sddm.conf.d 2>/dev/null || true
printf '[Theme]\nCurrent=aequalyn\n' > /mnt/etc/sddm.conf.d/aequalyn-theme.conf
chmod 644 /mnt/etc/sddm.conf.d/aequalyn-theme.conf 2>/dev/null || true
# Marker for the optional SDDM lock-screen theme pack: the Settings app only
# shows the Lock Screens page when this file exists.
if [[ "${AEQUALYN_INSTALL_LOCKSCREENS:-0}" == "1" ]]; then
    mkdir -p /mnt/usr/share/aequalyn
    chmod 755 /mnt/usr/share/aequalyn 2>/dev/null || true
    printf '1\n' > /mnt/usr/share/aequalyn/lockscreens.enabled
    chmod 644 /mnt/usr/share/aequalyn/lockscreens.enabled 2>/dev/null || true
fi
# The floating titlebar plugin only loads into the Hyprland it was made for: the one the ISO
# was made with is in vendor/hyprbars/built (copied with the rest above), and the first login
# takes it, or makes its own where the install got a newer Hyprland (aequalyn-hyprbars).
chmod 755 /mnt/usr/local/bin/aequalyn-* 2>/dev/null || true

# settings.json from [aequalyn] section. Browser theme sync is on for fresh
# installs so a theme change can publish its colour to the Chrome/Chromium
# policies; the root gate still asks before writing /etc.
python3 - "/mnt/home/$USERNAME/.config/aequalyn/settings.json" \
    "$THEME_MODE" "$THEME_APPS" "$BAR_HEIGHT" "$BAR_OPACITY" \
    "$BAR_LEFT" "$BAR_CENTER" "$BAR_RIGHT" <<'PY'
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {"version":1,"appearance":{},"hyprland":{}}
d.setdefault("appearance", {})
left, center, right = (sys.argv[6].split(), sys.argv[7].split(), sys.argv[8].split())
d["appearance"].update(themeMode=sys.argv[2],
                       themeApps=(sys.argv[3]=="true"),
                       themeBrowser=True,
                       barHeight=int(sys.argv[4]),
                       barOpacity=int(sys.argv[5]),
                       barLeft=left, barCenter=center, barRight=right,
                       pluginOrder=left + center + right)
# The installed dock pins the file manager, kitty and chromium (the apps that
# ship on every install). Aequalyn FM's desktop entry is registered above.
d.setdefault("dock", {})
d["dock"]["pinned"] = ["aequalyn.fm", "chromium", "kitty"]
open(p,"w").write(json.dumps(d, indent=2) + "\n")
PY
# settings.json above is only the seed. Once docks.json exists it is the
# authoritative pin list, so upgrades from an install that already has a dock
# would keep Nautilus and never gain the file manager. Add the pin to every
# existing dock here (the .desktop entry was registered above, otherwise the
# shell would prune it again after ~20s). A fresh home has no docks.json yet;
# DocksService seeds it from the settings.json written just above.
python3 - "/mnt/home/$USERNAME/.config/aequalyn/docks.json" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.isfile(p):
    raise SystemExit(0)
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit(0)
docks = d.get("docks")
if not isinstance(docks, list):
    raise SystemExit(0)
changed = False
for dock in docks:
    apps = dock.get("apps")
    if not isinstance(apps, list):
        continue
    if "aequalyn.fm" not in [str(a).removesuffix(".desktop") for a in apps]:
        apps.append("aequalyn.fm")
        dock["apps"] = apps
        changed = True
if changed:
    open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
# SDDM: autologin the installed user into the Aequalyn Wayland session
# (bin/aequalyn-session): with autologin on, log out starts a fresh desktop
# without the greeter, and Relogin stays off so a desktop that cannot start
# lands on the greeter instead of looping. Hyprland's own session file is the
# fallback when the Aequalyn one is missing.
for entry in aequalyn aequalyn-niri; do
    src=$AEQUALYN_ROOT/assets/wayland-sessions/$entry.desktop
    [[ -f $src ]] && install -Dm644 "$src" "/mnt/usr/share/wayland-sessions/$entry.desktop"
done
SDDM_SESSION=hyprland
case $COMPOSITOR in
    niri)     SDDM_SESSION=aequalyn-niri ;;
    both)     SDDM_SESSION=aequalyn ;;
    *)        [[ -f /mnt/usr/share/wayland-sessions/aequalyn.desktop ]] && SDDM_SESSION=aequalyn ;;
esac
mkdir -p /mnt/etc/sddm.conf.d
chmod 755 /mnt/etc/sddm.conf.d 2>/dev/null || true
printf '[Autologin]\nUser=%s\nSession=%s\nRelogin=false\n' "$USERNAME" "$SDDM_SESSION" \
    > /mnt/etc/sddm.conf.d/aequalyn-autologin.conf
chmod 644 /mnt/etc/sddm.conf.d/aequalyn-autologin.conf 2>/dev/null || true

# Enable the display manager in the target so the machine boots straight into
# the desktop. This must run inside the chroot: running it on the live ISO only
# touched the live system, leaving fresh installs booting to a console.
arch-chroot /mnt systemctl enable sddm.service 2>/dev/null \
    || warn "could not enable sddm.service; the installed system may boot to a console"

# With a display manager we don't need the .bash_profile desktop autostart;
# keep a bare one so a raw tty login still works as a fallback.
BP="/mnt/home/$USERNAME/.bash_profile"
[[ -f "$BP" ]] || printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' > "$BP"
if ! grep -q 'aequalyn: desktop on tty1' "$BP" 2>/dev/null; then
    cat >> "$BP" <<'EOF'

# aequalyn: desktop on tty1 (fallback when SDDM is not running)
if [[ -z ${WAYLAND_DISPLAY:-} && ${XDG_SESSION_TYPE:-tty} == tty && ${XDG_VTNR:-0} -eq 1 ]] && command -v aequalyn-desktop >/dev/null; then
    aequalyn-desktop
fi
EOF
fi

# Starts Hyprland; if it dies at once (a VM without 3D acceleration), retries
# with software rendering, then without atomic modesetting. Returns to the
# console if nothing works.
# The desktop's own commands (aequalyn-session-start, the bar's helpers) live
# in ~/.local/bin; Hyprland inherits PATH from the login shell.
cat > /mnt/etc/profile.d/aequalyn-path.sh <<'EOF'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF
cat > /mnt/usr/local/bin/aequalyn-desktop <<'EOF'
#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
launch() {
    if command -v start-hyprland >/dev/null 2>&1; then start-hyprland; else Hyprland; fi
}
t=$SECONDS; launch
(( SECONDS - t < 15 )) || exit 0
printf '\nThe desktop did not start with the GPU; trying software rendering...\n'
t=$SECONDS; LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe launch
(( SECONDS - t < 15 )) || exit 0
printf '\nTrying without atomic modesetting...\n'
AQ_NO_ATOMIC=1 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe launch
EOF
chmod 755 /mnt/usr/local/bin/aequalyn-desktop
chown -R "$UID_T:$GID_T" "/mnt/home/$USERNAME"

# First-boot helper: AUR set + regenerate colours for the installed user.
cat > /mnt/usr/local/bin/aequalyn-first-boot <<'EOF'
#!/usr/bin/env bash
set -u
C=/etc/aequalyn/install.toml
[[ -f "$C" ]] || exit 0

# Limine snapshot stack pre-built on the ISO and staged here by the installer.
# Installing these locally means offline installs still get snapshot boot
# entries; the AUR/network path below covers everything else.
shopt -s nullglob
for p in limine-mkinitcpio-hook limine-snapper-sync; do
    pacman -Q "$p" >/dev/null 2>&1 && continue
    for f in /var/cache/aequalyn-aur/$p-*.pkg.tar.zst; do
        pacman -U --noconfirm "$f" >/dev/null 2>&1 && break
    done
done

AUR=$(python3 -c 'import tomllib;print(tomllib.load(open("'$C'","rb")).get("packages",{}).get("aur",False))' 2>/dev/null || echo False)
if [[ "$AUR" == "True" ]] && ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
    if ! command -v yay >/dev/null 2>&1; then
        pacman -S --needed --noconfirm base-devel git >/dev/null 2>&1 || true
        su -c 'cd /tmp && git clone --depth 1 https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm' -s /bin/bash "$(id -un 1000)" >/dev/null 2>&1 || true
    fi
    # Boot-critical first, one at a time so a single dead download cannot
    # wedge the Limine snapshot stack; then the rest in one batch.
    for p in limine-mkinitcpio-hook limine-snapper-sync; do
        yay -S --needed --noconfirm "$p" >/dev/null 2>&1 || true
    done
    mapfile -t AUR_PKGS < <(sed -e 's/#.*//' /usr/share/aequalyn/packages/aur.packages | grep -v '^$' \
        | grep -vxE 'limine-mkinitcpio-hook|limine-snapper-sync')
    (( ${#AUR_PKGS[@]} )) && yay -S --needed --noconfirm "${AUR_PKGS[@]}" >/dev/null 2>&1 || true
fi
# Enable the snapshot boot-menu sync once its AUR unit is present.
if [[ -f /usr/lib/systemd/system/limine-snapper-sync.service ]]; then
    systemctl enable limine-snapper-sync.service >/dev/null 2>&1 || true
    systemctl enable snapper-cleanup.timer >/dev/null 2>&1 || true
fi
u=$(id -un 1000 2>/dev/null || true)
# colours from the wallpaper the install set (the Aequalyn theme's, or the sample
# one), without putting a different wallpaper on
[[ -n "$u" ]] && su - "$u" -c 'aequalyn-theme --refresh' >/dev/null 2>&1 || true
# Web apps are the Store's (its Web apps page manages them): the installer's
# seed_webapps flag plants the default set once, in the user's own home. The
# seed only writes what is not there yet -- anything the user removed stays
# removed -- and takes the browser the installer chose.
SEED_WA=$(python3 -c 'import tomllib;print(tomllib.load(open("'$C'","rb")).get("packages",{}).get("seed_webapps",False))' 2>/dev/null || echo False)
if [[ "$SEED_WA" == "True" && -n "$u" ]]; then
    WA_BROWSER=$(python3 -c 'import tomllib;print(tomllib.load(open("'$C'","rb")).get("packages",{}).get("browser","auto"))' 2>/dev/null || echo auto)
    su - "$u" -c "aequalyn-webapp seed --browser '$WA_BROWSER'" >/dev/null 2>&1 || true
fi
rm -f "$C"
systemctl disable aequalyn-first-boot.service >/dev/null 2>&1 || true
EOF
chmod 755 /mnt/usr/local/bin/aequalyn-first-boot
cat > /mnt/etc/systemd/system/aequalyn-first-boot.service <<'EOF'
[Unit]
Description=Aequalyn first-boot setup
After=network-online.target graphical.target
Wants=network-online.target
ConditionPathExists=/etc/aequalyn/install.toml
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aequalyn-first-boot
[Install]
WantedBy=multi-user.target
EOF
arch-chroot /mnt systemctl enable aequalyn-first-boot.service >/dev/null 2>&1 || true

# The built-in themes are not on the ISO (which has Aequalyn's own two): the installed
# system gets them the first time it has internet, quietly, then this unit retires.
mkdir -p /mnt/etc/aequalyn
touch /mnt/etc/aequalyn/builtin-themes.pending
cat > /mnt/etc/systemd/system/aequalyn-builtin-themes.service <<'EOF'
[Unit]
Description=Aequalyn built-in themes
After=network-online.target graphical.target
Wants=network-online.target
ConditionPathExists=/etc/aequalyn/builtin-themes.pending
[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/bash /usr/share/aequalyn/bin/aequalyn-builtin-themes --fetch
ExecStartPost=/usr/bin/rm -f /etc/aequalyn/builtin-themes.pending
Restart=on-failure
RestartSec=120
[Install]
WantedBy=graphical.target
EOF
arch-chroot /mnt systemctl enable aequalyn-builtin-themes.service >/dev/null 2>&1 || true

# What was chosen and could not be had during the install (a profile's apps, offline).
if (( ${#LATER[@]} )); then
    printf '%s\n' "${LATER[@]}" > /mnt/etc/aequalyn/packages.pending
    chmod 644 /mnt/etc/aequalyn/packages.pending
    cat > /mnt/etc/systemd/system/aequalyn-packages.service <<'EOF'
[Unit]
Description=Aequalyn: the apps chosen in the installer
After=network-online.target graphical.target aequalyn-pacman-online.service aequalyn-first-boot.service
Wants=network-online.target
ConditionPathExists=/etc/aequalyn/packages.pending
[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/bash /usr/local/bin/aequalyn-add-packages
Restart=on-failure
RestartSec=180
[Install]
WantedBy=graphical.target
EOF
    arch-chroot /mnt systemctl enable aequalyn-packages.service >/dev/null 2>&1 || true
    ok "${#LATER[@]} packages are added at the first start with internet"
fi

# Offline installs ship with SigLevel=Required but an uninitialised keyring and
# no package database sync. On the first boot that has internet, initialise the
# keyring, populate the Arch keys and sync the databases, then retire this unit.
if [[ $OFFLINE -eq 1 ]]; then
    mkdir -p /mnt/etc/aequalyn
    touch /mnt/etc/aequalyn/offline-install
    cat > /mnt/usr/local/bin/aequalyn-pacman-online <<'EOF'
#!/usr/bin/bash
set -u
MARKER=/etc/aequalyn/offline-install
[[ -f "$MARKER" ]] || exit 0

# Wait for connectivity (up to ~5 minutes).
for _ in $(seq 1 60); do
    ping -c1 -W2 archlinux.org >/dev/null 2>&1 && break
    sleep 5
done
ping -c1 -W2 archlinux.org >/dev/null 2>&1 || exit 0

pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true
pacman -Sy --noconfirm >/dev/null 2>&1 || true

rm -f "$MARKER"
systemctl disable aequalyn-pacman-online.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/aequalyn-pacman-online.service /usr/local/bin/aequalyn-pacman-online
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
EOF
    chmod 755 /mnt/usr/local/bin/aequalyn-pacman-online
    cat > /mnt/etc/systemd/system/aequalyn-pacman-online.service <<'EOF'
[Unit]
Description=Aequalyn offline-install pacman keyring and database sync
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/aequalyn/offline-install
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aequalyn-pacman-online
[Install]
WantedBy=multi-user.target
EOF
    arch-chroot /mnt systemctl enable aequalyn-pacman-online.service >/dev/null 2>&1 || true
    ok "offline pacman key/sync unit enabled"
fi
ok "Aequalyn desktop installed"

# ---------------------------------------------------------- permissions -------
# Re-assert traversable permissions right before unmounting: a restrictive
# umask or a later step can still leave /etc (and the SDDM config) unreadable
# by non-root users, which breaks D-Bus, the gate and SDDM autologin.
chmod 755 /mnt 2>/dev/null || true
chmod 755 /mnt/etc 2>/dev/null || true
for d in var home boot usr opt srv mnt tmp; do
    [[ -e /mnt/$d ]] || continue
    case "$d" in
        tmp) chmod 1777 /mnt/$d 2>/dev/null || true ;;
        root) chmod 700 /mnt/$d 2>/dev/null || true ;;
        *) chmod 755 /mnt/$d 2>/dev/null || true ;;
    esac
done
chmod 755 /mnt/etc/sddm.conf.d 2>/dev/null || true
chmod 755 /mnt/usr/share/sddm/themes 2>/dev/null || true
chmod -R 755 /mnt/usr/share/sddm/themes/aequalyn 2>/dev/null || true
# The desktop reads /usr/share/aequalyn/lockscreens.enabled with a watching
# FileView; a mode-700 directory makes that fail with "Permission denied".
chmod 755 /mnt/usr/share/aequalyn /mnt/etc/aequalyn 2>/dev/null || true
[[ -e /mnt/usr/share/aequalyn/lockscreens.enabled ]] \
    && chmod 644 /mnt/usr/share/aequalyn/lockscreens.enabled 2>/dev/null || true
# Re-assert here as well: later steps can recreate a cache/db dir under a
# restrictive umask, and an unreadable local db breaks pacman for users.
for d in /mnt/var/lib/pacman /mnt/var/lib/pacman/local /mnt/var/lib/pacman/sync \
         /mnt/var/cache/pacman /mnt/var/cache/pacman/pkg; do
    [[ -d $d ]] && chmod 755 "$d" 2>/dev/null || true
done
# Its version file above all: pacman, run by a user who cannot read it, says the database is of
# an incorrect version and ends with 255.
[[ -f /mnt/var/lib/pacman/local/ALPM_DB_VERSION ]] && chmod 644 /mnt/var/lib/pacman/local/ALPM_DB_VERSION 2>/dev/null || true
# Same trap as aequalyn-browser-theme itself: the managed-policy dirs for the
# Chromium-family browsers must be readable by the installed desktop user. A
# restrictive umask during pacstrap/package install leaves them 0700, so the
# 0644 color.json is unreachable and every theme change re-asks for the gate.
for d in /mnt/etc/opt /mnt/etc/chromium /mnt/etc/brave /mnt/etc/vivaldi \
         /mnt/etc/yandex-browser; do
    [[ -d $d ]] && chmod 755 "$d" 2>/dev/null || true
done
for d in /mnt/etc/opt/* /mnt/etc/chromium/* /mnt/etc/brave/* /mnt/etc/vivaldi/* \
         /mnt/etc/yandex-browser/*; do
    [[ -d $d ]] && chmod 755 "$d" 2>/dev/null || true
done
for d in /mnt/etc/opt/*/policies/managed /mnt/etc/chromium/policies/managed \
         /mnt/etc/brave/policies/managed /mnt/etc/vivaldi/policies/managed \
         /mnt/etc/yandex-browser/policies/managed; do
    [[ -d $d ]] || continue
    chmod 755 "$d" 2>/dev/null || true
    [[ -f $d/color.json ]] && chmod 644 "$d/color.json" 2>/dev/null || true
done

# ---------------------------------------------------------- cleanup ----------
cp "$LOGFILE" /mnt/var/log/aequalyn-install.log 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if [[ "$ENCRYPT" == "true" ]]; then cryptsetup close aequalyn_root 2>/dev/null || true; fi
ok "filesystems unmounted"
