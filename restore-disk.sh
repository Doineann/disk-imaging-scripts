#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd 7z lsblk blockdev; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

echo "========================================"
echo "       FULL DISK RESTORE (7z + dd)      "
echo "========================================"

read -rp "Enter the path to the backup .7z file: " SRC_ARCHIVE
if [[ ! -f "$SRC_ARCHIVE" ]]; then
    echo "Error: File '$SRC_ARCHIVE' not found."
    exit 1
fi

# Extract uncompressed size from 7z archive metadata if available
UNCOMPRESSED_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')

echo ""
echo "Available target drives:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
echo "----------------------------------------"

read -rp "Enter the TARGET drive to overwrite (e.g., /dev/nvme0n1 or /dev/sda): " DEST_DRIVE
if [[ ! -b "$DEST_DRIVE" ]]; then
    echo "Error: '$DEST_DRIVE' is not a valid block device."
    exit 1
fi

ARCHIVE_DEV=$(df --output=source "$SRC_ARCHIVE" | tail -n 1)
if [[ "$ARCHIVE_DEV" == "$DEST_DRIVE"* ]]; then
    echo "Error: Target drive '$DEST_DRIVE' contains the backup file itself! Aborting."
    exit 1
fi

if lsblk -no MOUNTPOINT "$DEST_DRIVE" | grep -q -v '^$'; then
    echo "Error: Target drive '$DEST_DRIVE' has mounted partitions. Unmount them first."
    exit 1
fi

TARGET_BYTES=$(blockdev --getsize64 "$DEST_DRIVE")
if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
    echo "Error: Backup image ($UNCOMPRESSED_BYTES bytes) is larger than target drive ($TARGET_BYTES bytes)."
    exit 1
fi

echo ""
echo "!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!"
echo "ALL DATA ON $DEST_DRIVE ($(lsblk -dn -o SIZE,MODEL "$DEST_DRIVE")) WILL BE PERMANENTLY ERASED!"
echo "Source Archive : $SRC_ARCHIVE"
echo "Target Drive   : $DEST_DRIVE"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -rp "To confirm, type the exact target device path ($DEST_DRIVE): " CONFIRM_DEV
if [[ "$CONFIRM_DEV" != "$DEST_DRIVE" ]]; then
    echo "Device path did not match. Restore cancelled."
    exit 0
fi

echo ""
echo "Restoring image... Do NOT interrupt or power off."

# -bso0 -bsp0 prevents 7z from overwriting dd's progress line
if command -v pv &>/dev/null && [[ -n "$UNCOMPRESSED_BYTES" ]]; then
    7z x -so -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$UNCOMPRESSED_BYTES" | dd of="$DEST_DRIVE" bs=4M status=none oflag=direct
else
    7z x -so -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd of="$DEST_DRIVE" bs=4M status=progress oflag=direct
fi

echo ""
echo "Flushing buffers to disk..."
sync
echo "Restore completed successfully onto $DEST_DRIVE."
