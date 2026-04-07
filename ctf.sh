#!/usr/bin/env bash
###############################################################################
# Script:  ctf.sh  (Collect To File)
# Author:  Mikhail Deynekin <mid1977@gmail.com> | https://deynekin.com
# Version: 1.0.0
# Description:
#   Recursively collects source files by extension into a single
#   well-structured Markdown document, preserving relative paths
#   from the root search directory.
# Usage:
#   ctf.sh [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
# Compatibility:
#   Bash 4.2+  ·  Debian 10-13  ·  Ubuntu 20-24  ·  CentOS 7
###############################################################################

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_VERSION="1.0.0"

# ─── Terminal colours (disabled when stderr is not a TTY) ─────────────────────
if [[ -t 2 ]]; then
    _R='\033[0;31m' _Y='\033[0;33m' _G='\033[0;32m' _N='\033[0m'
else
    _R='' _Y='' _G='' _N=''
fi

die()      { printf "${_R}[ERROR]${_N} %s\n" "$*" >&2; exit 1; }
log_info() { printf "${_G}[INFO] ${_N} %s\n" "$*" >&2; }
log_warn() { printf "${_Y}[WARN] ${_N} %s\n" "$*" >&2; }

# ─── Help / version ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Collect source files into a Markdown aggregate

USAGE
    ${SCRIPT_NAME} [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

ARGUMENTS
    EXTENSION    Extension to collect (e.g. php  .js  sh).
                 Pass "" or omit to collect ALL non-binary files.
    SOURCE_DIR   Root search directory.  Default: current directory.
    OUTPUT_FILE  Destination Markdown file.
                 Default: all-<EXTENSION>-files.md  or  All-Project-Files.md

OPTIONS
    -h, --help      Show this help and exit.
    -V, --version   Show version and exit.

EXAMPLES
    ${SCRIPT_NAME} php ./src result.md   # PHP files in ./src → result.md
    ${SCRIPT_NAME} js                    # .js files in CWD  → all-js-files.md
    ${SCRIPT_NAME} "" /var/www proj.md   # all files in /var/www → proj.md
    ${SCRIPT_NAME}                       # all files in CWD  → All-Project-Files.md
EOF
    exit 0
}

# ─── Extension → Markdown fenced-block language tag ──────────────────────────
map_lang() {
    case "${1,,}" in
        sh|bash|zsh|ksh|fish)   echo bash        ;;
        py|pyw)                 echo python      ;;
        rb)                     echo ruby        ;;
        pl|pm)                  echo perl        ;;
        php|php5|php7|php8)     echo php         ;;
        js|mjs|cjs)             echo javascript  ;;
        ts)                     echo typescript  ;;
        tsx)                    echo tsx         ;;
        jsx)                    echo jsx         ;;
        html|htm|xhtml)         echo html        ;;
        xml|xsl|xsd|rss|atom)   echo xml         ;;
        svg)                    echo xml         ;;
        css)                    echo css         ;;
        scss)                   echo scss        ;;
        sass)                   echo sass        ;;
        less)                   echo less        ;;
        json|jsonc|json5)       echo json        ;;
        yaml|yml)               echo yaml        ;;
        toml)                   echo toml        ;;
        sql)                    echo sql         ;;
        go)                     echo go          ;;
        rs)                     echo rust        ;;
        c)                      echo c           ;;
        cpp|cc|cxx|"c++")       echo cpp         ;;
        h|hh)                   echo c           ;;
        hpp|hxx)                echo cpp         ;;
        java)                   echo java        ;;
        kt|kts)                 echo kotlin      ;;
        swift)                  echo swift       ;;
        cs)                     echo csharp      ;;
        lua)                    echo lua         ;;
        r)                      echo r           ;;
        ps1|psm1|psd1)          echo powershell  ;;
        md|markdown)            echo markdown    ;;
        dockerfile)             echo dockerfile  ;;
        makefile|mk)            echo makefile    ;;
        conf|cfg|ini)           echo ini         ;;
        env|envrc)              echo bash        ;;
        nginx)                  echo nginx       ;;
        tf|tfvars)              echo hcl         ;;
        *)                      echo "${1,,}"    ;;
    esac
}

# ─── Binary-file guard ────────────────────────────────────────────────────────
# Returns 0 (true) if the file looks binary; 1 if text.
is_binary() {
    local file="$1"
    if command -v file &>/dev/null; then
        file --brief --mime-encoding "${file}" 2>/dev/null | grep -q 'binary'
    else
        # Fallback: scan first 8 KiB for null bytes
        LC_ALL=C grep -qP '\x00' <(head -c 8192 "${file}" 2>/dev/null)
    fi
}

# ─── Portable absolute-path resolution (no coreutils realpath needed) ─────────
# Usage: abspath PATH [must_exist]
#   must_exist — pass "must_exist" to return 1 if the *directory part* is absent.
abspath() {
    local path="$1" flag="${2:-}"
    local dir file resolved_dir

    dir="$(dirname "${path}")"
    file="$(basename "${path}")"

    if [[ "${flag}" == "must_exist" ]]; then
        resolved_dir="$(cd "${dir}" 2>/dev/null && pwd)" \
            || return 1
    else
        resolved_dir="$(cd "${dir}" 2>/dev/null && pwd || true)"
        [[ -z "${resolved_dir}" ]] && resolved_dir="$(pwd)/${dir}"
    fi

    printf '%s/%s' "${resolved_dir}" "${file}"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help)    usage ;;
    -V|--version) printf '%s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
esac

EXT="${1:-}"
SRC_DIR="${2:-.}"
OUT_FILE="${3:-}"

# Normalise extension — strip leading dot, collapse to lowercase
[[ -n "${EXT}" ]] && EXT="${EXT#.}"

# Validate source directory and get its canonical path
[[ -d "${SRC_DIR}" ]] || die "Source directory '${SRC_DIR}' does not exist."
SRC_ABS="$(cd "${SRC_DIR}" && pwd)"

# Determine default output file name
if [[ -z "${OUT_FILE}" ]]; then
    [[ -n "${EXT}" ]] \
        && OUT_FILE="all-${EXT}-files.md" \
        || OUT_FILE="All-Project-Files.md"
fi

# Resolve absolute output path and validate its parent directory
OUT_ABS="$(abspath "${OUT_FILE}")"
OUT_DIR="$(dirname "${OUT_ABS}")"
[[ -d "${OUT_DIR}" ]] || die "Output directory '${OUT_DIR}' does not exist."
[[ -w "${OUT_DIR}" ]] || die "Output directory '${OUT_DIR}' is not writable."
[[ -f "${OUT_ABS}" ]] && log_warn "Output file '${OUT_FILE}' exists — overwriting."

# ─── Build find(1) argument list ──────────────────────────────────────────────
declare -a FIND_ARGS=(-type f ! -path "${OUT_ABS}")
[[ -n "${EXT}" ]] && FIND_ARGS+=(-name "*.${EXT}")

# ─── Collect file list into an array (main-shell loop — no variable loss) ─────
log_info "Scanning '${SRC_ABS}' for '${EXT:-*}' files…"

declare -a FILES=()
while IFS= read -r -d '' entry; do
    FILES+=("${entry}")
done < <(find "${SRC_ABS}" "${FIND_ARGS[@]}" -print0 2>/dev/null | sort -z)

TOTAL="${#FILES[@]}"
log_info "Found ${TOTAL} candidate file(s)."

# ─── Write Markdown header ────────────────────────────────────────────────────
{
    printf '# Project Source Code Aggregate\n\n'
    printf '| Field      | Value |\n'
    printf '|:-----------|:------|\n'
    printf '| Generated  | `%s` |\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '| Script     | `%s v%s` |\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
    printf '| Source     | `%s` |\n' "${SRC_ABS}"
    printf '| Extension  | `%s` |\n' "${EXT:-*}"
    printf '| Candidates | %d |\n'   "${TOTAL}"
    printf '\n---\n\n'
} > "${OUT_ABS}"

# ─── Process each file ────────────────────────────────────────────────────────
FILE_COUNT=0
SKIP_COUNT=0

for file in "${FILES[@]+"${FILES[@]}"}"; do

    rel="${file#"${SRC_ABS}/"}"   # path relative to search root

    # Guard: unreadable
    if [[ ! -r "${file}" ]]; then
        log_warn "Skip (unreadable): ${rel}"
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
        continue
    fi

    # Guard: binary
    if is_binary "${file}"; then
        log_warn "Skip (binary):     ${rel}"
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
        continue
    fi

    lang="$(map_lang "${file##*.}")"
    FILE_COUNT=$(( FILE_COUNT + 1 ))

    {
        printf '### `%s`\n\n' "${rel}"
        printf '```%s\n' "${lang}"
        cat "${file}"
        # Ensure the closing fence always starts on its own line
        [[ -n "$(tail -c1 "${file}")" ]] && printf '\n'
        printf '```\n\n---\n\n'
    } >> "${OUT_ABS}"

done

# ─── Footer / summary table ───────────────────────────────────────────────────
{
    printf '## Summary\n\n'
    printf '| Metric    | Count |\n'
    printf '|:----------|------:|\n'
    printf '| Processed | %d |\n' "${FILE_COUNT}"
    printf '| Skipped   | %d |\n' "${SKIP_COUNT}"
    printf '| Total     | %d |\n' "$(( FILE_COUNT + SKIP_COUNT ))"
} >> "${OUT_ABS}"

OUT_SIZE="$(du -sh "${OUT_ABS}" 2>/dev/null | cut -f1)"

log_info "Done: ${FILE_COUNT} file(s) written, ${SKIP_COUNT} skipped."
log_info "Output → ${OUT_ABS} (${OUT_SIZE})"
