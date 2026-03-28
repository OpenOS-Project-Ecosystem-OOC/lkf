#!/usr/bin/env bash
# lkf - Linux Kernel Framework
# Distro-agnostic, architecture-agnostic framework for building, developing,
# ricing/remixing, and redistributing Linux kernels.
#
# Incorporates concepts from:
#   ghazzor/Xanmod-Kernel-Builder     - Clang/LLVM CI workflow, LTO configs
#   kodx/symlink-initrd-kernel-in-root - Boot symlink management
#   rawdaGastan/go-extract-vmlinux     - vmlinux/vmlinuz extraction (Go)
#   elfmaster/kdress                   - vmlinuz -> debuggable vmlinux transform
#   eballetbo/unzboot                  - EFI zboot ARM64 extraction
#   Biswa96/android-kernel-builder     - Android/ARM cross-compile + boot.img repack
#   AlexanderARodin/LinuxComponentsBuilder - kernel+initrd+rootfs+squash pipeline
#   osresearch/linux-builder           - Appliance/firmware, unified EFI kernel
#   tsirysndr/vmlinux-builder          - TypeScript/Deno config API, multi-arch CI
#   rizalmart/puppy-linux-kernel-maker - AUFS patch, firmware driver workflow
#   deepseagirl/easylkb                - QEMU debug environment, GDB integration
#   limitcool/xm                       - Cross-compile manager (Go/Rust/ARM/x86)
#   masahir0y/kbuild_skeleton          - Kbuild/Kconfig standalone template
#   h0tc0d3/kbuild                     - Flexible build script, DKMS, GPG verify
#   WangNan0/kbuild-standalone         - Standalone kconfig+kbuild as a library

set -euo pipefail

LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LKF_VERSION="0.1.0"

# shellcheck source=core/lib.sh
source "${LKF_ROOT}/core/lib.sh"
# shellcheck source=core/detect.sh
source "${LKF_ROOT}/core/detect.sh"
# shellcheck source=core/toolchain.sh
source "${LKF_ROOT}/core/toolchain.sh"

usage() {
    cat <<EOF
lkf ${LKF_VERSION} - Linux Kernel Framework

USAGE: lkf <command> [options]

COMMANDS:
  build       Fetch, configure, patch, and compile a kernel
  remix       Build a kernel from a declarative remix.toml descriptor
  config      Manage kernel .config files (generate, merge, validate, convert)
  patch       Apply or manage patch sets
  initrd      Build initramfs/initrd images
  image       Package kernel into distro packages or EFI unified images
  install     Install kernel + initrd to /boot, manage symlinks
  debug       Launch QEMU+GDB debug environment
  extract     Extract vmlinux from vmlinuz/EFI/boot.img
  dkms        Manage DKMS modules alongside a kernel build
  profile     List, create, or switch named build profiles
  ci          Emit CI workflow files (GitHub Actions, GitLab CI, Forgejo)
  info        Show detected host/target environment

Run 'lkf <command> --help' for command-specific options.

EXAMPLES:
  # Build mainline 6.12 for the current host
  lkf build --version 6.12

  # Build Xanmod with Clang/LLVM + Full LTO for x86_64
  lkf build --version 6.12 --flavor xanmod --arch x86_64 --llvm --lto full

  # Cross-compile for aarch64 (Android boot.img output)
  lkf build --version 6.1 --arch aarch64 --target android --cross aarch64-linux-gnu-

  # Build with AUFS patch for Puppy Linux
  lkf build --version 6.12 --patch-set aufs --output deb

  # Launch QEMU debug session
  lkf debug --version 6.12 --port-ssh 10021 --port-gdb 1234

  # Extract vmlinux from a compressed vmlinuz
  lkf extract --input /boot/vmlinuz-6.12 --output /tmp/vmlinux --symbols /boot/System.map-6.12

  # Generate a unified EFI kernel image
  lkf image --type efi-unified --kernel build/vmlinuz --initrd build/initrd.cpio.xz --cmdline cmdline.txt

  # Emit a GitHub Actions workflow
  lkf ci --provider github --arch x86_64,aarch64 --output .github/workflows/kernel.yml
EOF
}

main() {
    [[ $# -eq 0 ]] && { usage; exit 0; }

    local cmd="$1"; shift

    case "${cmd}" in
        build)   cmd_build "$@" ;;
        remix)   cmd_remix "$@" ;;
        config)  cmd_config "$@" ;;
        patch)   cmd_patch "$@" ;;
        initrd)  cmd_initrd "$@" ;;
        image)   cmd_image "$@" ;;
        install) cmd_install "$@" ;;
        debug)   cmd_debug "$@" ;;
        extract) cmd_extract "$@" ;;
        dkms)    cmd_dkms "$@" ;;
        profile) cmd_profile "$@" ;;
        ci)      cmd_ci "$@" ;;
        info)    cmd_info "$@" ;;
        -h|--help|help) usage ;;
        *) lkf_die "Unknown command: ${cmd}. Run 'lkf --help'." ;;
    esac
}

# Lazy-load command modules
cmd_build()   { source "${LKF_ROOT}/core/build.sh";   build_main "$@"; }
cmd_remix()   { source "${LKF_ROOT}/core/remix.sh";   remix_main "$@"; }
cmd_config()  { source "${LKF_ROOT}/core/config.sh";  config_main "$@"; }
cmd_patch()   { source "${LKF_ROOT}/core/patch.sh";   patch_main "$@"; }
cmd_initrd()  { source "${LKF_ROOT}/core/initrd.sh";  initrd_main "$@"; }
cmd_image()   { source "${LKF_ROOT}/core/image.sh";   image_main "$@"; }
cmd_install() { source "${LKF_ROOT}/core/install.sh"; install_main "$@"; }
cmd_debug()   { source "${LKF_ROOT}/core/debug.sh";   debug_main "$@"; }
cmd_extract() { source "${LKF_ROOT}/core/extract.sh"; extract_main "$@"; }
cmd_dkms()    { source "${LKF_ROOT}/core/dkms.sh";    dkms_main "$@"; }
cmd_profile() { source "${LKF_ROOT}/core/profile.sh"; profile_main "$@"; }
cmd_ci()      { source "${LKF_ROOT}/ci/ci.sh";        ci_main "$@"; }
cmd_info()    { source "${LKF_ROOT}/core/detect.sh";  detect_print_info; }

main "$@"
