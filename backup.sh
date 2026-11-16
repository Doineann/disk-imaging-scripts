#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

for cmd in dd 7z lsblk blockdev sha256sum tee; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' is not installed."
        exit 1
    fi
done

# Resolve the human user who invoked us via sudo, so we can hand ownership of the
# backup files back to them (the script itself runs as root). Prefer $SUDO_USER;
# fall back to the effective user if that's unavailable.
OWNER_UID="$(id -u)"
if [[ -n "${SUDO_USER:-}" ]]; then
    OWNER_NAME="$SUDO_USER"
else
    OWNER_NAME="$(id -un)"
fi
# Primary group of that user (for chown user:group).
OWNER_GROUP="$(getent group "$OWNER_NAME" 2>/dev/null | cut -d: -f3 || true)"

# Hand ownership of the produced backup files back to the invoking user.
chown_backup() {
    local f
    for f in "$@"; do
        [[ -e "$f" ]] && chown "${OWNER_NAME}:${OWNER_GROUP}" -- "$f" 2>/dev/null || true
    done
}

# --- Cleanup on exit / interrupt: remove any artifacts THIS run created. ---
# Only files we actually made are tracked (CREATED=1), so a pre-existing file is never
# touched, and the trap is only armed after the user confirms "Start backup".
CLEANUP_FILES=()
cleanup_on_exit() {
    local rc=$? f
    # On success (rc==0) keep everything; on error/interrupt remove our artifacts.
    if (( rc != 0 )); then
        for f in "${CLEANUP_FILES[@]}"; do rm -f -- "$f" 2>/dev/null || true; done
    fi
}
track_file() { [[ -n "${1:-}" ]] && CREATED=1 CLEANUP_FILES+=("$1"); }
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "========================================"
bold "  FULL DISK BACKUP (dd + 7z + SHA256)   "
echo "========================================"
echo ""

pick_source "Enter the SOURCE drive to back up:" || exit 1

if ! ensure_unmounted "$SRC_DEVICE"; then
    # Reading a live disk may yield changing data; warn but allow the user to proceed.
    echo ""
    read -rp "One or more partitions are still mounted. Continue reading anyway? (y/n): " MOUNT_CONFIRM
    if [[ ! "$MOUNT_CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Aborted."
        exit 1
    fi
fi

read -rp "Enter the DESTINATION folder path (e.g., /mnt/external_drive/backups): " DEST_DIR
# An empty answer means "put it here" — default to the current working directory.
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

# Determine filename suffix based on source type.
if [[ "$SRC_TYPE" == "part" ]]; then
    SUFFIX=".part.img.7z"
else
    SUFFIX=".disk.img.7z"
fi

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
echo "Checksums         : Raw Disk SHA-256 + Compressed Archive SHA-256"
bold "========================================="
read -rp "Start backup? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Backup cancelled."
    exit 0
fi

# Prompt for the backup password (hidden input). A BLANK answer means "no encryption" — we
# don't fail, we just create an unencrypted archive. When a password IS given we confirm
# it with a second read. Bare `-p` can't be used: in these pipelines 7z's stdin is a pipe,
# so it cannot open /dev/tty to prompt (E_INVALIDARG); we pass the secret explicitly.
read -rsp "Enter backup password (blank for none): " PASS1
echo
if [[ -n "$PASS1" ]]; then
    read -rsp "Re-enter backup password: " PASS2
    echo
    if [[ "$PASS1" != "$PASS2" ]]; then
        err "Passwords did not match. Aborting."
        exit 1
    fi
fi

# Build the 7z password argument: empty -> no -p (unencrypted), else -p"$PASS".
PW_ARG=()
[[ -n "$PASS1" ]] && PW_ARG=(-p"$PASS1")

echo ""
if [[ -n "$PASS1" ]]; then
    info "Backing up ${C_BOLD}$DRIVE_GB GiB${C_RESET} and computing raw SHA-256 on the fly (encrypted)..."
else
    info "Backing up ${C_BOLD}$DRIVE_GB GiB${C_RESET} and computing raw SHA-256 on the fly (unencrypted)..."
fi
warn "Do NOT interrupt or power off."

# The raw-hash file is created at pipeline start (by the tee branch), so track + chown it
# as soon as it exists — not only at the end.
touch "$RAW_HASH_FILE"; track_file "$RAW_HASH_FILE"
chown_backup "$RAW_HASH_FILE"

if command -v pv &>/dev/null; then
    dd if="$SRC_DEVICE" bs=$DD_BS status=none | pv -s "$DRIVE_BYTES" "${PV_OPTS[@]}" | tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") | 7z a -si -mx=1 "${PW_ARG[@]}" -bso0 -bsp0 -bse1 "$DEST_FILE"
else
    dd if="$SRC_DEVICE" bs=$DD_BS status=progress | tee >(sha256sum | awk '{print $1 "  raw-disk-image"}' > "$RAW_HASH_FILE") | 7z a -si -mx=1 "${PW_ARG[@]}" -bso0 -bsp0 -bse1 "$DEST_FILE"
fi

# The archive now exists (possibly partial if interrupted) — track + chown it immediately.
track_file "$DEST_FILE"
chown_backup "$DEST_FILE"

echo ""
info "Flushing buffers to disk..."
sync

info "Generating compressed archive SHA-256 checksum..."
(cd "$(dirname "$DEST_FILE")" && sha256sum "$(basename "$DEST_FILE")" > "$ARCHIVE_HASH_FILE")
track_file "$ARCHIVE_HASH_FILE"
chown_backup "$ARCHIVE_HASH_FILE"

FINAL_SIZE=$(du -h "$DEST_FILE" | cut -f1)
echo ""
ok "Backup completed successfully!"
echo "Archive           : ${C_BOLD}$DEST_FILE${C_RESET} ($FINAL_SIZE)"
echo "Raw Disk SHA-256  : $(awk '{print $1}' "$RAW_HASH_FILE")"
echo "Archive SHA-256   : $(awk '{print $1}' "$ARCHIVE_HASH_FILE")"
echo "Owned by          : ${OWNER_NAME}:${OWNER_GROUP}"
