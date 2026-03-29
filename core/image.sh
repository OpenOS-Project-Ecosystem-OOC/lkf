#!/usr/bin/env bash
# core/image.sh - Kernel image packaging
#
# Incorporates patterns from:
#   osresearch/linux-builder      - unify-kernel (EFI unified image)
#   Biswa96/android-kernel-builder - boot.img repack via mkbootimg
#   rizalmart/puppy-linux-kernel-maker - firmware driver packaging
#   tsirysndr/vmlinux-builder     - multi-arch release artifacts

image_usage() {
    cat <<EOF
lkf image - Package kernel into various image formats

USAGE: lkf image <subcommand> [options]

SUBCOMMANDS:
  efi-unified   Bundle kernel + initrd + cmdline into a signed EFI application
  android-boot  Repack kernel into an Android boot.img
  firmware      Package kernel modules as a firmware driver archive
  tar           Create a portable kernel tarball

EXAMPLES:
  lkf image efi-unified \\
      --kernel build/vmlinuz \\
      --initrd build/initrd.cpio.xz \\
      --cmdline cmdline.txt \\
      --output build/bootx64.efi

  lkf image android-boot \\
      --kernel arch/arm64/boot/Image.gz \\
      --base-img boot.img \\
      --output repacked.img

  lkf image firmware \\
      --modules-dir /lib/modules/6.12.0 \\
      --output firmware-6.12.0.tar.gz
EOF
}

image_main() {
    [[ $# -eq 0 ]] && { image_usage; return 0; }
    local subcmd="$1"; shift
    case "${subcmd}" in
        efi-unified)  image_cmd_efi_unified "$@" ;;
        android-boot) image_cmd_android_boot "$@" ;;
        firmware)     image_cmd_firmware "$@" ;;
        tar)          image_cmd_tar "$@" ;;
        --help|-h)    image_usage ;;
        *) lkf_die "Unknown image subcommand: ${subcmd}" ;;
    esac
}

# ── EFI Unified Kernel Image ──────────────────────────────────────────────────
# Inspired by osresearch/linux-builder unify-kernel script.
# Bundles vmlinuz + initrd + kernel cmdline into a single signed EFI PE binary.

image_cmd_efi_unified() {
    local kernel="" initrd="" cmdline_file="" output="bootx64.efi"
    local sign=0 sign_key="" sign_cert="" stub=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel)   kernel="$2"; shift 2 ;;
            --initrd)   initrd="$2"; shift 2 ;;
            --cmdline)  cmdline_file="$2"; shift 2 ;;
            --output)   output="$2"; shift 2 ;;
            --sign)     sign=1; shift ;;
            --sign-key) sign_key="$2"; shift 2 ;;
            --sign-cert) sign_cert="$2"; shift 2 ;;
            --stub)     stub="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${kernel}" ]] && lkf_die "--kernel required"
    [[ ! -f "${kernel}" ]] && lkf_die "Kernel not found: ${kernel}"

    lkf_require objcopy

    # Find EFI stub
    if [[ -z "${stub}" ]]; then
        for candidate in \
            /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
            /usr/lib/gummiboot/linuxx64.efi.stub \
            /usr/share/systemd/bootx64.efi.stub; do
            [[ -f "${candidate}" ]] && stub="${candidate}" && break
        done
    fi
    [[ -z "${stub}" ]] && lkf_die "EFI stub not found. Install systemd-boot-efi or specify --stub."

    lkf_step "Building unified EFI image: ${output}"
    lkf_ensure_dir "$(dirname "${output}")"

    local objcopy_args=(objcopy)

    # Embed cmdline
    if [[ -n "${cmdline_file}" && -f "${cmdline_file}" ]]; then
        objcopy_args+=(--add-section .cmdline="${cmdline_file}"
                       --change-section-vma .cmdline=0x30000)
    fi

    # Embed kernel
    objcopy_args+=(--add-section .linux="${kernel}"
                   --change-section-vma .linux=0x2000000)

    # Embed initrd
    if [[ -n "${initrd}" && -f "${initrd}" ]]; then
        objcopy_args+=(--add-section .initrd="${initrd}"
                       --change-section-vma .initrd=0x3000000)
    fi

    objcopy_args+=("${stub}" "${output}")
    "${objcopy_args[@]}"

    # Optional Secure Boot signing
    if [[ "${sign}" -eq 1 ]]; then
        lkf_require sbsign
        [[ -z "${sign_key}" || -z "${sign_cert}" ]] && \
            lkf_die "--sign-key and --sign-cert required for signing"
        lkf_step "Signing EFI image"
        sbsign --key "${sign_key}" --cert "${sign_cert}" \
               --output "${output}" "${output}"
    fi

    lkf_info "EFI unified image: ${output} ($(du -sh "${output}" | cut -f1))"
}

image_efi_unified() {
    local src_dir="$1" build_dir="$2"
    local kernel="${src_dir}/arch/x86/boot/bzImage"
    [[ ! -f "${kernel}" ]] && kernel=$(find "${src_dir}" -name "bzImage" -o -name "Image.gz" | head -1)
    local initrd="${build_dir}/initrd.cpio.xz"
    local output="${build_dir}/bootx64.efi"
    [[ -f "${kernel}" ]] && image_cmd_efi_unified \
        --kernel "${kernel}" \
        ${initrd:+--initrd "${initrd}"} \
        --output "${output}"
}

# ── Android boot.img ──────────────────────────────────────────────────────────
# Inspired by Biswa96/android-kernel-builder

image_cmd_android_boot() {
    local kernel="" base_img="" output="repacked.img"
    local ramdisk="" cmdline="" pagesize="4096"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel)   kernel="$2"; shift 2 ;;
            --base-img) base_img="$2"; shift 2 ;;
            --ramdisk)  ramdisk="$2"; shift 2 ;;
            --cmdline)  cmdline="$2"; shift 2 ;;
            --pagesize) pagesize="$2"; shift 2 ;;
            --output)   output="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${kernel}" ]] && lkf_die "--kernel required"

    if command -v mkbootimg &>/dev/null; then
        lkf_step "Repacking boot.img with mkbootimg"
        local args=(mkbootimg --kernel "${kernel}" --output "${output}")
        [[ -n "${ramdisk}" ]] && args+=(--ramdisk "${ramdisk}")
        [[ -n "${cmdline}" ]] && args+=(--cmdline "${cmdline}")
        args+=(--pagesize "${pagesize}")
        "${args[@]}"
        lkf_info "Android boot.img: ${output}"
    elif [[ -n "${base_img}" ]] && command -v abootimg &>/dev/null; then
        lkf_step "Repacking with abootimg"
        cp "${base_img}" "${output}"
        abootimg -u "${output}" -k "${kernel}"
        lkf_info "Android boot.img: ${output}"
    else
        lkf_warn "mkbootimg/abootimg not found. Install android-tools or mkbootimg."
        lkf_warn "Kernel image available at: ${kernel}"
    fi
}

image_android_boot() {
    local src_dir="$1" build_dir="$2"
    local kernel
    kernel=$(find "${src_dir}/arch" -name "Image.gz" -o -name "zImage" | head -1)
    [[ -z "${kernel}" ]] && { lkf_warn "No Android kernel image found."; return 0; }
    image_cmd_android_boot --kernel "${kernel}" --output "${build_dir}/repacked.img"
}

# ── Firmware driver archive ───────────────────────────────────────────────────
# Inspired by rizalmart/puppy-linux-kernel-maker firmware-driver workflow

image_cmd_firmware() {
    local modules_dir="" output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --modules-dir) modules_dir="$2"; shift 2 ;;
            --output)      output="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${modules_dir}" ]] && lkf_die "--modules-dir required"
    [[ ! -d "${modules_dir}" ]] && lkf_die "Modules directory not found: ${modules_dir}"
    [[ -z "${output}" ]] && output="firmware-$(basename "${modules_dir}").tar.gz"

    lkf_step "Packaging firmware/modules: ${modules_dir} -> ${output}"
    tar -czf "${output}" -C "$(dirname "${modules_dir}")" "$(basename "${modules_dir}")"
    lkf_info "Firmware archive: ${output} ($(du -sh "${output}" | cut -f1))"
}

# ── Generic tarball ───────────────────────────────────────────────────────────

image_cmd_tar() {
    local kernel="" initrd="" modules_dir="" output="kernel.tar.gz"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel)      kernel="$2"; shift 2 ;;
            --initrd)      initrd="$2"; shift 2 ;;
            --modules-dir) modules_dir="$2"; shift 2 ;;
            --output)      output="$2"; shift 2 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    local staging
    staging=$(lkf_mktemp_dir)
    # shellcheck disable=SC2064  # intentional: expand $staging now, not at EXIT time
    trap "rm -rf ${staging}" EXIT

    lkf_ensure_dir "${staging}/boot"
    [[ -n "${kernel}" && -f "${kernel}" ]] && cp "${kernel}" "${staging}/boot/"
    [[ -n "${initrd}" && -f "${initrd}" ]] && cp "${initrd}" "${staging}/boot/"
    if [[ -n "${modules_dir}" && -d "${modules_dir}" ]]; then
        lkf_ensure_dir "${staging}/lib/modules"
        cp -r "${modules_dir}" "${staging}/lib/modules/"
    fi

    tar -czf "${output}" -C "${staging}" .
    lkf_info "Kernel tarball: ${output}"
}
