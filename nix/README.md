# NixOS / Nix support

lkf detects NixOS automatically and provides two entry points:

## nix-shell (classic)

```sh
# Default gcc environment
nix-shell nix/shell.nix

# With LLVM/Clang
nix-shell nix/shell.nix --arg withLLVM true

# Cross-compile for aarch64
nix-shell nix/shell.nix --arg crossTarget "aarch64-unknown-linux-gnu"

# Run a build directly
nix-shell nix/shell.nix --run 'lkf build --version 6.12'
```

## nix develop (flakes)

```sh
# Default gcc environment
nix develop .#

# LLVM/Clang environment
nix develop .#llvm

# aarch64 cross-compile environment
nix develop .#aarch64
```

## Auto-detection

When `lkf --install-deps` is run on NixOS and `IN_NIX_SHELL` is not set,
lkf prints the correct `nix-shell` invocation rather than attempting to
use a missing package manager.

If `IN_NIX_SHELL` or `LKF_NIX_SHELL` is set (i.e. you are already inside
a nix-shell), lkf proceeds normally — all build dependencies are on `PATH`.

## Adding packages

Edit `nix/shell.nix` or `nix/flake.nix` and add packages to the
`buildInputs` list using NixOS package names from
[search.nixos.org](https://search.nixos.org/packages).
