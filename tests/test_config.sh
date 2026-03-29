#!/usr/bin/env bash
# tests/test_config.sh - Unit tests for core/config.sh

set -euo pipefail
LKF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LKF_ROOT}/core/lib.sh"
source "${LKF_ROOT}/core/detect.sh"
source "${LKF_ROOT}/core/config.sh"

pass=0; fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"
        pass=$((pass + 1))
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "${haystack}" | grep -q "${needle}"; then
        echo "  PASS: ${desc}"
        pass=$((pass + 1))
    else
        echo "  FAIL: ${desc} — '${needle}' not found in output"
        fail=$((fail + 1))
    fi
}

echo "=== test_config.sh ==="

# Create a temp config file
tmp_config=$(mktemp /tmp/lkf-test-config.XXXXXX)
# shellcheck disable=SC2064  # intentional: expand $tmp_config now, not at EXIT time
trap "rm -f ${tmp_config}" EXIT

cat > "${tmp_config}" <<'EOF'
CONFIG_HZ_1000=y
CONFIG_PREEMPT=y
CONFIG_KVM=m
# CONFIG_SOUND is not set
CONFIG_BTRFS_FS=m
CONFIG_SECURITY=y
CONFIG_RANDOMIZE_BASE=y
EOF

# Test config_set_option: update existing
config_set_option "${tmp_config}" "CONFIG_HZ_1000" "n"
val=$(grep "^CONFIG_HZ_1000=" "${tmp_config}" | cut -d= -f2)
assert_eq "config_set_option update existing" "n" "${val}"

# Test config_set_option: add new
config_set_option "${tmp_config}" "CONFIG_NEW_OPTION" "y"
val=$(grep "^CONFIG_NEW_OPTION=" "${tmp_config}" | cut -d= -f2)
assert_eq "config_set_option add new" "y" "${val}"

# Test config_set_option: enable commented-out option
config_set_option "${tmp_config}" "CONFIG_SOUND" "m"
val=$(grep "^CONFIG_SOUND=" "${tmp_config}" | cut -d= -f2)
assert_eq "config_set_option enable commented" "m" "${val}"

# Test config_cmd_show: security category
output=$(config_cmd_show --file "${tmp_config}" --category security)
assert_contains "show security category" "CONFIG_SECURITY" "${output}"
assert_contains "show security RANDOMIZE_BASE" "CONFIG_RANDOMIZE_BASE" "${output}"

# Test config_cmd_convert: json
json_output=$(config_cmd_convert --file "${tmp_config}" --format json)
assert_contains "convert to json" '"CONFIG_PREEMPT"' "${json_output}"

# Test config_cmd_convert: toml
toml_output=$(config_cmd_convert --file "${tmp_config}" --format toml)
assert_contains "convert to toml" 'CONFIG_PREEMPT' "${toml_output}"

# Test config_cmd_convert: yaml
yaml_output=$(config_cmd_convert --file "${tmp_config}" --format yaml)
assert_contains "convert to yaml" 'CONFIG_PREEMPT' "${yaml_output}"

# Test config_cmd_validate: pass
if ( config_cmd_validate --file "${tmp_config}" --require "CONFIG_PREEMPT,CONFIG_KVM" 2>/dev/null ); then
    echo "  PASS: config_cmd_validate pass"
    pass=$((pass + 1))
else
    echo "  FAIL: config_cmd_validate should have passed"
    fail=$((fail + 1))
fi

# Test config_cmd_validate: fail
if ! ( config_cmd_validate --file "${tmp_config}" --require "CONFIG_MISSING_OPTION" 2>/dev/null ); then
    echo "  PASS: config_cmd_validate correctly fails for missing option"
    pass=$((pass + 1))
else
    echo "  FAIL: config_cmd_validate should have failed"
    fail=$((fail + 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
