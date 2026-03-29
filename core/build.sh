#!/usr/bin/env bash
# core/build.sh - Kernel fetch, configure, patch, and compile pipeline
#
# Incorporates patterns from:
#   h0tc0d3/kbuild          - Flexible CLI flags, DKMS, GPG verify, stop-at stages
#   ghazzor/Xanmod-Kernel-Builder - Clang/LLVM flags, LTO, deb-pkg output
#   tsirysndr/vmlinux-builder     - Multi-arch CI, version normalization
#   rizalmart/puppy-linux-kernel-maker - AUFS patch, firmware workflow
#   osresearch/linux-builder      - Appliance/firmware kernel, patch sets
#   deepseagirl/easylkb           - localyesconfig, debug-friendly config
#   Biswa96/android-kernel-builder - Android cross-compile, boot.img repack

# Default values documented here for reference; actual defaults are set in build_main()
# LKF_KERNEL_VERSION=""        LKF_ARCH=""              LKF_CROSS_PREFIX=""
# LKF_CC="gcc"                 LKF_LLVM=0               LKF_LLVM_VERSION=""
# LKF_LTO="none"               LKF_FLAVOR="mainline"    LKF_CONFIG_SOURCE="defconfig"
# LKF_CONFIGURATOR=""          LKF_PATCH_SET=""         LKF_PATCHES=()
# LKF_OUTPUT_FORMAT=""         LKF_LOCALVERSION=""      LKF_KCFLAGS=""
# LKF_BUILD_DIR="${PWD}/build" LKF_DOWNLOAD_DIR="${PWD}/downloads"
# LKF_SOURCE_DIR=""            LKF_THREADS=""           LKF_VERIFY_GPG=0
# LKF_DISTCLEAN=0              LKF_CLEAN_AFTER=0        LKF_REMOVE_AFTER=0
# LKF_COPY_SYSTEM_MAP=0        LKF_STOP_AFTER=""        LKF_TARGET="desktop"
# LKF_INSTALL_DEPS=0

build_usage() {
    cat <<EOF
lkf build - Fetch, configure, patch, and compile a Linux kernel

USAGE: lkf build [options]

SOURCE OPTIONS:
  --version, -v <ver>       Kernel version (e.g. 6.12, 6.1.y, v6.12.3)
  --flavor <name>           Kernel flavor: mainline, xanmod, cachyos, zen, rt, tkg, android, custom
  --source-dir <path>       Use an existing kernel source tree (skip download)
  --download-dir <path>     Directory for downloaded tarballs [${PWD}/downloads]

ARCHITECTURE:
  --arch <arch>             Target arch: x86_64, aarch64, arm, riscv64 [host arch]
  --cross <prefix>          Cross-compiler prefix (e.g. aarch64-linux-gnu-)

COMPILER:
  --cc <compiler>           Compiler: gcc or clang [auto-detected]
  --llvm                    Enable LLVM=1 LLVM_IAS=1 (implies --cc clang)
  --llvm-version <n>        Install and use specific LLVM version (e.g. 19)
  --lto <mode>              LTO mode: none, thin, full [none]
  --kcflags <flags>         Extra CFLAGS passed to kernel build

CONFIGURATION:
  --config <source>         Config source: defconfig, localyesconfig, localmodconfig,
                            or path to a .config / .config.gz file
  --configurator <tool>     Launch config UI: menuconfig, nconfig, xconfig
  --target <profile>        Config profile: desktop, server, android, embedded, appliance, debug

PATCHING:
  --patch-set <name>        Apply a named patch set: aufs, rt, xanmod, cachyos, tkg
  --patch <file>            Apply an extra patch file (repeatable)

OUTPUT:
  --output <format>         Output format: deb, rpm, pkg.tar.zst, tar.gz,
                            efi-unified, android-boot [auto-detected]
  --localversion <str>      Kernel LOCALVERSION suffix
  --build-dir <path>        Build output directory [${PWD}/build]

PIPELINE CONTROL:
  --stop-after <stage>      Stop after: download, extract, patch, config, build, install
  --distclean               Run make distclean before build
  --clean-after             Run make clean after build
  --remove-after            Remove source tree after build
  --verify-gpg              Verify kernel tarball GPG signature
  --copy-system-map         Copy System.map to /boot

MISC:
  --threads, -j <n>         Parallel build jobs [nproc]
  --install-deps            Install build dependencies before building

TKG FLAVOR OPTIONS (only used with --flavor tkg):
  --tkg-cpusched <sched>    CPU scheduler: bore, eevdf, cfs, bmq, pds [eevdf]
  --tkg-ntsync              Enable NTsync (Wine/Proton performance)
  --tkg-no-fsync            Disable Fsync legacy patch
  --tkg-no-clear            Disable Clear Linux performance patches
  --tkg-acs                 Enable ACS IOMMU override (GPU passthrough)
  --tkg-openrgb             Enable OpenRGB kernel support
  --tkg-o3                  Enable O3 + per-CPU-arch optimizations
  --tkg-no-zenify           Disable glitched-base (TkG base tweaks)
  --help                    Show this help
EOF
}

build_main() {
    # Apply defaults
    local LKF_KERNEL_VERSION="" LKF_ARCH="" LKF_CROSS_PREFIX="" LKF_CC=""
    local LKF_LLVM=0 LKF_LLVM_VERSION="" LKF_LTO="none" LKF_FLAVOR="mainline"
    local LKF_CONFIG_SOURCE="defconfig" LKF_CONFIGURATOR="" LKF_PATCH_SET=""
    local LKF_PATCHES=() LKF_OUTPUT_FORMAT="" LKF_LOCALVERSION="" LKF_KCFLAGS=""
    local LKF_BUILD_DIR="${PWD}/build" LKF_DOWNLOAD_DIR="${PWD}/downloads"
    local LKF_SOURCE_DIR="" LKF_THREADS="" LKF_VERIFY_GPG=0 LKF_DISTCLEAN=0
    local LKF_CLEAN_AFTER=0 LKF_REMOVE_AFTER=0 LKF_COPY_SYSTEM_MAP=0
    local LKF_STOP_AFTER="" LKF_TARGET="desktop" LKF_INSTALL_DEPS=0
    # TKG flavor options (only used when --flavor tkg); exported so patch.sh can read them
    TKG_CPUSCHED="eevdf" TKG_NTSYNC=0 TKG_FSYNC=1 TKG_CLEAR=1
    TKG_ACS=0 TKG_OPENRGB=0 TKG_O3=0 TKG_ZENIFY=1
    export TKG_CPUSCHED TKG_NTSYNC TKG_FSYNC TKG_CLEAR TKG_ACS TKG_OPENRGB TKG_O3 TKG_ZENIFY

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-v)       LKF_KERNEL_VERSION="$2"; shift 2 ;;
            --flavor)           LKF_FLAVOR="$2"; shift 2 ;;
            --source-dir)       LKF_SOURCE_DIR="$2"; shift 2 ;;
            --download-dir)     LKF_DOWNLOAD_DIR="$2"; shift 2 ;;
            --arch)             LKF_ARCH="$2"; shift 2 ;;
            --cross)            LKF_CROSS_PREFIX="$2"; shift 2 ;;
            --cc)               LKF_CC="$2"; shift 2 ;;
            --llvm)             LKF_LLVM=1; LKF_CC="clang"; shift ;;
            --llvm-version)     LKF_LLVM_VERSION="$2"; LKF_LLVM=1; LKF_CC="clang"; shift 2 ;;
            --lto)              LKF_LTO="$2"; shift 2 ;;
            --kcflags)          LKF_KCFLAGS="$2"; shift 2 ;;
            --config)           LKF_CONFIG_SOURCE="$2"; shift 2 ;;
            --configurator)     LKF_CONFIGURATOR="$2"; shift 2 ;;
            --target)           LKF_TARGET="$2"; shift 2 ;;
            --patch-set)        LKF_PATCH_SET="$2"; shift 2 ;;
            --patch)            LKF_PATCHES+=("$2"); shift 2 ;;
            --output)           LKF_OUTPUT_FORMAT="$2"; shift 2 ;;
            --localversion)     LKF_LOCALVERSION="$2"; shift 2 ;;
            --build-dir)        LKF_BUILD_DIR="$2"; shift 2 ;;
            --stop-after)       LKF_STOP_AFTER="$2"; shift 2 ;;
            --threads|-j)       LKF_THREADS="$2"; shift 2 ;;
            --distclean)        LKF_DISTCLEAN=1; shift ;;
            --clean-after)      LKF_CLEAN_AFTER=1; shift ;;
            --remove-after)     LKF_REMOVE_AFTER=1; shift ;;
            --verify-gpg)       LKF_VERIFY_GPG=1; shift ;;
            --copy-system-map)  LKF_COPY_SYSTEM_MAP=1; shift ;;
            --install-deps)     LKF_INSTALL_DEPS=1; shift ;;
            # TKG flavor options
            --tkg-cpusched)     TKG_CPUSCHED="$2"; shift 2 ;;
            --tkg-ntsync)       TKG_NTSYNC=1; shift ;;
            --tkg-no-fsync)     TKG_FSYNC=0; shift ;;
            --tkg-no-clear)     TKG_CLEAR=0; shift ;;
            --tkg-acs)          TKG_ACS=1; shift ;;
            --tkg-openrgb)      TKG_OPENRGB=1; shift ;;
            --tkg-o3)           TKG_O3=1; shift ;;
            --tkg-no-zenify)    TKG_ZENIFY=0; shift ;;
            --help|-h)          build_usage; return 0 ;;
            *) lkf_die "Unknown build option: $1" ;;
        esac
    done

    # Resolve defaults
    [[ -z "${LKF_ARCH}" ]] && LKF_ARCH=$(detect_host_arch)
    [[ -z "${LKF_THREADS}" ]] && LKF_THREADS=$(lkf_nproc)
    [[ -z "${LKF_CC}" ]] && LKF_CC=$(detect_cc)
    [[ -z "${LKF_OUTPUT_FORMAT}" ]] && LKF_OUTPUT_FORMAT=$(detect_default_output_format)

    # Auto-detect cross prefix if not set
    if [[ -z "${LKF_CROSS_PREFIX}" ]]; then
        LKF_CROSS_PREFIX=$(detect_cross_prefix "${LKF_ARCH}")
    fi

    # Install deps if requested
    if [[ "${LKF_INSTALL_DEPS}" -eq 1 ]]; then
        toolchain_install_deps
        [[ "${LKF_LLVM}" -eq 1 ]] && toolchain_install_llvm "${LKF_LLVM_VERSION}"
        [[ -n "${LKF_CROSS_PREFIX}" ]] && toolchain_install_cross "${LKF_ARCH}"
    fi

    # Validate
    [[ -z "${LKF_KERNEL_VERSION}" && -z "${LKF_SOURCE_DIR}" ]] && \
        lkf_die "Specify --version <ver> or --source-dir <path>"

    # Resolve version
    if [[ -n "${LKF_KERNEL_VERSION}" ]]; then
        LKF_KERNEL_VERSION=$(lkf_normalize_version "${LKF_KERNEL_VERSION}")
        LKF_KERNEL_VERSION=$(lkf_resolve_version "${LKF_KERNEL_VERSION}")
    fi

    lkf_info "Building Linux ${LKF_KERNEL_VERSION} | arch=${LKF_ARCH} | flavor=${LKF_FLAVOR} | cc=${LKF_CC} | lto=${LKF_LTO}"

    # ── Stage: Download ───────────────────────────────────────────────────────
    if [[ -z "${LKF_SOURCE_DIR}" ]]; then
        build_stage_download
        [[ "${LKF_STOP_AFTER}" == "download" ]] && return 0

        # ── Stage: Extract ────────────────────────────────────────────────────
        build_stage_extract
        [[ "${LKF_STOP_AFTER}" == "extract" ]] && return 0
    fi

    # ── Stage: Patch ──────────────────────────────────────────────────────────
    build_stage_patch
    [[ "${LKF_STOP_AFTER}" == "patch" ]] && return 0

    # ── Stage: Configure ──────────────────────────────────────────────────────
    build_stage_configure
    [[ "${LKF_STOP_AFTER}" == "config" ]] && return 0

    # ── Stage: Compile ────────────────────────────────────────────────────────
    build_stage_compile
    [[ "${LKF_STOP_AFTER}" == "build" ]] && return 0

    # ── Stage: Package ────────────────────────────────────────────────────────
    build_stage_package

    # ── Cleanup ───────────────────────────────────────────────────────────────
    [[ "${LKF_CLEAN_AFTER}" -eq 1 ]] && \
        make -C "${LKF_SOURCE_DIR}" clean -j"${LKF_THREADS}"
    [[ "${LKF_REMOVE_AFTER}" -eq 1 ]] && rm -rf "${LKF_SOURCE_DIR}"

    lkf_info "Build complete."
}

# ── Stage implementations ─────────────────────────────────────────────────────

build_stage_download() {
    lkf_ensure_dir "${LKF_DOWNLOAD_DIR}"
    local base_url tarball

    case "${LKF_FLAVOR}" in
        mainline|zen|rt|cachyos|tkg)
            # Vanilla kernel from kernel.org (tkg applies patches on top)
            local major="${LKF_KERNEL_VERSION%%.*}"
            tarball="${LKF_DOWNLOAD_DIR}/linux-${LKF_KERNEL_VERSION}.tar.xz"
            base_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x"
            lkf_download "${base_url}/linux-${LKF_KERNEL_VERSION}.tar.xz" "${tarball}"
            if [[ "${LKF_VERIFY_GPG}" -eq 1 ]]; then
                lkf_download "${base_url}/linux-${LKF_KERNEL_VERSION}.tar.sign" \
                    "${tarball%.xz}.sign"
                # Decompress for verification
                xz -dk "${tarball}" -c > "${tarball%.xz}" 2>/dev/null || true
                lkf_verify_gpg "${tarball%.xz}" "${tarball%.xz}.sign"
            fi
            ;;
        xanmod)
            tarball="${LKF_DOWNLOAD_DIR}/linux-${LKF_KERNEL_VERSION}-xanmod.tar.gz"
            lkf_download \
                "https://gitlab.com/xanmod/linux/-/archive/${LKF_KERNEL_VERSION}/linux-${LKF_KERNEL_VERSION}.tar.gz" \
                "${tarball}"
            ;;
        android)
            lkf_warn "Android kernel source must be specified via --source-dir."
            lkf_warn "See: https://source.android.com/docs/setup/build/building-kernels"
            ;;
        custom)
            lkf_warn "Custom flavor: use --source-dir to point to your kernel tree."
            ;;
    esac

    LKF_TARBALL="${tarball:-}"
}

build_stage_extract() {
    [[ -z "${LKF_TARBALL:-}" ]] && return 0
    lkf_ensure_dir "${LKF_BUILD_DIR}"

    lkf_step "Extracting ${LKF_TARBALL}"
    local extract_dir="${LKF_BUILD_DIR}/src"
    lkf_ensure_dir "${extract_dir}"

    case "${LKF_TARBALL}" in
        *.tar.xz)  tar -xf "${LKF_TARBALL}" -C "${extract_dir}" ;;
        *.tar.gz)  tar -xzf "${LKF_TARBALL}" -C "${extract_dir}" ;;
        *.tar.bz2) tar -xjf "${LKF_TARBALL}" -C "${extract_dir}" ;;
    esac

    # Find the extracted directory
    LKF_SOURCE_DIR=$(find "${extract_dir}" -maxdepth 1 -type d -name 'linux-*' | head -1)
    [[ -z "${LKF_SOURCE_DIR}" ]] && \
        LKF_SOURCE_DIR=$(find "${extract_dir}" -maxdepth 1 -type d | grep -v "^${extract_dir}$" | head -1)
    [[ -z "${LKF_SOURCE_DIR}" ]] && lkf_die "Could not find extracted kernel source."
    lkf_info "Source tree: ${LKF_SOURCE_DIR}"

    if [[ "${LKF_DISTCLEAN}" -eq 1 ]]; then
        lkf_step "Running make distclean"
        make -C "${LKF_SOURCE_DIR}" distclean -j"${LKF_THREADS}" 2>/dev/null || true
    fi
}

build_stage_patch() {
    source "${LKF_ROOT}/core/patch.sh"

    # tkg flavor: use the option-aware tkg patch stack instead of generic apply
    if [[ "${LKF_FLAVOR}" == "tkg" ]] && [[ -z "${LKF_PATCH_SET}" ]]; then
        patch_apply_set_tkg "${LKF_SOURCE_DIR}"
    else
        patch_apply_set "${LKF_SOURCE_DIR}" "${LKF_PATCH_SET}" "${LKF_KERNEL_VERSION}"
    fi

    for p in "${LKF_PATCHES[@]+"${LKF_PATCHES[@]}"}"; do
        [[ -n "${p}" ]] && patch_apply_file "${LKF_SOURCE_DIR}" "${p}"
    done
}

build_stage_configure() {
    source "${LKF_ROOT}/core/config.sh"
    config_apply \
        "${LKF_SOURCE_DIR}" \
        "${LKF_CONFIG_SOURCE}" \
        "${LKF_TARGET}" \
        "${LKF_ARCH}" \
        "${LKF_CROSS_PREFIX}" \
        "${LKF_CC}" \
        "${LKF_LLVM}" \
        "${LKF_LTO}"

    if [[ -n "${LKF_CONFIGURATOR}" ]]; then
        lkf_step "Launching ${LKF_CONFIGURATOR}"
        build_make "${LKF_SOURCE_DIR}" "${LKF_CONFIGURATOR}"
    fi
}

build_stage_compile() {
    lkf_step "Compiling kernel (${LKF_THREADS} threads)"
    local make_args=()

    # Determine make target based on output format
    case "${LKF_OUTPUT_FORMAT}" in
        deb)            make_args+=(deb-pkg) ;;
        rpm)            make_args+=(rpm-pkg) ;;
        pkg.tar.zst)    make_args+=(tarbz2-pkg) ;;
        android-boot)   make_args+=(Image.gz) ;;
        *)              make_args+=(all) ;;
    esac

    build_make "${LKF_SOURCE_DIR}" "${make_args[@]}"
}

build_stage_package() {
    case "${LKF_OUTPUT_FORMAT}" in
        deb|rpm|pkg.tar.zst)
            lkf_info "Packages built in: $(dirname "${LKF_SOURCE_DIR}")"
            ;;
        android-boot)
            source "${LKF_ROOT}/core/image.sh"
            image_android_boot "${LKF_SOURCE_DIR}" "${LKF_BUILD_DIR}"
            ;;
        efi-unified)
            source "${LKF_ROOT}/core/image.sh"
            image_efi_unified "${LKF_SOURCE_DIR}" "${LKF_BUILD_DIR}"
            ;;
    esac

    if [[ "${LKF_COPY_SYSTEM_MAP}" -eq 1 ]]; then
        local map="${LKF_SOURCE_DIR}/System.map"
        [[ -f "${map}" ]] && sudo cp "${map}" "/boot/System.map-${LKF_KERNEL_VERSION}${LKF_LOCALVERSION}"
    fi
}

# ── make wrapper ─────────────────────────────────────────────────────────────

build_make() {
    local src_dir="$1"; shift
    local kernel_arch
    kernel_arch=$(arch_to_kernel_arch "${LKF_ARCH}")

    local make_cmd=(
        make
        -C "${src_dir}"
        -j"${LKF_THREADS}"
        ARCH="${kernel_arch}"
    )

    [[ -n "${LKF_CROSS_PREFIX}" ]] && make_cmd+=(CROSS_COMPILE="${LKF_CROSS_PREFIX}")

    if [[ "${LKF_LLVM}" -eq 1 ]]; then
        make_cmd+=(CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1)
    else
        [[ -n "${LKF_CC}" && "${LKF_CC}" != "gcc" ]] && make_cmd+=(CC="${LKF_CC}")
    fi

    [[ -n "${LKF_KCFLAGS}" ]] && make_cmd+=(KCFLAGS="${LKF_KCFLAGS}")
    [[ -n "${LKF_LOCALVERSION}" ]] && make_cmd+=(LOCALVERSION="${LKF_LOCALVERSION}")

    make_cmd+=("$@")

    lkf_step "Running: ${make_cmd[*]}"
    "${make_cmd[@]}"
}
