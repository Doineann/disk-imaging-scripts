#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd 7z lsblk blockdev find du date; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# Block size for dd. Larger blocks cut syscall overhead on fast media (modern SSDs
# can sustain ~10 GB/s), but each dd allocates one buffer of this size, so keep it
# modest to bound memory use across the pipeline. 64 MiB is a good balance.
DD_BS=64M

# How many MiB of the image head to extract during pre-flight, just enough to reach
# GPT's LBA0..LBA33 (512 B sectors) and MBR. 8 MiB covers both comfortably.
PREFLIGHT_HEAD_MIB=8

# Offer to unmount any partitions on $1 (a whole disk) before we write to it.
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
echo "       FULL DISK RESTORE (7z + dd)      "
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
        read -rp "Select a backup to restore: " CHOICE
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

# Ask for the destination FIRST (before any 7z work), so you can abort early if you picked
# the wrong archive without waiting through pre-flight / password prompts.
echo ""
echo "Available target drives:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
echo "----------------------------------------"

read -rp "Enter the TARGET drive to overwrite (e.g., /dev/nvme0n1 or /dev/sda): " DEST_DRIVE
if [[ ! -b "$DEST_DRIVE" ]]; then
    echo "Error: '$DEST_DRIVE' is not a valid block device."
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
    echo "Pre-flight checks (no writes yet)..."

    # Stream the decoded head to a small temp file (only PREFLIGHT_HEAD_MIB MiB, not the
    # whole image). Run in background so pipefail/SIGPIPE can't trip set -e; judge by size.
    local head_bytes=$(( PREFLIGHT_HEAD_MIB * 1024 * 1024 ))
    local tmp_head
    tmp_head=$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")
    { 7z x -so -p"$pass" -bso0 -bsp0 "$archive" 2>/dev/null | head -c "$head_bytes" > "$tmp_head"; } &
    wait
    if [[ ! -s "$tmp_head" ]]; then
        echo "ERROR: Failed to decode the first ${PREFLIGHT_HEAD_MIB} MiB of '$archive'."
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
    if [[ "$gpt_sig" == "4546492050415254" ]]; then found=1; echo "OK: GPT signature ('EFI PART') present at offset 512."; fi
    # MBR: boot signature 0x55AA at offset 446.
    if [[ "$mbr_sig" == "55aa" ]]; then found=1; echo "OK: MBR boot signature (0x55AA) present at offset 446."; fi

    rm -f -- "$tmp_head"

    if (( found == 0 )); then
        echo "WARNING: No GPT/MBR partition-table signature found in the image head."
        echo "         The image may be a raw disk without a table, or not a standard layout."
    fi
    return 0
}

if ! preflight "$SRC_ARCHIVE" "$PASS"; then
    exit 1
fi

# Uncompressed size from archive metadata (header-only; no decompression).
UNCOMPRESSED_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')

ARCHIVE_DEV=$(df --output=source "$SRC_ARCHIVE" | tail -n 1)
if [[ "$ARCHIVE_DEV" == "$DEST_DRIVE"* ]]; then
    echo "Error: Target drive '$DEST_DRIVE' contains the backup file itself! Aborting."
    exit 1
fi

# Writing to a disk with live mounts is destructive and unsafe — require unmounting.
if ! ensure_unmounted "$DEST_DRIVE"; then
    echo "Error: Target drive '$DEST_DRIVE' still has mounted partitions. Unmount them first."
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

# Stream-decode straight to the target drive (no temp file). -bso0/-bsp0 keep 7z from
# clobbering dd's progress line; pv shows throughput against the known total size.
if command -v pv &>/dev/null && [[ -n "$UNCOMPRESSED_BYTES" ]]; then
    7z x -so -p"$PASS" -bso0 -bsp0 "$SRC_ARCHIVE" | pv -s "$UNCOMPRESSED_BYTES" -w 63 --format '%b %p %r' | dd of="$DEST_DRIVE" bs=$DD_BS status=none iflag=fullblock oflag=direct
else
    7z x -so -p"$PASS" -bso0 -bsp0 "$SRC_ARCHIVE" | dd of="$DEST_DRIVE" bs=$DD_BS status=progress iflag=fullblock oflag=direct
fi

echo ""
echo "Flushing buffers to disk..."
sync
echo "Restore completed successfully onto $DEST_DRIVE."
