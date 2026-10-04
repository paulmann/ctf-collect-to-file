#!/usr/bin/env bash
###############################################################################
# Script:  ctf.sh (Collect To File)
# Author:  Mikhail Deynekin <Mikhail@Deynekin.com> | https://deynekin.com
# Version: 3.0.0
#
# Description:
#   Recursively collects source files by extension into a single Markdown
#   aggregate, preserving paths relative to the source root.
#
# Usage:
#   ctf.sh [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
#
# Compatibility:
#   Bash 4.2+; intended for GNU/Linux userland (Debian/Ubuntu/CentOS).
#   The script also degrades gracefully when optional tools are missing.
#
# Changes in 3.0.0:
#   - Fixed file/directory confusion and unsafe set -e constructs.
#   - Added strict source/output validation and symlink-aware finalization.
#   - Added temporary-file based output writing.
#   - Added dynamic Markdown fences to avoid broken code blocks.
#   - Hardened binary detection, extension parsing, and portability.
###############################################################################

# Require Bash before using Bash-only syntax.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'This script requires Bash.' >&2
    exit 1
fi

# Require Bash 4.2 or newer.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    printf '%s\n' 'This script requires Bash 4.2 or newer.' >&2
    exit 1
fi

set -euo pipefail

# Predictable tool behaviour for sorting, character classes, and byte scans.
export LC_ALL=C

# Safe default field splitting.
IFS=$' \t\n'

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly SCRIPT_VERSION="3.0.0"

# Backtick character stored safely for reuse in strings and comparisons.
readonly BACKTICK="$(printf '\140')"

# Terminal colours are enabled only when stderr is attached to a TTY.
if [[ -t 2 ]]; then
    _R=$'\033[0;31m'
    _Y=$'\033[0;33m'
    _G=$'\033[0;32m'
    _N=$'\033[0m'
else
    _R=''
    _Y=''
    _G=''
    _N=''
fi

die() {
    printf '%s\n' "${_R}[ERROR]${_N} $*" >&2
    exit 1
}

log_info() {
    printf '%s\n' "${_G}[INFO]${_N} $*" >&2
}

log_warn() {
    printf '%s\n' "${_Y}[WARN]${_N} $*" >&2
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Collect source files into a Markdown aggregate

USAGE
  ${SCRIPT_NAME} [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

ARGUMENTS
  EXTENSION    Extension to collect (e.g. php, js, sh).
               Pass an empty string or omit to collect all non-binary files.
  SOURCE_DIR   Root search directory. Default: current directory.
  OUTPUT_FILE  Destination Markdown file.
               Default: all-<EXTENSION>-files.md or All-Project-Files.md

OPTIONS
  -h, --help      Show this help and exit.
  -V, --version   Show version and exit.
  --              End of options (useful for paths beginning with dash).

EXAMPLES
  ${SCRIPT_NAME} php ./src result.md
  ${SCRIPT_NAME} js
  ${SCRIPT_NAME} "" /var/www proj.md
  ${SCRIPT_NAME}
EOF
    exit 0
}

# Map a file path to a Markdown fenced-code language tag.
map_lang() {
    local base="${1##*/}"
    local lower="${base,,}"

    # Special file names first.
    case "$lower" in
        dockerfile*|containerfile*)
            printf 'dockerfile'
            return 0
            ;;
        makefile*|gnumakefile*)
            printf 'makefile'
            return 0
            ;;
        jenkinsfile)
            printf 'groovy'
            return 0
            ;;
        cmakelists.txt)
            printf 'cmake'
            return 0
            ;;
        readme)
            printf 'markdown'
            return 0
            ;;
    esac

    local ext="${lower##*.}"

    # If there was no dot, ext equals the whole file name.
    if [[ "$ext" == "$lower" ]]; then
        ext=""
    fi

    case "$ext" in
        sh|bash|zsh|ksh|fish)     printf 'bash' ;;
        py|pyw)                   printf 'python' ;;
        rb)                       printf 'ruby' ;;
        pl|pm)                    printf 'perl' ;;
        php|php5|php7|php8)       printf 'php' ;;
        js|mjs|cjs)               printf 'javascript' ;;
        ts)                       printf 'typescript' ;;
        tsx)                      printf 'tsx' ;;
        jsx)                      printf 'jsx' ;;
        html|htm|xhtml)           printf 'html' ;;
        xml|xsl|xsd|rss|atom|svg) printf 'xml' ;;
        css)                      printf 'css' ;;
        scss)                     printf 'scss' ;;
        sass)                     printf 'sass' ;;
        less)                     printf 'less' ;;
        json|jsonc|json5)         printf 'json' ;;
        yaml|yml)                 printf 'yaml' ;;
        toml)                     printf 'toml' ;;
        sql)                      printf 'sql' ;;
        go)                       printf 'go' ;;
        rs)                       printf 'rust' ;;
        c)                        printf 'c' ;;
        cpp|cc|cxx|"c++")         printf 'cpp' ;;
        h|hh)                     printf 'c' ;;
        hpp|hxx)                  printf 'cpp' ;;
        java)                     printf 'java' ;;
        kt|kts)                   printf 'kotlin' ;;
        swift)                    printf 'swift' ;;
        cs)                       printf 'csharp' ;;
        lua)                      printf 'lua' ;;
        r)                        printf 'r' ;;
        ps1|psm1|psd1)            printf 'powershell' ;;
        md|markdown)              printf 'markdown' ;;
        dockerfile)               printf 'dockerfile' ;;
        makefile|mk)              printf 'makefile' ;;
        conf|cfg|ini)             printf 'ini' ;;
        env|envrc)                printf 'bash' ;;
        nginx)                    printf 'nginx' ;;
        tf|tfvars)                printf 'hcl' ;;
        cmake)                    printf 'cmake' ;;
        rst)                      printf 'rst' ;;
        txt|text|log)             printf 'text' ;;
        *)
            # Emit unknown simple extensions as-is; otherwise emit nothing.
            if [[ "$ext" =~ ^[a-z0-9_+.-]+$ ]]; then
                printf '%s' "$ext"
            fi
            ;;
    esac

    return 0
}

# Return 0 when the file looks binary, 1 when it should be treated as text.
is_binary() {
    local file="$1"
    local enc=""

    # Empty files are safe and should not be marked binary.
    if [[ ! -s "$file" ]]; then
        return 1
    fi

    if (( HAVE_FILE )); then
        enc="$(file --brief --mime-encoding "$file" 2>/dev/null || true)"
        if [[ -n "$enc" ]]; then
            if [[ "$enc" == *binary* ]]; then
                return 0
            fi
            return 1
        fi
    fi

    # Fallback: look for NUL bytes in the first 8 KiB.
    if (( HAVE_OD )) && (( HAVE_HEAD )); then
        if head -c 8192 < "$file" 2>/dev/null \
            | od -A n -v -t x1 2>/dev/null \
            | tr -s '[:space:]' '\n' \
            | grep -qx '00'; then
            return 0
        fi
    fi

    return 1
}

# Choose a Markdown fence that cannot be closed accidentally by file content.
choose_fence() {
    local file="$1"
    local stats=""
    local max_b=0
    local max_t=0
    local len_b=3
    local len_t=3
    local len=0
    local char=""
    local fence=""
    local i=0

    if (( HAVE_AWK )); then
        stats="$(
            awk '
                BEGIN {
                    b = sprintf("%c", 96)
                    t = "~"
                    mb = 0
                    mt = 0
                }
                {
                    line = $0

                    # CommonMark closing fences may be indented by up to 3 spaces.
                    spaces = 0
                    while (spaces < 3 && substr(line, spaces + 1, 1) == " ") {
                        spaces++
                    }
                    line = substr(line, spaces + 1)

                    first = substr(line, 1, 1)

                    if (first == b) {
                        n = 0
                        while (substr(line, n + 1, 1) == b) {
                            n++
                        }
                        if (n > mb) {
                            mb = n
                        }
                    } else if (first == t) {
                        n = 0
                        while (substr(line, n + 1, 1) == t) {
                            n++
                        }
                        if (n > mt) {
                            mt = n
                        }
                    }
                }
                END {
                    printf "%d %d\n", mb, mt
                }
            ' < "$file" 2>/dev/null || printf '0 0\n'
        )"

        read -r max_b max_t <<< "$stats" || {
            max_b=0
            max_t=0
        }

        if [[ ! "$max_b" =~ ^[0-9]+$ ]]; then
            max_b=0
        fi

        if [[ ! "$max_t" =~ ^[0-9]+$ ]]; then
            max_t=0
        fi
    else
        # Without awk, use a slightly longer default fence.
        max_b=3
        max_t=3
    fi

    len_b=$(( max_b + 1 ))
    len_t=$(( max_t + 1 ))

    if (( len_b < 3 )); then
        len_b=3
    fi

    if (( len_t < 3 )); then
        len_t=3
    fi

    if (( len_b <= len_t )); then
        char="$BACKTICK"
        len=$len_b
    else
        char='~'
        len=$len_t
    fi

    fence=""
    for (( i = 0; i < len; i++ )); do
        fence+="$char"
    done

    printf '%s' "$fence"
}

# Produce a human-readable file size without depending on du.
file_size_human() {
    local file="$1"
    local bytes=""

    if command -v wc >/dev/null 2>&1; then
        bytes="$(wc -c < "$file" 2>/dev/null || true)"
    fi

    # Keep digits only.
    bytes="${bytes//[!0-9]/}"

    if [[ -z "$bytes" ]]; then
        bytes=0
    fi

    if (( bytes >= 1048576 )); then
        printf '%d MiB' $(( bytes / 1048576 ))
    elif (( bytes >= 1024 )); then
        printf '%d KiB' $(( bytes / 1024 ))
    else
        printf '%d B' "$bytes"
    fi
}

# Remove temporary output file if the script exits prematurely.
cleanup() {
    if [[ -n "${TMP_FILE:-}" && -f "${TMP_FILE:-}" ]]; then
        rm -f -- "$TMP_FILE" 2>/dev/null || true
    fi
}

# Optional capability detection.
HAVE_AWK=0
if command -v awk >/dev/null 2>&1; then
    HAVE_AWK=1
fi

HAVE_FILE=0
if command -v file >/dev/null 2>&1; then
    HAVE_FILE=1
fi

HAVE_OD=0
if command -v od >/dev/null 2>&1; then
    HAVE_OD=1
fi

HAVE_HEAD=0
if command -v head >/dev/null 2>&1; then
    HAVE_HEAD=1
fi

TMP_FILE=""
trap cleanup EXIT

main() {
    local EXT=""
    local SRC_DIR="."
    local OUT_FILE=""

    local SRC_ABS=""
    local OUT_DIR=""
    local OUT_BASE=""
    local OUT_DIR_ABS=""
    local OUT_ABS=""

    local FIND_NAME_OPT="-name"
    local SORT_Z=0
    local TOTAL=0
    local FILE_COUNT=0
    local SKIP_COUNT=0

    local entry=""
    local file=""
    local rel=""
    local rel_display=""
    local lang=""
    local fence=""
    local last_char=""
    local generated_at=""
    local OUT_SIZE=""
    local tmp_prefix=""

    # Parse options before positional arguments.
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                ;;
            -V|--version)
                printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -?*)
                die "Unknown option: $1 (use --help)"
                ;;
            *)
                break
                ;;
        esac
    done

    if (( $# > 0 )); then
        EXT="$1"
        shift
    fi

    if (( $# > 0 )); then
        SRC_DIR="$1"
        shift
    fi

    if (( $# > 0 )); then
        OUT_FILE="$1"
        shift
    fi

    if (( $# > 0 )); then
        die "Too many arguments. Use --help."
    fi

    # Empty source directory means current directory.
    if [[ -z "$SRC_DIR" ]]; then
        SRC_DIR="."
    fi

    # Normalize extension.
    if [[ "$EXT" == "*" || "$EXT" == ".*" ]]; then
        EXT=""
    fi

    # Strip all leading dots.
    while [[ "$EXT" == .* ]]; do
        EXT="${EXT#.}"
    done

    if [[ -n "$EXT" ]]; then
        EXT="${EXT,,}"

        if [[ "$EXT" == */* || "$EXT" == *[[:space:]]* || "$EXT" == *"*"* || "$EXT" == *"?"* || "$EXT" == *"["* || "$EXT" == *"]"* ]]; then
            die "Invalid extension '$EXT'. Use a simple extension without path or wildcard characters."
        fi
    fi

    # Validate source directory.
    if [[ ! -d "$SRC_DIR" ]]; then
        die "Source directory '$SRC_DIR' does not exist or is not a directory."
    fi

    if [[ ! -r "$SRC_DIR" || ! -x "$SRC_DIR" ]]; then
        die "Source directory '$SRC_DIR' is not readable/searchable."
    fi

    SRC_ABS="$(cd -- "$SRC_DIR" 2>/dev/null && pwd -P)" \
        || die "Cannot resolve source directory '$SRC_DIR'."

    # Default output file name.
    if [[ -z "$OUT_FILE" ]]; then
        if [[ -n "$EXT" ]]; then
            OUT_FILE="all-${EXT}-files.md"
        else
            OUT_FILE="All-Project-Files.md"
        fi
    fi

    # Validate output path and make sure it is not a directory.
    if [[ "$OUT_FILE" == */ ]]; then
        die "Output file '$OUT_FILE' must not end with '/'."
    fi

    if [[ -d "$OUT_FILE" ]]; then
        die "Output path '$OUT_FILE' is a directory."
    fi

    OUT_DIR="$(dirname -- "$OUT_FILE" 2>/dev/null)" \
        || die "Cannot determine parent directory for output file '$OUT_FILE'."

    OUT_BASE="$(basename -- "$OUT_FILE" 2>/dev/null)" \
        || die "Cannot determine base name for output file '$OUT_FILE'."

    if [[ -z "$OUT_BASE" || "$OUT_BASE" == "." || "$OUT_BASE" == ".." ]]; then
        die "Invalid output file name '$OUT_FILE'."
    fi

    if [[ ! -d "$OUT_DIR" ]]; then
        die "Output directory '$OUT_DIR' does not exist."
    fi

    if [[ ! -w "$OUT_DIR" ]]; then
        die "Output directory '$OUT_DIR' is not writable."
    fi

    OUT_DIR_ABS="$(cd -- "$OUT_DIR" 2>/dev/null && pwd -P)" \
        || die "Cannot resolve output directory '$OUT_DIR'."

    if [[ "$OUT_DIR_ABS" == "/" ]]; then
        OUT_ABS="/${OUT_BASE}"
    else
        OUT_ABS="${OUT_DIR_ABS}/${OUT_BASE}"
    fi

    if [[ -e "$OUT_ABS" || -L "$OUT_ABS" ]]; then
        if [[ ! -f "$OUT_ABS" && ! -L "$OUT_ABS" ]]; then
            die "Output path '$OUT_ABS' exists and is not a regular file or symlink."
        fi

        if [[ -f "$OUT_ABS" && ! -w "$OUT_ABS" ]]; then
            die "Output file '$OUT_ABS' exists but is not writable."
        fi

        log_warn "Output file '$OUT_FILE' exists - overwriting."
    fi

    if ! command -v find >/dev/null 2>&1; then
        die "Required command 'find' is not available."
    fi

    # Prefer case-insensitive matching when supported.
    if find /dev/null -iname x -print >/dev/null 2>&1; then
        FIND_NAME_OPT="-iname"
    fi

    # Prefer NUL-aware sorting when supported.
    if printf '' | sort -z >/dev/null 2>&1; then
        SORT_Z=1
    fi

    declare -a FIND_ARGS=(-type f)

    if [[ -n "$EXT" ]]; then
        FIND_ARGS+=("$FIND_NAME_OPT" "*.${EXT}")
    fi

    log_info "Scanning '$SRC_ABS' for '${EXT:-*}' files..."

    declare -a FILES=()

    if (( SORT_Z )); then
        while IFS= read -r -d '' entry; do
            FILES+=("$entry")
        done < <(find "$SRC_ABS" "${FIND_ARGS[@]}" -print0 2>/dev/null | sort -z)
    else
        while IFS= read -r -d '' entry; do
            FILES+=("$entry")
        done < <(find "$SRC_ABS" "${FIND_ARGS[@]}" -print0 2>/dev/null)
    fi

    TOTAL="${#FILES[@]}"
    log_info "Found ${TOTAL} candidate file(s)."

    # Create a temporary output file in the destination directory.
    if command -v mktemp >/dev/null 2>&1; then
        TMP_FILE="$(mktemp -- "${OUT_DIR_ABS}/.${OUT_BASE}.ctf.XXXXXX" 2>/dev/null || true)"
    fi

    if [[ -z "$TMP_FILE" ]]; then
        TMP_FILE="${OUT_DIR_ABS}/.${OUT_BASE}.ctf.$$"

        if [[ -e "$TMP_FILE" ]]; then
            die "Temporary file '$TMP_FILE' already exists."
        fi

        if ! : > "$TMP_FILE"; then
            die "Cannot create temporary file in '$OUT_DIR_ABS'."
        fi
    fi

    if [[ ! -w "$TMP_FILE" ]]; then
        die "Temporary file '$TMP_FILE' is not writable."
    fi

    generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"

    # Write Markdown header.
    {
        printf '# Project Source Code Aggregate\n\n'
        printf '| Field | Value |\n'
        printf '|:------|:------|\n'
        printf '| Generated | %s |\n' "$generated_at"
        printf '| Script | %s v%s |\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '| Source | %s |\n' "$SRC_ABS"
        printf '| Extension | %s |\n' "${EXT:-*}"
        printf '| Candidates | %d |\n\n' "$TOTAL"
        printf '%s\n\n' '---'
    } > "$TMP_FILE"

    tmp_prefix="${OUT_DIR_ABS}/.${OUT_BASE}.ctf."

    if (( TOTAL > 0 )); then
        for file in "${FILES[@]}"; do
            # Relative path for Markdown headings.
            if [[ "$SRC_ABS" == "/" ]]; then
                rel="${file#/}"
            else
                rel="${file#"$SRC_ABS"/}"
            fi

            if [[ -z "$rel" ]]; then
                rel="$file"
            fi

            # Make logs/headings safe against CR/LF in unusual file names.
            rel_display="${rel//$'\n'/ }"
            rel_display="${rel_display//$'\r'/ }"

            # Never include the final output file itself.
            if [[ -e "$OUT_ABS" && "$file" -ef "$OUT_ABS" ]]; then
                log_warn "Skip (output file): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            # Skip stale temporary files from previous interrupted runs.
            if [[ "$file" == "${tmp_prefix}"* ]]; then
                log_warn "Skip (temporary file): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            # Defensive checks: find should already return regular files only.
            if [[ -d "$file" ]]; then
                log_warn "Skip (directory): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            if [[ ! -f "$file" ]]; then
                log_warn "Skip (non-regular): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            if [[ ! -r "$file" ]]; then
                log_warn "Skip (unreadable): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            if is_binary "$file"; then
                log_warn "Skip (binary): ${rel_display}"
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                continue
            fi

            lang="$(map_lang "$file")"
            fence="$(choose_fence "$file")"

            if [[ -z "$fence" ]]; then
                fence="${BACKTICK}${BACKTICK}${BACKTICK}"
            fi

            FILE_COUNT=$(( FILE_COUNT + 1 ))

            {
                if [[ "$rel_display" == *"$BACKTICK"* ]]; then
                    printf '### %s\n\n' "$rel_display"
                else
                    printf '### `%s`\n\n' "$rel_display"
                fi

                printf '%s%s\n' "$fence" "$lang"

                cat < "$file"

                # Ensure closing fence always starts on its own line.
                if [[ -s "$file" ]]; then
                    last_char="$(tail -c 1 < "$file" 2>/dev/null || true)"
                    if [[ -n "$last_char" ]]; then
                        printf '\n'
                    fi
                fi

                printf '%s\n\n' "$fence"
                printf '%s\n\n' '---'
            } >> "$TMP_FILE"
        done
    fi

    # Write summary.
    {
        printf '## Summary\n\n'
        printf '| Metric | Count |\n'
        printf '|:-------|------:|\n'
        printf '| Processed | %d |\n' "$FILE_COUNT"
        printf '| Skipped | %d |\n' "$SKIP_COUNT"
        printf '| Total | %d |\n' "$TOTAL"
    } >> "$TMP_FILE"

    # Finalize output. Preserve symlinks by writing through them.
    if [[ -L "$OUT_ABS" ]]; then
        if ! cat < "$TMP_FILE" > "$OUT_ABS"; then
            die "Cannot write output file '$OUT_ABS'."
        fi

        rm -f -- "$TMP_FILE" 2>/dev/null || true
    else
        if ! mv -f -- "$TMP_FILE" "$OUT_ABS"; then
            die "Cannot finalize output file '$OUT_ABS'."
        fi
    fi

    TMP_FILE=""

    OUT_SIZE="$(file_size_human "$OUT_ABS")"

    log_info "Done: ${FILE_COUNT} file(s) written, ${SKIP_COUNT} skipped."
    log_info "Output -> ${OUT_ABS} (${OUT_SIZE})"
}

main "$@"
