#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd 7z lsblk blockdev find du date; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' is not installed."
        exit 1
    fi
done

# How many MiB of the image head to extract during pre-flight, just enough to reach
# GPT's LBA0..LBA33 (512 B sectors) and MBR. 8 MiB covers both comfortably.
PREFLIGHT_HEAD_MIB=8

echo ""
echo "========================================"
bold "       FULL DISK RESTORE (7z + dd)      "
echo "========================================"
echo ""

pick_archive "Select a backup to restore:"

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    err "File '$SRC_ARCHIVE' not found."
    exit 1
fi

# Detect type from filename suffix.
case "$SRC_ARCHIVE" in
    *.part.img.7z)  SRC_TYPE="part" ;;
    *.disk.img.7z)  SRC_TYPE="disk" ;;
    *)              SRC_TYPE="disk" ;;  # fallback for legacy .img.7z / .7z names
esac

echo ""
info "Selected: ${C_BOLD}$SRC_ARCHIVE${C_RESET}"

# Ask for the destination FIRST (before any 7z work), so you can abort early if you picked
# the wrong archive without waiting through pre-flight / password prompts.
echo ""
info "Available target drives:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
echo "----------------------------------------"

if [[ "$SRC_TYPE" == "part" ]]; then
    read -rp "Enter the TARGET partition to overwrite (e.g., /dev/sda1): " DEST_DEVICE
else
    read -rp "Enter the TARGET drive to overwrite (e.g., /dev/nvme0n1 or /dev/sda): " DEST_DEVICE
fi

if [[ ! -b "$DEST_DEVICE" ]]; then
    err "'$DEST_DEVICE' is not a valid block device."
    exit 1
fi

# Type-mismatch guard: partition image → partition target, disk image → whole-disk target.
parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$(basename "${DEST_DEVICE%/}")" '$2==x{print $1; exit}')
if [[ "$SRC_TYPE" == "part" && -z "$parent" ]]; then
    err "'$DEST_DEVICE' is a whole disk. A partition image must be restored to a PARTITION (e.g., /dev/sda1)."
    exit 1
fi
if [[ "$SRC_TYPE" == "disk" && -n "$parent" ]]; then
    err "'$DEST_DEVICE' is a partition of /dev/$parent. A whole-disk image must be restored to a WHOLE DISK (e.g., /dev/sda)."
    exit 1
fi

# Ask for the password ONCE, up front. Everything after this streams (no temp file); the
# secret is only ever needed to feed 7z's decode, so we hold it in $PASS for the run.
read -rsp "Enter backup password (blank if none): " PASS
echo

# --- Pre-flight: stream-decode just the first PREFLIGHT_HEAD_MIB MiB and confirm a
# partition table is present, BEFORE we overwrite anything. No writes yet. ---
preflight() {
    local archive="$1" pass="$2"
    echo ""
    info "Pre-flight checks (no writes yet)..."

    # Stream the decoded head to a small temp file (only PREFLIGHT_HEAD_MIB MiB, not the
    # whole image). Run in background so pipefail/SIGPIPE can't trip set -e; judge by size.
    local head_bytes=$(( PREFLIGHT_HEAD_MIB * 1024 * 1024 ))
    local tmp_head
    tmp_head=$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")
    { 7z x -so -p"$pass" -bso0 -bsp0 "$archive" 2>/dev/null | head -c "$head_bytes" > "$tmp_head"; } &
    wait
    if [[ ! -s "$tmp_head" ]]; then
        err "Failed to decode the first ${PREFLIGHT_HEAD_MIB} MiB of '$archive'."
        echo "       (wrong password, or corrupt archive)"
        rm -f -- "$tmp_head"
        return 1
    fi

    # Inspect bytes 0..512 for GPT / MBR signatures.
    local gpt_sig mbr_sig
    gpt_sig=$(dd if="$tmp_head" bs=1 skip=512 count=8 status=none | od -An -tx1 | tr -d ' \n')
    mbr_sig=$(dd if="$tmp_head" bs=1 skip=446 count=2 status=none | od -An -tx1 | tr -d ' \n')

    local found=0
    # GPT: "EFI PART" at offset 512 (bytes 45 46 49 20 50 41 52 54).
    if [[ "$gpt_sig" == "4546492050415254" ]]; then found=1; ok "GPT signature ('EFI PART') present at offset 512."; fi
    # MBR: boot signature 0x55AA at offset 446.
    if [[ "$mbr_sig" == "55aa" ]]; then found=1; ok "MBR boot signature (0x55AA) present at offset 446."; fi

    rm -f -- "$tmp_head"

    if (( found == 0 )); then
        if [[ "$SRC_TYPE" == "part" ]]; then
            info "No partition-table signature in head (expected for a partition image)."
        else
            warn "No GPT/MBR partition-table signature found in the image head."
            echo "         The image may be a raw disk without a table, or not a standard layout."
        fi
    fi
    return 0
}

if ! preflight "$SRC_ARCHIVE" "$PASS"; then
    exit 1
fi

# Uncompressed size from archive metadata (header-only; no decompression).
UNCOMPRESSED_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')

ARCHIVE_DEV=$(df --output=source "$SRC_ARCHIVE" | tail -n 1)
if [[ "$ARCHIVE_DEV" == "$DEST_DEVICE"* ]]; then
    err "Target device '$DEST_DEVICE' contains the backup file itself! Aborting."
    exit 1
fi

# Writing to a disk with live mounts is destructive and unsafe — require unmounting.
if ! ensure_unmounted "$DEST_DEVICE"; then
    err "Target device '$DEST_DEVICE' still has mounted partitions. Unmount them first."
    exit 1
fi

TARGET_BYTES=$(blockdev --getsize64 "$DEST_DEVICE")

# Size check: partition images require EXACT match, disk images must fit.
if [[ "$SRC_TYPE" == "part" ]]; then
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -ne "$TARGET_BYTES" ]]; then
        err "Image size ($UNCOMPRESSED_BYTES B) does not EXACTLY match target partition size ($TARGET_BYTES B)."
        echo "       Partition backups require an exact-size match to preserve filesystem end-metadata."
        exit 1
    fi
else
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
        err "Backup image ($UNCOMPRESSED_BYTES bytes) is larger than target drive ($TARGET_BYTES bytes)."
        exit 1
    fi
fi

echo ""
printf "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!${C_RESET}\n"
if [[ "$SRC_TYPE" == "part" ]]; then
    printf "${C_RED}${C_BOLD}ALL DATA ON %s WILL BE PERMANENTLY ERASED!${C_RESET}\n" "$DEST_DEVICE"
else
    printf "${C_RED}${C_BOLD}ALL DATA ON %s (%s) WILL BE PERMANENTLY ERASED!${C_RESET}\n" "$DEST_DEVICE" "$(lsblk -dn -o SIZE,MODEL "$DEST_DEVICE")"
fi
echo "Source Archive : $SRC_ARCHIVE"
if [[ "$SRC_TYPE" == "part" ]]; then
    echo "Target Partition: ${C_BOLD}$DEST_DEVICE${C_RESET}"
else
    echo "Target Drive   : ${C_BOLD}$DEST_DEVICE${C_RESET}"
fi
printf "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}\n"
read -rp "To confirm, type the exact target device path ($DEST_DEVICE): " CONFIRM_DEV
if [[ "$CONFIRM_DEV" != "$DEST_DEVICE" ]]; then
    warn "Device path did not match. Restore cancelled."
    exit 0
fi

echo ""
info "Restoring image... Do NOT interrupt or power off."

# Stream-decode straight to the target device (no temp file). -bso0/-bsp0 keep 7z from
# clobbering dd's progress line; pv shows throughput against the known total size.
if command -v pv &>/dev/null && [[ -n "$UNCOMPRESSED_BYTES" ]]; then
    7z x -so -p"$PASS" -bso0 -bsp0 "$SRC_ARCHIVE" | pv -s "$UNCOMPRESSED_BYTES" "${PV_OPTS[@]}" | dd of="$DEST_DEVICE" bs=$DD_BS status=none iflag=fullblock oflag=direct
else
    7z x -so -p"$PASS" -bso0 -bsp0 "$SRC_ARCHIVE" | dd of="$DEST_DEVICE" bs=$DD_BS status=progress iflag=fullblock oflag=direct
fi

echo ""
info "Flushing buffers to disk..."
sync
ok "Restore completed successfully onto ${C_BOLD}$DEST_DEVICE${C_RESET}."
