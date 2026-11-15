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

# Block size for dd. Larger blocks cut syscall overhead on fast media (modern SSDs
# can sustain ~10 GB/s), but each dd allocates one buffer of this size, so keep it
# modest to bound memory use across the pipeline. 64 MiB is a good balance.
DD_BS=64M

# Offer to unmount any partitions on $1 (a whole disk) before we read from it.
# Returns 0 if no mounts remain after the prompt, 1 if some are still mounted.
ensure_unmounted() {
    local dev="$1"
    # Collect the mountpoints of this disk's partitions that are currently mounted.
    local mps=() mp
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && mps+=("$mp")
    done < <(lsblk -no MOUNTPOINT "$dev" | grep -v '^$')
    if [[ ${#mps[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo "The following partitions on $dev are currently mounted:"
    local m; for m in "${mps[@]}"; do printf "  %s\n" "$m"; done
    read -rp "Unmount them now? (y/n): " UNMOUNT_ANSWER
    if [[ ! "$UNMOUNT_ANSWER" =~ ^[Yy]$ ]]; then
        echo "Leaving partitions mounted."
        return 1
    fi

    local ok=0 m2
    for m in "${mps[@]}"; do
        # The mountpoint may be a bind/loop path; unmount the device itself.
        if umount "$m" 2>/dev/null; then
            echo "Unmounted $m."
        else
            echo "Could not unmount $m (in use or permission denied)."
            ok=1
        fi
    done
    return $ok
}

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
    dd "$@" bs=$DD_BS status=progress 2> >(awk 'BEGIN{RS="\r|\n"} NF{gsub(/copied/, "verified"); printf "\r\033[K%s", $0 > "/dev/stderr"; fflush("/dev/stderr")} END{printf "\n" > "/dev/stderr"}')
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
    COMPUTED_IMAGE_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$IMAGE_BYTES" -w 63 --format '%b %p %r' | sha256sum | awk '{print $1}')
else
    COMPUTED_IMAGE_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd_verify | sha256sum | awk '{print $1}')
fi

# 2. SHA-256 of the first IMAGE_BYTES bytes read from the target drive
echo ""
echo "[2/2] Reading $DEST_DRIVE and computing its SHA-256..."
if command -v pv &>/dev/null; then
    COMPUTED_DISK_HASH=$(dd if="$DEST_DRIVE" bs=$DD_BS count="$IMAGE_BYTES" iflag=count_bytes status=none | pv -s "$IMAGE_BYTES" -w 63 --format '%b %p %r' | sha256sum | awk '{print $1}')
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
