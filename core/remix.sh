#!/usr/bin/env bash
# core/remix.sh - Declarative kernel remix builder
#
# A "remix" is a reproducible, named kernel configuration described in a
# remix.toml file.  lkf remix reads the TOML, translates it into lkf build
# flags, and drives the full build pipeline.
#
# remix.toml format (TOML subset — no arrays of tables, no inline tables):
#
#   [remix]
#   name    = "my-desktop"
#   version = "6.12"
#   flavor  = "xanmod"          # mainline | xanmod | cachyos | rt | android | custom
#   arch    = "x86_64"
#   description = "Gaming desktop kernel with LLVM LTO"
#
#   [build]
#   llvm    = true
#   lto     = "thin"            # none | thin | full
#   threads = 0                 # 0 = nproc
#   config  = "defconfig"       # defconfig | localyesconfig | path/to/.config
#   target  = "desktop"         # desktop | server | android | embedded | debug
#   output  = "deb"             # deb | rpm | tar.gz | efi-unified | android-boot
#   localversion = "-my-remix"
#   kcflags = "-O3 -march=native"
#
#   [patches]
#   sets   = ["rt", "cachyos"]  # named patch sets
#   files  = ["patches/custom/my.patch"]
#
#   [cross]
#   prefix = ""                 # e.g. aarch64-linux-gnu-
#
#   [output]
#   build_dir    = "build"
#   download_dir = "downloads"
#   clean_after  = false
#   remove_after = false

remix_usage() {
    cat <<EOF
lkf remix - Build a kernel from a remix.toml descriptor

USAGE: lkf remix [options] [remix.toml]

OPTIONS:
  --file, -f <path>   Path to remix.toml [default: remix.toml in current dir]
  --dry-run           Print the resolved lkf build command without running it
  --stop-after <stage> Override stop-after stage (download|extract|patch|config|build)
  --build-dir <path>  Override build directory from remix.toml
  --help              Show this help

EXAMPLES:
  lkf remix                          # use ./remix.toml
  lkf remix --file kernels/gaming.toml
  lkf remix --dry-run                # show what would be built
  lkf remix --stop-after config      # configure only

REMIX.TOML EXAMPLE:
  [remix]
  name    = "gaming"
  version = "6.12"
  flavor  = "xanmod"
  arch    = "x86_64"

  [build]
  llvm   = true
  lto    = "thin"
  config = "defconfig"
  target = "desktop"
  output = "deb"

  [patches]
  sets = ["cachyos"]
EOF
}

# ── Minimal TOML parser ───────────────────────────────────────────────────────
# Handles the subset used by remix.toml:
#   [section]
#   key = "string"
#   key = true | false
#   key = 123
#   key = ["a", "b", "c"]   (simple string arrays only)
# Returns values via remix_get <section> <key>

declare -A _REMIX_TOML=()

remix_parse_toml() {
    local file="$1"
    local section=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments and leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        # Section header
        if [[ "${line}" =~ ^\[([a-zA-Z_][a-zA-Z0-9_]*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # key = value
        if [[ "${line}" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\ *=\ *(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val="${val%"${val##*[![:space:]]}"}"  # rtrim

            # String: "value"
            if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            # Boolean
            elif [[ "${val}" == "true" ]]; then
                val="1"
            elif [[ "${val}" == "false" ]]; then
                val="0"
            # Array: [] or ["a", "b"]  → space-separated (empty → "")
            elif [[ "${val}" == "[]" ]]; then
                val=""
            elif [[ "${val}" =~ ^\[(.+)\]$ ]]; then
                local arr_raw="${BASH_REMATCH[1]}"
                val=""
                # Extract quoted strings from the array
                while [[ "${arr_raw}" =~ \"([^\"]+)\" ]]; do
                    val+="${BASH_REMATCH[1]} "
                    arr_raw="${arr_raw#*\"${BASH_REMATCH[1]}\"}"
                done
                val="${val% }"  # rtrim trailing space
            fi

            _REMIX_TOML["${section}.${key}"]="${val}"
        fi
    done < "${file}"
}

remix_get() {
    local section="$1" key="$2" default="${3:-}"
    echo "${_REMIX_TOML["${section}.${key}"]:-${default}}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

remix_main() {
    local toml_file="" dry_run=0 stop_after="" override_build_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|-f)      toml_file="$2"; shift 2 ;;
            --dry-run)      dry_run=1; shift ;;
            --stop-after)   stop_after="$2"; shift 2 ;;
            --build-dir)    override_build_dir="$2"; shift 2 ;;
            --help|-h)      remix_usage; return 0 ;;
            *.toml)         toml_file="$1"; shift ;;
            *) lkf_die "Unknown option: $1" ;;
        esac
    done

    # Locate remix.toml
    if [[ -z "${toml_file}" ]]; then
        if [[ -f "remix.toml" ]]; then
            toml_file="remix.toml"
        else
            lkf_die "No remix.toml found in current directory. Use --file <path>."
        fi
    fi
    [[ -f "${toml_file}" ]] || lkf_die "remix.toml not found: ${toml_file}"

    lkf_step "Parsing ${toml_file}"
    remix_parse_toml "${toml_file}"

    # ── Read remix fields ─────────────────────────────────────────────────────
    local name version flavor arch description
    name="$(remix_get remix name "unnamed")"
    version="$(remix_get remix version "")"
    flavor="$(remix_get remix flavor "mainline")"
    arch="$(remix_get remix arch "")"
    description="$(remix_get remix description "")"

    [[ -z "${version}" ]] && lkf_die "[remix] version is required in ${toml_file}"

    # ── Read build fields ─────────────────────────────────────────────────────
    local llvm lto threads config_src target output_fmt localversion kcflags
    llvm="$(remix_get build llvm "0")"
    lto="$(remix_get build lto "none")"
    threads="$(remix_get build threads "0")"
    config_src="$(remix_get build config "defconfig")"
    target="$(remix_get build target "desktop")"
    output_fmt="$(remix_get build output "")"
    localversion="$(remix_get build localversion "")"
    kcflags="$(remix_get build kcflags "")"

    [[ "${threads}" == "0" ]] && threads="$(nproc)"

    # ── Read patches fields ───────────────────────────────────────────────────
    local patch_sets patch_files
    patch_sets="$(remix_get patches sets "")"
    patch_files="$(remix_get patches files "")"

    # ── Read cross fields ─────────────────────────────────────────────────────
    local cross_prefix
    cross_prefix="$(remix_get cross prefix "")"

    # ── Read output fields ────────────────────────────────────────────────────
    local build_dir download_dir clean_after remove_after
    build_dir="${override_build_dir:-$(remix_get output build_dir "build")}"
    download_dir="$(remix_get output download_dir "downloads")"
    clean_after="$(remix_get output clean_after "0")"
    remove_after="$(remix_get output remove_after "0")"

    # ── Assemble lkf build command ────────────────────────────────────────────
    local cmd=("${LKF_ROOT}/lkf.sh" build)
    cmd+=(--version "${version}")
    cmd+=(--flavor  "${flavor}")
    cmd+=(--config  "${config_src}")
    cmd+=(--target  "${target}")
    cmd+=(--threads "${threads}")
    cmd+=(--build-dir "${build_dir}")
    cmd+=(--download-dir "${download_dir}")

    [[ -n "${arch}" ]]         && cmd+=(--arch "${arch}")
    [[ "${llvm}" == "1" ]]     && cmd+=(--llvm)
    [[ "${lto}" != "none" ]]   && cmd+=(--lto "${lto}")
    [[ -n "${localversion}" ]] && cmd+=(--localversion "${localversion}")
    [[ -n "${kcflags}" ]]      && cmd+=(--kcflags "${kcflags}")
    [[ -n "${cross_prefix}" ]] && cmd+=(--cross "${cross_prefix}")
    [[ -n "${output_fmt}" ]]   && cmd+=(--output "${output_fmt}")
    [[ "${clean_after}" == "1" ]]  && cmd+=(--clean-after)
    [[ "${remove_after}" == "1" ]] && cmd+=(--remove-after)
    [[ -n "${stop_after}" ]]   && cmd+=(--stop-after "${stop_after}")

    # Patch sets (space-separated from TOML array; skip empty/bracket-only values)
    for ps in ${patch_sets}; do
        [[ "${ps}" == "[]" || -z "${ps}" ]] && continue
        cmd+=(--patch-set "${ps}")
    done

    # Extra patch files
    for pf in ${patch_files}; do
        [[ "${pf}" == "[]" || -z "${pf}" ]] && continue
        cmd+=(--patch "${pf}")
    done

    # ── Print summary ─────────────────────────────────────────────────────────
    lkf_info "Remix: ${name}${description:+ — ${description}}"
    lkf_info "  kernel  : ${version} (${flavor})"
    lkf_info "  arch    : ${arch:-host}"
    lkf_info "  compiler: $([ "${llvm}" = "1" ] && echo "clang (LLVM)" || echo "gcc") | lto=${lto}"
    lkf_info "  config  : ${config_src} | target=${target}"
    [[ -n "${patch_sets}" ]] && lkf_info "  patches : ${patch_sets}"
    lkf_info "  output  : ${build_dir}/ (format=${output_fmt:-auto})"

    if [[ "${dry_run}" -eq 1 ]]; then
        lkf_info "Dry run — would execute:"
        echo "  ${cmd[*]}"
        return 0
    fi

    lkf_step "Starting remix build: ${name}"
    "${cmd[@]}"
}
