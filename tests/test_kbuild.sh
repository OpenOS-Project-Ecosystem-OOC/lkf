#!/usr/bin/env bash
# tests/test_kbuild.sh - Tests for lkf kbuild (core/kbuild.sh)
#
# Covers:
#   1.  kbuild_usage prints expected subcommands
#   2.  kbuild_main with no args prints usage (exit 0)
#   3.  kbuild_main --help prints usage (exit 0)
#   4.  kbuild_main unknown subcommand exits non-zero
#   5.  _kbuild_parse_common sets expected defaults
#   6.  _kbuild_make_flags: gcc path emits CC=gcc, ARCH=x86_64
#   7.  _kbuild_make_flags: --llvm emits LLVM=1 LLVM_IAS=1 CC=clang
#   8.  _kbuild_make_flags: --cross sets CROSS_COMPILE
#   9.  kbuild_cmd_module fails when --kdir does not exist
#  10.  kbuild_cmd_module fails when --src does not exist
#  11.  kbuild_cmd_info prints KDIR, ARCH, CC, LLVM, CROSS
#  12.  kbuild_cmd_info --llvm shows LLVM: 1
#  13.  kbuild_cmd_info --cross shows CROSS prefix
#  14.  kbuild_cmd_validate fails when --config file missing
#  15.  kbuild_cmd_symbols finds symbols in a fake Kconfig tree
#  16.  kbuild_cmd_symbols --filter narrows results
#  17.  arch_to_kernel_arch maps aarch64 → arm64
#  18.  arch_to_kernel_arch maps x86_64 → x86_64 (passthrough)
#  19.  arch_to_kernel_arch maps arm → arm (passthrough)
#  20.  kbuild_cmd_defconfig fails when --kdir does not exist

set -euo pipefail

LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/lib.sh"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/detect.sh"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/kbuild.sh"

pass=0; fail=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

echo "=== test_kbuild.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()        { echo "  PASS: $1"; pass=$(( pass + 1 )); }
fail_test() { echo "  FAIL: $1"; fail=$(( fail + 1 )); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then ok "${desc}"
    else fail_test "${desc} — expected '${expected}', got '${actual}'"; fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then ok "${desc}"
    else fail_test "${desc} — '${needle}' not found in output"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then ok "${desc}"
    else fail_test "${desc} — '${needle}' unexpectedly found"; fi
}

assert_exits_nonzero() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then ok "${desc}"
    else fail_test "${desc} — expected non-zero exit"; fi
}

assert_exits_zero() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"
    else fail_test "${desc} — expected zero exit"; fi
}

# ── 1-4: kbuild_main dispatch ─────────────────────────────────────────────────
echo ""
echo "-- kbuild_main dispatch --"

usage_out=$(kbuild_usage 2>&1)
assert_contains "usage lists 'module' subcommand"   "module"   "${usage_out}"
assert_contains "usage lists 'config' subcommand"   "config"   "${usage_out}"
assert_contains "usage lists 'validate' subcommand" "validate" "${usage_out}"
assert_contains "usage lists 'symbols' subcommand"  "symbols"  "${usage_out}"
assert_contains "usage lists 'info' subcommand"     "info"     "${usage_out}"

assert_exits_zero    "kbuild_main no args exits 0"       kbuild_main
assert_exits_zero    "kbuild_main --help exits 0"        kbuild_main --help
assert_exits_nonzero "kbuild_main unknown cmd exits non-zero" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/kbuild.sh'; kbuild_main bogus-cmd"

# ── 5: _kbuild_parse_common defaults ─────────────────────────────────────────
echo ""
echo "-- _kbuild_parse_common defaults --"

(
    _kbuild_parse_common
    assert_eq "_kbuild_parse_common: CC=gcc"   "gcc" "${KBUILD_CC}"
    assert_eq "_kbuild_parse_common: LLVM=0"   "0"   "${KBUILD_LLVM}"
    assert_eq "_kbuild_parse_common: CROSS=''" ""    "${KBUILD_CROSS}"
)

# ── 6-8: _kbuild_make_flags ───────────────────────────────────────────────────
echo ""
echo "-- _kbuild_make_flags --"

(
    _kbuild_parse_common
    KBUILD_ARCH="x86_64"
    flags=$(_kbuild_make_flags)
    assert_contains "gcc path: CC=gcc"        "CC=gcc"   "${flags}"
    assert_contains "gcc path: ARCH=x86_64"   "ARCH=x86_64" "${flags}"
    assert_not_contains "gcc path: no LLVM=1" "LLVM=1"   "${flags}"
)

(
    _kbuild_parse_common
    KBUILD_ARCH="x86_64"
    KBUILD_LLVM=1
    flags=$(_kbuild_make_flags)
    assert_contains "llvm path: LLVM=1"      "LLVM=1"    "${flags}"
    assert_contains "llvm path: LLVM_IAS=1"  "LLVM_IAS=1" "${flags}"
    assert_contains "llvm path: CC=clang"    "CC=clang"  "${flags}"
    assert_not_contains "llvm path: no CC=gcc" "CC=gcc"  "${flags}"
)

(
    _kbuild_parse_common
    # shellcheck disable=SC2034  # read by _kbuild_make_flags
    KBUILD_ARCH="aarch64"
    KBUILD_CROSS="aarch64-linux-gnu-"
    flags=$(_kbuild_make_flags)
    assert_contains "cross path: CROSS_COMPILE" "CROSS_COMPILE=aarch64-linux-gnu-" "${flags}"
)

# ── 9-10: kbuild_cmd_module validation ───────────────────────────────────────
echo ""
echo "-- kbuild_cmd_module validation --"

assert_exits_nonzero "module: missing --kdir fails" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/kbuild.sh'; \
             kbuild_cmd_module --kdir /nonexistent/kdir --src ${TMPDIR_TEST}"

assert_exits_nonzero "module: missing --src fails" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/kbuild.sh'; \
             kbuild_cmd_module --kdir ${TMPDIR_TEST} --src /nonexistent/src"

# ── 11-13: kbuild_cmd_info ────────────────────────────────────────────────────
echo ""
echo "-- kbuild_cmd_info --"

info_out=$(kbuild_cmd_info 2>&1)
assert_contains "info: shows KDIR"  "KDIR"  "${info_out}"
assert_contains "info: shows ARCH"  "ARCH"  "${info_out}"
assert_contains "info: shows CC"    "CC"    "${info_out}"
assert_contains "info: shows LLVM"  "LLVM"  "${info_out}"
assert_contains "info: shows CROSS" "CROSS" "${info_out}"

info_llvm=$(kbuild_cmd_info --llvm 2>&1)
assert_contains "info --llvm: LLVM: 1" "LLVM    : 1" "${info_llvm}"

info_cross=$(kbuild_cmd_info --cross "aarch64-linux-gnu-" 2>&1)
assert_contains "info --cross: shows prefix" "aarch64-linux-gnu-" "${info_cross}"

# ── 14: kbuild_cmd_validate missing config ────────────────────────────────────
echo ""
echo "-- kbuild_cmd_validate --"

assert_exits_nonzero "validate: missing --config fails" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/kbuild.sh'; \
             kbuild_cmd_validate --config /nonexistent/.config"

# ── 15-16: kbuild_cmd_symbols ─────────────────────────────────────────────────
echo ""
echo "-- kbuild_cmd_symbols --"

# Build a minimal fake Kconfig tree
FAKE_KCONFIG_DIR="${TMPDIR_TEST}/fake-kconfig"
mkdir -p "${FAKE_KCONFIG_DIR}"
cat > "${FAKE_KCONFIG_DIR}/Kconfig" <<'EOF'
config FAKE_FEATURE
    bool "Enable fake feature"
    default y

config FAKE_TURBO
    tristate "Turbo mode"
    default m

config FAKE_LEVEL
    int "Level setting"
    default 3
EOF

symbols_out=$(kbuild_cmd_symbols --src "${FAKE_KCONFIG_DIR}" 2>/dev/null)
assert_contains "symbols: finds bool symbol"     "Enable fake feature" "${symbols_out}"
assert_contains "symbols: finds tristate symbol" "Turbo mode"          "${symbols_out}"
assert_contains "symbols: finds int symbol"      "Level setting"       "${symbols_out}"

filtered_out=$(kbuild_cmd_symbols --src "${FAKE_KCONFIG_DIR}" --filter "turbo" 2>/dev/null)
assert_contains     "symbols --filter: matches turbo"    "Turbo mode"          "${filtered_out}"
assert_not_contains "symbols --filter: excludes feature" "Enable fake feature" "${filtered_out}"

# ── 17-19: arch_to_kernel_arch ───────────────────────────────────────────────
echo ""
echo "-- arch_to_kernel_arch --"

assert_eq "aarch64 → arm64"       "arm64"  "$(arch_to_kernel_arch aarch64)"
assert_eq "x86_64 passthrough"    "x86_64" "$(arch_to_kernel_arch x86_64)"
assert_eq "arm passthrough"       "arm"    "$(arch_to_kernel_arch arm)"

# ── 20: kbuild_cmd_defconfig missing kdir ────────────────────────────────────
echo ""
echo "-- kbuild_cmd_defconfig --"

assert_exits_nonzero "defconfig: missing --kdir fails" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/kbuild.sh'; \
             kbuild_cmd_defconfig --kdir /nonexistent/kdir"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
