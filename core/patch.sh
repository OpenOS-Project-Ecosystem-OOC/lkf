#!/usr/bin/env bash
# core/patch.sh - Patch set management
#
# Incorporates patterns from:
#   rizalmart/puppy-linux-kernel-maker - AUFS patch workflow
#   osresearch/linux-builder           - patches/ directory, patch sets
#   ghazzor/Xanmod-Kernel-Builder      - zen4_clang.patch workaround
#   h0tc0d3/kbuild                     - PATCHES array, apply toggle

patch_usage() {
    cat <<EOF
lkf patch - Apply or manage kernel patch sets

USAGE: lkf patch <subcommand> [options]

SUBCOMMANDS:
  apply     Apply a named patch set or individual patch file
  list      List available built-in patch sets
  fetch     Download a patch set from a known source

EXAMPLES:
  lkf patch apply --set aufs --source-dir /path/to/linux
  lkf patch apply --file my.patch --source-dir /path/to/linux
  lkf patch list
  lkf patch fetch --version 6.6.130              # fetch all sets
  lkf patch fetch --version 6.6.130 --set rt     # fetch RT only
  lkf patch fetch --version 6.6.130 --set cachyos --dir /tmp/patches
EOF
}

patch_main() {
    [[ $# -eq 0 ]] && { patch_usage; return 0; }
    local subcmd="$1"; shift
    case "${subcmd}" in
        apply) patch_cmd_apply "$@" ;;
        list)  patch_cmd_list ;;
        fetch) patch_cmd_fetch "$@" ;;
        --help|-h) patch_usage ;;
        *) lkf_die "Unknown patch subcommand: ${subcmd}" ;;
    esac
}

# ── Built-in patch set registry ───────────────────────────────────────────────

# Each entry: "name|description|fetch_url_template"
# {VERSION} is replaced with the kernel version at fetch time.
declare -A PATCH_SETS=(
    [aufs]="AUFS union filesystem patch|https://github.com/sfjro/aufs-standalone/archive/refs/heads/aufs{MAJOR}.{MINOR}.tar.gz"
    [rt]="PREEMPT_RT realtime patch|https://cdn.kernel.org/pub/linux/kernel/projects/rt/{MAJOR}.{MINOR}/patch-{VERSION}-rt{RT_VER}.patch.xz"
    [xanmod]="Xanmod kernel patches (applied via source clone)|https://gitlab.com/xanmod/linux"
    [cachyos]="CachyOS kernel patches|https://github.com/CachyOS/kernel-patches/archive/refs/heads/master.tar.gz"
    [zen4-clang]="Zen4 Clang compiler workaround|${LKF_ROOT}/patches/zen4_clang.patch"
)

patch_cmd_list() {
    echo "Available built-in patch sets:"
    echo "────────────────────────────────────────"
    for name in "${!PATCH_SETS[@]}"; do
        local desc
        desc=$(echo "${PATCH_SETS[${name}]}" | cut -d'|' -f1)
        printf "  %-16s %s\n" "${name}" "${desc}"
    done
    echo ""
    echo "Custom patches in ${LKF_ROOT}/patches/:"
    find "${LKF_ROOT}/patches" -name "*.patch" -o -name "*.diff" 2>/dev/null \
        | sed "s|${LKF_ROOT}/patches/||" | sort | sed 's/^/  /'
}

patch_cmd_apply() {
    local set_name="" patch_file="" src_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set)        set_name="$2"; shift 2 ;;
            --file)       patch_file="$2"; shift 2 ;;
            --source-dir) src_dir="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${src_dir}" ]] && lkf_die "--source-dir required"
    [[ -n "${set_name}" ]] && patch_apply_set "${src_dir}" "${set_name}" ""
    [[ -n "${patch_file}" ]] && patch_apply_file "${src_dir}" "${patch_file}"
}

patch_cmd_fetch() {
    local set_name="all" version="" dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set)     set_name="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --dir)     dir="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: lkf patch fetch --version <kver> [--set <set>] [--dir <path>]"
                echo "  --version  Kernel version, e.g. 6.6.30 (required)"
                echo "  --set      Patch set: aufs, rt, xanmod, cachyos, all [default: all]"
                echo "  --dir      Download directory [default: \${LKF_ROOT}/patches]"
                return 0 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${version}" ]] && lkf_die "--version is required (e.g. lkf patch fetch --version 6.6.30)"

    local fetch_script="${LKF_ROOT}/patches/fetch.sh"
    [[ -f "${fetch_script}" ]] || lkf_die "fetch script not found: ${fetch_script}"

    local fetch_args=(--version "${version}" --set "${set_name}")
    [[ -n "${dir}" ]] && fetch_args+=(--dir "${dir}")

    bash "${fetch_script}" "${fetch_args[@]}"
}

# ── Internal helpers (called from build pipeline) ─────────────────────────────

patch_apply_set() {
    local src_dir="$1" set_name="$2" version="$3"
    [[ -z "${set_name}" ]] && return 0

    lkf_step "Applying patch set: ${set_name}"

    # Check local patches directory first
    local local_dir="${LKF_ROOT}/patches/${set_name}"
    if [[ -d "${local_dir}" ]]; then
        local patches
        mapfile -t patches < <(find "${local_dir}" -name "*.patch" -o -name "*.diff" | sort)
        for p in "${patches[@]}"; do
            patch_apply_file "${src_dir}" "${p}"
        done
        return 0
    fi

    # Check for a single local patch file
    local local_file="${LKF_ROOT}/patches/${set_name}.patch"
    if [[ -f "${local_file}" ]]; then
        patch_apply_file "${src_dir}" "${local_file}"
        return 0
    fi

    lkf_warn "Patch set '${set_name}' not found locally in ${LKF_ROOT}/patches/."
    lkf_warn "Run 'lkf patch fetch --set ${set_name}' to download it first."
}

patch_apply_file() {
    local src_dir="$1" patch_file="$2"
    [[ -z "${patch_file}" || ! -f "${patch_file}" ]] && {
        lkf_warn "Patch file not found: ${patch_file}"
        return 1
    }

    lkf_step "Applying patch: $(basename "${patch_file}")"

    # Detect compression
    case "${patch_file}" in
        *.xz)  xz -dc "${patch_file}" | patch -d "${src_dir}" -p1 --forward ;;
        *.gz)  gzip -dc "${patch_file}" | patch -d "${src_dir}" -p1 --forward ;;
        *.bz2) bzip2 -dc "${patch_file}" | patch -d "${src_dir}" -p1 --forward ;;
        *)     patch -d "${src_dir}" -p1 --forward < "${patch_file}" ;;
    esac
}
