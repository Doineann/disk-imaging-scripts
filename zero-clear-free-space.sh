#!/usr/bin/env bash
set -euo pipefail

# Loose reserve left free at the end (we stop when the partition is full, so the real
# leftover may be a bit more or less than this — that's fine).
RESERVE_BYTES=$((1024 * 1024 * 64))   # ~64 MiB

# Block size for dd. Larger blocks cut syscall overhead on fast media (modern SSDs
# can sustain ~10 GB/s), but each dd allocates one buffer of this size, so keep it
# modest to bound memory use across the pipeline. 64 MiB is a good balance.
DD_BS=64M
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
        echo "  (no free space to wipe on this partition)"
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
            echo "  Zeroing ~$((want / (1024*1024*1024))) GiB of free space..."
        else
            echo "  Zeroing chunk $((idx + 1))/$nfiles (~$((want / (1024*1024*1024))) GiB)..."
        fi

        ok=0
        if command -v pv &>/dev/null; then
            dd if=/dev/zero bs=$DD_BS count="$blocks" status=none | pv -s $(( blocks * DD_BS_BYTES )) > "$f" || ok=$?
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
    echo "========================================"
    echo "   WIPE FREE SPACE ON PARTITIONS        "
    echo "========================================"
    echo ""
    echo "Available drives and partitions:"
    lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
    echo "----------------------------------------"

    read -rp "Enter the DISK whose partitions to wipe (e.g. /dev/nvme0n1 or /dev/sda): " DISK_DEV
    local disk_name
    disk_name=$(basename "${DISK_DEV%/}")

    if [[ ! -b "/dev/$disk_name" ]]; then
        echo "Error: '/dev/$disk_name' is not a block device."
        exit 1
    fi
    # Refuse partitions: only operate on whole disks.
    local parent
    parent=$(lsblk -ln -o PKNAME,NAME | awk -v x="$disk_name" '$2==x{print $1; exit}')
    if [[ -n "$parent" ]]; then
        echo "Error: '/dev/$disk_name' is a partition of /dev/$parent. Enter the whole disk."
        exit 1
    fi

    # Enumerate this disk's partitions (clean, undecorated names).
    mapfile -t PART_NAMES < <(lsblk -ln -o PKNAME,NAME | awk -v d="$disk_name" '$1==d && $2!=""{print $2}')
    if [[ ${#PART_NAMES[@]} -eq 0 ]]; then
        echo "No partitions found on /dev/$disk_name."
        exit 1
    fi

    # Gather per-partition info.
    local PART_SIZE=() PART_FSTYPE=() PART_MP=()
    echo ""
    echo "Partitions on /dev/$disk_name:"
    echo "------------------------------------------------------------------------"
    for i in "${!PART_NAMES[@]}"; do
        local name="${PART_NAMES[$i]}"
        local dev="/dev/${name}"
        local sz fst mp tag
        sz=$(lsblk -no SIZE "$dev")
        fst=$(lsblk -no FSTYPE "$dev")
        mp=$(lsblk -no MOUNTPOINT "$dev")
        PART_SIZE[i]="$sz"; PART_FSTYPE[i]="$fst"; PART_MP[i]="$mp"
        tag=""; [[ -n "$mp" ]] && tag="  (mounted: $mp)"
        printf "  [%d] %s   %-8s  %-10s%s\n" "$((i + 1))" "$name" "${sz:-?}" "${fst:-<none>}" "$tag"
    done
    echo "------------------------------------------------------------------------"

    # Selection.
    local SEL SELECTED=() s SEL_RE='^[0-9][0-9 ,]*$'
    while true; do
        read -rp "Wipe free space on which partition(s)?  [numbers, or 'a' = all unmounted]: " SEL
        if [[ "$SEL" == "a" || "$SEL" == "A" ]]; then
            for i in "${!PART_NAMES[@]}"; do [[ -z "${PART_MP[$i]}" ]] && SELECTED+=("$i"); done
            break
        elif [[ "$SEL" =~ $SEL_RE ]]; then
            SELECTED=()
            for s in ${SEL//,/ }; do
                if (( s >= 1 && s <= ${#PART_NAMES[@]} )); then SELECTED+=("$((s - 1))"); fi
            done
            break
        else
            echo "Invalid selection. Enter numbers (e.g. '1 3'), or 'a' for all unmounted."
        fi
    done

    if [[ ${#SELECTED[@]} -eq 0 ]]; then
        echo "No partitions selected. Nothing to do."
        exit 0
    fi

    # Estimate total bytes to write (across selected, unmounted) for the warning.
    # df on an UNMOUNTED device node reports the host's /dev filesystem (devtmpfs),
    # not the partition — so mount each one read-only first to measure real free space.
    local total_bytes=0 a probe_mp
    for i in "${SELECTED[@]}"; do
        if [[ -n "${PART_MP[$i]}" ]]; then continue; fi   # mounted -> skipped at run time
        probe_mp="$BASE_WORK/probe_${PART_NAMES[$i]}"
        mkdir -p -- "$probe_mp"
        if mount -o ro "/dev/${PART_NAMES[$i]}" "$probe_mp"; then
            a=$(df --output=avail -B1 "$probe_mp" | tail -n 1)
            umount "$probe_mp"
            total_bytes=$(( total_bytes + a ))
        else
            echo "  (could not probe ${PART_NAMES[$i]} read-only; excluded from estimate)"
        fi
        rmdir -- "$probe_mp" 2>/dev/null || true
    done
    local total_gib
    total_gib=$(awk "BEGIN{printf \"%.2f\", $total_bytes/1073741824}")

    echo ""
    echo "This will WRITE ~${total_gib} GiB of zeros (a full physical write of the free space)."
    echo "It is a normal disk-wear operation and may take a while. Do NOT interrupt or power off."
    read -rp "Type 'WIPE' to continue: " CONFIRM
    if [[ "$CONFIRM" != "WIPE" ]]; then
        echo "Aborted."
        exit 0
    fi

    # Process each selected partition in turn.
    for i in "${SELECTED[@]}"; do
        local name="${PART_NAMES[$i]}"
        local dev="/dev/${name}"
        local fstype gib
        if [[ -n "${PART_MP[$i]}" ]]; then
            echo "SKIP ${name}: currently mounted (${PART_MP[$i]}). Unmount it first."
            continue
        fi
        fstype="${PART_FSTYPE[$i]}"
        if [[ -z "$fstype" ]]; then
            echo "SKIP ${name}: no filesystem (raw/unformatted)."
            continue
        fi

        CURRENT_MP="$BASE_WORK/${name}"
        mkdir -p -- "$CURRENT_MP"
        mount "/dev/${name}" "$CURRENT_MP"
        CURRENT_TMP="$CURRENT_MP/.wipe_free_tmp"

        echo ""
        echo "Wiping free space on ${name} (${fstype})..."
        wipe_free_on_mounted "$CURRENT_MP" "$fstype"

        sync
        umount "$CURRENT_MP"
        rmdir -- "$CURRENT_MP" 2>/dev/null || true
        CURRENT_MP=""; CURRENT_TMP=""

        gib=$(awk "BEGIN{printf \"%.2f\", $CLEARED_BYTES/1073741824}")
        echo "OK: cleared ~${gib} GiB of free space on ${name}."
    done

    echo ""
    echo "========================================"
    echo "  DONE: FREE SPACE ZEROED              "
    echo "========================================"
}

# Enforce runtime guards and run only when executed directly (not sourced by tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root (use sudo)."
        exit 1
    fi
    for cmd in dd df lsblk mount umount chattr awk; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Required command '$cmd' is not installed."
            exit 1
        fi
    done
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main "$@"
fi
