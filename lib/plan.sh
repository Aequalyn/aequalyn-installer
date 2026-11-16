#!/usr/bin/env bash
# aequalyn-install :: plan -- preview what lib/apply.sh will do to a disk.
#
#   plan.sh DISK MODE EFI_MB ENCRYPT(0|1)
#
# Read-only: nothing is written. The arithmetic mirrors apply.sh (fullwipe,
# dualboot, manual) so the preview shows the same partitions the install makes.
#
# Output, one record per line, tab-separated:
#   cur    NAME SIZE_GIB FSTYPE LABEL   an existing partition, kept or erased
#   plan   TEXT                         a change apply.sh will make
#   warn   TEXT                         data loss or something to check first
#   block  TEXT                         apply.sh would refuse: fix before installing
set -uo pipefail

DISK=${1:-}; MODE=${2:-fullwipe}; EFI_MB=${3:-2048}; ENC=${4:-0}
[[ -n "$DISK" && -b "$DISK" ]] || { printf 'block\tno such disk: %s\n' "$DISK"; exit 0; }

GIB=1073741824
MIB=1048576
gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# Existing partitions first, so the table in the GUI reflects the disk as it is.
parts=0
last_num=0
field() { sed -n "s/.*\b$1=\"\([^\"]*\)\".*/\1/p" <<<"$2"; }
while IFS= read -r row; do
    [[ "$(field TYPE "$row")" == part ]] || continue
    parts=$((parts + 1))
    name=$(field NAME "$row")
    size=$(field SIZE "$row")
    fstype=$(field FSTYPE "$row")
    label=$(field PARTLABEL "$row")
    printf 'cur\t%s\t%s\t%s\t%s\n' "$name" "$(gib "$size")" "${fstype:--}" "${label:--}"
done < <(lsblk -bpnP -o NAME,TYPE,SIZE,FSTYPE,PARTLABEL "$DISK" 2>/dev/null)
last_num=$(lsblk -n -o PARTN "$DISK" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
last_num=${last_num:-0}

disk_bytes=$(lsblk -bdno SIZE "$DISK" 2>/dev/null | head -1)
disk_bytes=${disk_bytes:-0}
efi_b=$((EFI_MB * MIB))
enc_note=""
[[ "$ENC" == 1 ]] && enc_note=" (LUKS2 encrypted)"

case "$MODE" in
fullwipe)
    if (( parts > 0 )); then
        printf 'warn\tERASE: all %d existing partition(s) on %s are deleted, with their data\n' "$parts" "$DISK"
    fi
    printf 'plan\tcreate a new GPT partition table on %s\n' "$DISK"
    printf 'plan\tpartition 1: EFI system partition, FAT32, label AEQUALYN_EFI, %s MiB (%s GiB)\n' "$EFI_MB" "$(gib "$efi_b")"
    printf 'plan\tpartition 2: Btrfs root, label AEQUALYN_ROOT, rest of the disk (%s GiB)%s\n' \
        "$(gib $((disk_bytes - efi_b)))" "$enc_note"
    ;;

dualboot)
    # Largest free region, same rule as apply.sh: it needs at least 12 GiB.
    free=$(parted -m "$DISK" unit B print free 2>/dev/null | \
        awk -F: '$NF ~ /free/ { gsub(/B/, "", $2); gsub(/B/, "", $4); if ($4 + 0 > m + 0) { m = $4 + 0; s = $2 } } END { if (m > 0) printf "%s %.0f", s, m }' || true)
    free_start=$(awk '{print $1}' <<<"$free" | tr -d ' ')
    free_bytes=$(awk '{print $2}' <<<"$free" | tr -d ' ')
    free_bytes=${free_bytes:-0}
    if (( parts == 0 )); then
        printf 'block\t%s has no partition table; dual boot needs existing partitions (use Erase disk)\n' "$DISK"
    elif (( free_bytes < 12 * GIB )); then
        printf 'block\tlargest unallocated region on %s is %s GiB; dual boot needs 12 GiB. Free space in Windows (Disk Management) first\n' \
            "$DISK" "$(gib "$free_bytes")"
    else
        printf 'plan\tkeep all %d existing partition(s) unchanged\n' "$parts"
        printf 'plan\tpartition %d: EFI system partition, FAT32, label AEQUALYN_EFI, %s MiB, at the start of the free region\n' \
            $((last_num + 1)) "$EFI_MB"
        printf 'plan\tpartition %d: Btrfs root, label AEQUALYN_ROOT, rest of the free region (%s GiB)%s\n' \
            $((last_num + 2)) "$(gib $((free_bytes - efi_b)))" "$enc_note"
        printf 'plan\tWindows boot stays on its own EFI partition; Limine is added to the new one\n'
    fi
    ;;

manual)
    printf 'plan\tthe partition table on %s is not changed\n' "$DISK"
    printf 'plan\tEFI and root are the partitions named in [disk] (efi_device, root_device)\n'
    ;;

*)
    printf 'block\tunknown mode: %s\n' "$MODE"
    ;;
esac
