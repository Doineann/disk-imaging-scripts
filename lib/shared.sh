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

    local ok=0
    for m in "${mps[@]}"; do
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
# Prints a numbered list of .zstd / .zstd.enc backup files found in CWD (maxdepth 2)
# and reads a selection. Sets SRC_ARCHIVE to the chosen path. Returns 1 if not found.
pick_archive() {
    local prompt_label="$1"
    echo "Searching current folder for backup archives (*.zstd / *.zstd.enc)..."

    mapfile -t FOUND_FILES < <(
        find . -maxdepth 2 -type f \( -name "*.zstd" -o -name "*.zstd.enc" \) 2>/dev/null |
            sed 's|^\./||' |
            sort
    )

    SRC_ARCHIVE=""

    if [[ ${#FOUND_FILES[@]} -gt 0 ]]; then
        echo ""
        info "Found the following backup files:"
        echo "------------------------------------------------------------------------"
        for i in "${!FOUND_FILES[@]}"; do
            FILE_PATH="${FOUND_FILES[$i]}"
            FILE_SIZE=$(du -h "$FILE_PATH" 2>/dev/null | cut -f1)
            FILE_DATE=$(date -r "$FILE_PATH" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown date")
            ENC_TAG=""
            [[ "$FILE_PATH" == *.enc ]] && ENC_TAG=" ${C_YELLOW}[Encrypted]${C_RESET}"
            printf "  ${C_BOLD}[%d]${C_RESET} %s (%s, %s)%s\n" "$((i + 1))" "$FILE_PATH" "$FILE_SIZE" "$FILE_DATE" "$ENC_TAG"
        done
        echo "  Enter a custom file path manually"
        echo "------------------------------------------------------------------------"

        local clean_label="${prompt_label%:}"
        while true; do
            read -rp "${clean_label}: " CHOICE
            if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
                if [[ "$CHOICE" -eq 0 ]]; then
                    read -rp "Enter the full path to the backup file (.zstd / .zstd.enc): " SRC_ARCHIVE
                    break
                elif [[ "$CHOICE" -ge 1 && "$CHOICE" -le ${#FOUND_FILES[@]} ]]; then
                    SRC_ARCHIVE="${FOUND_FILES[$((CHOICE - 1))]}"
                    break
                fi
            fi
            warn "Invalid selection. Please enter a number from the list above."
        done
    else
        warn "No .zstd or .zstd.enc backup files found in the current folder."
        read -rp "Enter the full path to the backup file (.zstd / .zstd.enc): " SRC_ARCHIVE
    fi

    if [[ ! -f "$SRC_ARCHIVE" ]]; then
        err "File '$SRC_ARCHIVE' not found."
        return 1
    fi
}

# --- pick_source <prompt-label> -------------------------------------------
# Lists drives, user picks a drive -> lists partitions + Whole disk.
# Sets SRC_DEVICE to the chosen device path (/dev/sda or /dev/sda1).
# Sets SRC_TYPE to "disk" or "part".
pick_source() {
    local prompt_label="$1"
    echo ""
    info "Available drives:"
    lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
    echo "----------------------------------------"

    read -rp "${prompt_label%:} (e.g., /dev/nvme0n1 or /dev/sda): " SRC_DRIVE
    if [[ ! -b "$SRC_DRIVE" ]]; then
        err "'$SRC_DRIVE' is not a valid block device."
        return 1
    fi

    local input_name
    input_name=$(basename "${SRC_DRIVE%/}")
    local input_parent
    input_parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$input_name" '$2==x{print $1; exit}')
    if [[ -n "$input_parent" ]]; then
        SRC_DEVICE="$SRC_DRIVE"
        SRC_TYPE="part"
        info "Detected partition ${C_BOLD}$SRC_DEVICE${C_RESET} (on /dev/$input_parent)."
        return 0
    fi

    local disk_name
    disk_name="$input_name"
    mapfile -t PART_NAMES < <(lsblk -ln -o PKNAME,NAME | awk -v d="$disk_name" '$1==d && $2!=""{print $2}')

    if [[ ${#PART_NAMES[@]} -gt 0 ]]; then
        echo ""
        info "Partitions on ${C_BOLD}$SRC_DRIVE${C_RESET}:"
        echo "------------------------------------------------------------------------"
        printf "  ${C_BOLD}${C_RESET} Whole disk (%s)\n" "$disk_name"
        for i in "${!PART_NAMES[@]}"; do
            local name="${PART_NAMES[$i]}"
            local dev="/dev/${name}"
            local sz fst mp tag
            sz=$(lsblk -no SIZE "$dev")
            fst=$(lsblk -no FSTYPE "$dev")
            mp=$(lsblk -no MOUNTPOINT "$dev")
            tag=""; [[ -n "$mp" ]] && tag="  (mounted: $mp)"
            printf "  ${C_BOLD}[%d]${C_RESET} %s   %-8s  %-10s%s\n" "$((i + 1))" "$name" "${sz:-?}" "${fst:-<none>}" "$tag"
        done
        echo "------------------------------------------------------------------------"

        local SEL
        while true; do
            read -rp "Select source [0 = whole disk]: " SEL
            if [[ "$SEL" == "0" ]]; then
                SRC_DEVICE="$SRC_DRIVE"
                SRC_TYPE="disk"
                break
            elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#PART_NAMES[@]} )); then
                SRC_DEVICE="/dev/${PART_NAMES[$((SEL - 1))]}"
                SRC_TYPE="part"
                break
            else
                warn "Invalid selection. Enter 0 for whole disk, or a partition number."
            fi
        done
    else
        SRC_DEVICE="$SRC_DRIVE"
        SRC_TYPE="disk"
    fi

    return 0
}

# --- dd_verify <dd-args...> -----------------------------------------------
# Fallback progress display when pv is unavailable. Passes stream to stdout while
# rewriting "copied" to "verified" on stderr.
dd_verify() {
    dd "$@" bs=$DD_BS status=progress 2> >(sed -u 's/copied/verified/g' >&2)
}
