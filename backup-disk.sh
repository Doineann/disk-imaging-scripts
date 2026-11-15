#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd 7z lsblk blockdev sha256sum tee; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

echo "========================================"
echo "  FULL DISK BACKUP (dd + 7z + SHA256)   "
echo "========================================"
echo "Available drives:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
echo "----------------------------------------"

read -rp "Enter the SOURCE drive to back up (e.g., /dev/nvme0n1 or /dev/sda): " SRC_DRIVE
if [[ ! -b "$SRC_DRIVE" ]]; then
    echo "Error: '$SRC_DRIVE' is not a valid block device."
    exit 1
fi

if lsblk -no MOUNTPOINT "$SRC_DRIVE" | grep -q -v '^$'; then
    echo "Warning: One or more partitions on $SRC_DRIVE are currently mounted!"
    read -rp "Are you sure you want to continue anyway? (yes/no): " MOUNT_CONFIRM
    [[ "$MOUNT_CONFIRM" != "yes" ]] && echo "Aborted." && exit 1
fi

read -rp "Enter the DESTINATION folder path (e.g., /mnt/external_drive/backups): " DEST_DIR
if [[ ! -d "$DEST_DIR" ]]; then
    read -rp "Directory '$DEST_DIR' does not exist. Create it? (y/n): " CREATE_DIR
    if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
        mkdir -p "$DEST_DIR"
    else
        echo "Aborted."
        exit 1
    fi
fi

DEFAULT_NAME="fedora-backup-$(basename "$SRC_DRIVE")-$(date +%Y%m%d-%H%M).img.7z"
read -rp "Enter backup filename [$DEFAULT_NAME]: " FILENAME
FILENAME="${FILENAME:-$DEFAULT_NAME}"
DEST_FILE="${DEST_DIR%/}/$FILENAME"
RAW_HASH_FILE="${DEST_FILE}.raw.sha256"
ARCHIVE_HASH_FILE="${DEST_FILE}.sha256"

if [[ -e "$DEST_FILE" ]]; then
    echo "Error: Destination file '$DEST_FILE' already exists. Aborting."
    exit 1
fi

DRIVE_BYTES=$(blockdev --getsize64 "$SRC_DRIVE")
DRIVE_GB=$(awk "BEGIN {printf \"%.2f\", $DRIVE_BYTES / (1024^3)}")

echo ""
echo "================ SUMMARY ================"
echo "Source Drive      : $SRC_DRIVE (${DRIVE_GB} GiB - $(lsblk -dn -o MODEL "$SRC_DRIVE"))"
echo "Destination File  : $DEST_FILE"
echo "Checksums         : Raw Disk SHA-256 + Compressed Archive SHA-256"
echo "========================================="
read -rp "Type 'BACKUP' to start cloning: " CONFIRM
if [[ "$CONFIRM" != "BACKUP" ]]; then
    echo "Backup cancelled."
    exit 0
fi

echo ""
echo "Backing up $DRIVE_GB GiB and computing raw SHA-256 on the fly..."

if command -v pv &>/dev/null; then
    dd if="$SRC_DRIVE" bs=4M status=none | pv -s "$DRIVE_BYTES" | tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") | 7z a -si -mx=1 -bso0 -bsp0 -bse1 "$DEST_FILE"
else
    dd if="$SRC_DRIVE" bs=4M status=progress | tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") | 7z a -si -mx=1 -bso0 -bsp0 -bse1 "$DEST_FILE"
fi

echo ""
echo "Flushing buffers to disk..."
sync

echo "Generating compressed archive SHA-256 checksum..."
(cd "$(dirname "$DEST_FILE")" && sha256sum "$(basename "$DEST_FILE")" > "$ARCHIVE_HASH_FILE")

FINAL_SIZE=$(du -h "$DEST_FILE" | cut -f1)
echo ""
echo "Backup completed successfully!"
echo "Archive           : $DEST_FILE ($FINAL_SIZE)"
echo "Raw Disk SHA-256  : $(awk '{print $1}' "$RAW_HASH_FILE")"
echo "Archive SHA-256   : $(awk '{print $1}' "$ARCHIVE_HASH_FILE")"
