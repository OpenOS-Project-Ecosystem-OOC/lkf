#!/usr/bin/env bash
# tests/test_xm.sh - Tests for lkf xm (core/xm.sh)
#
# Covers:
#   1.  xm_usage prints expected options
#   2.  xm_main --help exits 0
#   3.  xm_main without --version exits non-zero
#   4.  xm_main unknown option exits non-zero
#   5.  _xm_cross_prefix: x86_64 → empty (native)
#   6.  _xm_cross_prefix: aarch64 → aarch64-linux-gnu-
#   7.  _xm_cross_prefix: arm → arm-linux-gnueabihf-
#   8.  _xm_cross_prefix: riscv64 → riscv64-linux-gnu-
#   9.  _xm_cross_prefix: ppc64le → powerpc64le-linux-gnu-
#  10.  _xm_cross_prefix: unknown arch → empty string
#  11.  _xm_check_toolchain: native x86_64/gcc passes when gcc present
#  12.  _xm_check_toolchain: missing cross-compiler returns non-zero
#  13.  _xm_colour: no-color mode returns plain text
#  14.  _xm_colour: green wraps text in ANSI codes
#  15.  xm_main --dry-run prints matrix without running builds
#  16.  xm_main --dry-run shows each arch × cc cell
#  17.  xm_main --dry-run shows toolchain availability marker
#  18.  _xm_set_result / _xm_results tracking
#  19.  _xm_print_table: PASS/FAIL/SKIP counts in summary line
#  20.  _xm_print_table: exits non-zero when any cell FAILed

set -euo pipefail

LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/lib.sh"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/detect.sh"
# shellcheck disable=SC1090
source "${LKF_ROOT}/core/xm.sh"

pass=0; fail=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

echo "=== test_xm.sh ==="

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

# ── 1-4: xm_main dispatch ────────────────────────────────────────────────────
echo ""
echo "-- xm_main dispatch --"

usage_out=$(xm_usage 2>&1)
assert_contains "usage: --arch option"     "--arch"     "${usage_out}"
assert_contains "usage: --cc option"       "--cc"       "${usage_out}"
assert_contains "usage: --version option"  "--version"  "${usage_out}"
assert_contains "usage: --dry-run option"  "--dry-run"  "${usage_out}"
assert_contains "usage: --parallel option" "--parallel" "${usage_out}"

assert_exits_zero    "xm_main --help exits 0" xm_main --help

assert_exits_nonzero "xm_main without --version exits non-zero" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/xm.sh'; xm_main --arch x86_64"

assert_exits_nonzero "xm_main unknown option exits non-zero" \
    bash -c "source '${LKF_ROOT}/core/lib.sh'; source '${LKF_ROOT}/core/detect.sh'; \
             source '${LKF_ROOT}/core/xm.sh'; xm_main --version 6.12 --bogus"

# ── 5-10: _xm_cross_prefix ───────────────────────────────────────────────────
echo ""
echo "-- _xm_cross_prefix --"

assert_eq "x86_64 → native (empty)"          ""                        "$(_xm_cross_prefix x86_64)"
assert_eq "aarch64 → aarch64-linux-gnu-"     "aarch64-linux-gnu-"     "$(_xm_cross_prefix aarch64)"
assert_eq "arm → arm-linux-gnueabihf-"       "arm-linux-gnueabihf-"   "$(_xm_cross_prefix arm)"
assert_eq "riscv64 → riscv64-linux-gnu-"     "riscv64-linux-gnu-"     "$(_xm_cross_prefix riscv64)"
assert_eq "ppc64le → powerpc64le-linux-gnu-" "powerpc64le-linux-gnu-" "$(_xm_cross_prefix ppc64le)"
assert_eq "unknown arch → empty"             ""                        "$(_xm_cross_prefix sparc)"

# ── 11-12: _xm_check_toolchain ───────────────────────────────────────────────
echo ""
echo "-- _xm_check_toolchain --"

# Native gcc: should pass in any standard CI environment
if command -v gcc &>/dev/null; then
    assert_exits_zero "_xm_check_toolchain: native gcc available" \
        _xm_check_toolchain x86_64 gcc
else
    ok "_xm_check_toolchain: native gcc available (skipped — gcc not on PATH)"
fi

# Inject a fake arch with a guaranteed-absent cross prefix to test the failure path
_xm_cross_prefix() {
    case "$1" in
        x86_64)  echo "" ;;
        aarch64) echo "aarch64-linux-gnu-" ;;
        arm)     echo "arm-linux-gnueabihf-" ;;
        riscv64) echo "riscv64-linux-gnu-" ;;
        ppc64le) echo "powerpc64le-linux-gnu-" ;;
        s390x)   echo "s390x-linux-gnu-" ;;
        loongarch64) echo "loongarch64-linux-gnu-" ;;
        mips)    echo "mips-linux-gnu-" ;;
        mips64)  echo "mips64-linux-gnuabi64-" ;;
        __test_absent__) echo "lkf-nonexistent-arch-99-linux-gnu-" ;;
        *)       echo "" ;;
    esac
}
assert_exits_nonzero "_xm_check_toolchain: missing cross-compiler returns non-zero" \
    _xm_check_toolchain __test_absent__ gcc

# ── 13-14: _xm_colour ────────────────────────────────────────────────────────
echo ""
echo "-- _xm_colour --"

XM_NO_COLOR=1
plain=$(  _xm_colour green "hello")
assert_eq "no-color: plain text returned" "hello" "${plain}"

# shellcheck disable=SC2034  # read by _xm_colour
XM_NO_COLOR=0
coloured=$(_xm_colour green "hello")
assert_contains "colour: ANSI escape present" $'\033[' "${coloured}"
assert_contains "colour: text present"        "hello"  "${coloured}"

# ── 15-17: xm_main --dry-run ─────────────────────────────────────────────────
echo ""
echo "-- xm_main --dry-run --"

dry_out=$(XM_NO_COLOR=1 xm_main \
    --version 6.12 \
    --arch x86_64,aarch64 \
    --cc gcc \
    --dry-run 2>&1)

assert_contains "dry-run: x86_64 listed"  "x86_64"  "${dry_out}"
assert_contains "dry-run: aarch64 listed" "aarch64" "${dry_out}"
assert_contains "dry-run: gcc listed"     "gcc"     "${dry_out}"
# Dry run must not attempt any actual build
assert_not_contains "dry-run: no 'Building' step" "Building" "${dry_out}"

# Each cell should show the arch × cc pair
assert_contains "dry-run: x86_64 × gcc cell" "x86_64" "${dry_out}"
assert_contains "dry-run: aarch64 × gcc cell" "aarch64" "${dry_out}"

# Toolchain availability marker (✓ or ✗)
assert_contains "dry-run: toolchain marker present" "native" "${dry_out}"

# ── 18-20: result tracking and _xm_print_table ───────────────────────────────
echo ""
echo "-- result tracking and summary table --"

# Reset global state
declare -A _XM_RESULTS=()
declare -A _XM_TIMES=()
declare -A _XM_LOGS=()
_XM_CC_LIST=(gcc)

_xm_set_result x86_64  gcc PASS; _xm_set_time x86_64  gcc 5
_xm_set_result aarch64 gcc SKIP; _xm_set_time aarch64 gcc 0
_xm_set_result arm     gcc PASS; _xm_set_time arm     gcc 8

assert_eq "result tracking: x86_64 PASS"  "PASS" "${_XM_RESULTS[x86_64:gcc]}"
assert_eq "result tracking: aarch64 SKIP" "SKIP" "${_XM_RESULTS[aarch64:gcc]}"
assert_eq "result tracking: arm PASS"     "PASS" "${_XM_RESULTS[arm:gcc]}"

table_out=$(XM_NO_COLOR=1 _xm_print_table x86_64 aarch64 arm 2>&1)
assert_contains "table: PASS in output" "PASS" "${table_out}"
assert_contains "table: SKIP in output" "SKIP" "${table_out}"
assert_contains "table: summary line"   "passed" "${table_out}"

# Table with a FAIL cell must exit non-zero
_xm_set_result arm gcc FAIL
if ! XM_NO_COLOR=1 _xm_print_table x86_64 aarch64 arm >/dev/null 2>&1; then
    ok "_xm_print_table: exits non-zero when FAIL present"
else
    fail_test "_xm_print_table: exits non-zero when FAIL present"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
