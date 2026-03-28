#!/usr/bin/env bash
# core/toolchain.sh - Toolchain setup and dependency installation
# Distro-agnostic: maps required build deps to each package manager.
# Inspired by: ghazzor/Xanmod-Kernel-Builder, deepseagirl/easylkb,
#              osresearch/linux-builder, tsirysndr/vmlinux-builder

# ── Dependency maps ───────────────────────────────────────────────────────────

# Core kernel build dependencies per package manager
declare -A _DEPS_APT=(
    [build-essential]="build-essential"
    [bison]="bison"
    [flex]="flex"
    [libncurses-dev]="libncurses-dev"
    [libssl-dev]="libssl-dev"
    [libelf-dev]="libelf-dev"
    [bc]="bc"
    [lz4]="lz4"
    [zstd]="zstd"
    [rsync]="rsync"
    [pahole]="pahole"
    [dwarves]="dwarves"
    [cpio]="cpio"
    [xz-utils]="xz-utils"
    [bzip2]="bzip2"
    [git]="git"
    [make]="make"
    [gcc]="gcc"
    [perl]="perl"
    [python3]="python3"
)

declare -A _DEPS_PACMAN=(
    [base-devel]="base-devel"
    [bison]="bison"
    [flex]="flex"
    [ncurses]="ncurses"
    [openssl]="openssl"
    [libelf]="libelf"
    [bc]="bc"
    [lz4]="lz4"
    [zstd]="zstd"
    [rsync]="rsync"
    [pahole]="pahole"
    [cpio]="cpio"
    [xz]="xz"
    [bzip2]="bzip2"
    [git]="git"
    [make]="make"
    [gcc]="gcc"
    [perl]="perl"
    [python]="python"
)

declare -A _DEPS_DNF=(
    [gcc]="gcc"
    [g++]="gcc-c++"
    [bison]="bison"
    [flex]="flex"
    [ncurses-devel]="ncurses-devel"
    [openssl-devel]="openssl-devel"
    [elfutils-libelf-devel]="elfutils-libelf-devel"
    [bc]="bc"
    [lz4]="lz4"
    [zstd]="zstd"
    [rsync]="rsync"
    [pahole]="pahole"
    [cpio]="cpio"
    [xz]="xz"
    [bzip2]="bzip2"
    [git]="git"
    [make]="make"
    [perl-FindBin]="perl-FindBin"
    [perl-File-Compare]="perl-File-Compare"
    [python3]="python3"
)

declare -A _DEPS_APK=(
    [build-base]="build-base"
    [bison]="bison"
    [flex]="flex"
    [ncurses-dev]="ncurses-dev"
    [openssl-dev]="openssl-dev"
    [elfutils-dev]="elfutils-dev"
    [bc]="bc"
    [lz4]="lz4"
    [zstd]="zstd"
    [rsync]="rsync"
    [cpio]="cpio"
    [xz]="xz"
    [bzip2]="bzip2"
    [git]="git"
    [make]="make"
    [gcc]="gcc"
    [perl]="perl"
    [python3]="python3"
)

# LLVM/Clang additional deps
declare -A _DEPS_LLVM_APT=(
    [clang]="clang"
    [llvm]="llvm"
    [lld]="lld"
    [llvm-dev]="llvm-dev"
)

declare -A _DEPS_LLVM_PACMAN=(
    [clang]="clang"
    [llvm]="llvm"
    [lld]="lld"
)

declare -A _DEPS_LLVM_DNF=(
    [clang]="clang"
    [llvm]="llvm"
    [lld]="lld"
)

# Debug/QEMU deps (for lkf debug command, inspired by deepseagirl/easylkb)
declare -A _DEPS_DEBUG_APT=(
    [qemu-system]="qemu-system-x86"
    [debootstrap]="debootstrap"
    [gdb]="gdb"
)

declare -A _DEPS_DEBUG_PACMAN=(
    [qemu]="qemu-full"
    [gdb]="gdb"
)

declare -A _DEPS_DEBUG_DNF=(
    [qemu]="qemu-kvm"
    [gdb]="gdb"
)

# ── Install functions ─────────────────────────────────────────────────────────

toolchain_install_deps() {
    local pm
    pm=$(detect_pkg_manager)
    lkf_step "Installing kernel build dependencies via ${pm}..."

    case "${pm}" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y --no-install-recommends \
                "${_DEPS_APT[@]}"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm --needed \
                "${_DEPS_PACMAN[@]}"
            ;;
        dnf)
            sudo dnf install -y \
                "${_DEPS_DNF[@]}"
            ;;
        apk)
            sudo apk add --no-cache \
                "${_DEPS_APK[@]}"
            ;;
        zypper)
            sudo zypper install -y \
                gcc make bison flex ncurses-devel libopenssl-devel \
                libelf-devel bc lz4 zstd rsync cpio xz bzip2 git perl python3
            ;;
        emerge)
            sudo emerge --ask=n \
                sys-devel/gcc sys-devel/make sys-devel/bison sys-devel/flex \
                sys-libs/ncurses dev-libs/openssl dev-libs/elfutils \
                sys-apps/bc app-arch/lz4 app-arch/zstd net-misc/rsync \
                app-arch/cpio app-arch/xz-utils app-arch/bzip2 dev-vcs/git \
                dev-lang/perl dev-lang/python
            ;;
        nix)
            # On NixOS / with Nix, prefer nix-shell with the provided shell.nix.
            # If already inside a nix-shell (IN_NIX_SHELL is set), deps are present.
            if [[ -n "${IN_NIX_SHELL:-}" ]]; then
                lkf_info "Already inside nix-shell — build dependencies are available."
            else
                local shell_nix="${LKF_ROOT}/nix/shell.nix"
                if [[ -f "${shell_nix}" ]]; then
                    lkf_info "NixOS detected. Re-entering via nix-shell ${shell_nix} ..."
                    lkf_info "Run: nix-shell ${shell_nix} --run 'lkf ${LKF_ORIG_ARGS:-build}'"
                else
                    lkf_warn "nix/shell.nix not found. Install deps manually or run:"
                    lkf_warn "  nix-shell -p gcc gnumake bison flex ncurses openssl elfutils bc lz4 zstd rsync cpio xz bzip2 git perl python3"
                fi
            fi
            ;;
        *)
            lkf_warn "Unknown package manager '${pm}'. Install build deps manually."
            lkf_warn "Required: gcc/clang, make, bison, flex, libncurses-dev, libssl-dev,"
            lkf_warn "          libelf-dev, bc, lz4, zstd, rsync, cpio, xz, bzip2, git, perl, python3"
            ;;
    esac
}

toolchain_install_llvm() {
    local version="${1:-}"
    local pm
    pm=$(detect_pkg_manager)
    lkf_step "Installing LLVM/Clang toolchain..."

    case "${pm}" in
        apt)
            if [[ -n "${version}" ]]; then
                # Use the official LLVM apt installer (from ghazzor/Xanmod-Kernel-Builder)
                lkf_step "Using llvm.sh installer for LLVM ${version}"
                local tmp
                tmp=$(lkf_mktemp_dir)
                lkf_download "https://apt.llvm.org/llvm.sh" "${tmp}/llvm.sh"
                chmod +x "${tmp}/llvm.sh"
                sudo bash "${tmp}/llvm.sh" "${version}"
                rm -rf "${tmp}"
            else
                sudo apt-get install -y --no-install-recommends \
                    "${_DEPS_LLVM_APT[@]}"
            fi
            ;;
        pacman)
            sudo pacman -Sy --noconfirm --needed "${_DEPS_LLVM_PACMAN[@]}"
            ;;
        dnf)
            sudo dnf install -y "${_DEPS_LLVM_DNF[@]}"
            ;;
        *)
            lkf_warn "Install clang, llvm, lld manually for your distro."
            ;;
    esac
}

toolchain_install_debug_deps() {
    local pm
    pm=$(detect_pkg_manager)
    lkf_step "Installing debug/QEMU dependencies..."

    case "${pm}" in
        apt)    sudo apt-get install -y --no-install-recommends "${_DEPS_DEBUG_APT[@]}" ;;
        pacman) sudo pacman -Sy --noconfirm --needed "${_DEPS_DEBUG_PACMAN[@]}" ;;
        dnf)    sudo dnf install -y "${_DEPS_DEBUG_DNF[@]}" ;;
        *)      lkf_warn "Install qemu, gdb, debootstrap manually." ;;
    esac
}

# ── Cross-compiler installation ───────────────────────────────────────────────

toolchain_install_cross() {
    local target_arch="$1"
    local pm
    pm=$(detect_pkg_manager)
    lkf_step "Installing cross-compiler for ${target_arch}..."

    case "${pm}" in
        apt)
            case "${target_arch}" in
                aarch64) sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu ;;
                arm)     sudo apt-get install -y gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf ;;
                riscv64) sudo apt-get install -y gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu ;;
                *)       lkf_warn "No apt cross-compiler known for ${target_arch}" ;;
            esac
            ;;
        pacman)
            case "${target_arch}" in
                aarch64) sudo pacman -Sy --noconfirm --needed aarch64-linux-gnu-gcc ;;
                arm)     sudo pacman -Sy --noconfirm --needed arm-linux-gnueabihf-gcc ;;
                *)       lkf_warn "Install cross-compiler for ${target_arch} from AUR." ;;
            esac
            ;;
        dnf)
            case "${target_arch}" in
                aarch64) sudo dnf install -y gcc-aarch64-linux-gnu ;;
                arm)     sudo dnf install -y gcc-arm-linux-gnu ;;
                *)       lkf_warn "No dnf cross-compiler known for ${target_arch}" ;;
            esac
            ;;
        *)
            lkf_warn "Install cross-compiler for ${target_arch} manually."
            ;;
    esac
}
