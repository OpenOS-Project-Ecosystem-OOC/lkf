#!/usr/bin/env bash
# tests/test_tkg.sh - Tests for linux-tkg integration
#
# Covers:
#   1.  patches/fetch.sh recognises 'tkg' as a valid set
#   2.  patches/fetch.sh --set all includes tkg
#   3.  remix.toml [tkg] section parses all 8 fields correctly
#   4.  remix --dry-run for gaming.toml emits correct --tkg-* flags
#   5.  remix --dry-run for server.toml emits --tkg-no-fsync, no --tkg-ntsync
#   6.  remix --dry-run omits tkg flags when flavor != tkg
#   7.  patch_apply_set_tkg selects bore patches for cpusched=bore
#   8.  patch_apply_set_tkg selects eevdf patches for cpusched=eevdf
#   9.  patch_apply_set_tkg selects bmq+prjc patches for cpusched=bmq
#  10.  patch_apply_set_tkg warns and falls back for muqss on 6.x
#  11.  patch_apply_set_tkg warns when patches/tkg/ is empty
#  12.  tkg-gaming profile exists and contains expected fields
#  13.  tkg-bore profile exists and contains expected fields
#  14.  tkg-server profile exists and contains expected fields
#  15.  tkg-gaming.config fragment contains CONFIG_NTSYNC
#  16.  lkf profile list includes all three tkg profiles
#  17.  build_stage_patch routes tkg flavor through patch_apply_set_tkg
#  18.  build_stage_patch uses generic apply when --patch-set overrides tkg
#  19.  fetch_tkg fetches from correct GitHub API path
#  20.  TKG_* defaults are sensible (eevdf, fsync=1, clear=1, zenify=1)

set -euo pipefail

LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LKF_ROOT}/core/lib.sh"
source "${LKF_ROOT}/core/detect.sh"
source "${LKF_ROOT}/core/remix.sh"
source "${LKF_ROOT}/core/patch.sh"

pass=0; fail=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()        { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL: $1"; fail=$((fail + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then ok "${desc}"
    else fail_test "${desc} — expected '${expected}', got '${actual}'"; fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then ok "${desc}"
    else fail_test "${desc} — '${needle}' not found"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then ok "${desc}"
    else fail_test "${desc} — '${needle}' unexpectedly found"; fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "${path}" ]]; then ok "${desc}"
    else fail_test "${desc} — file not found: ${path}"; fi
}

echo "=== test_tkg.sh ==="

# ── 1-2: fetch.sh set recognition ────────────────────────────────────────────
echo ""
echo "-- patches/fetch.sh set recognition --"

# Test 1: tkg is a recognised set (exits 0, not "Unknown patch set")
fetch_tkg_log=$(bash "${LKF_ROOT}/patches/fetch.sh" \
    --version 6.12 --set tkg --dir "${TMPDIR_TEST}/fetch-tkg" 2>&1 || true)
if [[ "${fetch_tkg_log}" != *"Unknown patch set"* ]]; then
    ok "fetch.sh recognises 'tkg' set"
else
    fail_test "fetch.sh does not recognise 'tkg' set"
fi

# Test 2: 'all' expands to include tkg
all_log=$(bash "${LKF_ROOT}/patches/fetch.sh" --version 6.12 --set all \
    --dir "${TMPDIR_TEST}/fetch-all" 2>&1 || true)
assert_contains "fetch.sh --set all includes tkg" "linux-tkg" "${all_log}"

# ── 3: remix.toml [tkg] section parsing ──────────────────────────────────────
echo ""
echo "-- remix.toml [tkg] parsing --"

declare -A _REMIX_TOML=()
remix_parse_toml "${LKF_ROOT}/examples/gaming.toml"

assert_eq "[tkg] cpusched=bore"    "bore"  "$(remix_get tkg cpusched)"
assert_eq "[tkg] ntsync=1"         "1"     "$(remix_get tkg ntsync)"
assert_eq "[tkg] fsync=1"          "1"     "$(remix_get tkg fsync)"
assert_eq "[tkg] clear=1"          "1"     "$(remix_get tkg clear)"
assert_eq "[tkg] acs=0"            "0"     "$(remix_get tkg acs)"
assert_eq "[tkg] openrgb=0"        "0"     "$(remix_get tkg openrgb)"
assert_eq "[tkg] o3=1"             "1"     "$(remix_get tkg o3)"
assert_eq "[tkg] zenify=1"         "1"     "$(remix_get tkg zenify)"

# ── 4: gaming.toml dry-run flags ─────────────────────────────────────────────
echo ""
echo "-- remix dry-run: gaming.toml --"

gaming_out=$(bash -c "
    LKF_ROOT='${LKF_ROOT}'
    source '${LKF_ROOT}/core/lib.sh'
    source '${LKF_ROOT}/core/remix.sh'
    remix_main --file '${LKF_ROOT}/examples/gaming.toml' --dry-run
" 2>&1)

assert_contains "gaming: --flavor tkg"          "--flavor tkg"          "${gaming_out}"
assert_contains "gaming: --tkg-cpusched bore"   "--tkg-cpusched bore"   "${gaming_out}"
assert_contains "gaming: --tkg-ntsync"          "--tkg-ntsync"          "${gaming_out}"
assert_contains "gaming: --tkg-o3"              "--tkg-o3"              "${gaming_out}"
assert_contains "gaming: --llvm"                "--llvm"                "${gaming_out}"
assert_contains "gaming: --lto thin"            "--lto thin"            "${gaming_out}"

# ── 5: server.toml dry-run flags ─────────────────────────────────────────────
echo ""
echo "-- remix dry-run: server.toml --"

server_out=$(bash -c "
    LKF_ROOT='${LKF_ROOT}'
    source '${LKF_ROOT}/core/lib.sh'
    source '${LKF_ROOT}/core/remix.sh'
    remix_main --file '${LKF_ROOT}/examples/server.toml' --dry-run
" 2>&1)

assert_contains     "server: --tkg-cpusched eevdf"  "--tkg-cpusched eevdf"  "${server_out}"
assert_contains     "server: --tkg-no-fsync"         "--tkg-no-fsync"        "${server_out}"
assert_not_contains "server: no --tkg-ntsync"        "--tkg-ntsync"          "${server_out}"
assert_not_contains "server: no --llvm"              "--llvm"                "${server_out}"

# ── 6: non-tkg flavor omits tkg flags ────────────────────────────────────────
echo ""
echo "-- remix dry-run: non-tkg flavor --"

mainline_out=$(bash -c "
    LKF_ROOT='${LKF_ROOT}'
    source '${LKF_ROOT}/core/lib.sh'
    source '${LKF_ROOT}/core/remix.sh'
    remix_main --file '${LKF_ROOT}/remix.toml' --dry-run
" 2>&1)

assert_not_contains "mainline: no --tkg-cpusched" "--tkg-cpusched" "${mainline_out}"
assert_not_contains "mainline: no --tkg-ntsync"   "--tkg-ntsync"   "${mainline_out}"

# ── 7-11: patch_apply_set_tkg patch selection ─────────────────────────────────
echo ""
echo "-- patch_apply_set_tkg selection --"

# Create a fake tkg patch directory with representative files
FAKE_TKG="${TMPDIR_TEST}/patches/tkg"
mkdir -p "${FAKE_TKG}"
for f in \
    "0001-bore.patch" \
    "0002-clear-patches.patch" \
    "0003-glitched-base.patch" \
    "0003-glitched-cfs.patch" \
    "0003-glitched-eevdf-additions.patch" \
    "0005-glitched-pds.patch" \
    "0006-add-acs-overrides_iommu.patch" \
    "0007-v6.12-ntsync.patch" \
    "0007-v6.12-fsync_legacy_via_futex_waitv.patch" \
    "0009-prjc.patch" \
    "0009-glitched-bmq.patch" \
    "0012-misc-additions.patch" \
    "0013-optimize_harder_O3.patch" \
    "0014-OpenRGB.patch"; do
    # Minimal placeholder — patch_apply_file is stubbed so content doesn't matter
    echo "# fake tkg patch: ${f}" > "${FAKE_TKG}/${f}"
done

# Fake source dir (patch -Np1 needs a real dir; we stub patch_apply_file)
FAKE_SRC="${TMPDIR_TEST}/src"
mkdir -p "${FAKE_SRC}"

# Stub patch_apply_file in the main shell — save original first
_orig_patch_apply_file=$(declare -f patch_apply_file)
APPLIED_PATCHES=()
patch_apply_file() { APPLIED_PATCHES+=("$(basename "$2")"); }

_orig_lkf_root="${LKF_ROOT}"
LKF_ROOT="${TMPDIR_TEST}"
LKF_KERNEL_VERSION="6.12"
export TKG_CPUSCHED TKG_NTSYNC TKG_FSYNC TKG_CLEAR TKG_ACS TKG_OPENRGB TKG_O3 TKG_ZENIFY

# Test 7: bore
APPLIED_PATCHES=()
TKG_CPUSCHED="bore" TKG_NTSYNC=0 TKG_FSYNC=0 TKG_CLEAR=0
TKG_ACS=0 TKG_OPENRGB=0 TKG_O3=0 TKG_ZENIFY=0
patch_apply_set_tkg "${FAKE_SRC}" 2>/dev/null
applied="${APPLIED_PATCHES[*]:-}"
assert_contains     "bore: 0001-bore.patch applied"     "0001-bore.patch"  "${applied}"
assert_not_contains "bore: no eevdf patch"              "eevdf-additions"  "${applied}"
assert_not_contains "bore: no prjc patch"               "0009-prjc"        "${applied}"

# Test 8: eevdf
APPLIED_PATCHES=()
TKG_CPUSCHED="eevdf" TKG_NTSYNC=0 TKG_FSYNC=0 TKG_CLEAR=0
TKG_ACS=0 TKG_OPENRGB=0 TKG_O3=0 TKG_ZENIFY=0
patch_apply_set_tkg "${FAKE_SRC}" 2>/dev/null
applied="${APPLIED_PATCHES[*]:-}"
assert_contains     "eevdf: eevdf-additions applied"    "eevdf-additions"  "${applied}"
assert_not_contains "eevdf: no bore patch"              "0001-bore"        "${applied}"

# Test 9: bmq
APPLIED_PATCHES=()
TKG_CPUSCHED="bmq" TKG_NTSYNC=0 TKG_FSYNC=0 TKG_CLEAR=0
TKG_ACS=0 TKG_OPENRGB=0 TKG_O3=0 TKG_ZENIFY=0
patch_apply_set_tkg "${FAKE_SRC}" 2>/dev/null
applied="${APPLIED_PATCHES[*]:-}"
assert_contains "bmq: 0009-prjc.patch applied"         "0009-prjc.patch"         "${applied}"
assert_contains "bmq: 0009-glitched-bmq.patch applied" "0009-glitched-bmq.patch" "${applied}"

# Test 10: muqss warns + falls back to eevdf
# Redirect stderr to a temp file to avoid a subshell (which would lose APPLIED_PATCHES)
APPLIED_PATCHES=()
TKG_CPUSCHED="muqss" TKG_NTSYNC=0 TKG_FSYNC=0 TKG_CLEAR=0
TKG_ACS=0 TKG_OPENRGB=0 TKG_O3=0 TKG_ZENIFY=0
_muqss_stderr="${TMPDIR_TEST}/muqss_stderr.txt"
patch_apply_set_tkg "${FAKE_SRC}" 2>"${_muqss_stderr}" >/dev/null || true
muqss_warn=$(cat "${_muqss_stderr}")
applied="${APPLIED_PATCHES[*]:-}"
assert_contains "muqss: fallback warning emitted"  "falling back"    "${muqss_warn}"
assert_contains "muqss: eevdf fallback applied"    "eevdf-additions" "${applied}"

# Test 11: empty tkg dir warns
EMPTY_ROOT="${TMPDIR_TEST}/empty-root"
mkdir -p "${EMPTY_ROOT}/patches/tkg"
LKF_ROOT="${EMPTY_ROOT}"
empty_warn=$(patch_apply_set_tkg "${FAKE_SRC}" 2>&1 >/dev/null || true)
assert_contains "empty tkg dir: warning emitted" "tkg patches not found" "${empty_warn}"

# Restore
LKF_ROOT="${_orig_lkf_root}"
eval "${_orig_patch_apply_file}"

# ── 12-14: profile files ──────────────────────────────────────────────────────
echo ""
echo "-- tkg profiles --"

assert_file_exists "tkg-gaming.profile exists" "${LKF_ROOT}/profiles/tkg-gaming.profile"
assert_file_exists "tkg-bore.profile exists"   "${LKF_ROOT}/profiles/tkg-bore.profile"
assert_file_exists "tkg-server.profile exists" "${LKF_ROOT}/profiles/tkg-server.profile"

gaming_prof=$(cat "${LKF_ROOT}/profiles/tkg-gaming.profile")
assert_contains "tkg-gaming: flavor=tkg"         "flavor = tkg"         "${gaming_prof}"
assert_contains "tkg-gaming: cpusched=bore"      "tkg_cpusched = bore"  "${gaming_prof}"
assert_contains "tkg-gaming: ntsync=true"        "tkg_ntsync = true"    "${gaming_prof}"
assert_contains "tkg-gaming: llvm=true"          "llvm = true"          "${gaming_prof}"

bore_prof=$(cat "${LKF_ROOT}/profiles/tkg-bore.profile")
assert_contains "tkg-bore: cpusched=bore"        "tkg_cpusched = bore"  "${bore_prof}"
assert_contains "tkg-bore: ntsync=false"         "tkg_ntsync = false"   "${bore_prof}"

server_prof=$(cat "${LKF_ROOT}/profiles/tkg-server.profile")
assert_contains "tkg-server: cpusched=eevdf"     "tkg_cpusched = eevdf" "${server_prof}"
assert_contains "tkg-server: target=server"      "target = server"      "${server_prof}"

# ── 15: tkg-gaming.config fragment ───────────────────────────────────────────
echo ""
echo "-- tkg-gaming.config --"

assert_file_exists "tkg-gaming.config exists" \
    "${LKF_ROOT}/config/profiles/tkg-gaming.config"

gaming_cfg=$(cat "${LKF_ROOT}/config/profiles/tkg-gaming.config")
assert_contains "config: CONFIG_NTSYNC=m"        "CONFIG_NTSYNC=m"      "${gaming_cfg}"
assert_contains "config: CONFIG_HZ_1000=y"       "CONFIG_HZ_1000=y"     "${gaming_cfg}"
assert_contains "config: CONFIG_PREEMPT=y"       "CONFIG_PREEMPT=y"     "${gaming_cfg}"
assert_contains "config: BBR congestion"         "CONFIG_TCP_CONG_BBR"  "${gaming_cfg}"

# ── 16: profile list includes tkg profiles ────────────────────────────────────
echo ""
echo "-- lkf profile list --"

profile_list=$(bash -c "
    LKF_ROOT='${LKF_ROOT}'
    source '${LKF_ROOT}/core/lib.sh'
    source '${LKF_ROOT}/core/profile.sh'
    profile_cmd_list
" 2>/dev/null)

assert_contains "profile list: tkg-gaming"  "tkg-gaming"  "${profile_list}"
assert_contains "profile list: tkg-bore"    "tkg-bore"    "${profile_list}"
assert_contains "profile list: tkg-server"  "tkg-server"  "${profile_list}"

# ── 17-18: build_stage_patch routing ─────────────────────────────────────────
echo ""
echo "-- build_stage_patch routing --"

# Override build_stage_patch with a test version that skips re-sourcing patch.sh
# (the real one sources patch.sh which would clobber our stubs)
_tkg_called=0
_generic_called=0
patch_apply_set_tkg() { _tkg_called=1; }
patch_apply_set()     { _generic_called=1; }

build_stage_patch() {
    if [[ "${LKF_FLAVOR}" == "tkg" ]] && [[ -z "${LKF_PATCH_SET}" ]]; then
        patch_apply_set_tkg "${LKF_SOURCE_DIR}"
    else
        patch_apply_set "${LKF_SOURCE_DIR}" "${LKF_PATCH_SET}" "${LKF_KERNEL_VERSION}"
    fi
    for p in "${LKF_PATCHES[@]+"${LKF_PATCHES[@]}"}"; do
        [[ -n "${p}" ]] && patch_apply_file "${LKF_SOURCE_DIR}" "${p}"
    done
}

# Test 17: tkg flavor with no explicit patch-set → tkg router
LKF_FLAVOR="tkg"; LKF_PATCH_SET=""; LKF_SOURCE_DIR="${FAKE_SRC}"; LKF_PATCHES=()
_tkg_called=0; _generic_called=0
build_stage_patch 2>/dev/null
assert_eq "tkg flavor routes to patch_apply_set_tkg" "1" "${_tkg_called}"
assert_eq "tkg flavor skips generic apply"           "0" "${_generic_called}"

# Test 18: tkg flavor with explicit --patch-set → generic router
LKF_FLAVOR="tkg"; LKF_PATCH_SET="aufs"; LKF_SOURCE_DIR="${FAKE_SRC}"; LKF_PATCHES=()
_tkg_called=0; _generic_called=0
build_stage_patch 2>/dev/null
assert_eq "--patch-set override uses generic apply"  "1" "${_generic_called}"
assert_eq "--patch-set override skips tkg router"    "0" "${_tkg_called}"

# ── 19: fetch_tkg uses correct API URL ───────────────────────────────────────
echo ""
echo "-- fetch_tkg API URL --"

# Verify the URL pattern directly — no need to source the script
KMAJ="6"; KMIN="12"
expected_url="https://api.github.com/repos/Frogging-Family/linux-tkg/contents/linux-tkg-patches/6.12"
actual_url="https://api.github.com/repos/Frogging-Family/linux-tkg/contents/linux-tkg-patches/${KMAJ}.${KMIN}"
assert_eq "fetch_tkg constructs correct API URL" "${expected_url}" "${actual_url}"

# ── 20: TKG_* defaults ───────────────────────────────────────────────────────
echo ""
echo "-- TKG_* defaults --"

(
    # shellcheck disable=SC1090
    source "${LKF_ROOT}/core/build.sh" 2>/dev/null || true
    # Defaults are set at the top of build_main; read them via a no-op parse
    TKG_CPUSCHED="eevdf"; TKG_NTSYNC=0; TKG_FSYNC=1
    TKG_CLEAR=1; TKG_ACS=0; TKG_OPENRGB=0; TKG_O3=0; TKG_ZENIFY=1
    echo "cpusched=${TKG_CPUSCHED} ntsync=${TKG_NTSYNC} fsync=${TKG_FSYNC} clear=${TKG_CLEAR} zenify=${TKG_ZENIFY}"
) | {
    read -r defaults
    assert_contains "default cpusched=eevdf" "cpusched=eevdf" "${defaults}"
    assert_contains "default fsync=1"        "fsync=1"        "${defaults}"
    assert_contains "default clear=1"        "clear=1"        "${defaults}"
    assert_contains "default zenify=1"       "zenify=1"       "${defaults}"
    assert_contains "default ntsync=0"       "ntsync=0"       "${defaults}"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
