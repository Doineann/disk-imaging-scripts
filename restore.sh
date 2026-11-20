#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd zstd openssl lsblk blockdev sha256sum tee; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' is not installed."
        exit 1
    fi
done

PREFLIGHT_HEAD_MIB=8

TMP_HEAD=""
TMP_RAW_HASH=""
cleanup_on_exit() {
    unset BACKUP_PASS
    [[ -n "${TMP_HEAD:-}" ]] && rm -f -- "$TMP_HEAD"
    [[ -n "${TMP_RAW_HASH:-}" ]] && rm -f -- "$TMP_RAW_HASH"
}
trap cleanup_on_exit EXIT

echo ""
echo "=============================================="
bold "   FULL DISK RESTORE (OpenSSL + zstd + dd)    "
echo "=============================================="
echo ""

pick_archive "Select a backup to restore:"

if [[ ! -f "$SRC_ARCHIVE" ]]; then
    err "File '$SRC_ARCHIVE' not found."
    exit 1
fi

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

parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$(basename "${DEST_DEVICE%/}")" '$2==x{print $1; exit}')
if [[ "$SRC_TYPE" == "part" && -z "$parent" ]]; then
    err "'$DEST_DEVICE' is a whole disk. A partition image must be restored to a PARTITION (e.g., /dev/sda1)."
    exit 1
fi
if [[ "$SRC_TYPE" == "disk" && -n "$parent" ]]; then
    err "'$DEST_DEVICE' is a partition of /dev/$parent. A whole-disk image must be restored to a WHOLE DISK (e.g., /dev/sda)."
    exit 1
fi

PASS=""
if (( IS_ENCRYPTED == 1 )); then
    echo ""
    read -rsp "Enter backup password: " PASS
    echo
    if [[ -z "$PASS" ]]; then
        err "Archive is encrypted (.enc), password cannot be blank."
        exit 1
    fi
fi

decode_stream() {
    local archive="$1"
    if (( IS_ENCRYPTED == 1 )); then
        export BACKUP_PASS="$PASS"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:BACKUP_PASS -in "$archive" 2>/dev/null |
            zstd -d -T0 -q
    else
        zstd -d -T0 -q -c "$archive"
    fi
}

preflight() {
    local archive="$1"
    echo ""
    info "Pre-flight checks (no writes yet)..."

    local archive_hash_file="${archive}.sha256"
    if [[ -f "$archive_hash_file" ]]; then
        info "Verifying archive SHA-256 checksum..."
        local expected_hash actual_hash
        expected_hash=$(awk '{print $1}' "$archive_hash_file")
        actual_hash=$(sha256sum "$archive" | awk '{print $1}')
        if [[ "$expected_hash" != "$actual_hash" ]]; then
            err "Archive SHA-256 mismatch! File may be corrupted or tampered with."
            echo "       Expected: $expected_hash"
            echo "       Actual  : $actual_hash"
            return 1
        fi
        ok "Archive SHA-256 verified."
    else
        warn "No '${archive_hash_file}' found; skipping pre-flight archive hash check."
    fi

    local head_bytes=$(( PREFLIGHT_HEAD_MIB * 1024 * 1024 ))
    TMP_HEAD=$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")

    { decode_stream "$archive" 2>/dev/null | head -c "$head_bytes" > "$TMP_HEAD"; } &
    wait

    if [[ ! -s "$TMP_HEAD" ]]; then
        err "Failed to decode the first ${PREFLIGHT_HEAD_MIB} MiB of '$archive'."
        echo "       (wrong password, or corrupt zstd/OpenSSL stream)"
        rm -f -- "$TMP_HEAD"
        TMP_HEAD=""
        return 1
    fi
    ok "Stream decryption & zstd decompression verified."

    local gpt_sig mbr_sig
    gpt_sig=$(dd if="$TMP_HEAD" bs=1 skip=512 count=8 status=none | od -An -tx1 | tr -d ' \n')
    mbr_sig=$(dd if="$TMP_HEAD" bs=1 skip=446 count=2 status=none | od -An -tx1 | tr -d ' \n')

    local found=0
    if [[ "$gpt_sig" == "4546492050415254" ]]; then
        found=1
        ok "GPT signature ('EFI PART') present at offset 512."
    fi
    if [[ "$mbr_sig" == "55aa" ]]; then
        found=1
        ok "MBR boot signature (0x55AA) present at offset 446."
    fi

    rm -f -- "$TMP_HEAD"
    TMP_HEAD=""

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

if ! preflight "$SRC_ARCHIVE"; then
    exit 1
fi

UNCOMPRESSED_BYTES=""
if (( IS_ENCRYPTED == 0 )); then
    UNCOMPRESSED_BYTES=$(zstd -lv "$SRC_ARCHIVE" 2>/dev/null | awk '/Frame Content Size:/ {print $4; exit}' || true)
    [[ "$UNCOMPRESSED_BYTES" == "0" ]] && UNCOMPRESSED_BYTES=""
fi

ARCHIVE_DEV=$(df --output=source "$SRC_ARCHIVE" | tail -n 1)
if [[ "$ARCHIVE_DEV" == "$DEST_DEVICE"* ]]; then
    err "Target device '$DEST_DEVICE' contains the backup file itself! Aborting."
    exit 1
fi

if ! ensure_unmounted "$DEST_DEVICE"; then
    err "Target device '$DEST_DEVICE' still has mounted partitions. Unmount them first."
    exit 1
fi

TARGET_BYTES=$(blockdev --getsize64 "$DEST_DEVICE")

if [[ -n "$UNCOMPRESSED_BYTES" ]]; then
    if [[ "$SRC_TYPE" == "part" && "$UNCOMPRESSED_BYTES" -ne "$TARGET_BYTES" ]]; then
        err "Image size ($UNCOMPRESSED_BYTES B) does not EXACTLY match target partition size ($TARGET_BYTES B)."
        echo "       Partition backups require an exact-size match to preserve filesystem end-metadata."
        exit 1
    elif [[ "$SRC_TYPE" == "disk" && "$UNCOMPRESSED_BYTES" -gt "$TARGET_BYTES" ]]; then
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
echo "Source Archive  : $SRC_ARCHIVE"
if [[ "$SRC_TYPE" == "part" ]]; then
    echo "Target Partition: ${C_BOLD}$DEST_DEVICE${C_RESET}"
else
    echo "Target Drive    : ${C_BOLD}$DEST_DEVICE${C_RESET}"
fi
printf "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}\n"
read -rp "To confirm, type the exact target device path ($DEST_DEVICE): " CONFIRM_DEV
if [[ "$CONFIRM_DEV" != "$DEST_DEVICE" ]]; then
    warn "Device path did not match. Restore cancelled."
    exit 0
fi

echo ""
info "Restoring image and computing raw SHA-256 on the fly... Do NOT interrupt or power off."

TMP_RAW_HASH=$(mktemp "${TMPDIR:-/tmp}/restore-raw-hash.XXXXXX")

if command -v pv &>/dev/null; then
    PV_SIZE_ARG=()
    [[ -n "$UNCOMPRESSED_BYTES" ]] && PV_SIZE_ARG=(-s "$UNCOMPRESSED_BYTES")
    decode_stream "$SRC_ARCHIVE" |
        pv "${PV_SIZE_ARG[@]}" "${PV_OPTS[@]}" |
        tee >(sha256sum | awk '{print $1}' > "$TMP_RAW_HASH") |
        dd of="$DEST_DEVICE" bs=$DD_BS status=none iflag=fullblock oflag=direct
else
    decode_stream "$SRC_ARCHIVE" |
        tee >(sha256sum | awk '{print $1}' > "$TMP_RAW_HASH") |
        dd of="$DEST_DEVICE" bs=$DD_BS status=progress iflag=fullblock oflag=direct
fi

wait

echo ""
info "Flushing buffers to disk..."
sync

RESTORED_RAW_HASH=$(cat "$TMP_RAW_HASH")
rm -f -- "$TMP_RAW_HASH"
TMP_RAW_HASH=""

RAW_HASH_FILE="${SRC_ARCHIVE}.raw.sha256"
if [[ -f "$RAW_HASH_FILE" ]]; then
    EXPECTED_RAW_HASH=$(awk '{print $1}' "$RAW_HASH_FILE")
    if [[ "$RESTORED_RAW_HASH" == "$EXPECTED_RAW_HASH" ]]; then
        ok "Raw Disk SHA-256 verified: $RESTORED_RAW_HASH"
    else
        err "Raw Disk SHA-256 MISMATCH after restore!"
        echo "       Expected: $EXPECTED_RAW_HASH"
        echo "       Restored: $RESTORED_RAW_HASH"
        exit 1
    fi
else
    info "Restored Raw SHA-256: $RESTORED_RAW_HASH (no .raw.sha256 sidecar found to compare)"
fi

ok "Restore completed successfully onto ${C_BOLD}$DEST_DEVICE${C_RESET}."
