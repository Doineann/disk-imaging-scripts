#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE}")/lib/shared.sh"

for cmd in zstd openssl sha256sum lsblk blockdev dd awk wc; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' is not installed."
        exit 1
    fi
done

TMP_BYTE_COUNT=""
cleanup_on_exit() {
    unset BACKUP_PASS
    [[ -n "${TMP_BYTE_COUNT:-}" ]] && rm -f -- "$TMP_BYTE_COUNT"
}
trap cleanup_on_exit EXIT

echo ""
echo "=============================================="
bold "   DISK VERIFICATION (OpenSSL + zstd + SHA)   "
echo "=============================================="
echo ""

# ============================================================================
# PHASE 1: Gather all inputs & authentication upfront
# ============================================================================

pick_archive "Select a backup to verify:"

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    err "File '$SRC_ARCHIVE' not found."
    exit 1
fi

# Detect encryption and image type from filename suffix.
IS_ENCRYPTED=0
[[ "$SRC_ARCHIVE" == *.enc ]] && IS_ENCRYPTED=1

case "$SRC_ARCHIVE" in
    *.part.img.zstd|*.part.img.zstd.enc) SRC_TYPE="part" ;;
    *.disk.img.zstd|*.disk.img.zstd.enc) SRC_TYPE="disk" ;;
    *)                                   SRC_TYPE="disk" ;;
esac

echo ""
info "Selected: ${C_BOLD}$SRC_ARCHIVE${C_RESET}"
if (( IS_ENCRYPTED == 1 )); then
    info "Format  : zstd compressed + OpenSSL AES-256-CBC encrypted"
else
    info "Format  : zstd compressed (unencrypted)"
fi

RAW_HASH_FILE="${SRC_ARCHIVE}.raw.sha256"
ARCHIVE_HASH_FILE="${SRC_ARCHIVE}.sha256"

# Uncompressed size from zstd frame header (available when unencrypted and --stream-size was used).
UNCOMPRESSED_BYTES=""
if (( IS_ENCRYPTED == 0 )); then
    UNCOMPRESSED_BYTES=$(zstd -lv "$SRC_ARCHIVE" 2>/dev/null | awk '/Frame Content Size:/ {print $4; exit}' || true)
    [[ "$UNCOMPRESSED_BYTES" == "0" ]] && UNCOMPRESSED_BYTES=""
fi

# Prompt for password upfront if encrypted, and do a fast 64 KiB test decode so
# a typo is caught immediately rather than after hashing a huge archive.
PASS=""
if (( IS_ENCRYPTED == 1 )); then
    echo ""
    read -rsp "Enter backup password: " PASS
    echo
    if [[ -z "$PASS" ]]; then
        err "Archive is encrypted (.enc), password cannot be blank."
        exit 1
    fi

    export BACKUP_PASS="$PASS"
    TEST_BYTES=$(
        { openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:BACKUP_PASS -in "$SRC_ARCHIVE" 2>/dev/null |
          zstd -d -T0 -q |
          head -c 65536 | wc -c; } || true
    )
    if [[ "${TEST_BYTES:-0}" -eq 0 ]]; then
        err "Quick password check failed (wrong password or corrupt stream)."
        exit 1
    fi
fi

# Ask upfront if also verifying against a physical disk/partition.
echo ""
read -rp "Also verify this image against a disk or partition? (y/n): " DEVICE_CHECK
DEVICE_CHECK="${DEVICE_CHECK:-n}"
DEST_DEVICE=""
SUDO=""
TARGET_BYTES=0

if [[ "$DEVICE_CHECK" =~ ^[Yy]$ ]]; then
    if [[ $EUID -ne 0 ]]; then
        SUDO="sudo"
        info "Admin rights are required to read block devices."
        sudo -v
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

    # Type-mismatch guard: partition image -> partition target, disk image -> whole-disk target.
    parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$(basename "${DEST_DEVICE%/}")" '$2==x{print $1; exit}')
    if [[ "$SRC_TYPE" == "part" && -z "$parent" ]]; then
        err "'$DEST_DEVICE' is a whole disk. A partition image must be verified against a PARTITION (e.g., /dev/sda1)."
        exit 1
    fi
    if [[ "$SRC_TYPE" == "disk" && -n "$parent" ]]; then
        err "'$DEST_DEVICE' is a partition of /dev/$parent. A whole-disk image must be verified against a WHOLE DISK (e.g., /dev/sda)."
        exit 1
    fi

    TARGET_BYTES=$($SUDO blockdev --getsize64 "$DEST_DEVICE")
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
        err "Image ($UNCOMPRESSED_BYTES B) is larger than target device ($TARGET_BYTES B)."
        exit 1
    fi

    if ! ensure_unmounted "$DEST_DEVICE"; then
        echo ""
        read -rp "One or more partitions are still mounted. Continue reading anyway? (y/n): " MOUNT_CONFIRM
        if [[ ! "$MOUNT_CONFIRM" =~ ^[Yy]$ ]]; then
            warn "Aborted."
            exit 1
        fi
    fi
fi

# ============================================================================
# PHASE 2: Run all verification steps unattended
# ============================================================================

decode_stream() {
    local archive="$1"
    if (( IS_ENCRYPTED == 1 )); then
        export BACKUP_PASS="$PASS"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:BACKUP_PASS -in "$archive" |
            zstd -d -T0 -q
    else
        zstd -d -T0 -q -c "$archive"
    fi
}

# --- Step 1: Verify compressed/encrypted archive SHA-256 -------------------
echo ""
if [[ -f "$ARCHIVE_HASH_FILE" ]]; then
    info "[1/3] Verifying archive SHA-256..."
    EXPECTED_ARCHIVE_HASH=$(awk '{print $1}' "$ARCHIVE_HASH_FILE")

    if command -v pv &>/dev/null; then
        COMPUTED_ARCHIVE_HASH=$(pv "${PV_OPTS[@]}" "$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    else
        COMPUTED_ARCHIVE_HASH=$(dd_verify if="$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    fi

    if [[ "$COMPUTED_ARCHIVE_HASH" == "$EXPECTED_ARCHIVE_HASH" ]]; then
        ok "Archive file matches original checksum ($COMPUTED_ARCHIVE_HASH)."
    else
        err "Archive SHA-256 mismatch!"
        echo "Expected: $EXPECTED_ARCHIVE_HASH"
        echo "Actual  : $COMPUTED_ARCHIVE_HASH"
        exit 1
    fi
else
    warn "[1/3] No .sha256 file found for archive (skipping)."
fi

# --- Step 2: Decode stream, verify raw image SHA-256 -----------------------
echo ""
info "[2/3] Decompressing stream and verifying raw image SHA-256..."

TMP_BYTE_COUNT=$(mktemp "${TMPDIR:-/tmp}/verify-bytes.XXXXXX")

if command -v pv &>/dev/null; then
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt 0 ]]; then
        COMPUTED_RAW_HASH=$(decode_stream "$SRC_ARCHIVE" |
            pv -s "$UNCOMPRESSED_BYTES" "${PV_OPTS[@]}" |
            tee >(wc -c > "$TMP_BYTE_COUNT") |
            sha256sum | awk '{print $1}')
    else
        COMPUTED_RAW_HASH=$(decode_stream "$SRC_ARCHIVE" |
            pv -pterb "${PV_OPTS[@]}" |
            tee >(wc -c > "$TMP_BYTE_COUNT") |
            sha256sum | awk '{print $1}')
    fi
else
    COMPUTED_RAW_HASH=$(decode_stream "$SRC_ARCHIVE" |
        dd_verify |
        tee >(wc -c > "$TMP_BYTE_COUNT") |
        sha256sum | awk '{print $1}')
fi

wait
ACTUAL_UNCOMPRESSED_BYTES=$(tr -d ' \n' < "$TMP_BYTE_COUNT")

if [[ -z "$ACTUAL_UNCOMPRESSED_BYTES" || "$ACTUAL_UNCOMPRESSED_BYTES" -eq 0 ]]; then
    err "Decompression produced 0 bytes (wrong password or corrupt stream)."
    exit 1
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
    ok "Decompression succeeded with valid zstd checksums (no .raw.sha256 sidecar found)."
fi

# --- Step 3: (optional) Verify against disk/partition -----------------------
if [[ "$DEVICE_CHECK" =~ ^[Yy]$ ]]; then
    echo ""
    info "[3/3] Reading $DEST_DEVICE ($ACTUAL_UNCOMPRESSED_BYTES bytes) and computing its SHA-256..."

    if [[ "$ACTUAL_UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
        err "Image ($ACTUAL_UNCOMPRESSED_BYTES B) is larger than target device ($TARGET_BYTES B)."
        exit 1
    fi

    # Refresh sudo timestamp in case steps [1/3] and [2/3] took longer than the sudo timeout.
    [[ -n "$SUDO" ]] && sudo -n true 2>/dev/null || true

    if command -v pv &>/dev/null; then
        COMPUTED_DISK_HASH=$($SUDO dd if="$DEST_DEVICE" bs=$DD_BS count="$ACTUAL_UNCOMPRESSED_BYTES" iflag=count_bytes status=none |
            pv -s "$ACTUAL_UNCOMPRESSED_BYTES" "${PV_OPTS[@]}" |
            sha256sum | awk '{print $1}')
    else
        COMPUTED_DISK_HASH=$($SUDO dd if="$DEST_DEVICE" bs=$DD_BS count="$ACTUAL_UNCOMPRESSED_BYTES" iflag=count_bytes status=none 2>/dev/null |
            dd_verify |
            sha256sum | awk '{print $1}')
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
echo "=============================================="
bold "    ALL CHECKS PASSED: BACKUP IS HEALTHY      "
echo "=============================================="
