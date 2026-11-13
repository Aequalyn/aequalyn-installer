#!/usr/bin/env bash
# aequalyn-install :: apply -- deterministic executor for install.toml.
# Called by aequalyn-install after the user has approved the config. Never asks
# interactive questions; everything comes from the config + the password arg.
set -euo pipefail

CONFIG=$1
PASSWORD=$2
LOGFILE=${3:-/root/aequalyn-install.log}
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
FLATPAK=${PACKAGES_FLATPAK:-false}
AUR=${PACKAGES_AUR:-false}
EXTRA=${PACKAGES_EXTRA:-}
EDITOR=${PACKAGES_EDITOR:-nano}
SNAPSHOT_BEFORE=${AGENT_SNAPSHOT_BEFORE:-true}
THEME_MODE=${AEQUALYN_THEME_MODE:-wallpaper}
THEME_APPS=${AEQUALYN_THEME_APPS:-true}
BAR_HEIGHT=${AEQUALYN_BAR_HEIGHT:-32}
BAR_OPACITY=${AEQUALYN_BAR_OPACITY:-100}

[[ $EUID -eq 0 ]] || abort "must run as root"
# UEFI is the main target; legacy BIOS (VMs that default to it, such as GNOME
# Boxes, older PCs) gets Limine's BIOS stage on a full-disk GPT install.
if [[ -d /sys/firmware/efi ]]; then FIRMWARE=uefi; else FIRMWARE=bios; fi
if [[ $FIRMWARE == bios && "$MODE" != fullwipe ]]; then
    abort "booted in legacy BIOS mode: only a full-disk install is supported (boot in UEFI mode for dual boot)"
fi
info "firmware: $FIRMWARE"
[[ -n "$DISK" && -b "$DISK" ]] || abort "invalid or missing [disk].device: $DISK"

# Never touch the device the ISO booted from.
BOOT_SRC=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
if [[ -n "$BOOT_SRC" ]]; then
    d="$BOOT_SRC"
    while :; do
        parent=$(lsblk -dno PKNAME "$d" 2>/dev/null | tail -1 || true)
        [[ -n "$parent" ]] || break
        d="/dev/$parent"
    done
    [[ "$DISK" == "$d" ]] && abort "refusing to install onto the live USB ($d)"
fi

# ---------------------------------------------------------- package source ---
OFFLINE_REPO="/var/cache/offline-repo"
OFFLINE=0
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
    ping -c 1 -W 2 archlinux.org >/dev/null 2>&1 || abort "no internet and no offline repo"
    ok "using online Arch mirrors"
fi

# ---------------------------------------------------------- package list -----
read_list() { # read_list <file> -> package names
    [[ -f "$1" ]] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

PKGS=()
PKGS+=($(read_list "$AEQUALYN_ROOT/packages/base.packages"))
PKGS+=($(read_list "$AEQUALYN_ROOT/packages/desktop.packages"))

# Hardware conditionals (L1 detection, no AI)
# aequalyn-detect --shell emits shell-safe `KEY=%q` lines (see its header),
# so source them instead of parsing with sed/tr, which would leave the
# backslash-escapes from %q attached to multi-word values such as
# "nvidia-open nvidia-utils" (bug: "target not found: nvidia-open\\").
DET_ENV=$(mktemp)
bash "$AEQUALYN_ROOT/installer/aequalyn-detect" --shell > "$DET_ENV"
# shellcheck disable=SC1090
. "$DET_ENV"
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

case "$BROWSER" in
    firefox) PKGS+=(firefox) ;;
    zen)     PKGS+=(chromium); warn "Zen Browser is an AUR package; installed post-boot when online" ;;
    *)       PKGS+=(chromium) ;;
esac
# Do not ship two browsers: drop the one that was not selected.
if [[ "$BROWSER" != "chromium" && "$BROWSER" != "zen" ]]; then
    PKGS=("${PKGS[@]/chromium/}")
fi
if [[ "$BROWSER" != "firefox" ]]; then
    PKGS=("${PKGS[@]/firefox/}")
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
        if compgen -G "$OFFLINE_REPO/${p}-[0-9]*.pkg.tar.zst" >/dev/null; then
            FILTERED+=("$p")
        else
            warn "dropping $p (not in offline repo)"
        fi
    done
    PKGS=("${FILTERED[@]}")
else
    mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -v '^$' | sort -u)
fi
ok "packages to install: ${#PKGS[@]}"

# ---------------------------------------------------------- snapshot ---------
if [[ "$SNAPSHOT_BEFORE" == "true" ]]; then
    bash "$AEQUALYN_ROOT/bin/aequalyn-snapshot" "$DISK" || warn "pre-install snapshot skipped"
fi

# ---------------------------------------------------------- partitioning -----
part_num() { # part_num <device> <n> -> nvme/mmcblk need a 'p'
    local dev=$1 n=$2
    [[ "$dev" == *nvme* || "$dev" == *mmcblk* ]] && printf '%sp%s' "$dev" "$n" || printf '%s%s' "$dev" "$n"
}

WIN_EFI=""
for p in $(blkid -t TYPE=vfat -o device 2>/dev/null || true); do
    mp=$(mktemp -d)
    if mount -o ro "$p" "$mp" 2>/dev/null; then
        [[ -d "$mp/EFI/Microsoft" ]] && WIN_EFI="$p"
        umount "$mp" 2>/dev/null || true
    fi
    rmdir "$mp" 2>/dev/null || true
    [[ -n "$WIN_EFI" ]] && break
done

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
else # dualboot
    FREE=$(parted -m "$DISK" unit B print free 2>/dev/null | \
        awk -F: '$NF ~ /free/ {gsub(/B/,"",$2);gsub(/B/,"",$3);gsub(/B/,"",$4); if($4+0>m+0){m=$4+0;s=$2;e=$3}} END{if(m>0) printf "%s %s %s",s,e,m}' || true)
    START_B=$(awk '{print $1}' <<<"$FREE")
    END_B=$(awk '{print $2}' <<<"$FREE")
    SIZE_B=$(awk '{print $3}' <<<"$FREE")
    [[ -n "$FREE" && "$SIZE_B" -ge $((12*1073741824)) ]] || \
        abort "no free region >= 12 GiB on $DISK (shrink a partition first)"
    LAST=$(lsblk -n -o PARTN "$DISK" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
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

mkfs.fat -F32 -n AEQUALYN "$EFI_DEV" >/dev/null
udevadm settle
mount "$EFI_DEV" /mnt/boot
ok "filesystems ready (btrfs: ${SUBVOLS[*]})"

# Chainload Windows bootloader into our ESP
if [[ "$MODE" == "dualboot" && -n "$WIN_EFI" && "$WIN_EFI" != "$EFI_DEV" ]]; then
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

if [[ "$ENCRYPT" == "true" ]]; then
    printf 'aequalyn_root UUID=%s none luks,discard\n' "$LUKS_UUID" >> /mnt/etc/crypttab
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

# ---------------------------------------------------------- chroot -----------
info "configuring system in chroot ..."
cat > /mnt/setup.sh <<'CHROOT'
#!/usr/bin/bash
set -euo pipefail
trap 'echo "setup.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR
source /pwhash.env
rm -f /pwhash.env

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
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
else
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block filesystems fsck)/' /etc/mkinitcpio.conf
fi
printf 'COMPRESSION="zstd"\n' >> /etc/mkinitcpio.conf
mkinitcpio -P

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
bash "$AEQUALYN_ROOT/install.sh" --target "/mnt/home/$USERNAME" --owner "$UID_T:$GID_T"
# install.sh sees the live-ISO mount path; rewrite it for the installed system.
printf '/home/%s/Pictures/Wallpapers/beach.jpg' "$USERNAME" \
    > "/mnt/home/$USERNAME/.config/quickshell/wallpaper.conf"
chown "$UID_T:$GID_T" "/mnt/home/$USERNAME/.config/quickshell/wallpaper.conf"

mkdir -p /mnt/usr/share/aequalyn /mnt/etc/aequalyn
cp -r "$AEQUALYN_ROOT/." /mnt/usr/share/aequalyn/
# Make /usr/share/aequalyn a git repo tracking GitHub so aequalyn-update can
# pull updates later. remote add is local (no network), so offline installs
# still work; aequalyn-update fetches when the user runs it online.
if command -v git >/dev/null 2>&1 && [[ ! -d /mnt/usr/share/aequalyn/.git ]]; then
    git -C /mnt/usr/share/aequalyn init -q
    git -C /mnt/usr/share/aequalyn remote add origin https://github.com/Aequalyn/aequalyn.git
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
chmod 755 /mnt/usr/local/bin/aequalyn-* 2>/dev/null || true

# settings.json from [aequalyn] section
python3 - "/mnt/home/$USERNAME/.config/aequalyn/settings.json" "$THEME_MODE" "$THEME_APPS" "$BAR_HEIGHT" "$BAR_OPACITY" <<'PY'
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {"version":1,"appearance":{},"hyprland":{}}
d.setdefault("appearance", {})
d["appearance"].update(themeMode=sys.argv[2],
                       themeApps=(sys.argv[3]=="true"),
                       barHeight=int(sys.argv[4]),
                       barOpacity=int(sys.argv[5]))
open(p,"w").write(json.dumps(d, indent=2) + "\n")
PY
# SDDM: autologin the installed user into the Aequalyn Wayland session.
mkdir -p /mnt/etc/sddm.conf.d
cat > /mnt/etc/sddm.conf.d/aequalyn-autologin.conf <<'SDDM'
[Autologin]
User=__USERNAME__
Session=aequalyn
Relogin=false
SDDM

# Enable the display manager so the machine boots straight into the desktop.
systemctl enable sddm.service 2>/dev/null || true

# With a display manager we don't need the .bash_profile desktop autostart;
# keep a bare one so a raw tty login still works as a fallback.
BP="/mnt/home/$USERNAME/.bash_profile"
[[ -f "$BP" ]] || printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' > "$BP"
if ! grep -q 'aequalyn: desktop on tty1' "$BP" 2>/dev/null; then
    cat >> "$BP" <<'EOF'

# aequalyn: desktop on tty1 (fallback when SDDM is not running)
if [[ -z ${WAYLAND_DISPLAY:-} && ${XDG_VTNR:-0} -eq 1 ]] && command -v aequalyn-desktop >/dev/null; then
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
[[ -n "$u" ]] && su - "$u" -c 'aequalyn-theme "$HOME/Pictures/Wallpapers/beach.jpg"' >/dev/null 2>&1 || true
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
ok "Aequalyn desktop installed"

# ---------------------------------------------------------- cleanup ----------
cp "$LOGFILE" /mnt/var/log/aequalyn-install.log 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if [[ "$ENCRYPT" == "true" ]]; then cryptsetup close aequalyn_root 2>/dev/null || true; fi
ok "filesystems unmounted"
