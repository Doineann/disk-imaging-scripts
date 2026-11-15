#!/usr/bin/env bash
# lib/shared.sh — shared helpers for the disk-imaging scripts. Sourced, not executed.
# Harmless when run directly: only defines variables and functions, no side effects.

set -euo pipefail

# --- Constants -----------------------------------------------------------

# Block size for dd. Larger blocks cut syscall overhead on fast media (modern SSDs
# can sustain ~10 GB/s), but each dd allocates one buffer of this size, so keep it
# modest to bound memory use across the pipeline. 64 MiB is a good balance.
DD_BS=64M

# pv progress-bar options: cap width at 70 cols, clean format (bytes, bar+%, rate).
# Stored as an array so each argument is passed intact to pv.
PV_OPTS=(-w 70 --format '%b %p %r')

# --- Colors ---------------------------------------------------------------
# ANSI codes, auto-disabled when stdout is not a TTY (so piped/redirected output
# stays clean). Semantic helpers: ok / err / warn / info / bold / reset.
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

ok()   { printf "${C_GREEN}OK${C_RESET}: %s\n" "$*"; }
err()  { printf "${C_RED}ERROR${C_RESET}: %s\n" "$*" >&2; }
warn() { printf "${C_YELLOW}WARNING${C_RESET}: %s\n" "$*"; }
info() { printf "${C_BLUE}%s${C_RESET}\n" "$*"; }
bold() { printf "${C_BOLD}%s${C_RESET}\n" "$*"; }

# --- ensure_unmounted <dev> -----------------------------------------------
# Offer to unmount any partitions on $1 (a whole disk) before we read/write it.
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
    info "The following partitions on ${C_BOLD}$dev${C_RESET} are currently mounted:"
    local m; for m in "${mps[@]}"; do printf "  %s\n" "$m"; done
    read -rp "Unmount them now? (y/n): " UNMOUNT_ANSWER
    if [[ ! "$UNMOUNT_ANSWER" =~ ^[Yy]$ ]]; then
        warn "Leaving partitions mounted."
        return 1
    fi

    local ok=0 m2
    for m in "${mps[@]}"; do
        # The mountpoint may be a bind/loop path; unmount the device itself.
        if umount "$m" 2>/dev/null; then
            ok "Unmounted $m."
        else
            warn "Could not unmount $m (in use or permission denied)."
            ok=1
        fi
    done
    return $ok
}

# --- pick_archive <prompt-label> ------------------------------------------
# Prints a numbered list of .7z backup files found in CWD (maxdepth 2) and reads
# a selection. Sets SRC_ARCHIVE to the chosen path. Returns 1 if no file selected.
pick_archive() {
    local prompt_label="$1"
    echo "Searching current folder for backup archives (*.img.7z / *.7z)..."

    mapfile -t FOUND_FILES < <(find . -maxdepth 2 -type f \( -name "*.img.7z" -o -name "*.7z" \) 2>/dev/null | sed 's|^\./||' | sort)

    SRC_ARCHIVE=""

    if [[ ${#FOUND_FILES[@]} -gt 0 ]]; then
        echo ""
        info "Found the following backup files:"
        echo "------------------------------------------------------------------------"
        for i in "${!FOUND_FILES[@]}"; do
            FILE_PATH="${FOUND_FILES[$i]}"
            FILE_SIZE=$(du -h "$FILE_PATH" 2>/dev/null | cut -f1)
            FILE_DATE=$(date -r "$FILE_PATH" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown date")
            printf "  ${C_BOLD}[%d]${C_RESET} %s (%s, %s)\n" "$((i + 1))" "$FILE_PATH" "$FILE_SIZE" "$FILE_DATE"
        done
        echo "  [0] Enter a custom file path manually"
        echo "------------------------------------------------------------------------"

        # Strip any trailing colon from the label so we don't get "::" in the prompt.
        local clean_label="${prompt_label%:}"
        while true; do
            read -rp "${clean_label}: " CHOICE
            if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
                if [[ "$CHOICE" -eq 0 ]]; then
                    read -rp "Enter the full path to the backup .7z file: " SRC_ARCHIVE
                    break
                elif [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#FOUND_FILES[@]} ]]; then
                    SRC_ARCHIVE="${FOUND_FILES[$((CHOICE - 1))]}"
                    break
                fi
            fi
            warn "Invalid selection. Please enter a number from the list above."
        done
    else
        warn "No .7z backup files found in the current folder."
        read -rp "Enter the full path to the backup .7z file: " SRC_ARCHIVE
    fi

    if [[ ! -f "$SRC_ARCHIVE" ]]; then
        err "File '$SRC_ARCHIVE' not found."
        return 1
    fi
}

# --- dd_verify <dd-args...> -----------------------------------------------
# Fallback progress display when pv is unavailable. Runs dd with status=progress,
# rewriting "copied" to "verified" in the live stderr line.
dd_verify() {
    dd "$@" bs=$DD_BS status=progress 2> >(awk 'BEGIN{RS="\r|\n"} NF{gsub(/copied/, "verified"); printf "\r\033[K%s", $0 > "/dev/stderr"; fflush("/dev/stderr")} END{printf "\n" > "/dev/stderr"}')
}
