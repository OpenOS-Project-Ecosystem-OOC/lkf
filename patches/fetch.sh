#!/usr/bin/env bash
# patches/fetch.sh — Download upstream patch sets for a given kernel version.
#
# Usage:
#   fetch.sh --version <kver> [--set aufs|rt|xanmod|cachyos|all] [--dir <patches_dir>]
#
# Examples:
#   fetch.sh --version 6.6.30
#   fetch.sh --version 6.6.30 --set rt
#   fetch.sh --version 6.6.30 --set cachyos --dir /tmp/patches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}"
KVER=""
SETS=()

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    local code="${1:-0}"
    echo "Usage: $0 --version <kver> [--set <set>] [--dir <dir>]"
    echo "  --version  Kernel version, e.g. 6.6.30"
    echo "  --set      Patch set: aufs, rt, xanmod, cachyos, all (default: all)"
    echo "  --dir      Output directory (default: script directory)"
    exit "${code}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) KVER="$2"; shift 2 ;;
        --set)     SETS+=("$2"); shift 2 ;;
        --dir)     PATCHES_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown argument: $1"; usage 1 ;;
    esac
done

[[ -z "$KVER" ]] && { echo "Error: --version is required"; usage 1; }
[[ ${#SETS[@]} -eq 0 ]] && SETS=("all")

# Expand "all"
if [[ " ${SETS[*]} " == *" all "* ]]; then
    SETS=(aufs rt xanmod cachyos)
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[fetch] $*"; }
warn() { echo "[fetch] WARNING: $*" >&2; }

download() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        log "Already exists: $(basename "$dest")"
        return 0
    fi
    log "Downloading $(basename "$dest") ..."
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 3 -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --tries=3 -O "$dest" "$url"
    else
        echo "Error: neither curl nor wget found" >&2
        return 1
    fi
}

# Parse version components
KMAJ="${KVER%%.*}"
KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"
# shellcheck disable=SC2034  # KPATCH used by fetch_tkg added in this session
KPATCH="${KVER##*.}"

# ── Fetch functions ───────────────────────────────────────────────────────────

fetch_rt() {
    local dir="${PATCHES_DIR}/rt"
    mkdir -p "$dir"

    # RT patch naming: patch-<kver>-rt<N>.patch
    # We probe the kernel.org RT directory for the latest rt suffix.
    local base_url="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KMAJ}.${KMIN}/"
    log "Probing RT patch index at ${base_url} ..."

    local index
    if command -v curl &>/dev/null; then
        index=$(curl -fsSL --retry 3 "$base_url" 2>/dev/null || true)
    else
        index=$(wget -q -O- "$base_url" 2>/dev/null || true)
    fi

    if [[ -z "$index" ]]; then
        warn "Could not reach RT patch index for ${KMAJ}.${KMIN}"
        return 0
    fi

    # Find the highest rt<N> suffix for this exact kver (prefer .xz, fall back to .patch)
    local rt_file
    rt_file=$(echo "$index" | grep -oP "patch-${KVER}-rt[0-9]+\.patch(\.xz)?" | sort -V | tail -1 || true)

    if [[ -z "$rt_file" ]]; then
        warn "No RT patch found for ${KVER} (only the latest stable RT patch is kept on the CDN)"
        return 0
    fi

    if [[ "$rt_file" == *.xz ]]; then
        local dest="${dir}/${rt_file%.xz}"
        if [[ -f "$dest" ]]; then
            log "Already exists: $(basename "$dest")"
            return 0
        fi
        download "${base_url}${rt_file}" "${dir}/${rt_file}"
        xz -d "${dir}/${rt_file}"
        log "RT patch ready: $(basename "$dest")"
    else
        local dest="${dir}/${rt_file}"
        download "${base_url}${rt_file}" "$dest"
        log "RT patch ready: $(basename "$dest")"
    fi
}

fetch_aufs() {
    local dir="${PATCHES_DIR}/aufs"
    mkdir -p "$dir"

    # AUFS standalone repo tags follow the major.minor kernel version
    local branch="${KMAJ}.${KMIN}"
    local filename="aufs${branch}.patch"
    local dest="${dir}/${filename}"

    # Try the aufs-standalone GitHub repo (sfjro)
    local url="https://raw.githubusercontent.com/sfjro/aufs-standalone/aufs${branch}/aufs${branch}.patch"
    download "$url" "$dest" || warn "AUFS patch not found for ${branch}"
}

fetch_xanmod() {
    local dir="${PATCHES_DIR}/xanmod"
    mkdir -p "$dir"

    # XanMod patches are in the linux-patches repo, branch linux-<kver.y>-xanmod
    local branch="linux-${KMAJ}.${KMIN}.y-xanmod"
    local api_url="https://api.github.com/repos/xanmod/linux-patches/contents/linux-${KMAJ}.${KMIN}.y-xanmod"
    log "Fetching XanMod patch list for ${KMAJ}.${KMIN} ..."

    local listing
    listing=$(curl -fsSL --retry 3 "$api_url" 2>/dev/null || true)
    if [[ -z "$listing" ]]; then
        warn "Could not reach XanMod patch index"
        return 0
    fi

    # Extract download URLs for .patch files
    local urls
    urls=$(echo "$listing" | grep -oP '"download_url":\s*"\K[^"]+\.patch' || true)

    if [[ -z "$urls" ]]; then
        warn "No XanMod patches found for ${KMAJ}.${KMIN}"
        return 0
    fi

    while IFS= read -r url; do
        local fname
        fname=$(basename "$url")
        download "$url" "${dir}/${fname}"
    done <<< "$urls"
}

fetch_cachyos() {
    local dir="${PATCHES_DIR}/cachyos"
    mkdir -p "$dir"

    local api_url="https://api.github.com/repos/CachyOS/kernel-patches/contents/${KMAJ}.${KMIN}"
    log "Fetching CachyOS patch list for ${KMAJ}.${KMIN} ..."

    local listing
    listing=$(curl -fsSL --retry 3 "$api_url" 2>/dev/null || true)
    if [[ -z "$listing" ]]; then
        warn "Could not reach CachyOS patch index"
        return 0
    fi

    local urls
    urls=$(echo "$listing" | grep -oP '"download_url":\s*"\K[^"]+\.patch' || true)

    if [[ -z "$urls" ]]; then
        warn "No CachyOS patches found for ${KMAJ}.${KMIN}"
        return 0
    fi

    while IFS= read -r url; do
        local fname
        fname=$(basename "$url")
        download "$url" "${dir}/${fname}"
    done <<< "$urls"
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Fetching patches for kernel ${KVER} (sets: ${SETS[*]})"

for set in "${SETS[@]}"; do
    case "$set" in
        rt)      fetch_rt ;;
        aufs)    fetch_aufs ;;
        xanmod)  fetch_xanmod ;;
        cachyos) fetch_cachyos ;;
        *) warn "Unknown patch set: $set (skipping)" ;;
    esac
done

log "Done."
