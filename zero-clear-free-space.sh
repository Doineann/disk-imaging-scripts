#!/usr/bin/env bash
set -euo pipefail

# Loose reserve left free at the end (we stop when the partition is full, so the real
# leftover may be a bit more or less than this — that's fine).
RESERVE_BYTES=$((1024 * 1024 * 64))   # ~64 MiB

source "$(dirname "${BASH_SOURCE[0]}")/lib/shared.sh"
DD_BS_BYTES=$((64 * 1024 * 1024))

BASE_WORK="/run/wipe-free-space.$$"
CURRENT_MP=""
CURRENT_TMP=""
CLEARED_BYTES=0

on_exit() {
    if [[ -n "$CURRENT_TMP" && -d "$CURRENT_TMP" ]]; then rm -rf -- "$CURRENT_TMP"; fi
    if [[ -n "$CURRENT_MP"  && -d "$CURRENT_MP"  ]]; then umount "$CURRENT_MP" 2>/dev/null || true; fi
    rm -rf -- "$BASE_WORK" 2>/dev/null || true
}

# Core: roughly zero the free space of an ALREADY-mounted filesystem at $1.
#   $1 = mountpoint, $2 = fstype (ext4|vfat|exfat|ntfs|btrfs)
# Writes one big zero-file up to ~all-but-a-reserve of the free space (or several
# ~3 GiB chunks on FAT32, which can't hold files >= 4 GiB). Not exact: we stop when
# the partition is full. Sets CLEARED_BYTES to bytes physically written as zeros.
wipe_free_on_mounted() {
    local mp="$1" fstype="$2"
    local tmpdir="$mp/.wipe_free_tmp"

    # Remove any leftover from a previously interrupted run on this fs, then start fresh.
    rm -rf -- "$tmpdir"
    mkdir -- "$tmpdir"

    # FAT32 can't hold files >= 4 GiB, so we write it as ~3 GiB chunks instead of one file.
    local maxfile=0
    if [[ "$fstype" == "vfat" ]]; then
        maxfile=$((1024 * 1024 * 3))   # 3 GiB per file
    fi

    CLEARED_BYTES=0
    local avail target nfiles written idx rem want blocks f ok
    avail=$(df --output=avail -B1 "$mp" | tail -n 1)
    target=$(( avail - RESERVE_BYTES ))
    if (( target <= 0 )); then
        info "  (no free space to clear on this partition)"
        return 0
    fi

    # One big file, or several ~3 GiB chunks for FAT32.
    if (( maxfile > 0 )); then
        nfiles=$(( (target + maxfile - 1) / maxfile ))   # ceil, loose
    else
        nfiles=1
    fi

    written=0
    for (( idx = 0; idx < nfiles; idx++ )); do
        rem=$(( target - written ))
        want=$rem
        if (( maxfile > 0 )) && (( rem > maxfile )); then want=$maxfile; fi
        blocks=$(( want / DD_BS_BYTES ))                # whole DD_BS-sized blocks (loose)
        if (( blocks < 1 )); then break; fi

        f="$tmpdir/zero_$(printf '%03d' "$idx")"
        : > "$f"                                          # create empty so flags can be set pre-write
        if [[ "$fstype" == "btrfs" ]]; then chattr +C "$f"; fi   # store zeros physically, not compressed

        if (( nfiles == 1 )); then
            info "  Zeroing ~$((want / (1024*1024*1024))) GiB of free space..."
        else
            info "  Zeroing chunk $((idx + 1))/$nfiles (~$((want / (1024*1024*1024))) GiB)..."
        fi

        ok=0
        if command -v pv &>/dev/null; then
            dd if=/dev/zero bs=$DD_BS count="$blocks" status=none | pv -s $(( blocks * DD_BS_BYTES )) "${PV_OPTS[@]}" > "$f" || ok=$?
        else
            dd if=/dev/zero of="$f" bs=$DD_BS count="$blocks" status=progress || ok=$?
        fi
        # A short final write just means the partition is full — that's what we want.
        if (( ok != 0 )); then break; fi

        written=$(( written + blocks * 4 * 1024 * 1024 ))
    done

    CLEARED_BYTES=$written

    # Delete the zero-file(s): their blocks are freed again, now physically containing zeros.
    rm -rf -- "$tmpdir"
}

main() {
    echo ""
    echo "========================================"
    bold "   CLEAR FREE SPACE ON PARTITIONS       "
    echo "========================================"
    echo ""

    # --- Source selection: whole disk or single partition ---------------------
    local SRC_DEVICE SRC_TYPE
    pick_source "Enter the DISK or PARTITION to clear:" || exit 1

    # Build the partition list based on what was selected.
    local PART_NAMES=() PART_SIZE=() PART_FSTYPE=() PART_MP=()
    if [[ "$SRC_TYPE" == "part" ]]; then
        # Single partition selected — use it directly.
        PART_NAMES=( "$(basename "${SRC_DEVICE%/}")" )
        PART_SIZE[0]=$(lsblk -no SIZE "$SRC_DEVICE")
        PART_FSTYPE[0]=$(lsblk -no FSTYPE "$SRC_DEVICE")
        PART_MP[0]=$(lsblk -no MOUNTPOINT "$SRC_DEVICE")
    else
        # Whole disk selected — enumerate all partitions.
        local disk_name
        disk_name=$(basename "${SRC_DEVICE%/}")
        mapfile -t PART_NAMES < <(lsblk -ln -o PKNAME,NAME | awk -v d="$disk_name" '$1==d && $2!=""{print $2}')
        if [[ ${#PART_NAMES[@]} -eq 0 ]]; then
            warn "No partitions found on /dev/$disk_name."
            exit 1
        fi
        for i in "${!PART_NAMES[@]}"; do
            local dev="/dev/${PART_NAMES[$i]}"
            PART_SIZE[i]=$(lsblk -no SIZE "$dev")
            PART_FSTYPE[i]=$(lsblk -no FSTYPE "$dev")
            PART_MP[i]=$(lsblk -no MOUNTPOINT "$dev")
        done
    fi

    # Display partitions.
    echo ""
    info "Partitions on ${C_BOLD}$SRC_DEVICE${C_RESET}:"
    echo "------------------------------------------------------------------------"
    for i in "${!PART_NAMES[@]}"; do
        local name="${PART_NAMES[$i]}"
        local tag=""
        [[ -n "${PART_MP[$i]}" ]] && tag="  (mounted: ${PART_MP[$i]})"
        printf "  ${C_BOLD}[%d]${C_RESET} %s   %-8s  %-10s%s\n" "$((i + 1))" "$name" "${PART_SIZE[$i]:-?}" "${PART_FSTYPE[$i]:-<none>}" "$tag"
    done
    echo "------------------------------------------------------------------------"

    # Selection.
    local SEL SELECTED=() s SEL_RE='^[0-9][0-9 ,]*$'
    if [[ ${#PART_NAMES[@]} -eq 1 ]]; then
        # Single partition — no need to ask, just confirm.
        info "Clearing free space on ${C_BOLD}${PART_NAMES[0]}${C_RESET}."
        SELECTED=(0)
    else
        while true; do
            read -rp "Clear free space on which partition(s)?  [numbers, or 'a' = all]: " SEL
            if [[ "$SEL" == "a" || "$SEL" == "A" ]]; then
                for i in "${!PART_NAMES[@]}"; do SELECTED+=("$i"); done
                break
            elif [[ "$SEL" =~ $SEL_RE ]]; then
                SELECTED=()
                for s in ${SEL//,/ }; do
                    if (( s >= 1 && s <= ${#PART_NAMES[@]} )); then SELECTED+=("$((s - 1))"); fi
                done
                break
            else
                warn "Invalid selection. Enter numbers (e.g. '1 3'), or 'a' for all."
            fi
        done
    fi

    if [[ ${#SELECTED[@]} -eq 0 ]]; then
        info "No partitions selected. Nothing to do."
        exit 0
    fi

    # Estimate total bytes to write (across selected, unmounted) for the warning.
    # df on an UNMOUNTED device node reports the host's /dev filesystem (devtmpfs),
    # not the partition — so mount each one read-only first to measure real free space.
    local total_bytes=0 a probe_mp
    for i in "${SELECTED[@]}"; do
        if [[ -n "${PART_MP[$i]}" ]]; then continue; fi   # mounted -> will unmount at run time
        probe_mp="$BASE_WORK/probe_${PART_NAMES[$i]}"
        mkdir -p -- "$probe_mp"
        if mount -o ro "/dev/${PART_NAMES[$i]}" "$probe_mp"; then
            a=$(df --output=avail -B1 "$probe_mp" | tail -n 1)
            umount "$probe_mp"
            total_bytes=$(( total_bytes + a ))
        else
            warn "  (could not probe ${PART_NAMES[$i]} read-only; excluded from estimate)"
        fi
        rmdir -- "$probe_mp" 2>/dev/null || true
    done
    local total_gib
    total_gib=$(awk "BEGIN{printf \"%.2f\", $total_bytes/1073741824}")

    echo ""
    warn "This will WRITE ~${C_BOLD}${total_gib} GiB${C_RESET} of zeros (a full physical write of the free space)."
    warn "It is a normal disk-wear operation and may take a while. Do NOT interrupt or power off."
    read -rp "Type 'CLEAR' to continue: " CONFIRM
    if [[ "$CONFIRM" != "CLEAR" ]]; then
        info "Aborted."
        exit 0
    fi

    # Process each selected partition in turn.
    for i in "${SELECTED[@]}"; do
        local name="${PART_NAMES[$i]}"
        local dev="/dev/${name}"
        local fstype gib
        fstype="${PART_FSTYPE[$i]}"
        if [[ -z "$fstype" ]]; then
            warn "SKIP ${C_BOLD}${name}${C_RESET}: no filesystem (raw/unformatted)."
            continue
        fi

        # Unmount if currently mounted, so we can remount cleanly for the zero-write.
        if [[ -n "${PART_MP[$i]}" ]]; then
            info "Unmounting ${C_BOLD}${name}${C_RESET} (${PART_MP[$i]})..."
            umount "/dev/${name}" 2>/dev/null || true
        fi

        CURRENT_MP="$BASE_WORK/${name}"
        mkdir -p -- "$CURRENT_MP"
        mount "/dev/${name}" "$CURRENT_MP"
        CURRENT_TMP="$CURRENT_MP/.wipe_free_tmp"

        echo ""
        info "Clearing free space on ${C_BOLD}${name}${C_RESET} (${fstype})..."
        wipe_free_on_mounted "$CURRENT_MP" "$fstype"

        sync
        umount "$CURRENT_MP"
        rmdir -- "$CURRENT_MP" 2>/dev/null || true
        CURRENT_MP=""; CURRENT_TMP=""

        gib=$(awk "BEGIN{printf \"%.2f\", $CLEARED_BYTES/1073741824}")
        ok "Cleared ~${gib} GiB of free space on ${C_BOLD}${name}${C_RESET}."
    done

    echo ""
    echo "========================================"
    bold "  DONE: FREE SPACE CLEARED             "
    echo "========================================"
}

# Enforce runtime guards and run only when executed directly (not sourced by tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)."
        exit 1
    fi
    for cmd in dd df lsblk mount umount chattr awk; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Required command '$cmd' is not installed."
            exit 1
        fi
    done
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main "$@"
fi
