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

echo "========================================"
echo "           DISK VERIFICATION            "
echo "========================================"
echo "Searching current folder for backup archives (*.img.7z / *.7z)..."

mapfile -t FOUND_FILES < <(find . -maxdepth 2 -type f \( -name "*.img.7z" -o -name "*.7z" \) 2>/dev/null | sed 's|^\./||' | sort)

SRC_ARCHIVE=""

if [[ ${#FOUND_FILES[@]} -gt 0 ]]; then
    echo ""
    echo "Found the following backup files:"
    echo "------------------------------------------------------------------------"
    for i in "${!FOUND_FILES[@]}"; do
        FILE_PATH="${FOUND_FILES[$i]}"
        FILE_SIZE=$(du -h "$FILE_PATH" 2>/dev/null | cut -f1)
        FILE_DATE=$(date -r "$FILE_PATH" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown date")
        printf "  [%d] %s (%s, %s)\n" "$((i + 1))" "$FILE_PATH" "$FILE_SIZE" "$FILE_DATE"
    done
    echo "  [0] Enter a custom file path manually"
    echo "------------------------------------------------------------------------"

    while true; do
        read -rp "Select a backup to verify: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
            if [[ "$CHOICE" -eq 0 ]]; then
                read -rp "Enter the full path to the backup .7z file: " SRC_ARCHIVE
                break
            elif [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#FOUND_FILES[@]} ]]; then
                SRC_ARCHIVE="${FOUND_FILES[$((CHOICE - 1))]}"
                break
            fi
        fi
        echo "Invalid selection. Please enter a number from the list above."
    done
else
    echo "No .7z backup files found in the current folder."
    read -rp "Enter the full path to the backup .7z file: " SRC_ARCHIVE
fi

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    echo "Error: File '$SRC_ARCHIVE' not found."
    exit 1
fi

echo ""
echo "Selected: $SRC_ARCHIVE"

# Unbuffered on-the-fly replacement of "copied" with "verified"
dd_verify() {
    dd "$@" bs=4M status=progress 2> >(awk 'BEGIN{RS="\r|\n"} NF{gsub(/copied/, "verified"); printf "\r\033[K%s", $0 > "/dev/stderr"; fflush("/dev/stderr")} END{printf "\n" > "/dev/stderr"}')
}

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

if lsblk -no MOUNTPOINT "$DEST_DRIVE" | grep -q -v '^$'; then
    echo ""
    echo "Warning: One or more partitions on $DEST_DRIVE are currently mounted."
    echo "Reading a live disk may yield changing data and a spurious mismatch."
fi

echo ""
echo "Verifying $DEST_DRIVE against the image (first $IMAGE_BYTES bytes only)..."
echo "Do NOT interrupt or power off."

# 1. SHA-256 of the extracted image data (exactly IMAGE_BYTES)
echo ""
echo "[1/2] Extracting image stream and computing its SHA-256..."
if command -v pv &>/dev/null; then
    COMPUTED_IMAGE_HASH=$(7z x -so -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$IMAGE_BYTES" | sha256sum | awk '{print $1}')
else
    COMPUTED_IMAGE_HASH=$(7z x -so -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd_verify | sha256sum | awk '{print $1}')
fi

# 2. SHA-256 of the first IMAGE_BYTES bytes read from the target drive
echo ""
echo "[2/2] Reading $DEST_DRIVE and computing its SHA-256..."
if command -v pv &>/dev/null; then
    COMPUTED_DISK_HASH=$(dd if="$DEST_DRIVE" bs=4M count="$IMAGE_BYTES" iflag=count_bytes status=none | pv -s "$IMAGE_BYTES" | sha256sum | awk '{print $1}')
else
    COMPUTED_DISK_HASH=$(dd if="$DEST_DRIVE" bs=4M count="$IMAGE_BYTES" iflag=count_bytes status=none 2>/dev/null | dd_verify | sha256sum | awk '{print $1}')
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
