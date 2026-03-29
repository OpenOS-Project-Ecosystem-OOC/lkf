#!/usr/bin/env bash
# core/initrd.sh - initramfs/initrd image builder
#
# Incorporates patterns from:
#   osresearch/linux-builder           - initrd-builder, cpio file assembly
#   AlexanderARodin/LinuxComponentsBuilder - kernel+initrd+rootfs pipeline
#   kodx/symlink-initrd-kernel-in-root - /vmlinuz and /initrd.img symlinks
#   deepseagirl/easylkb                - Debian rootfs via debootstrap

initrd_usage() {
    cat <<EOF
lkf initrd - Build initramfs/initrd images

USAGE: lkf initrd <subcommand> [options]

SUBCOMMANDS:
  build     Build an initrd from a config file or binary list
  symlink   Create /vmlinuz and /initrd.img symlinks (Debian-style)
  inspect   List contents of an existing initrd

EXAMPLES:
  lkf initrd build --config initrd.conf --output build/initrd.cpio.xz
  lkf initrd build --debootstrap --suite bookworm --output build/rootfs.img
  lkf initrd symlink --kernel /boot/vmlinuz-6.12.0 --initrd /boot/initrd.img-6.12.0
  lkf initrd inspect --file build/initrd.cpio.xz
EOF
}

initrd_main() {
    [[ $# -eq 0 ]] && { initrd_usage; return 0; }
    local subcmd="$1"; shift
    case "${subcmd}" in
        build)   initrd_cmd_build "$@" ;;
        symlink) initrd_cmd_symlink "$@" ;;
        inspect) initrd_cmd_inspect "$@" ;;
        --help|-h) initrd_usage ;;
        *) lkf_die "Unknown initrd subcommand: ${subcmd}" ;;
    esac
}

# ── Build initrd ──────────────────────────────────────────────────────────────

initrd_cmd_build() {
    local config_file="" output="initrd.cpio.xz" debootstrap=0
    local suite="bookworm" arch="" compression="xz"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)      config_file="$2"; shift 2 ;;
            --output)      output="$2"; shift 2 ;;
            --debootstrap) debootstrap=1; shift ;;
            --suite)       suite="$2"; shift 2 ;;
            --arch)        arch="$2"; shift 2 ;;
            --compression) compression="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${arch}" ]] && arch=$(detect_host_arch)

    if [[ "${debootstrap}" -eq 1 ]]; then
        initrd_build_debootstrap "${suite}" "${arch}" "${output}"
    elif [[ -n "${config_file}" ]]; then
        initrd_build_from_config "${config_file}" "${output}" "${compression}"
    else
        lkf_die "Specify --config <file> or --debootstrap"
    fi
}

# Build a minimal initrd from a list of binaries/files
# Inspired by osresearch/linux-builder initrd-builder
initrd_build_from_config() {
    local config_file="$1" output="$2" compression="${3:-xz}"
    lkf_require cpio find

    local staging
    staging=$(lkf_mktemp_dir)
    # shellcheck disable=SC2064  # intentional: expand $staging now, not at EXIT time
    trap "rm -rf ${staging}" EXIT

    lkf_step "Building initrd from config: ${config_file}"

    # Parse config: each line is a binary path or "dir: /path"
    while IFS= read -r line; do
        [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
        if [[ "${line}" =~ ^dir:\ (.+)$ ]]; then
            local dir="${BASH_REMATCH[1]}"
            lkf_ensure_dir "${staging}${dir}"
        elif [[ -f "${line}" ]]; then
            local dest_dir
            dest_dir="${staging}/$(dirname "${line}")"
            lkf_ensure_dir "${dest_dir}"
            cp "${line}" "${dest_dir}/"
            # Copy shared library dependencies
            if command -v ldd &>/dev/null; then
                ldd "${line}" 2>/dev/null | grep -oP '/\S+\.so\S*' | while read -r lib; do
                    [[ -f "${lib}" ]] || continue
                    local lib_dir
                    lib_dir="${staging}/$(dirname "${lib}")"
                    lkf_ensure_dir "${lib_dir}"
                    cp -n "${lib}" "${lib_dir}/" 2>/dev/null || true
                done
            fi
        else
            lkf_warn "Skipping missing entry: ${line}"
        fi
    done < "${config_file}"

    # Create essential directories
    for d in proc sys dev tmp run; do
        lkf_ensure_dir "${staging}/${d}"
    done

    # Pack into cpio
    lkf_step "Packing initrd -> ${output}"
    lkf_ensure_dir "$(dirname "${output}")"

    case "${compression}" in
        xz)   (cd "${staging}" && find . | cpio -H newc -o 2>/dev/null) | xz -9 --check=crc32 > "${output}" ;;
        gzip) (cd "${staging}" && find . | cpio -H newc -o 2>/dev/null) | gzip -9 > "${output}" ;;
        zstd) (cd "${staging}" && find . | cpio -H newc -o 2>/dev/null) | zstd -19 > "${output}" ;;
        none) (cd "${staging}" && find . | cpio -H newc -o > "${output}" 2>/dev/null) ;;
        *) lkf_die "Unknown compression: ${compression}" ;;
    esac

    lkf_info "initrd built: ${output} ($(du -sh "${output}" | cut -f1))"
}

# Build a Debian rootfs image using debootstrap
# Inspired by deepseagirl/easylkb
initrd_build_debootstrap() {
    local suite="$1" arch="$2" output="$3"
    lkf_require debootstrap

    local rootfs_dir
    rootfs_dir=$(lkf_mktemp_dir)
    # shellcheck disable=SC2064  # intentional: expand $rootfs_dir now, not at EXIT time
    trap "rm -rf ${rootfs_dir}" EXIT

    lkf_step "Running debootstrap: suite=${suite}, arch=${arch}"
    sudo debootstrap --arch="${arch}" "${suite}" "${rootfs_dir}" \
        "http://deb.debian.org/debian"

    # Basic setup
    sudo chroot "${rootfs_dir}" /bin/bash -c "
        echo 'root:root' | chpasswd
        echo 'lkf-debug' > /etc/hostname
        apt-get install -y --no-install-recommends openssh-server 2>/dev/null || true
    "

    # Pack to ext4 image
    local size_mb=2048
    lkf_step "Creating ${size_mb}MB ext4 image: ${output}"
    dd if=/dev/zero of="${output}" bs=1M count="${size_mb}" status=none
    mkfs.ext4 -q "${output}"
    local mnt
    mnt=$(lkf_mktemp_dir)
    sudo mount -o loop "${output}" "${mnt}"
    sudo cp -a "${rootfs_dir}/." "${mnt}/"
    sudo umount "${mnt}"
    rmdir "${mnt}"

    lkf_info "Rootfs image: ${output}"
}

# ── Symlink management ────────────────────────────────────────────────────────
# Inspired by kodx/symlink-initrd-kernel-in-root

initrd_cmd_symlink() {
    local kernel_path="" initrd_path="" root_dir="/"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel) kernel_path="$2"; shift 2 ;;
            --initrd) initrd_path="$2"; shift 2 ;;
            --root)   root_dir="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${kernel_path}" ]] && lkf_die "--kernel required"

    lkf_step "Creating boot symlinks in ${root_dir}"

    if [[ -f "${kernel_path}" ]]; then
        sudo ln -sfn "${kernel_path}" "${root_dir%/}/vmlinuz"
        lkf_info "  /vmlinuz -> ${kernel_path}"
    fi

    if [[ -n "${initrd_path}" && -f "${initrd_path}" ]]; then
        sudo ln -sfn "${initrd_path}" "${root_dir%/}/initrd.img"
        lkf_info "  /initrd.img -> ${initrd_path}"
    fi

    # Also manage .old symlinks (Debian convention)
    local old_vmlinuz="${root_dir%/}/vmlinuz.old"
    local old_initrd="${root_dir%/}/initrd.img.old"
    [[ -L "${root_dir%/}/vmlinuz" ]] && \
        sudo cp -P "${root_dir%/}/vmlinuz" "${old_vmlinuz}" 2>/dev/null || true
    [[ -L "${root_dir%/}/initrd.img" ]] && \
        sudo cp -P "${root_dir%/}/initrd.img" "${old_initrd}" 2>/dev/null || true
}

# ── Inspect initrd ────────────────────────────────────────────────────────────

initrd_cmd_inspect() {
    local initrd_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) initrd_file="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "${initrd_file}" ]] && lkf_die "--file required"
    [[ ! -f "${initrd_file}" ]] && lkf_die "File not found: ${initrd_file}"

    lkf_step "Contents of ${initrd_file}:"
    case "${initrd_file}" in
        *.xz)   xz -dc "${initrd_file}" | cpio -t 2>/dev/null ;;
        *.gz)   gzip -dc "${initrd_file}" | cpio -t 2>/dev/null ;;
        *.zst)  zstd -dc "${initrd_file}" | cpio -t 2>/dev/null ;;
        *)      cpio -t < "${initrd_file}" 2>/dev/null ;;
    esac
}
