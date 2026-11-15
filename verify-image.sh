#!/usr/bin/env bash
set -euo pipefail

for cmd in 7z sha256sum find du date dd awk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# Block size for dd. Larger blocks cut syscall overhead on fast media (modern SSDs
# can sustain ~10 GB/s), but each dd allocates one buffer of this size, so keep it
# modest to bound memory use across the pipeline. 64 MiB is a good balance.
DD_BS=64M

echo "========================================"
echo "        BACKUP INTEGRITY VERIFIER       "
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

RAW_HASH_FILE="${SRC_ARCHIVE}.raw.sha256"
ARCHIVE_HASH_FILE="${SRC_ARCHIVE}.sha256"

# Unbuffered on-the-fly replacement of "copied" with "verified"
dd_verify() {
    dd "$@" bs=$DD_BS status=progress 2> >(awk 'BEGIN{RS="\r|\n"} NF{gsub(/copied/, "verified"); printf "\r\033[K%s", $0 > "/dev/stderr"; fflush("/dev/stderr")} END{printf "\n" > "/dev/stderr"}')
}

# 1. Compressed File SHA-256 Check with Progress
echo ""
if [[ -f "$ARCHIVE_HASH_FILE" ]]; then
    echo "[1/2] Verifying compressed archive SHA-256..."
    EXPECTED_ARCHIVE_HASH=$(awk '{print $1}' "$ARCHIVE_HASH_FILE")

    if command -v pv &>/dev/null; then
        COMPUTED_ARCHIVE_HASH=$(pv -w 63 --format '%b %p %r' "$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    else
        COMPUTED_ARCHIVE_HASH=$(dd_verify if="$SRC_ARCHIVE" | sha256sum | awk '{print $1}')
    fi

    if [[ "$COMPUTED_ARCHIVE_HASH" == "$EXPECTED_ARCHIVE_HASH" ]]; then
        echo "OK: Compressed file matches original checksum ($COMPUTED_ARCHIVE_HASH)."
    else
        echo "ERROR: Compressed archive SHA-256 mismatch!"
        echo "Expected: $EXPECTED_ARCHIVE_HASH"
        echo "Actual  : $COMPUTED_ARCHIVE_HASH"
        exit 1
    fi
else
    echo "[1/2] No .sha256 file found for compressed archive (skipping)."
fi

# 2. Full Decompression & Raw Stream SHA-256 Check with Progress
echo ""
echo "[2/2] Decompressing stream and verifying raw disk SHA-256..."
UNCOMPRESSED_BYTES=$(7z l -slt "$SRC_ARCHIVE" 2>/dev/null | awk -F' = ' '/^Size = /{print $2; exit}')

# Encrypted (PFS) backups need a password to decode. Bare `-p` can't be used here: 7z's
# stdin is a pipe in these pipelines, so it cannot open /dev/tty to prompt (E_INVALIDARG).
# We read the secret explicitly; blank is fine for unencrypted archives.
read -rsp "Enter backup password (blank if none): " PASS
echo

if command -v pv &>/dev/null; then
    if [[ -n "$UNCOMPRESSED_BYTES" && "$UNCOMPRESSED_BYTES" -gt 0 ]]; then
        COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -s "$UNCOMPRESSED_BYTES" -w 63 --format '%b %p %r' | sha256sum | awk '{print $1}')
    else
        COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | pv -pterb -w 63 --format '%b %p %r' | sha256sum | awk '{print $1}')
    fi
else
    COMPUTED_RAW_HASH=$(7z x -so -p"$PASS" -bso0 -bsp0 -bse1 "$SRC_ARCHIVE" | dd_verify | sha256sum | awk '{print $1}')
fi

if [[ -f "$RAW_HASH_FILE" ]]; then
    EXPECTED_RAW_HASH=$(awk '{print $1}' "$RAW_HASH_FILE")
    if [[ "$COMPUTED_RAW_HASH" == "$EXPECTED_RAW_HASH" ]]; then
        echo "OK: Raw uncompressed stream matches original drive SHA-256 ($COMPUTED_RAW_HASH)."
    else
        echo "ERROR: Raw stream SHA-256 mismatch!"
        echo "Expected: $EXPECTED_RAW_HASH"
        echo "Actual  : $COMPUTED_RAW_HASH"
        exit 1
    fi
else
    echo "OK: Decompression succeeded with no 7z CRC errors."
fi

echo ""
echo "========================================"
echo "  ALL CHECKS PASSED: BACKUP IS HEALTHY  "
echo "========================================"
