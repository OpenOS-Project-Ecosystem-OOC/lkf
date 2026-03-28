{
  description = "lkf — Linux Kernel Framework build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        kernelBuildDeps = with pkgs; [
          gcc gnumake bison flex bc perl python3
          ncurses openssl elfutils pahole
          lz4 zstd xz bzip2
          rsync cpio git curl wget
          dpkg rpm
          gdb qemu
        ];

        llvmDeps = with pkgs; [ clang lld llvm ];

      in {
        # Default shell: gcc build environment
        devShells.default = pkgs.mkShell {
          name = "lkf";
          buildInputs = kernelBuildDeps;
          shellHook = ''
            export LKF_NIX_SHELL=1
            echo "[lkf] nix develop shell ready (gcc)"
          '';
        };

        # LLVM/Clang build environment
        devShells.llvm = pkgs.mkShell {
          name = "lkf-llvm";
          buildInputs = kernelBuildDeps ++ llvmDeps;
          shellHook = ''
            export LKF_NIX_SHELL=1
            echo "[lkf] nix develop shell ready (clang $(clang --version | head -1 | grep -oP '\d+\.\d+\.\d+'))"
          '';
        };

        # Cross-compile for aarch64
        devShells.aarch64 = pkgs.mkShell {
          name = "lkf-aarch64";
          buildInputs = kernelBuildDeps ++ [
            pkgs.pkgsCross.aarch64-multiplatform.buildPackages.gcc
            pkgs.pkgsCross.aarch64-multiplatform.buildPackages.binutils
          ];
          shellHook = ''
            export LKF_NIX_SHELL=1
            export CROSS_COMPILE=aarch64-unknown-linux-gnu-
            echo "[lkf] nix develop shell ready (aarch64 cross)"
          '';
        };
      }
    );
}
