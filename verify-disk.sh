#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

for cmd in 7z sha256sum find du date dd awk lsblk blockdev; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"

echo "========================================"
echo "           DISK VERIFICATION            "
echo "========================================"

pick_archive "Select a backup to verify:"

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    echo "Error: File '$SRC_ARCHIVE' not found."
    exit 1
fi

echo ""
echo "Selected: $SRC_ARCHIVE"

# Exact number of bytes in the image (we only ever compare that many)
IMAGE_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')
if [[ ! "$IMAGE_BYTES" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not determine the image size from '$SRC_ARCHIVE'."
    exit 1
fi

echo ""
echo "Available target drives:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
echo "----------------------------------------"

read -rp "Enter the TARGET drive to verify (e.g., /dev/nvme0n1 or /dev/sda): " DEST_DRIVE
if [[ ! -b "$DEST_DRIVE" ]]; then
    echo "Error: '$DEST_DRIVE' is not a valid block device."
    exit 1
fi

TARGET_BYTES=$(blockdev --getsize64 "$DEST_DRIVE")
if [[ "$IMAGE_BYTES" -gt "$TARGET_BYTES" ]]; then
    echo "Error: Image ($IMAGE_BYTES bytes) is larger than target drive ($TARGET_BYTES bytes)."
    exit 1
fi

# Reading a live disk may yield changing data and a spurious mismatch — offer to unmount.
if ! ensure_unmounted "$DEST_DRIVE"; then
    echo ""
    read -rp "One or more partitions are still mounted. Continue reading anyway? (y/n): " MOUNT_CONFIRM
    if [[ ! "$MOUNT_CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo "Verifying $DEST_DRIVE against the image (first $IMAGE_BYTES bytes only)..."
echo "Do NOT interrupt or power off."

# Encrypted (PFS) backups need a password to decode. Bare `-p` can't be used: 7z's stdin is
# a pipe here, so it cannot open /dev/tty to prompt (E_INVALIDARG). Read explicitly; blank
# is fine for unencrypted archives.
read -rsp "Enter backup password (blank if none): " PASS
echo

# 1. SHA-256 of the extracted image data (exactly IMAGE_BYTES)
echo ""
echo "[1/2] Extracting image stream and computing its SHA-256..."
if command -v pv &>/dev/null; then
    COMPUTED_IMAGE_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$IMAGE_BYTES" "${PV_OPTS[@]}" | sha256sum | awk '{print $1}')
else
    COMPUTED_IMAGE_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd_verify | sha256sum | awk '{print $1}')
fi

# 2. SHA-256 of the first IMAGE_BYTES bytes read from the target drive
echo ""
echo "[2/2] Reading $DEST_DRIVE and computing its SHA-256..."
if command -v pv &>/dev/null; then
    COMPUTED_DISK_HASH=$(dd if="$DEST_DRIVE" bs=$DD_BS count="$IMAGE_BYTES" iflag=count_bytes status=none | pv -s "$IMAGE_BYTES" "${PV_OPTS[@]}" | sha256sum | awk '{print $1}')
else
    COMPUTED_DISK_HASH=$(dd if="$DEST_DRIVE" bs=$DD_BS count="$IMAGE_BYTES" iflag=count_bytes status=none 2>/dev/null | dd_verify | sha256sum | awk '{print $1}')
fi

if [[ "$COMPUTED_IMAGE_HASH" == "$COMPUTED_DISK_HASH" ]]; then
    echo "OK: Disk matches image data ($COMPUTED_IMAGE_HASH)."
else
    echo "ERROR: Disk SHA-256 mismatch!"
    echo "Image : $COMPUTED_IMAGE_HASH"
    echo "Disk  : $COMPUTED_DISK_HASH"
    exit 1
fi

echo ""
echo "========================================"
echo "  ALL CHECKS PASSED: DISK MATCHES IMAGE "
echo "========================================"
