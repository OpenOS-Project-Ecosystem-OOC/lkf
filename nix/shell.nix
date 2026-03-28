# nix/shell.nix — nix-shell environment for lkf kernel builds
#
# Usage:
#   nix-shell nix/shell.nix
#   nix-shell nix/shell.nix --run 'lkf build --version 6.12'
#
# With LLVM/Clang:
#   nix-shell nix/shell.nix --arg withLLVM true
#
# Cross-compile for aarch64:
#   nix-shell nix/shell.nix --arg crossTarget "aarch64-unknown-linux-gnu"

{ pkgs ? import <nixpkgs> {}
, withLLVM ? false
, crossTarget ? ""
}:

let
  llvmPkgs = if withLLVM then [
    pkgs.clang
    pkgs.lld
    pkgs.llvm
  ] else [];

  crossPkgs = if crossTarget != "" then [
    pkgs.pkgsCross.aarch64-multiplatform.buildPackages.gcc
    pkgs.pkgsCross.aarch64-multiplatform.buildPackages.binutils
  ] else [];

  kernelBuildDeps = with pkgs; [
    # Core build tools
    gcc
    gnumake
    bison
    flex
    bc
    perl
    python3

    # Kernel config / headers
    ncurses
    openssl
    elfutils
    pahole

    # Compression
    lz4
    zstd
    xz
    bzip2

    # Packaging / install
    rsync
    cpio
    git
    curl
    wget

    # Optional: deb/rpm packaging
    dpkg
    rpm

    # Debugging
    gdb
    qemu
  ];

in pkgs.mkShell {
  name = "lkf-kernel-build";

  buildInputs = kernelBuildDeps ++ llvmPkgs ++ crossPkgs;

  shellHook = ''
    export LKF_NIX_SHELL=1
    echo "[lkf] nix-shell ready — kernel build environment active"
    echo "[lkf] Run: lkf build --version 6.12"
    ${if withLLVM then ''echo "[lkf] LLVM/Clang available: $(clang --version | head -1)"'' else ""}
  '';
}
