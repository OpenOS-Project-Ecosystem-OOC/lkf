#!/usr/bin/env bash
# core/detect.sh - Host and target environment detection
# Distro-agnostic: detects package manager, compiler toolchain, and architecture.

# ── Architecture detection ────────────────────────────────────────────────────

detect_host_arch() {
    local machine
    machine=$(uname -m)
    case "${machine}" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7*|armhf)   echo "arm" ;;
        riscv64)        echo "riscv64" ;;
        loongarch64)    echo "loongarch64" ;;
        mips*)          echo "mips" ;;
        ppc64le)        echo "powerpc" ;;
        s390x)          echo "s390" ;;
        *)              echo "${machine}" ;;
    esac
}

# Map lkf arch name to kernel ARCH= value
arch_to_kernel_arch() {
    case "$1" in
        x86_64)     echo "x86_64" ;;
        aarch64)    echo "arm64" ;;
        arm)        echo "arm" ;;
        riscv64)    echo "riscv" ;;
        loongarch64) echo "loongarch" ;;
        mips*)      echo "mips" ;;
        powerpc)    echo "powerpc" ;;
        s390)       echo "s390" ;;
        *)          echo "$1" ;;
    esac
}

# ── Distro detection ──────────────────────────────────────────────────────────

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "${ID:-unknown}"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/fedora-release ]]; then
        echo "fedora"
    else
        echo "unknown"
    fi
}

detect_pkg_manager() {
    local distro
    distro=$(detect_distro)
    case "${distro}" in
        ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)
            echo "apt" ;;
        arch|manjaro|endeavouros|garuda|artix)
            echo "pacman" ;;
        fedora|rhel|centos|rocky|almalinux)
            echo "dnf" ;;
        opensuse*|sles)
            echo "zypper" ;;
        alpine)
            echo "apk" ;;
        void)
            echo "xbps" ;;
        gentoo)
            echo "emerge" ;;
        nixos)
            echo "nix" ;;
        *)
            # Fallback: probe for known package managers
            for pm in apt dnf pacman zypper apk xbps-install emerge; do
                command -v "${pm}" &>/dev/null && echo "${pm}" && return
            done
            # nix-env presence → nix
            command -v nix-env &>/dev/null && echo "nix" && return
            echo "unknown"
            ;;
    esac
}

# ── Compiler detection ────────────────────────────────────────────────────────

detect_cc() {
    if command -v clang &>/dev/null; then
        echo "clang"
    elif command -v gcc &>/dev/null; then
        echo "gcc"
    else
        echo "none"
    fi
}

detect_llvm_version() {
    if command -v clang &>/dev/null; then
        clang --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1
    fi
}

# ── Cross-compile toolchain detection ────────────────────────────────────────

# Returns a suitable cross-compiler prefix for a given target arch.
# Inspired by Biswa96/android-kernel-builder and limitcool/xm.
detect_cross_prefix() {
    local target_arch="$1"
    local host_arch
    host_arch=$(detect_host_arch)

    # No cross-compile needed if host == target
    [[ "${host_arch}" == "${target_arch}" ]] && echo "" && return

    case "${target_arch}" in
        aarch64)
            for prefix in aarch64-linux-gnu- aarch64-linux-musl- aarch64-unknown-linux-gnu-; do
                command -v "${prefix}gcc" &>/dev/null && echo "${prefix}" && return
            done
            ;;
        arm)
            for prefix in arm-linux-gnueabihf- arm-linux-gnueabi- arm-none-eabi-; do
                command -v "${prefix}gcc" &>/dev/null && echo "${prefix}" && return
            done
            ;;
        riscv64)
            for prefix in riscv64-linux-gnu- riscv64-unknown-linux-gnu-; do
                command -v "${prefix}gcc" &>/dev/null && echo "${prefix}" && return
            done
            ;;
        x86_64)
            for prefix in x86_64-linux-gnu- x86_64-unknown-linux-gnu-; do
                command -v "${prefix}gcc" &>/dev/null && echo "${prefix}" && return
            done
            ;;
    esac
    echo ""
}

# ── Output format detection ───────────────────────────────────────────────────

# Determine the default output package format for the detected distro.
detect_default_output_format() {
    local pm
    pm=$(detect_pkg_manager)
    case "${pm}" in
        apt)    echo "deb" ;;
        pacman) echo "pkg.tar.zst" ;;
        dnf|zypper) echo "rpm" ;;
        *)      echo "tar.gz" ;;
    esac
}

# ── Print summary ─────────────────────────────────────────────────────────────

detect_print_info() {
    local host_arch distro pkg_manager cc llvm_ver cross_prefix output_fmt
    host_arch=$(detect_host_arch)
    distro=$(detect_distro)
    pkg_manager=$(detect_pkg_manager)
    cc=$(detect_cc)
    llvm_ver=$(detect_llvm_version)
    output_fmt=$(detect_default_output_format)

    cat <<EOF
lkf environment info
────────────────────────────────────────
Host arch       : ${host_arch}
Kernel ARCH=    : $(arch_to_kernel_arch "${host_arch}")
Distro          : ${distro}
Package manager : ${pkg_manager}
Default CC      : ${cc}
LLVM version    : ${llvm_ver:-n/a}
Default output  : ${output_fmt}
CPU threads     : $(lkf_nproc)
────────────────────────────────────────
EOF
}
