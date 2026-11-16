#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"

for cmd in 7z sha256sum find du date dd awk; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' is not installed."
        exit 1
    fi
done

echo ""
echo "========================================"
bold "           DISK VERIFICATION            "
echo "========================================"
echo ""

pick_archive "Select a backup to verify:"

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    err "File '$SRC_ARCHIVE' not found."
    exit 1
fi

echo ""
info "Selected: ${C_BOLD}$SRC_ARCHIVE${C_RESET}"

# Detect type from filename suffix.
case "$SRC_ARCHIVE" in
    *.part.img.7z)  SRC_TYPE="part" ;;
    *.disk.img.7z)  SRC_TYPE="disk" ;;
    *)              SRC_TYPE="disk" ;;  # fallback for legacy .img.7z / .7z names
esac

RAW_HASH_FILE="${SRC_ARCHIVE}.raw.sha256"
ARCHIVE_HASH_FILE="${SRC_ARCHIVE}.sha256"

# Uncompressed size from archive metadata (header-only; no decompression).
UNCOMPRESSED_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')

# --- Step 1: Ask if also verify against a disk/partition -------------------
echo ""
read -rp "Also verify this image against a disk or partition? (y/n): " DEVICE_CHECK
DEVICE_CHECK="${DEVICE_CHECK:-n}"
DEST_DEVICE=""
if [[ "$DEVICE_CHECK" =~ ^[Yy]$ ]]; then
    # Only dd needs root to open a block device. lsblk/blockdev work as any user.
    SUDO=""
    if [[ $EUID -ne 0 ]]; then
        SUDO="sudo"
    fi

    echo ""
    info "Available target drives:"
    lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
    echo "----------------------------------------"

    if [[ "$SRC_TYPE" == "part" ]]; then
        read -rp "Enter the TARGET partition to verify (e.g., /dev/sda1): " DEST_DEVICE
    else
        read -rp "Enter the TARGET drive to verify (e.g., /dev/nvme0n1 or /dev/sda): " DEST_DEVICE
    fi

    if [[ ! -b "$DEST_DEVICE" ]]; then
        err "'$DEST_DEVICE' is not a valid block device."
        exit 1
    fi

    # Type-mismatch guard: partition image → partition target, disk image → whole-disk target.
    parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$(basename "${DEST_DEVICE%/}")" '$2==x{print $1; exit}')
    if [[ "$SRC_TYPE" == "part" && -z "$parent" ]]; then
        err "'$DEST_DEVICE' is a whole disk. A partition image must be verified against a PARTITION (e.g., /dev/sda1)."
        exit 1
    fi
    if [[ "$SRC_TYPE" == "disk" && -n "$parent" ]]; then
        err "'$DEST_DEVICE' is a partition of /dev/$parent. A whole-disk image must be verified against a WHOLE DISK (e.g., /dev/sda)."
        exit 1
    fi

    # Size check: image must fit in the target. (blockdev needs root to open the device)
    TARGET_BYTES=$($SUDO blockdev --getsize64 "$DEST_DEVICE")
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
        err "Image ($UNCOMPRESSED_BYTES B) is larger than target device ($TARGET_BYTES B)."
        exit 1
    fi

    # Reading a live disk may yield changing data — offer to unmount.
    if ! ensure_unmounted "$DEST_DEVICE"; then
        echo ""
        read -rp "One or more partitions are still mounted. Continue reading anyway? (y/n): " MOUNT_CONFIRM
        if [[ ! "$MOUNT_CONFIRM" =~ ^[Yy]$ ]]; then
            warn "Aborted."
            exit 1
        fi
    fi
fi

# --- Step 2: Verify compressed archive SHA-256 ----------------------------
echo ""
if [[ -f "$ARCHIVE_HASH_FILE" ]]; then
    info "[1/3] Verifying compressed archive SHA-256..."
    EXPECTED_ARCHIVE_HASH=$(awk '{print $1}' "$ARCHIVE_HASH_FILE")

    if command -v pv &>/dev/null; then
        COMPUTED_ARCHIVE_HASH=$(pv "${PV_OPTS[@]}" "$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    else
        COMPUTED_ARCHIVE_HASH=$(dd_verify if="$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    fi

    if [[ "$COMPUTED_ARCHIVE_HASH" == "$EXPECTED_ARCHIVE_HASH" ]]; then
        ok "Compressed file matches original checksum ($COMPUTED_ARCHIVE_HASH)."
    else
        err "Compressed archive SHA-256 mismatch!"
        echo "Expected: $EXPECTED_ARCHIVE_HASH"
        echo "Actual  : $COMPUTED_ARCHIVE_HASH"
        exit 1
    fi
else
    warn "[1/3] No .sha256 file found for compressed archive (skipping)."
fi

# --- Step 3: Decode stream, verify raw image SHA-256 -----------------------
echo ""
info "[2/3] Decompressing stream and verifying raw image SHA-256..."

# Encrypted backups need a password to decode. Bare `-p` can't be used here: 7z's
# stdin is a pipe in these pipelines, so it cannot open /dev/tty to prompt (E_INVALIDARG).
read -rsp "Enter backup password (blank if none): " PASS
echo

if command -v pv &>/dev/null; then
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt 0 ]]; then
        COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$UNCOMPRESSED_BYTES" "${PV_OPTS[@]}" | sha256sum | awk '{print $1}')
    else
        COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -pterb "${PV_OPTS[@]}" | sha256sum | awk '{print $1}')
    fi
else
    COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd_verify | sha256sum | awk '{print $1}')
fi

if [[ -f "$RAW_HASH_FILE" ]]; then
    EXPECTED_RAW_HASH=$(awk '{print $1}' "$RAW_HASH_FILE")
    if [[ "$COMPUTED_RAW_HASH" == "$EXPECTED_RAW_HASH" ]]; then
        ok "Raw image stream matches original SHA-256 ($COMPUTED_RAW_HASH)."
    else
        err "Raw stream SHA-256 mismatch!"
        echo "Expected: $EXPECTED_RAW_HASH"
        echo "Actual  : $COMPUTED_RAW_HASH"
        exit 1
    fi
else
    ok "Decompression succeeded with no 7z CRC errors."
fi

# --- Step 4: (optional) Verify against disk/partition -----------------------
if [[ "$DEVICE_CHECK" =~ ^[Yy]$ ]]; then
    echo ""
    info "[3/3] Reading $DEST_DEVICE and computing its SHA-256..."

    if command -v pv &>/dev/null; then
        COMPUTED_DISK_HASH=$($SUDO dd if="$DEST_DEVICE" bs=$DD_BS count="$UNCOMPRESSED_BYTES" iflag=count_bytes status=none | pv -s "$UNCOMPRESSED_BYTES" "${PV_OPTS[@]}" | sha256sum | awk '{print $1}')
    else
        COMPUTED_DISK_HASH=$($SUDO dd if="$DEST_DEVICE" bs=$DD_BS count="$UNCOMPRESSED_BYTES" iflag=count_bytes status=none 2>/dev/null | dd_verify | sha256sum | awk '{print $1}')
    fi

    if [[ "$COMPUTED_RAW_HASH" == "$COMPUTED_DISK_HASH" ]]; then
        ok "Device matches image data ($COMPUTED_DISK_HASH)."
    else
        err "Device SHA-256 mismatch!"
        echo "Image : $COMPUTED_RAW_HASH"
        echo "Disk  : $COMPUTED_DISK_HASH"
        exit 1
    fi
fi

# --- Summary ----------------------------------------------------------------
echo ""
echo "========================================"
bold "  ALL CHECKS PASSED: BACKUP IS HEALTHY  "
echo "========================================"
