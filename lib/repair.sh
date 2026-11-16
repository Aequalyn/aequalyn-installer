#!/usr/bin/env bash
# aequalyn-install :: repair -- non-interactive backend for the GUI Repair flow.
#
#   repair.sh probe DISK               print ENCRYPTED, ROOT, ESP for DISK
#   repair.sh mount DISK               unlock (passphrase on stdin when LUKS) and mount on /mnt
#   repair.sh run KEYRING              reinitialise archlinux-keyring inside /mnt
#   repair.sh run KERNEL               reinstall linux and rebuild the initramfs inside /mnt
#   repair.sh run BOOTLOADER DISK      reinstall Limine inside /mnt
#   repair.sh unmount                  unmount /mnt and close the LUKS mapping
#
# Everything runs as root from the live ISO. Output is plain text so the GUI can
# show it as the live arch-chroot log.
set -euo pipefail

MNT=/mnt
CRYPT=cryptroot
ESP_LABEL=AEQUALYN

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# Partitions of DISK as "NAME SIZE FSTYPE", largest first.
partitions() {
    local disk=$1 name type size fstype
    while read -r name type size fstype; do
        [[ "$type" == part ]] || continue
        printf '%s %s %s\n' "$name" "$size" "${fstype:-}"
    done < <(lsblk -npbl -o NAME,TYPE,SIZE,FSTYPE "$disk")
}

# Print ENCRYPTED, ROOT and ESP for DISK. ENCRYPTED=1 when a LUKS partition
# exists; ROOT is the largest LUKS (or btrfs/ext4/xfs) partition.
probe() {
    local disk=$1 name size fstype
    local luks="" fs="" esp=""
    while read -r name size fstype; do
        case "$fstype" in
            crypto_LUKS) luks=${luks:+$luks$'\n'}"$name $size" ;;
            btrfs|ext4|xfs) fs=${fs:+$fs$'\n'}"$name $size" ;;
        esac
        if [[ "$fstype" == vfat ]] && [[ "$(lsblk -no LABEL "$name" 2>/dev/null)" == "$ESP_LABEL" ]]; then
            esp=$name
        fi
    done < <(partitions "$disk")

    local root="" encrypted=0
    if [[ -n "$luks" ]]; then
        encrypted=1
        root=$(sort -k2,2nr <<< "$luks" | head -n1 | awk '{print $1}')
    elif [[ -n "$fs" ]]; then
        root=$(sort -k2,2nr <<< "$fs" | head -n1 | awk '{print $1}')
    fi
    [[ -n "$root" ]] || die "no Linux root partition found on $disk"

    echo "ENCRYPTED=$encrypted"
    echo "ROOT=$root"
    echo "ESP=${esp:-}"
}

unmount_all() {
    umount -R "$MNT" 2>/dev/null || true
    if [[ -e "/dev/mapper/$CRYPT" ]]; then
        cryptsetup close "$CRYPT" 2>/dev/null || true
    fi
}

value() { sed -n "s/^$1=//p" <<< "$2"; }

do_mount() {
    local disk=$1
    local info root esp encrypted dev fstype
    info=$(probe "$disk")
    encrypted=$(value ENCRYPTED "$info")
    root=$(value ROOT "$info")
    esp=$(value ESP "$info")

    say "Target: $root (encrypted: $([[ $encrypted == 1 ]] && echo yes || echo no))"
    unmount_all
    mkdir -p "$MNT"

    if [[ "$encrypted" == 1 ]]; then
        local pass=""
        IFS= read -r pass || true
        [[ -n "$pass" ]] || die "passphrase required for $root"
        say "Unlocking $root"
        printf '%s' "$pass" | cryptsetup open --key-file=- "$root" "$CRYPT" \
            || die "could not unlock $root (wrong passphrase?)"
        dev="/dev/mapper/$CRYPT"
    else
        dev=$root
    fi

    fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "")
    case "$fstype" in
        btrfs)
            say "Mounting @ on $MNT"
            mount -o noatime,compress=zstd,subvol=@ "$dev" "$MNT" \
                || die "no @ subvolume on $dev; mount the root subvolume manually"
            local pair sub dest
            for pair in "@home:home" "@var:var" "@log:var/log" "@pkg:var/cache/pacman/pkg" \
                        "@.snapshots:.snapshots" "@root:root"; do
                sub=${pair%%:*}
                dest="$MNT/${pair#*:}"
                mkdir -p "$dest"
                if mount -o noatime,compress=zstd,subvol="$sub" "$dev" "$dest" 2>/dev/null; then
                    say "Mounted $sub on ${dest#"$MNT"}"
                else
                    echo "WARNING: subvolume $sub not found, skipped" >&2
                fi
            done
            ;;
        ext4|xfs)
            say "Mounting $fstype filesystem on $MNT"
            mount "$dev" "$MNT"
            ;;
        *)
            die "unsupported filesystem on $dev: ${fstype:-none}"
            ;;
    esac

    if [[ -n "$esp" ]]; then
        mkdir -p "$MNT/boot"
        mount "$esp" "$MNT/boot"
        say "Mounted EFI system partition $esp on /boot"
    else
        echo "WARNING: no $ESP_LABEL EFI partition found; /boot not mounted" >&2
    fi
    say "Mount complete"
}

do_run() {
    mountpoint -q "$MNT" || die "$MNT is not mounted; mount the system first"
    local what=$1 disk=${2:-}
    case "$what" in
        KEYRING)
            say "Reinitialising archlinux-keyring"
            arch-chroot "$MNT" bash -c '
                set -e
                rm -rf /etc/pacman.d/gnupg
                pacman-key --init
                pacman-key --populate archlinux
                pacman -Sy --noconfirm archlinux-keyring
            '
            ;;
        KERNEL)
            say "Reinstalling linux kernel"
            arch-chroot "$MNT" bash -c '
                set -e
                pacman -S --noconfirm linux
                # limine-mkinitcpio-hook replaces mkinitcpio with a wrapper that
                # prompts "run limine-mkinitcpio now?" after -P. With no TTY in
                # arch-chroot that read blocks forever, so call the non-interactive
                # limine-mkinitcpio directly. It rebuilds the initramfs and the
                # Limine kernel entries. Fall back to plain mkinitcpio otherwise.
                if command -v limine-mkinitcpio >/dev/null 2>&1; then
                    limine-mkinitcpio
                else
                    /usr/bin/mkinitcpio -P
                fi
            '
            ;;
        BOOTLOADER)
            [[ -n "$disk" ]] || die "bootloader repair needs the disk"
            say "Reinstalling Limine bootloader"
            local uefi=0
            [[ -d /sys/firmware/efi ]] && uefi=1
            arch-chroot "$MNT" bash -c "
                set -e
                pacman -S --noconfirm limine
                if [[ $uefi == 1 ]]; then
                    mkdir -p /boot/EFI/limine /boot/EFI/BOOT
                    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
                    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
                else
                    cp /usr/share/limine/limine-bios.sys /boot/
                    limine bios-install '$disk'
                fi
                if command -v limine-update >/dev/null 2>&1; then limine-update; fi
            "
            ;;
        *)
            die "unknown repair: $what"
            ;;
    esac
    say "Done: $what"
}

case "${1:-}" in
    probe)    [[ $# -ge 2 ]] || die "usage: repair.sh probe DISK"; probe "$2" ;;
    mount)    [[ $# -ge 2 ]] || die "usage: repair.sh mount DISK"; do_mount "$2" ;;
    run)      [[ $# -ge 2 ]] || die "usage: repair.sh run NAME [DISK]"; do_run "$2" "${3:-}" ;;
    unmount)  unmount_all; say "Unmounted $MNT"; ;;
    *)        die "usage: repair.sh probe|mount|run|unmount ..." ;;
esac
