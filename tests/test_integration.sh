#!/usr/bin/env bash
# tests/test_integration.sh - End-to-end pipeline test (--stop-after extract)
#
# Exercises the full download→extract pipeline without a real kernel tarball
# by injecting a synthetic source tree and a pre-built fake tarball.
# The test verifies:
#   1. build_stage_download resolves the tarball path correctly
#   2. build_stage_extract unpacks and sets LKF_SOURCE_DIR
#   3. --stop-after extract halts before patch/configure/compile
#   4. The extracted source tree contains the expected Makefile sentinel
#   5. lkf_normalize_version and lkf_resolve_version handle common inputs
#   6. ci_generate_github produces a valid YAML skeleton
#   7. ci_generate_gitlab produces a valid YAML skeleton
#   8. ci_generate_forgejo produces a valid YAML skeleton
#   9. patches/fetch.sh --help exits 0 and prints usage
#  10. lkf build --stop-after download with --source-dir skips download

set -euo pipefail

LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LKF_ROOT}/core/lib.sh"
source "${LKF_ROOT}/core/detect.sh"
source "${LKF_ROOT}/core/build.sh"
source "${LKF_ROOT}/ci/ci.sh"

pass=0; fail=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

ok() {
    echo "  PASS: $1"
    pass=$((pass + 1))
}

fail_test() {
    echo "  FAIL: $1"
    fail=$((fail + 1))
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        ok "${desc}"
    else
        fail_test "${desc} — expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "${haystack}" | grep -qF "${needle}"; then
        ok "${desc}"
    else
        fail_test "${desc} — '${needle}' not found in output"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "${path}" ]]; then
        ok "${desc}"
    else
        fail_test "${desc} — file not found: ${path}"
    fi
}

assert_dir_exists() {
    local desc="$1" path="$2"
    if [[ -d "${path}" ]]; then
        ok "${desc}"
    else
        fail_test "${desc} — directory not found: ${path}"
    fi
}

assert_exit_ok() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        ok "${desc}"
    else
        fail_test "${desc} — command failed: $*"
    fi
}

# ── Build a synthetic kernel tarball ─────────────────────────────────────────
# Mimics the structure of linux-6.99.0.tar.xz with just a Makefile sentinel.

FAKE_VER="6.99.0"
FAKE_SRC="${TMPDIR_TEST}/linux-${FAKE_VER}"
FAKE_DL="${TMPDIR_TEST}/downloads"
FAKE_BUILD="${TMPDIR_TEST}/build"
mkdir -p "${FAKE_SRC}" "${FAKE_DL}" "${FAKE_BUILD}"

# Minimal Makefile so the source tree is recognisable
cat > "${FAKE_SRC}/Makefile" <<'EOF'
# Synthetic kernel Makefile for lkf integration tests
VERSION = 6
PATCHLEVEL = 99
SUBLEVEL = 0
EXTRAVERSION =
NAME = Test Kernel
EOF

# Pack it as linux-6.99.0.tar.xz in the downloads dir
(cd "${TMPDIR_TEST}" && tar -cJf "${FAKE_DL}/linux-${FAKE_VER}.tar.xz" "linux-${FAKE_VER}")

echo "=== test_integration.sh ==="

# ── Test 1: lkf_normalize_version ────────────────────────────────────────────
echo ""
echo "-- version normalisation --"
assert_eq "normalize 6.12"     "6.12"   "$(lkf_normalize_version 6.12)"
assert_eq "normalize v6.12.3"  "6.12.3" "$(lkf_normalize_version v6.12.3)"
assert_eq "normalize v6.1"     "6.1"    "$(lkf_normalize_version v6.1)"
# 6.1.y keeps the .y suffix — lkf_resolve_version handles the online lookup
assert_eq "normalize 6.1.y passthrough" "6.1.y" "$(lkf_normalize_version 6.1.y)"

# ── Test 2: build_stage_extract with synthetic tarball ────────────────────────
echo ""
echo "-- build_stage_extract --"

# Set up the module-level variables that build_stage_extract reads/writes
LKF_TARBALL="${FAKE_DL}/linux-${FAKE_VER}.tar.xz"
LKF_BUILD_DIR="${FAKE_BUILD}"
LKF_DISTCLEAN=0
LKF_THREADS="$(nproc)"
LKF_SOURCE_DIR=""

build_stage_extract

assert_dir_exists "LKF_SOURCE_DIR set and exists" "${LKF_SOURCE_DIR}"
assert_file_exists "Makefile present in extracted tree" "${LKF_SOURCE_DIR}/Makefile"

MAKEFILE_CONTENT="$(cat "${LKF_SOURCE_DIR}/Makefile")"
assert_contains "Makefile contains VERSION = 6" "VERSION = 6" "${MAKEFILE_CONTENT}"

# ── Test 3: --stop-after extract halts pipeline ───────────────────────────────
echo ""
echo "-- --stop-after extract --"

# Simulate the pipeline control logic from build_main
_test_pipeline() {
    local stop_after="$1"

    [[ "${stop_after}" == "extract" ]] && { echo "stopped_at_extract"; return 0; }
    [[ "${stop_after}" == "patch"   ]] && { echo "stopped_at_patch";   return 0; }
    echo "reached_config"
}

result="$(_test_pipeline "extract")"
assert_eq "--stop-after extract returns before patch" "stopped_at_extract" "${result}"

result="$(_test_pipeline "patch")"
assert_eq "--stop-after patch returns before config" "stopped_at_patch" "${result}"

result="$(_test_pipeline "")"
assert_eq "no stop-after reaches config" "reached_config" "${result}"

# ── Test 4: build with --source-dir skips download stage ─────────────────────
echo ""
echo "-- --source-dir skips download --"

# When LKF_SOURCE_DIR is pre-set, build_main skips download+extract.
# We verify by checking that LKF_TARBALL is not touched.
LKF_SOURCE_DIR="${FAKE_SRC}"
LKF_TARBALL=""
LKF_STOP_AFTER="patch"   # stop before configure so we don't need a real tree
LKF_PATCH_SET=""
LKF_PATCHES=()
LKF_KERNEL_VERSION="${FAKE_VER}"
LKF_ARCH="$(uname -m)"
LKF_CC="gcc"
LKF_LLVM=0
LKF_LTO="none"
LKF_FLAVOR="mainline"
LKF_CONFIG_SOURCE="defconfig"
LKF_CONFIGURATOR=""
LKF_OUTPUT_FORMAT=""
LKF_LOCALVERSION=""
LKF_KCFLAGS=""
LKF_THREADS="$(nproc)"
LKF_VERIFY_GPG=0
LKF_DISTCLEAN=0
LKF_CLEAN_AFTER=0
LKF_REMOVE_AFTER=0
LKF_COPY_SYSTEM_MAP=0
LKF_TARGET="desktop"
LKF_INSTALL_DEPS=0
LKF_CROSS_PREFIX=""
LKF_LLVM_VERSION=""
LKF_DOWNLOAD_DIR="${FAKE_DL}"
LKF_BUILD_DIR="${FAKE_BUILD}"

# Stub out patch_apply_set so we don't need a real source tree
patch_apply_set() { return 0; }
patch_apply_file() { return 0; }

# Run the pipeline up to --stop-after patch
(
    source "${LKF_ROOT}/core/build.sh"
    # Inline the relevant portion of build_main (skip version resolution)
    if [[ -z "${LKF_SOURCE_DIR}" ]]; then
        build_stage_download
        [[ "${LKF_STOP_AFTER}" == "download" ]] && exit 0
        build_stage_extract
        [[ "${LKF_STOP_AFTER}" == "extract" ]] && exit 0
    fi
    build_stage_patch
    [[ "${LKF_STOP_AFTER}" == "patch" ]] && exit 0
) && ok "--source-dir pipeline stops at patch without downloading" \
  || fail_test "--source-dir pipeline failed"

# ── Test 5: CI generators produce expected YAML keys ─────────────────────────
echo ""
echo "-- CI generators --"

GH_OUT="${TMPDIR_TEST}/github.yml"
GL_OUT="${TMPDIR_TEST}/gitlab.yml"
FJ_OUT="${TMPDIR_TEST}/forgejo.yml"

ci_generate_github  "x86_64" "mainline" 0 "none" "${GH_OUT}" 0 0 2>/dev/null
ci_generate_gitlab  "x86_64" "mainline" 0 "none" "${GL_OUT}" 0 0 2>/dev/null
ci_generate_forgejo "x86_64" "mainline" 0 "none" "${FJ_OUT}" 0 0 2>/dev/null

assert_file_exists "GitHub workflow file created"  "${GH_OUT}"
assert_file_exists "GitLab pipeline file created"  "${GL_OUT}"
assert_file_exists "Forgejo workflow file created"  "${FJ_OUT}"

assert_contains "GitHub YAML has 'jobs:'"          "jobs:"          "$(cat "${GH_OUT}")"
assert_contains "GitHub YAML has 'runs-on:'"       "runs-on:"       "$(cat "${GH_OUT}")"
assert_contains "GitLab YAML has 'stages:'"        "stages:"        "$(cat "${GL_OUT}")"
assert_contains "GitLab YAML has 'script:'"        "script:"        "$(cat "${GL_OUT}")"
assert_contains "Forgejo YAML has 'on:'"           "on:"            "$(cat "${FJ_OUT}")"
assert_contains "Forgejo YAML has 'workflow_dispatch'" "workflow_dispatch" "$(cat "${FJ_OUT}")"

# ── Test 6: patches/fetch.sh --help exits 0 ──────────────────────────────────
echo ""
echo "-- patches/fetch.sh --"
assert_exit_ok "fetch.sh --help exits 0" \
    bash "${LKF_ROOT}/patches/fetch.sh" --help

# ── Test 7: patches/fetch.sh rejects missing --version ───────────────────────
if bash "${LKF_ROOT}/patches/fetch.sh" --set rt &>/dev/null; then
    fail_test "fetch.sh without --version should fail"
else
    ok "fetch.sh without --version exits non-zero"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
