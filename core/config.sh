#!/usr/bin/env bash
# core/config.sh - Kernel .config management
#
# Incorporates patterns from:
#   tsirysndr/vmlinux-builder  - Config parse/validate/serialize API
#   ghazzor/Xanmod-Kernel-Builder - localyesconfig, LTO config options
#   deepseagirl/easylkb        - Debug-friendly config generation
#   h0tc0d3/kbuild             - Config file sourcing (.kbuild style)
#   masahir0y/kbuild_skeleton  - Kconfig/Kbuild standalone usage

config_usage() {
    cat <<EOF
lkf config - Manage kernel .config files

USAGE: lkf config <subcommand> [options]

SUBCOMMANDS:
  generate    Generate a .config from a source (defconfig, localyesconfig, etc.)
  merge       Merge config fragments into a base .config
  validate    Check a .config for required options
  show        Display config options by category (processor, security, net, fs)
  convert     Convert .config to JSON, TOML, or YAML
  set         Set a specific CONFIG_ option
  diff        Show differences between two .config files

EXAMPLES:
  lkf config generate --source localyesconfig --arch x86_64
  lkf config merge --base .config --fragment debug.config
  lkf config validate --file .config --require CONFIG_KVM,CONFIG_VIRTIO
  lkf config show --file .config --category security
  lkf config convert --file .config --format json
  lkf config set --file .config --option CONFIG_PREEMPT --value y
EOF
}

config_main() {
    [[ $# -eq 0 ]] && { config_usage; return 0; }
    local subcmd="$1"; shift
    case "${subcmd}" in
        generate) config_cmd_generate "$@" ;;
        merge)    config_cmd_merge "$@" ;;
        validate) config_cmd_validate "$@" ;;
        show)     config_cmd_show "$@" ;;
        convert)  config_cmd_convert "$@" ;;
        set)      config_cmd_set "$@" ;;
        diff)     config_cmd_diff "$@" ;;
        --help|-h) config_usage ;;
        *) lkf_die "Unknown config subcommand: ${subcmd}" ;;
    esac
}

# ── config apply (called from build pipeline) ─────────────────────────────────

config_apply() {
    local src_dir="$1"
    local config_source="$2"
    local target_profile="$3"
    local arch="$4"
    local cross_prefix="$5"
    # shellcheck disable=SC2034  # cc/llvm/lto reserved for future config fragment selection
    local cc="$6"
    local llvm="$7"
    local lto="$8"

    local kernel_arch
    kernel_arch=$(arch_to_kernel_arch "${arch}")

    lkf_step "Configuring kernel: source=${config_source}, target=${target_profile}"

    case "${config_source}" in
        defconfig)
            make -C "${src_dir}" ARCH="${kernel_arch}" \
                ${cross_prefix:+CROSS_COMPILE="${cross_prefix}"} \
                defconfig
            ;;
        localyesconfig)
            # Inspired by ghazzor/Xanmod-Kernel-Builder guide
            lkf_warn "localyesconfig uses currently loaded modules. Ensure all devices are connected."
            make -C "${src_dir}" ARCH="${kernel_arch}" \
                ${cross_prefix:+CROSS_COMPILE="${cross_prefix}"} \
                localyesconfig
            ;;
        localmodconfig)
            make -C "${src_dir}" ARCH="${kernel_arch}" \
                ${cross_prefix:+CROSS_COMPILE="${cross_prefix}"} \
                localmodconfig
            ;;
        *.gz)
            # Support /proc/config.gz (from h0tc0d3/kbuild)
            zcat "${config_source}" > "${src_dir}/.config"
            make -C "${src_dir}" ARCH="${kernel_arch}" \
                ${cross_prefix:+CROSS_COMPILE="${cross_prefix}"} \
                olddefconfig
            ;;
        *)
            if [[ -f "${config_source}" ]]; then
                cp "${config_source}" "${src_dir}/.config"
                make -C "${src_dir}" ARCH="${kernel_arch}" \
                    ${cross_prefix:+CROSS_COMPILE="${cross_prefix}"} \
                    olddefconfig
            else
                lkf_die "Config source not found: ${config_source}"
            fi
            ;;
    esac

    # Apply target profile overlays
    config_apply_profile "${src_dir}" "${target_profile}" "${kernel_arch}"

    # Apply LTO settings
    config_apply_lto "${src_dir}" "${lto}" "${llvm}"
}

# Apply named target profile config fragments
config_apply_profile() {
    local src_dir="$1" profile="$2" kernel_arch="$3"
    local fragment="${LKF_ROOT}/config/profiles/${profile}.config"

    if [[ -f "${fragment}" ]]; then
        lkf_step "Applying profile config: ${profile}"
        config_merge_fragment "${src_dir}" "${fragment}" "${kernel_arch}"
    fi
}

# Apply LTO configuration
# Inspired by ghazzor/Xanmod-Kernel-Builder LTO tips
config_apply_lto() {
    local src_dir="$1" lto="$2" llvm="$3"
    [[ "${lto}" == "none" ]] && return 0

    if [[ "${llvm}" -ne 1 ]]; then
        lkf_warn "LTO requires LLVM. Skipping LTO configuration."
        return 0
    fi

    lkf_step "Applying LTO=${lto} configuration"
    case "${lto}" in
        thin)
            config_set_option "${src_dir}/.config" "CONFIG_LTO_CLANG_THIN" "y"
            config_set_option "${src_dir}/.config" "CONFIG_LTO_CLANG_FULL" "n"
            config_set_option "${src_dir}/.config" "CONFIG_LTO_NONE" "n"
            ;;
        full)
            config_set_option "${src_dir}/.config" "CONFIG_LTO_CLANG_FULL" "y"
            config_set_option "${src_dir}/.config" "CONFIG_LTO_CLANG_THIN" "n"
            config_set_option "${src_dir}/.config" "CONFIG_LTO_NONE" "n"
            ;;
    esac
    make -C "${src_dir}" olddefconfig
}

# Merge a config fragment using scripts/kconfig/merge_config.sh
config_merge_fragment() {
    local src_dir="$1" fragment="$2" kernel_arch="${3:-x86_64}"
    local merge_script="${src_dir}/scripts/kconfig/merge_config.sh"

    if [[ -x "${merge_script}" ]]; then
        ARCH="${kernel_arch}" bash "${merge_script}" -m \
            "${src_dir}/.config" "${fragment}"
        make -C "${src_dir}" ARCH="${kernel_arch}" olddefconfig
    else
        # Fallback: append fragment and run olddefconfig
        cat "${fragment}" >> "${src_dir}/.config"
        make -C "${src_dir}" ARCH="${kernel_arch}" olddefconfig
    fi
}

# Set a single CONFIG_ option in a .config file
config_set_option() {
    local config_file="$1" option="$2" value="$3"
    if grep -q "^${option}=" "${config_file}" 2>/dev/null; then
        sed -i "s|^${option}=.*|${option}=${value}|" "${config_file}"
    elif grep -q "^# ${option} is not set" "${config_file}" 2>/dev/null; then
        sed -i "s|^# ${option} is not set|${option}=${value}|" "${config_file}"
    else
        echo "${option}=${value}" >> "${config_file}"
    fi
}

# ── Subcommand implementations ────────────────────────────────────────────────

config_cmd_generate() {
    local source="defconfig" arch="" cross="" output=".config"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            --arch)   arch="$2"; shift 2 ;;
            --cross)  cross="$2"; shift 2 ;;
            --output) output="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${arch}" ]] && arch=$(detect_host_arch)
    local kernel_arch
    kernel_arch=$(arch_to_kernel_arch "${arch}")
    lkf_info "Generating config: source=${source}, arch=${kernel_arch}, output=${output}${cross:+, cross=${cross}}"
    # Requires a source dir - delegate to build pipeline
    lkf_warn "Run 'lkf build --config ${source}' to generate config within a build."
}

config_cmd_merge() {
    local base="" fragment=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)     base="$2"; shift 2 ;;
            --fragment) fragment="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${base}" || -z "${fragment}" ]] && lkf_die "--base and --fragment required"
    [[ ! -f "${base}" ]] && lkf_die "Base config not found: ${base}"
    [[ ! -f "${fragment}" ]] && lkf_die "Fragment not found: ${fragment}"
    lkf_step "Merging ${fragment} into ${base}"
    cat "${fragment}" >> "${base}"
    lkf_info "Merged. Run 'make olddefconfig' in your kernel tree to resolve."
}

config_cmd_validate() {
    local config_file="" require_opts=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)    config_file="$2"; shift 2 ;;
            --require) require_opts="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${config_file}" ]] && lkf_die "--file required"
    [[ ! -f "${config_file}" ]] && lkf_die "Config file not found: ${config_file}"

    local failed=0
    IFS=',' read -ra opts <<< "${require_opts}"
    for opt in "${opts[@]}"; do
        opt="${opt// /}"
        if grep -q "^${opt}=" "${config_file}"; then
            lkf_info "  ✅ ${opt} = $(grep "^${opt}=" "${config_file}" | cut -d= -f2)"
        else
            lkf_error "  ❌ ${opt} not set"
            failed=1
        fi
    done
    [[ "${failed}" -eq 1 ]] && lkf_die "Config validation failed."
    lkf_info "Config validation passed."
}

config_cmd_show() {
    local config_file="" category="all"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)     config_file="$2"; shift 2 ;;
            --category) category="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${config_file}" ]] && lkf_die "--file required"
    [[ ! -f "${config_file}" ]] && lkf_die "Config file not found: ${config_file}"

    # Category filters inspired by tsirysndr/vmlinux-builder config API
    case "${category}" in
        processor|cpu)
            grep -E "^CONFIG_(M[A-Z]|PROCESSOR|CPU|SMP|NUMA|HZ_|PREEMPT)" "${config_file}" | sort
            ;;
        security)
            grep -E "^CONFIG_(SECURITY|LOCKDOWN|HARDENED|RANDOMIZE|STACKPROTECTOR|CFI|KASAN|UBSAN)" \
                "${config_file}" | sort
            ;;
        networking|net)
            grep -E "^CONFIG_(NET|NETFILTER|BRIDGE|VLAN|TUN|VETH|WIREGUARD|IPSEC)" \
                "${config_file}" | sort
            ;;
        filesystem|fs)
            grep -E "^CONFIG_(EXT[234]|BTRFS|XFS|F2FS|TMPFS|OVERLAYFS|FUSE|NFS|CIFS)" \
                "${config_file}" | sort
            ;;
        virtualization|virt)
            grep -E "^CONFIG_(KVM|VIRTIO|VHOST|XEN|HYPERV)" "${config_file}" | sort
            ;;
        debug)
            grep -E "^CONFIG_(DEBUG|KASAN|UBSAN|KCSAN|KFENCE|LOCKDEP|FTRACE)" \
                "${config_file}" | sort
            ;;
        all)
            grep "^CONFIG_" "${config_file}" | sort
            ;;
        *)
            grep "^CONFIG_${category^^}" "${config_file}" | sort
            ;;
    esac
}

config_cmd_convert() {
    local config_file="" format="json"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)   config_file="$2"; shift 2 ;;
            --format) format="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${config_file}" ]] && lkf_die "--file required"
    [[ ! -f "${config_file}" ]] && lkf_die "Config file not found: ${config_file}"

    case "${format}" in
        json)
            echo "{"
            local first=1
            while IFS='=' read -r key val; do
                [[ "${key}" =~ ^CONFIG_ ]] || continue
                [[ "${first}" -eq 0 ]] && echo ","
                printf '  "%s": "%s"' "${key}" "${val}"
                first=0
            done < "${config_file}"
            echo ""
            echo "}"
            ;;
        toml)
            echo "# lkf kernel config export"
            while IFS='=' read -r key val; do
                [[ "${key}" =~ ^CONFIG_ ]] || continue
                printf '%s = "%s"\n' "${key}" "${val}"
            done < "${config_file}"
            ;;
        yaml)
            echo "# lkf kernel config export"
            while IFS='=' read -r key val; do
                [[ "${key}" =~ ^CONFIG_ ]] || continue
                printf '%s: "%s"\n' "${key}" "${val}"
            done < "${config_file}"
            ;;
        *) lkf_die "Unknown format: ${format}. Use json, toml, or yaml." ;;
    esac
}

config_cmd_set() {
    local config_file="" option="" value=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)   config_file="$2"; shift 2 ;;
            --option) option="$2"; shift 2 ;;
            --value)  value="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${config_file}" || -z "${option}" || -z "${value}" ]] && \
        lkf_die "--file, --option, and --value required"
    config_set_option "${config_file}" "${option}" "${value}"
    lkf_info "Set ${option}=${value} in ${config_file}"
}

config_cmd_diff() {
    local file_a="" file_b=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --a) file_a="$2"; shift 2 ;;
            --b) file_b="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${file_a}" || -z "${file_b}" ]] && lkf_die "--a and --b required"
    diff <(grep "^CONFIG_" "${file_a}" | sort) \
         <(grep "^CONFIG_" "${file_b}" | sort) || true
}
