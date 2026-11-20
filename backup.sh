#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE}")/lib/shared.sh"

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

# Resolve the human user who invoked us via sudo, so we can hand ownership of the
# backup files back to them (the script itself runs as root). Prefer $SUDO_USER;
# fall back to the effective user if that's unavailable.
if [[ -n "${SUDO_USER:-}" ]]; then
    OWNER_NAME="$SUDO_USER"
else
    OWNER_NAME="$(id -un)"
fi
# Primary group ID of that user (for chown user:group).
OWNER_GROUP="$(id -g "$OWNER_NAME" 2>/dev/null || true)"

# Hand ownership of the produced backup files back to the invoking user.
chown_backup() {
    local f
    for f in "$@"; do
        [[ -e "$f" ]] && chown "${OWNER_NAME}:${OWNER_GROUP}" -- "$f" 2>/dev/null || true
    done
}

# --- Cleanup on exit / interrupt: remove any artifacts THIS run created. ---
CLEANUP_FILES=()
cleanup_on_exit() {
    local rc=$? f
    unset BACKUP_PASS
    if (( rc != 0 )); then
        for f in "${CLEANUP_FILES[@]}"; do rm -f -- "$f" 2>/dev/null || true; done
    fi
}
track_file() { [[ -n "${1:-}" ]] && CLEANUP_FILES+=("$1"); }
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=============================================="
bold "  FULL DISK BACKUP (dd + zstd + OpenSSL)      "
echo "=============================================="
echo ""

pick_source "Enter the SOURCE drive to back up:" || exit 1

if ! ensure_unmounted "$SRC_DEVICE"; then
    echo ""
    read -rp "One or more partitions are still mounted. Continue reading anyway? (y/n): " MOUNT_CONFIRM
    if [[ ! "$MOUNT_CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Aborted."
        exit 1
    fi
fi

read -rp "Enter the DESTINATION folder path (e.g., /mnt/external_drive/backups): " DEST_DIR
DEST_DIR="${DEST_DIR:-$PWD}"
if [[ ! -d "$DEST_DIR" ]]; then
    read -rp "Directory '$DEST_DIR' does not exist. Create it? (y/n): " CREATE_DIR
    if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
        mkdir -p -- "$DEST_DIR"
    else
        warn "Aborted."
        exit 1
    fi
fi

# Prompt for the backup password early so we know whether to append .enc to the filename.
echo ""
read -rsp "Enter backup password (blank for unencrypted): " PASS1
echo
if [[ -n "$PASS1" ]]; then
    read -rsp "Re-enter backup password: " PASS2
    echo
    if [[ "$PASS1" != "$PASS2" ]]; then
        err "Passwords did not match. Aborting."
        exit 1
    fi
fi

# Determine filename suffix based on source type and encryption choice.
if [[ "$SRC_TYPE" == "part" ]]; then
    SUFFIX=".part.img.zstd"
else
    SUFFIX=".disk.img.zstd"
fi
[[ -n "$PASS1" ]] && SUFFIX="${SUFFIX}.enc"

DEFAULT_NAME="fedora-backup-$(basename "$SRC_DEVICE")-$(date +%Y%m%d-%H%M)${SUFFIX}"
read -rp "Enter backup filename [$DEFAULT_NAME]: " FILENAME
FILENAME="${FILENAME:-$DEFAULT_NAME}"
DEST_FILE="${DEST_DIR%/}/$FILENAME"
RAW_HASH_FILE="${DEST_FILE}.raw.sha256"
ARCHIVE_HASH_FILE="${DEST_FILE}.sha256"

if [[ -e "$DEST_FILE" ]]; then
    err "Destination file '$DEST_FILE' already exists. Aborting."
    exit 1
fi

DRIVE_BYTES=$(blockdev --getsize64 "$SRC_DEVICE")
DRIVE_GB=$(awk "BEGIN {printf \"%.2f\", $DRIVE_BYTES / (1024^3)}")

echo ""
bold "================ SUMMARY ================"
if [[ "$SRC_TYPE" == "part" ]]; then
    echo "Source Partition  : ${C_BOLD}$SRC_DEVICE${C_RESET} (${DRIVE_GB} GiB)"
else
    echo "Source Drive      : ${C_BOLD}$SRC_DEVICE${C_RESET} (${DRIVE_GB} GiB - $(lsblk -dn -o MODEL "$SRC_DEVICE"))"
fi
echo "Destination File  : $DEST_FILE"
if [[ -n "$PASS1" ]]; then
    echo "Compression / Enc : zstd (-3 -T0) + OpenSSL AES-256-CBC (Encrypted)"
else
    echo "Compression / Enc : zstd (-3 -T0) (Unencrypted)"
fi
echo "Checksums         : Raw Disk SHA-256 + Final Archive SHA-256 (on-the-fly)"
bold "========================================="
read -rp "Start backup? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Backup cancelled."
    exit 0
fi

# Encryption stage helper: passes data straight through with `cat` if unencrypted,
# or encrypts via OpenSSL using an environment variable so the password isn't exposed in `ps`.
encrypt_stream() {
    if [[ -n "$PASS1" ]]; then
        export BACKUP_PASS="$PASS1"
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:BACKUP_PASS
        local rc=$?
        unset BACKUP_PASS
        return $rc
    else
        cat
    fi
}

echo ""
if [[ -n "$PASS1" ]]; then
    info "Backing up ${C_BOLD}$DRIVE_GB GiB${C_RESET} (compressing, encrypting, and hashing on the fly)..."
else
    info "Backing up ${C_BOLD}$DRIVE_GB GiB${C_RESET} (compressing and hashing on the fly)..."
fi
warn "Do NOT interrupt or power off."

# All three output files are opened at pipeline start, so create, track, and chown them immediately.
touch "$RAW_HASH_FILE" "$DEST_FILE" "$ARCHIVE_HASH_FILE"
track_file "$RAW_HASH_FILE"
track_file "$DEST_FILE"
track_file "$ARCHIVE_HASH_FILE"
chown_backup "$RAW_HASH_FILE" "$DEST_FILE" "$ARCHIVE_HASH_FILE"

ARCHIVE_BASENAME="$(basename "$DEST_FILE")"

if command -v pv &>/dev/null; then
    dd if="$SRC_DEVICE" bs=$DD_BS status=none |
        pv -s "$DRIVE_BYTES" "${PV_OPTS[@]}" |
        tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") |
        zstd -3 -T0 -q --stream-size="$DRIVE_BYTES" |
        encrypt_stream |
        tee >(sha256sum | awk -v f="$ARCHIVE_BASENAME" '{print $1 "  " f}' > "$ARCHIVE_HASH_FILE") > "$DEST_FILE"
else
    dd if="$SRC_DEVICE" bs=$DD_BS status=progress |
        tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") |
        zstd -3 -T0 -q --stream-size="$DRIVE_BYTES" |
        encrypt_stream |
        tee >(sha256sum | awk -v f="$ARCHIVE_BASENAME" '{print $1 "  " f}' > "$ARCHIVE_HASH_FILE") > "$DEST_FILE"
fi

# Wait for both background sha256sum process substitutions to finish writing before reading them.
wait

echo ""
info "Flushing buffers to disk..."
sync

FINAL_SIZE=$(du -h "$DEST_FILE" | cut -f1)
echo ""
ok "Backup completed successfully!"
echo "Archive           : ${C_BOLD}$DEST_FILE${C_RESET} ($FINAL_SIZE)"
echo "Raw Disk SHA-256  : $(awk '{print $1}' "$RAW_HASH_FILE")"
echo "Archive SHA-256   : $(awk '{print $1}' "$ARCHIVE_HASH_FILE")"
echo "Owned by          : ${OWNER_NAME}:${OWNER_GROUP}"
