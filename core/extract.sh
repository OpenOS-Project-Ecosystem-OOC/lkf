#!/usr/bin/env bash
# core/extract.sh - Extract vmlinux from compressed/EFI/boot images
#
# Incorporates patterns from:
#   elfmaster/kdress           - vmlinuz -> debuggable vmlinux + ELF symbol table
#   rawdaGastan/go-extract-vmlinux - Go-based vmlinux/vmlinuz extraction
#   eballetbo/unzboot          - EFI zboot ARM64 kernel extraction

extract_usage() {
    cat <<EOF
lkf extract - Extract vmlinux from compressed kernel images

USAGE: lkf extract [options]

OPTIONS:
  --input <path>    Input file: vmlinuz, bzImage, EFI zboot, or boot.img [required]
  --output <path>   Output vmlinux path [./vmlinux]
  --symbols <path>  System.map file to instrument ELF symbol table (kdress mode)
  --type <type>     Force extraction type: auto, vmlinuz, efi-zboot, android-boot
  --arch <arch>     Target architecture hint [auto-detected]
  --validate        Validate the extracted ELF after extraction

EXAMPLES:
  # Extract from a standard compressed vmlinuz
  lkf extract --input /boot/vmlinuz-6.12.0 --output /tmp/vmlinux

  # Extract + instrument with full symbol table (kdress mode)
  lkf extract --input /boot/vmlinuz-6.12.0 --output /tmp/vmlinux \\
              --symbols /boot/System.map-6.12.0

  # Extract from EFI zboot (ARM64)
  lkf extract --input kernel.efi --output vmlinux --type efi-zboot

  # Validate extracted ELF
  lkf extract --input /boot/vmlinuz-6.12.0 --output /tmp/vmlinux --validate
EOF
}

extract_main() {
    local input="" output="./vmlinux" symbols="" type="auto"
    local arch="" validate=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input)    input="$2"; shift 2 ;;
            --output)   output="$2"; shift 2 ;;
            --symbols)  symbols="$2"; shift 2 ;;
            --type)     type="$2"; shift 2 ;;
            --arch)     arch="$2"; shift 2 ;;
            --validate) validate=1; shift ;;
            --help|-h)  extract_usage; return 0 ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    [[ -z "${input}" ]] && lkf_die "--input required"
    [[ ! -f "${input}" ]] && lkf_die "Input file not found: ${input}"
    [[ -z "${arch}" ]] && arch=$(detect_host_arch)

    lkf_ensure_dir "$(dirname "${output}")"

    # Auto-detect type
    if [[ "${type}" == "auto" ]]; then
        type=$(extract_detect_type "${input}")
    fi

    lkf_step "Extracting vmlinux from ${input} (type=${type})"

    case "${type}" in
        vmlinuz)     extract_vmlinuz "${input}" "${output}" ;;
        efi-zboot)   extract_efi_zboot "${input}" "${output}" "${arch}" ;;
        android-boot) extract_android_boot "${input}" "${output}" ;;
        elf)
            cp "${input}" "${output}"
            lkf_info "Input is already an ELF, copied to ${output}"
            ;;
        *) lkf_die "Unknown extraction type: ${type}" ;;
    esac

    # Instrument with symbol table (kdress mode)
    # Inspired by elfmaster/kdress
    if [[ -n "${symbols}" ]]; then
        extract_instrument_symbols "${output}" "${symbols}"
    fi

    # Validate
    if [[ "${validate}" -eq 1 ]]; then
        extract_validate_elf "${output}"
    fi

    lkf_info "Extracted: ${output}"
}

# ── Type detection ────────────────────────────────────────────────────────────

extract_detect_type() {
    local file="$1"
    local magic
    magic=$(xxd -l 4 "${file}" 2>/dev/null | head -1 | awk '{print $2$3}')

    # ELF magic: 7f454c46
    if [[ "${magic}" == "7f454c46" ]]; then
        echo "elf"
        return
    fi

    # EFI PE magic: 4d5a (MZ)
    if [[ "${magic:0:4}" == "4d5a" ]]; then
        # Check for EFI zboot signature
        if strings "${file}" 2>/dev/null | grep -q "EFI STUB"; then
            echo "efi-zboot"
            return
        fi
        echo "efi-zboot"
        return
    fi

    # Android boot magic: 414e4452 (ANDR)
    if [[ "${magic}" == "414e4452" ]]; then
        echo "android-boot"
        return
    fi

    # Default: treat as compressed vmlinuz
    echo "vmlinuz"
}

# ── vmlinuz extraction ────────────────────────────────────────────────────────
# Uses the kernel's own extract-vmlinux script logic.
# Inspired by rawdaGastan/go-extract-vmlinux and the official scripts/extract-vmlinux.

extract_vmlinuz() {
    local input="$1" output="$2"

    # Try the kernel's own extract-vmlinux script if available
    local extract_script
    for candidate in \
        /usr/src/linux-headers-$(uname -r)/scripts/extract-vmlinux \
        /usr/lib/linux-kbuild-*/scripts/extract-vmlinux \
        "${LKF_ROOT}/tools/extract-vmlinux/extract-vmlinux"; do
        [[ -x "${candidate}" ]] && extract_script="${candidate}" && break
    done

    if [[ -n "${extract_script}" ]]; then
        lkf_step "Using extract-vmlinux script"
        "${extract_script}" "${input}" > "${output}"
        return
    fi

    # Fallback: try known compression magic offsets
    lkf_step "Probing compression format..."
    local tmp
    tmp=$(lkf_mktemp_dir)
    # shellcheck disable=SC2064  # intentional: expand $tmp now, not at RETURN time
    trap "rm -rf ${tmp}" RETURN

    # Try each decompressor in order (gzip, bzip2, lzma, xz, lz4, zstd)
    local offsets
    # gzip magic: 1f8b
    offsets=$(grep -boa $'\x1f\x8b' "${input}" 2>/dev/null | cut -d: -f1)
    for offset in ${offsets}; do
        dd if="${input}" bs=1 skip="${offset}" 2>/dev/null | \
            gzip -dc > "${tmp}/vmlinux" 2>/dev/null && \
            file "${tmp}/vmlinux" | grep -q ELF && \
            cp "${tmp}/vmlinux" "${output}" && return 0
    done

    # xz magic: fd377a585a00
    offsets=$(grep -boa $'\xfd\x37\x7a\x58\x5a\x00' "${input}" 2>/dev/null | cut -d: -f1)
    for offset in ${offsets}; do
        dd if="${input}" bs=1 skip="${offset}" 2>/dev/null | \
            xz -dc > "${tmp}/vmlinux" 2>/dev/null && \
            file "${tmp}/vmlinux" | grep -q ELF && \
            cp "${tmp}/vmlinux" "${output}" && return 0
    done

    # zstd magic: 28b52ffd
    offsets=$(grep -boa $'\x28\xb5\x2f\xfd' "${input}" 2>/dev/null | cut -d: -f1)
    for offset in ${offsets}; do
        dd if="${input}" bs=1 skip="${offset}" 2>/dev/null | \
            zstd -dc > "${tmp}/vmlinux" 2>/dev/null && \
            file "${tmp}/vmlinux" | grep -q ELF && \
            cp "${tmp}/vmlinux" "${output}" && return 0
    done

    lkf_die "Could not extract vmlinux from ${input}. Try installing kernel-devel for extract-vmlinux."
}

# ── EFI zboot extraction ──────────────────────────────────────────────────────
# Inspired by eballetbo/unzboot (ARM64 EFI zboot images)

extract_efi_zboot() {
    local input="$1" output="$2" arch="${3:-aarch64}"

    # Check if we have the compiled unzboot tool
    local unzboot_bin="${LKF_ROOT}/tools/unzboot/unzboot"
    if [[ -x "${unzboot_bin}" ]]; then
        lkf_step "Using unzboot tool"
        "${unzboot_bin}" "${input}" "${output}"
        return
    fi

    # Fallback: use objcopy to extract .linux section from EFI PE
    if command -v objcopy &>/dev/null; then
        lkf_step "Extracting .linux section from EFI image"
        local raw_kernel
        raw_kernel=$(lkf_mktemp_dir)/kernel.raw
        objcopy -O binary --only-section=.linux "${input}" "${raw_kernel}" 2>/dev/null || true
        if [[ -s "${raw_kernel}" ]]; then
            extract_vmlinuz "${raw_kernel}" "${output}"
            return
        fi
    fi

    lkf_warn "unzboot not compiled. Build it with: make -C ${LKF_ROOT}/tools/unzboot"
    lkf_warn "Falling back to generic vmlinuz extraction."
    extract_vmlinuz "${input}" "${output}"
}

# ── Android boot.img extraction ───────────────────────────────────────────────

extract_android_boot() {
    local input="$1" output="$2"

    if command -v abootimg &>/dev/null; then
        lkf_step "Extracting kernel from Android boot.img"
        local tmp
        tmp=$(lkf_mktemp_dir)
        abootimg -x "${input}" -f "${tmp}/bootimg.cfg" \
                 -k "${tmp}/zImage" -r "${tmp}/initrd.img" 2>/dev/null
        if [[ -f "${tmp}/zImage" ]]; then
            extract_vmlinuz "${tmp}/zImage" "${output}"
            return
        fi
    fi

    lkf_warn "abootimg not found. Install android-tools."
}

# ── Symbol table instrumentation (kdress) ────────────────────────────────────
# Inspired by elfmaster/kdress: instruments a vmlinux ELF with a complete
# symbol table from System.map, enabling /proc/kcore debugging without
# recompiling with debug symbols.

extract_instrument_symbols() {
    local vmlinux="$1" system_map="$2"

    # Check for compiled kdress tool
    local kdress_bin="${LKF_ROOT}/tools/kdress/kdress"
    if [[ -x "${kdress_bin}" ]]; then
        lkf_step "Instrumenting vmlinux with symbol table (kdress)"
        sudo "${kdress_bin}" "${vmlinux}" "${vmlinux}.sym" "${system_map}"
        mv "${vmlinux}.sym" "${vmlinux}"
        lkf_info "Symbol table instrumented. Use with /proc/kcore for live debugging."
        return
    fi

    # Fallback: use nm + objcopy to add a basic symbol section
    lkf_warn "kdress tool not compiled. Build it with: make -C ${LKF_ROOT}/tools/kdress"
    lkf_warn "Symbol instrumentation skipped. vmlinux will work for static analysis only."
    lkf_info "To use kdress: https://github.com/elfmaster/kdress"
}

# ── ELF validation ────────────────────────────────────────────────────────────

extract_validate_elf() {
    local vmlinux="$1"
    lkf_require file readelf

    lkf_step "Validating ELF: ${vmlinux}"

    if ! file "${vmlinux}" | grep -q ELF; then
        lkf_die "Extracted file is not a valid ELF: ${vmlinux}"
    fi

    local elf_info
    elf_info=$(readelf -h "${vmlinux}" 2>/dev/null | grep -E "Class|Machine|Type")
    lkf_info "ELF info:"
    echo "${elf_info}" | sed 's/^/  /'

    # Check for symbol table
    if readelf -s "${vmlinux}" 2>/dev/null | grep -q "sys_call_table"; then
        lkf_info "  Symbol table: present (sys_call_table found)"
    else
        lkf_warn "  Symbol table: not present (use --symbols to instrument)"
    fi
}
