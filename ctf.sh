#!/usr/bin/env bash
###############################################################################
# ctf.sh — Collect To File
#
#   Recursively collects source files into a single Markdown / JSON / JSONL /
#   text aggregate, preserving paths relative to the source root. Built for
#   assembling LLM context, code-review bundles and auditable source snapshots.
#
# Author:   Mikhail Deynekin <Mikhail@Deynekin.com> | https://deynekin.com
# Version:  4.0.0   (must match the VERSION file — enforced by tests/test_meta.sh)
# License:  MIT
#
# Compatibility:
#   * Bash 4.2+ (CentOS/RHEL 7 baseline). Deliberately avoids everything that
#     requires a newer bash: no `local -n` (4.3), no `wait -n` (4.3),
#     no `mapfile -d` (4.4), no `${v@Q}` / `${v@U}` (4.4).
#   * Empty arrays are expanded as ${arr[@]+"${arr[@]}"} because bash 4.2
#     treats "${arr[@]}" as unbound under `set -u`.
#   * GNU or BSD userland. Required: awk, find, sort, sed, head, tail, od,
#     cat, wc, mktemp, dirname, basename, date, stat (or wc fallback).
#     Optional: file (faster binary check), git (--git), sha256sum|shasum
#     (--dedup, --metadata), curl|wget|python3|perl (--update / --check-update).
#
# Exit codes:
#   0  success
#   1  runtime error (I/O, permissions, unexpected state)
#   2  usage error (unknown option, invalid value)
#   3  update / network error (--check-update, --update)
#   4  nothing collected and --strict was given
#
# Reproducibility:
#   With --no-timestamp (or SOURCE_DATE_EPOCH set) the output is byte-identical
#   for identical input, so snapshots can be committed and diffed.
###############################################################################

# --- interpreter guard -------------------------------------------------------
# shellcheck disable=SC2317  # the exit branch runs only when the file is executed
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'ctf: this script requires Bash; a non-bash shell was detected.' >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC2317
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    printf 'ctf: Bash 4.2 or newer is required (found %s).\n' "$BASH_VERSION" >&2
    return 1 2>/dev/null || exit 1
fi

set -euo pipefail
export LC_ALL=C
IFS=$' \t\n'

readonly EX_OK=0 EX_RUNTIME=1 EX_USAGE=2 EX_UPDATE=3 EX_EMPTY=4

CTF_SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly CTF_SCRIPT_NAME
readonly CTF_SCRIPT_VERSION='4.0.0'
readonly CTF_REPO_OWNER='paulmann'
readonly CTF_REPO_NAME='ctf-collect-to-file'
# CTF_UPDATE_BASE_URL overrides the download root: use it for an internal
# mirror, an air-gapped artifact store, or an HTTP server in the test suite.
readonly CTF_RAW_BASE="${CTF_UPDATE_BASE_URL:-https://raw.githubusercontent.com/${CTF_REPO_OWNER}/${CTF_REPO_NAME}}"
readonly CTF_API_BASE="https://api.github.com/repos/${CTF_REPO_OWNER}/${CTF_REPO_NAME}"

ctf_self_path() {
    local d
    d="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s' "$d" "${BASH_SOURCE[0]##*/}"
}
CTF_SELF_RESOLVED="$(ctf_self_path)"
readonly CTF_SCRIPT_PATH="$CTF_SELF_RESOLVED"

BACKTICK="$(printf '\140')"
readonly BACKTICK

# Built-in excludes: VCS metadata, dependency trees, build output, caches, plus
# generated file patterns that are never useful as model context.
# Disable everything with --no-default-excludes.
readonly -a CTF_DEFAULT_EXCLUDE_DIRS=(
    .git .svn .hg .bzr .fossil-settings
    node_modules bower_components jspm_packages
    .venv venv virtualenv .tox .nox .eggs
    __pycache__ .mypy_cache .pytest_cache .ruff_cache .ipynb_checkpoints
    .gradle .m2 .sbt .terraform .terragrunt-cache
    build dist out output release target obj
    .next .nuxt .svelte-kit .output .turbo .parcel-cache .vite
    .cache .npm .yarn .pnpm-store
    coverage htmlcov .nyc_output
    .idea .vscode .vs .settings
)
readonly -a CTF_DEFAULT_EXCLUDE_GLOBS=(
    '*.min.js' '*.min.css' '*.map' '*.bundle.js' '*.chunk.js'
    'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml' 'composer.lock' 'poetry.lock' 'Gemfile.lock'
    '*.pack' '*.idx' '*.pyc' '*.pyo' '*.class' '*.o' '*.a' '*.so' '*.dylib' '*.dll' '*.exe'
)

###############################################################################
# 1. Logging
###############################################################################

CTF_COLOR='auto'
CTF_QUIET=0
CTF_VERBOSE=0
_C_R='' _C_Y='' _C_G='' _C_B='' _C_N=''

color_setup() {
    case "$1" in
        always) : ;;
        never)  _C_R='' _C_Y='' _C_G='' _C_B='' _C_N=''; return 0 ;;
        auto)   [[ -t 2 ]] || { _C_R='' _C_Y='' _C_G='' _C_B='' _C_N=''; return 0; } ;;
        *)      return 2 ;;
    esac
    _C_R=$'\033[0;31m'; _C_Y=$'\033[0;33m'; _C_G=$'\033[0;32m'
    _C_B=$'\033[0;36m'; _C_N=$'\033[0m'
}

die()  { printf '%s\n' "${_C_R}[ERROR]${_C_N} $*" >&2; exit "$EX_RUNTIME"; }
die2() { printf '%s\n' "${_C_R}[ERROR]${_C_N} $*" >&2; exit "$EX_USAGE"; }
die3() { printf '%s\n' "${_C_R}[ERROR]${_C_N} $*" >&2; exit "$EX_UPDATE"; }
info() { (( CTF_QUIET )) && return 0; printf '%s\n' "${_C_G}[INFO]${_C_N} $*" >&2; return 0; }
warn() { (( CTF_QUIET )) && return 0; printf '%s\n' "${_C_Y}[WARN]${_C_N} $*" >&2; return 0; }
verb() { (( CTF_VERBOSE )) || return 0; printf '%s\n' "${_C_B}[DEBUG]${_C_N} $*" >&2; return 0; }

usage() {
    cat <<EOF
${CTF_SCRIPT_NAME} v${CTF_SCRIPT_VERSION} — collect source files into one aggregate document

USAGE
  ${CTF_SCRIPT_NAME} [OPTIONS] [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

  The three positional arguments preserve the v1–v3 behaviour:
  EXTENSION ('' = every text file), SOURCE_DIR (default '.'), OUTPUT_FILE.
  They are equivalent to --ext / the source directory / --output.

COLLECTION
  -e, --ext LIST          Comma-separated extensions, e.g. 'php,js,sh'.
                          Repeatable; a leading dot is optional.
  -E, --exclude GLOB      Exclude matching paths (repeatable). '*' crosses '/';
                          the bare file name is matched as well.
  -I, --include GLOB      Keep only matching paths (repeatable).
      --exclude-dir NAME  Exclude a directory name at any depth (repeatable).
      --no-default-excludes
                          Do not apply the built-in VCS/deps/build excludes.
      --list-default-excludes
                          Print the built-in exclude lists and exit 0.
  -d, --max-depth N       Maximum depth below SOURCE_DIR (0 = unlimited).
  -L, --follow            Follow symlinks (default: symlinked files are counted
                          as skipped and directory symlinks are not descended).
      --max-size SIZE     Skip files larger than SIZE (bytes or K/M/G/T suffix).
      --min-size SIZE     Skip files smaller than SIZE.
      --files-from FILE   Read the file list from FILE ('-' = stdin), newline-
                          or NUL-separated, relative to SOURCE_DIR.
      --git MODE          Enumerate with git instead of find:
                            tracked = git ls-files --cached
                            all     = tracked + untracked, honouring .gitignore
      --binary MODE       Binary detection: auto (default) | never | always.

OUTPUT
  -o, --output FILE       Destination; '-' writes to stdout.
                          Default: all-<ext>-files.md or All-Project-Files.md
  -F, --format FMT        md (default) | json | jsonl | txt
      --heading-level N   Markdown heading level for paths (1–6, default 3).
      --path-style STYLE  rel (default) | abs
      --sort KEY          path (default) | name | size | mtime
      --title TEXT        Document title.
      --no-header         Omit the metadata header.
      --no-summary        Omit the trailing summary.
      --no-timestamp      Omit the generation timestamp (reproducible output).
      --toc               Add a table of contents with GitHub-style anchors.
      --metadata          Per-file HTML comment: bytes, lines, sha256/12.
      --line-numbers      Prefix content lines with their number.
      --lang-style STYLE  fenced (default) | indent4 | none
      --strip-bom         Remove a leading UTF-8 BOM from each file.
      --truncate-lines N  Keep at most N content lines per file (0 = all).
      --token-budget N    Estimated token budget (estimate = ceil(bytes / 4)).
      --budget-action A   When a file does not fit: truncate (default) | drop.
      --dedup             Emit byte-identical files once (needs sha256sum).

BEHAVIOUR
  -n, --dry-run           Print the selection as TSV; write nothing.
      --stats             Print machine-readable statistics and exit.
      --strict            Exit ${EX_EMPTY} when nothing was collected.
  -c, --config FILE       Read VAR=VALUE defaults from FILE (CTF_* only).
      --print-config      Show the effective configuration and exit.
  -q, --quiet             Errors only on stderr.
  -v, --verbose           Debug output on stderr.
      --color WHEN        auto (default) | always | never
  -h, --help              This help.
  -V, --version           Print the version and exit.

SELF-UPDATE
      --check-update      Query GitHub and report; exit 0 when up to date,
                          ${EX_UPDATE} when a newer version exists or the lookup fails.
      --update            Download and install the newer version over this file.
      --update-channel CH main (default) | latest | <branch-or-tag>
                          (CTF_UPDATE_BASE_URL overrides the download root,
                          e.g. an internal mirror)
      --update-force      Reinstall even when the version is identical.
      --update-timeout S  Per-request timeout in seconds (default 15).

EXAMPLES
  ${CTF_SCRIPT_NAME} php ./src result.md              # legacy positional form
  ${CTF_SCRIPT_NAME} -e php,js -o bundle.md ./src
  ${CTF_SCRIPT_NAME} --git all -o context.md .        # respect .gitignore
  ${CTF_SCRIPT_NAME} -e py --token-budget 120000 -o - | pbcopy
  ${CTF_SCRIPT_NAME} -E 'tests/*' -E '*.md' --stats ./src
  ${CTF_SCRIPT_NAME} --check-update

ENVIRONMENT
  CTF_CONFIG            Default configuration file (overridden by --config).
  NO_COLOR              Any value disables colours.
  SOURCE_DATE_EPOCH     Unix timestamp used instead of "now" (reproducible runs).
  CTF_UPDATE_CHANNEL    Default update channel.
  CTF_UPDATE_BASE_URL   Download root override (mirror / air-gapped install).
  CTF_UPDATE_TIMEOUT    Default per-request timeout in seconds.
EOF
    return 0
}

###############################################################################
# 2. Utilities
###############################################################################

parse_size() { # '12K' -> bytes ; '' -> ''
    local in="${1:-}" num unit
    [[ -z "$in" ]] && { printf ''; return 0; }
    if [[ "$in" =~ ^([0-9]+)([kKmMgGtT]?)[iI]?[bB]?$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    else
        die2 "Invalid size '$in'. Use a byte count with an optional K/M/G/T suffix."
    fi
    case "${unit,,}" in
        '') printf '%s' "$num" ;;
        k)  printf '%s' "$(( num * 1024 ))" ;;
        m)  printf '%s' "$(( num * 1048576 ))" ;;
        g)  printf '%s' "$(( num * 1073741824 ))" ;;
        t)  printf '%s' "$(( num * 1099511627776 ))" ;;
    esac
}

# Pure bash: no fork per call (runs once per file for metadata/txt headings).
# Округление — «от нуля» (round half away from zero), а не усечение: v3 и
# черновик v4 печатали 8699 байт как «8.4 KiB», тогда как ctf.ps1 давал «8.5 KiB»,
# и документ переставал совпадать побайтово. Дробная часть считается одним
# целочисленным выражением, поэтому перенос в старший разряд (9.96 -> 10.0)
# получается сам собой.
human_size() {
    local b="${1:-0}" v
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if (( b >= 1073741824 )); then
        v=$(( (b * 100 + 536870912) / 1073741824 ))
        printf '%d.%02d GiB' "$(( v / 100 ))" "$(( v % 100 ))"
    elif (( b >= 1048576 )); then
        v=$(( (b * 100 + 524288) / 1048576 ))
        printf '%d.%02d MiB' "$(( v / 100 ))" "$(( v % 100 ))"
    elif (( b >= 1024 )); then
        v=$(( (b * 10 + 512) / 1024 ))
        printf '%d.%d KiB' "$(( v / 10 ))" "$(( v % 10 ))"
    else
        printf '%d B' "$b"
    fi
}

stat_size() {
    local f="$1" s=''
    if (( CTF_HAVE_STAT_C )); then s="$(stat -c %s -- "$f" 2>/dev/null || true)"
    elif (( CTF_HAVE_STAT_F )); then s="$(stat -f %z -- "$f" 2>/dev/null || true)"
    fi
    if [[ ! "$s" =~ ^[0-9]+$ ]]; then
        s="$(wc -c < "$f" 2>/dev/null || printf 0)"; s="${s//[!0-9]/}"
    fi
    printf '%s' "${s:-0}"
}

stat_mtime() {
    local f="$1" t=''
    if (( CTF_HAVE_STAT_C )); then t="$(stat -c %Y -- "$f" 2>/dev/null || true)"
    elif (( CTF_HAVE_STAT_F )); then t="$(stat -f %m -- "$f" 2>/dev/null || true)"
    fi
    [[ "$t" =~ ^[0-9]+$ ]] || t=0
    printf '%s' "$t"
}

stat_mode() {
    local f="$1" m=''
    if (( CTF_HAVE_STAT_C )); then m="$(stat -c %a -- "$f" 2>/dev/null || true)"
    elif (( CTF_HAVE_STAT_F )); then m="$(stat -f %Lp -- "$f" 2>/dev/null || true)"; m="${m: -3}"; fi
    printf '%s' "$m"
}

# Numeric dotted comparison; returns 0 when a > b. No `sort -V` dependency.
version_gt() {
    local a="${1#v}" b="${2#v}" x y i n
    local -a ra=() rb=()
    IFS='.' read -r -a ra <<< "$a"
    IFS='.' read -r -a rb <<< "$b"
    n=$(( ${#ra[@]} > ${#rb[@]} ? ${#ra[@]} : ${#rb[@]} ))
    for (( i = 0; i < n; i++ )); do
        x="${ra[i]:-0}"; y="${rb[i]:-0}"
        x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
        x="${x:-0}"; y="${y:-0}"
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 1
}

# The right-hand side is deliberately unquoted: $1 is a glob pattern, which is
# the whole point of --include/--exclude matching.
# shellcheck disable=SC2053
glob_match() { [[ "$2" == $1 ]]; }

# GNU sha256sum/shasum переходят в «escape-режим», если имя файла содержит
# перевод строки или обратный слэш, и печатают '\\' ПЕРЕД хешем. Без его
# снятия хеш оказывался на один символ длиннее и с мусорным префиксом.
sha256_of() {
    local f="$1" h=''
    if (( CTF_HAVE_SHA256SUM )); then h="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')"
    elif (( CTF_HAVE_SHASUM )); then h="$(shasum -a 256 -- "$f" 2>/dev/null | awk '{print $1}')"; fi
    h="${h#\\}"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || { printf ''; return 0; }
    printf '%s' "$h"
}

# JSON escaping of a short string (paths, titles) — pure bash.
json_escape_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# JSON escaping of a file's content — awk, because a bash character loop is
# unusable on megabyte inputs. Control characters other than \t \n \r are
# removed (they are not valid unescaped JSON and never appear in source code).
json_escape_file() { # json_escape_file <file> <ends_nl:0|1>
    local f="$1" ends_nl="${2:-1}"
    # Экранирование построено посимвольной склейкой, а НЕ через gsub: в строке
    # замены gsub обратный слэш обрабатывается повторно, и gsub(/\\/, "\\\\")
    # выдаёт ОДИН слэш вместо двух. На содержимом с обратными слэшами
    # (Windows-пути, regex-ы, LaTeX) это давало невалидный JSON.
    tr -d '\000-\010\013\014\016-\037' < "$f" | awk -v ends_nl="$ends_nl" '
        function jesc(str,   out, i, c, n) {
            out = ""; n = length(str)
            for (i = 1; i <= n; i++) {
                c = substr(str, i, 1)
                if      (c == "\\") out = out "\\\\"
                else if (c == "\"") out = out "\\\""
                else if (c == "\t") out = out "\\t"
                else if (c == "\r") out = out "\\r"
                else                 out = out c
            }
            return out
        }
        BEGIN { ORS = "" }
        {
            if (NR > 1) print "\\n"
            print jesc($0)
        }
        END { if (ends_nl == "1" && NR > 0) print "\\n" }
    '
}

now_stamp() {
    if [[ -n "${SOURCE_DATE_EPOCH:-}" && "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]+$ ]]; then
        date -u -d "@${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
        date -u -r "${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
    fi
    date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown'
}

###############################################################################
# 3. Capability detection
###############################################################################

CTF_HAVE_AWK=0;       command -v awk       >/dev/null 2>&1 && CTF_HAVE_AWK=1
CTF_HAVE_FILE=0;      command -v file      >/dev/null 2>&1 && CTF_HAVE_FILE=1
CTF_HAVE_OD=0;        command -v od        >/dev/null 2>&1 && CTF_HAVE_OD=1
CTF_HAVE_FIND=0;      command -v find      >/dev/null 2>&1 && CTF_HAVE_FIND=1
CTF_HAVE_MKTEMP=0;    command -v mktemp    >/dev/null 2>&1 && CTF_HAVE_MKTEMP=1
CTF_HAVE_GIT=0;       command -v git       >/dev/null 2>&1 && CTF_HAVE_GIT=1
CTF_HAVE_CURL=0;      command -v curl      >/dev/null 2>&1 && CTF_HAVE_CURL=1
CTF_HAVE_WGET=0;      command -v wget      >/dev/null 2>&1 && CTF_HAVE_WGET=1
CTF_HAVE_PY3=0;       command -v python3   >/dev/null 2>&1 && CTF_HAVE_PY3=1
CTF_HAVE_PERL=0;      command -v perl      >/dev/null 2>&1 && CTF_HAVE_PERL=1
CTF_HAVE_SHA256SUM=0; command -v sha256sum >/dev/null 2>&1 && CTF_HAVE_SHA256SUM=1
CTF_HAVE_SHASUM=0;    (( CTF_HAVE_SHA256SUM )) || { command -v shasum >/dev/null 2>&1 && CTF_HAVE_SHASUM=1; }
# find -mindepth 1 обязателен: без него выражение -name <dir> -prune совпадает
# с самой стартовой точкой, и дерево с корнем вроде ./out или ./build вырезается
# целиком. Проверяем поддержку, а не предполагаем её (POSIX -mindepth не знает).
CTF_HAVE_FIND_MINDEPTH=0
if (( CTF_HAVE_FIND )); then
    find . -mindepth 1 -maxdepth 0 >/dev/null 2>&1 && CTF_HAVE_FIND_MINDEPTH=1
fi
CTF_HAVE_STAT_C=0;    stat -c %s / >/dev/null 2>&1 && CTF_HAVE_STAT_C=1
CTF_HAVE_STAT_PRINTF=0; stat --printf '%s' /dev/null >/dev/null 2>&1 && CTF_HAVE_STAT_PRINTF=1
CTF_HAVE_STAT_F=0;    (( CTF_HAVE_STAT_C )) || { stat -f %z / >/dev/null 2>&1 && CTF_HAVE_STAT_F=1; }

# grep -I (skip files it considers binary, i.e. files containing a NUL byte)
# plus -Z (NUL after each printed name) let us classify a whole batch of files
# in ONE process instead of two per file. The probe must use a file that really
# contains a NUL byte: a file with only control characters is still text for
# grep -I, so probing with \001\002\003 would report a false negative.
CTF_HAVE_GREP_IZ=0
if command -v grep >/dev/null 2>&1; then
    _ctf_probe="${TMPDIR:-/tmp}/.ctf-grep-probe.$$"
    if printf 'x\n' > "$_ctf_probe" 2>/dev/null && printf 'a\000b\n' > "${_ctf_probe}.bin" 2>/dev/null; then
        _ctf_listed="$(grep -Il '' -- "$_ctf_probe" "${_ctf_probe}.bin" 2>/dev/null | wc -l)"
        _ctf_nuls="$(grep -IlZ '' -- "$_ctf_probe" "${_ctf_probe}.bin" 2>/dev/null | tr -dc '\0' | wc -c)"
        if [[ "${_ctf_listed//[!0-9]/}" == 1 && "${_ctf_nuls//[!0-9]/}" == 1 ]]; then
            CTF_HAVE_GREP_IZ=1
        fi
    fi
    rm -f -- "$_ctf_probe" "${_ctf_probe}.bin" 2>/dev/null || true
fi

###############################################################################
# 4. Configuration state
###############################################################################

declare -a CTF_EXTS=() CTF_INCLUDE=() CTF_EXCLUDE=() CTF_EXCLUDE_DIRS=() CTF_FILES_FROM=()
declare -a CTF_FILES=() CTF_SELECTED=() CTF_REL=() CTF_REL_RENDERED=()
declare -A CTF_SKIP_COUNT=() CTF_SEEN_HASH=()

CTF_SRC_DIR='.'
CTF_SRC_SET=0
CTF_SRC_ABS=''
CTF_OUT_FILE=''
CTF_OUT_ABS=''
CTF_OUT_DIR_ABS=''
CTF_FORMAT='md'
CTF_HEADING_LEVEL=3
CTF_PATH_STYLE='rel'
CTF_SORT='path'
CTF_TITLE='Project Source Code Aggregate'
CTF_HEADER=1
CTF_SUMMARY=1
CTF_TIMESTAMP=1
CTF_TOC=0
CTF_METADATA=0
CTF_LINE_NUMBERS=0
CTF_LANG_STYLE='fenced'
CTF_STRIP_BOM=0
CTF_TRUNCATE_LINES=0
CTF_TOKEN_BUDGET=0
CTF_BUDGET_ACTION='truncate'
CTF_DEDUP=0
CTF_DEFAULT_EXCLUDES=1
CTF_MAX_DEPTH=0
CTF_FOLLOW=0
CTF_MAX_SIZE=''
CTF_MIN_SIZE=''
CTF_GIT_MODE=''
CTF_BINARY_MODE='auto'
CTF_DRY_RUN=0
CTF_STATS=0
CTF_STRICT=0
CTF_CONFIG_FILE="${CTF_CONFIG:-}"
CTF_PRINT_CONFIG=0
CTF_LIST_DEFAULT_EXCLUDES=0
CTF_DO_CHECK_UPDATE=0
CTF_DO_UPDATE=0
CTF_UPDATE_CHANNEL="${CTF_UPDATE_CHANNEL:-main}"
CTF_UPDATE_FORCE=0
CTF_UPDATE_TIMEOUT="${CTF_UPDATE_TIMEOUT:-15}"

CTF_HEAD_MARKS='###'
CTF_TOTAL_CANDIDATES=0
CTF_WRITTEN=0
CTF_SKIPPED=0
CTF_BYTES_IN=0
CTF_BYTES_OUT=0
CTF_TOKENS_EST=0
CTF_TRUNCATED_FILES=0
CTF_BUDGET_DROPPED=0
CTF_DUPLICATES=0

[[ -n "${NO_COLOR:-}" ]] && CTF_COLOR='never'

###############################################################################
# 5. Language tag mapping
###############################################################################

CTF_RET_LANG=''
map_lang() { # sets CTF_RET_LANG and prints the same value
    local base="${1##*/}" lower ext
    CTF_RET_LANG=''
    lower="${base,,}"
    case "$lower" in
        dockerfile*|containerfile*)  CTF_RET_LANG='dockerfile'; return 0 ;;
        makefile*|gnumakefile*)      CTF_RET_LANG='makefile'; return 0 ;;
        jenkinsfile*)                CTF_RET_LANG='groovy'; return 0 ;;
        cmakelists.txt)              CTF_RET_LANG='cmake'; return 0 ;;
        rakefile|gemfile|guardfile|vagrantfile|podfile|berksfile) CTF_RET_LANG='ruby'; return 0 ;;
        readme|license|changelog|authors|contributors|notice|copying) CTF_RET_LANG='markdown'; return 0 ;;
        .gitignore|.gitattributes|.dockerignore|.npmignore|.editorconfig|.env) CTF_RET_LANG='text'; return 0 ;;
    esac
    ext="${lower##*.}"
    [[ "$ext" == "$lower" ]] && ext=''
    case "$ext" in
        sh|bash|zsh|ksh|fish|bashrc|bash_profile|profile) CTF_RET_LANG='bash' ;;
        bat|cmd)                  CTF_RET_LANG='batch' ;;
        ps1|psm1|psd1)            CTF_RET_LANG='powershell' ;;
        py|pyw|pyi)               CTF_RET_LANG='python' ;;
        rb)                       CTF_RET_LANG='ruby' ;;
        pl|pm|t)                  CTF_RET_LANG='perl' ;;
        php|php3|php4|php5|php7|php8|phtml) CTF_RET_LANG='php' ;;
        js|mjs|cjs)               CTF_RET_LANG='javascript' ;;
        ts)                       CTF_RET_LANG='typescript' ;;
        tsx)                      CTF_RET_LANG='tsx' ;;
        jsx)                      CTF_RET_LANG='jsx' ;;
        vue)                      CTF_RET_LANG='vue' ;;
        svelte)                   CTF_RET_LANG='svelte' ;;
        html|htm|xhtml)           CTF_RET_LANG='html' ;;
        xml|xsl|xsd|rss|atom|svg|plist|wsdl|pom) CTF_RET_LANG='xml' ;;
        css)                      CTF_RET_LANG='css' ;;
        scss)                     CTF_RET_LANG='scss' ;;
        sass)                     CTF_RET_LANG='sass' ;;
        less)                     CTF_RET_LANG='less' ;;
        json|jsonc|json5|jsonl|ndjson|har) CTF_RET_LANG='json' ;;
        yaml|yml)                 CTF_RET_LANG='yaml' ;;
        toml)                     CTF_RET_LANG='toml' ;;
        ini|cfg|conf|config|properties) CTF_RET_LANG='ini' ;;
        env|envrc)                CTF_RET_LANG='bash' ;;
        sql)                      CTF_RET_LANG='sql' ;;
        go)                       CTF_RET_LANG='go' ;;
        rs)                       CTF_RET_LANG='rust' ;;
        c)                        CTF_RET_LANG='c' ;;
        cpp|cc|cxx|c++|cp)        CTF_RET_LANG='cpp' ;;
        h)                        CTF_RET_LANG='c' ;;
        hh|hpp|hxx|h++|tpp)       CTF_RET_LANG='cpp' ;;
        m)                        CTF_RET_LANG='objectivec' ;;
        mm)                       CTF_RET_LANG='objectivec' ;;
        java)                     CTF_RET_LANG='java' ;;
        kt|kts)                   CTF_RET_LANG='kotlin' ;;
        groovy|gvy|gradle)        CTF_RET_LANG='groovy' ;;
        scala|sc)                 CTF_RET_LANG='scala' ;;
        swift)                    CTF_RET_LANG='swift' ;;
        cs)                       CTF_RET_LANG='csharp' ;;
        fs|fsi|fsx)               CTF_RET_LANG='fsharp' ;;
        vb)                       CTF_RET_LANG='vbnet' ;;
        lua)                      CTF_RET_LANG='lua' ;;
        r|rmd)                    CTF_RET_LANG='r' ;;
        jl)                       CTF_RET_LANG='julia' ;;
        dart)                     CTF_RET_LANG='dart' ;;
        ex|exs)                   CTF_RET_LANG='elixir' ;;
        erl|hrl)                  CTF_RET_LANG='erlang' ;;
        hs|lhs)                   CTF_RET_LANG='haskell' ;;
        ml|mli)                   CTF_RET_LANG='ocaml' ;;
        clj|cljs|cljc|edn)        CTF_RET_LANG='clojure' ;;
        nim)                      CTF_RET_LANG='nim' ;;
        zig)                      CTF_RET_LANG='zig' ;;
        v|sv)                     CTF_RET_LANG='verilog' ;;
        vhd|vhdl)                 CTF_RET_LANG='vhdl' ;;
        asm|s)                    CTF_RET_LANG='asm' ;;
        proto)                    CTF_RET_LANG='protobuf' ;;
        graphql|gql)              CTF_RET_LANG='graphql' ;;
        tf|tfvars)                CTF_RET_LANG='hcl' ;;
        dockerfile)               CTF_RET_LANG='dockerfile' ;;
        mk|make|mak)              CTF_RET_LANG='makefile' ;;
        cmake)                    CTF_RET_LANG='cmake' ;;
        nginx)                    CTF_RET_LANG='nginx' ;;
        apache|htaccess)          CTF_RET_LANG='apache' ;;
        rst)                      CTF_RET_LANG='rst' ;;
        adoc|asciidoc)            CTF_RET_LANG='asciidoc' ;;
        tex|sty|cls)              CTF_RET_LANG='latex' ;;
        bib)                      CTF_RET_LANG='bibtex' ;;
        diff|patch)               CTF_RET_LANG='diff' ;;
        csv|tsv)                  CTF_RET_LANG='text' ;;
        md|markdown|mdx)          CTF_RET_LANG='markdown' ;;
        txt|text|log)             CTF_RET_LANG='text' ;;
        lock)                     CTF_RET_LANG='text' ;;
        *)
            if [[ "$ext" =~ ^[a-z0-9_+.-]+$ ]]; then CTF_RET_LANG="$ext"; fi
            ;;
    esac
    return 0
}

# Convenience wrapper: prints the tag (used by tests and interactive probing).
map_lang_print() { map_lang "$1"; printf '%s' "$CTF_RET_LANG"; }

###############################################################################
# 6. Binary detection
#
#   v3 used:  head -c 8192 file | od | tr | grep -q '00'
#   Under `set -o pipefail`, grep -q exits at the first match and closes the
#   pipe; od then dies of SIGPIPE and the pipeline reports 141, so the file was
#   classified as TEXT. The outcome depended on process scheduling: six
#   identical runs over the same tree collected 3, 2, 4, 4, 3 and 4 files.
#
#   This version never uses an early-exiting consumer — awk reads od's output to
#   EOF, so the verdict is deterministic. Two signals, both false-positive-free
#   for real text in any encoding:
#     * any NUL byte in the first 8 KiB (catches UTF-16 and every structured
#       binary format, and is statistically certain for random data);
#     * more than CTF_BINARY_CTRL_PCT % C0 control bytes other than \t \n \v \f \r,
#       plus DEL. Real source text contains none of these; a random or
#       structured binary contains many.
#   High bytes (>= 0x80) are deliberately NOT evidence of binary: they are
#   ordinary UTF-8, CP1251, KOI8-R or Latin-1 text, and treating them as
#   "weird" silently dropped every non-English source file.
###############################################################################

CTF_BINARY_SCAN_BYTES="${CTF_BINARY_SCAN_BYTES:-8192}"
CTF_BINARY_CTRL_PCT="${CTF_BINARY_CTRL_PCT:-5}"

is_binary() { # 0 = binary, 1 = text
    local f="$1" verdict
    [[ -s "$f" ]] || return 1
    case "$CTF_BINARY_MODE" in
        never)  return 1 ;;
        always) return 0 ;;
    esac
    if (( CTF_HAVE_FILE )); then
        local enc
        enc="$(file --brief --mime-encoding -- "$f" 2>/dev/null || true)"
        case "$enc" in
            binary|application/octet-stream) return 0 ;;
            utf-8|us-ascii|ascii|iso-8859-*|utf-7|utf-16*|utf-32*|euc-*|shift*|windows-*|ibm*) return 1 ;;
        esac
    fi
    if (( CTF_HAVE_OD && CTF_HAVE_AWK )); then
        # NOTE: awk must read od's output to EOF. An early `exit` closes the
        # pipe, od dies of SIGPIPE and, with pipefail, the substitution reports
        # failure — which is exactly how v3 turned binaries into text.
        verdict="$(od -A n -v -t u1 -N "$CTF_BINARY_SCAN_BYTES" -- "$f" 2>/dev/null | awk \
            -v ctrl_pct="$CTF_BINARY_CTRL_PCT" '
            {
                for (i = 1; i <= NF; i++) {
                    b = $i + 0; n++
                    if (b == 0) nul = 1
                    else if (b < 9 || (b > 13 && b < 32) || b == 127) ctrl++
                }
            }
            END {
                if (n == 0) { print "text"; exit }
                if (nul == 1) { print "binary"; exit }
                print ((ctrl + 0) * 100 > n * ctrl_pct) ? "binary" : "text"
            }' 2>/dev/null)"
        if [[ -z "$verdict" ]]; then verdict=text; fi
        [[ -z "$verdict" ]] && verdict=text
        [[ "$verdict" == binary ]] && return 0
        return 1
    fi
    return 1
}

###############################################################################
# 7. Per-file scan
#
#   One awk pass returns everything the renderer needs:
#     lines — number of records
#     mb/mt — length of the longest line that consists ONLY of backticks/tildes
#             (CommonMark: only such a line can close a fenced block)
#     bsum  — sum(length($0)) + lines, i.e. the size the file would have if
#             every record ended with "\n". Comparing bsum with the real size
#             tells us whether the file ends with a newline — no extra fork.
###############################################################################

scan_file() { # -> "<lines> <mb> <mt> <bsum> <ctrl>"
    local f="$1"
    (( CTF_HAVE_AWK )) || { printf '0 0 0 0 0'; return 0; }
    awk '
        BEGIN { b = sprintf("%c", 96); t = "~"; mb = 0; mt = 0; sum = 0; lines = 0; ctrl = 0 }
        {
            lines++
            sum += length($0)
            tmp = $0
            ctrl += gsub(/[\001-\010\016-\037\177]/, "", tmp)
            line = $0
            sp = 0
            while (sp < 3 && substr(line, sp + 1, 1) == " ") sp++
            line = substr(line, sp + 1)
            c = substr(line, 1, 1)
            if (c == b || c == t) {
                k = 0
                while (substr(line, k + 1, 1) == c) k++
                if (substr(line, k + 1) == "") {
                    if (c == b) { if (k > mb) mb = k } else { if (k > mt) mt = k }
                }
            }
        }
        END { printf "%d %d %d %d %d", lines, mb, mt, sum + lines, ctrl }
    ' < "$f" 2>/dev/null || printf '0 0 0 0 0'
}

CTF_RET_FENCE=''
choose_fence() { # choose_fence <mb> <mt> -> sets CTF_RET_FENCE
    local mb="${1:-0}" mt="${2:-0}" lb lt i fence=''
    [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
    [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    lb=$(( mb + 1 )); lt=$(( mt + 1 ))
    (( lb < 3 )) && lb=3
    (( lt < 3 )) && lt=3
    if (( lb <= lt )); then
        for (( i = 0; i < lb; i++ )); do fence+="$BACKTICK"; done
    else
        for (( i = 0; i < lt; i++ )); do fence+='~'; done
    fi
    CTF_RET_FENCE="$fence"
}

###############################################################################
# 8. Discovery
###############################################################################

discover_find() {
    local root="$1" d n entry
    local -a args=() prune=()
    (( CTF_FOLLOW )) && args+=(-L)
    args+=("$root")
    # Корень не подлежит исключению: -mindepth 1 убирает его из области действия
    # -prune. Если find его не поддерживает, корень отфильтровывается после выдачи.
    (( CTF_HAVE_FIND_MINDEPTH )) && args+=(-mindepth 1)
    (( CTF_MAX_DEPTH > 0 )) && args+=(-maxdepth "$CTF_MAX_DEPTH")
    if (( CTF_DEFAULT_EXCLUDES )); then
        for d in ${CTF_DEFAULT_EXCLUDE_DIRS[@]+"${CTF_DEFAULT_EXCLUDE_DIRS[@]}"}; do
            prune+=(-name "$d" -o)
        done
    fi
    for d in ${CTF_EXCLUDE_DIRS[@]+"${CTF_EXCLUDE_DIRS[@]}"}; do prune+=(-name "$d" -o); done
    if (( ${#prune[@]} > 0 )); then
        n=$(( ${#prune[@]} - 1 ))
        unset 'prune[n]'
        prune=("${prune[@]}")
        args+=( \( "${prune[@]}" \) -prune -o )
    fi
    if (( CTF_FOLLOW )); then args+=( \( -type f -o -type l \) -print0 )
    else args+=( -type f -print0 ); fi
    verb "find ${args[*]}"
    while IFS= read -r -d '' entry; do
        # Страховка для find без -mindepth: стартовая точка never попадает в список.
        [[ "$entry" == "$root" ]] && continue
        CTF_FILES+=("$entry")
    done < <(find "${args[@]}" 2>/dev/null)
}

discover_git() {
    local root="$1" entry
    local -a gargs=(ls-files -z)
    (( CTF_HAVE_GIT )) || die2 "--git requires git(1) in PATH."
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die2 "--git: '$root' is not inside a git work tree."
    case "$CTF_GIT_MODE" in
        tracked) gargs+=(--cached) ;;
        all)     gargs+=(--cached --others --exclude-standard) ;;
        *)       die2 "--git accepts 'tracked' or 'all', got '$CTF_GIT_MODE'." ;;
    esac
    verb "git -C $root ${gargs[*]}"
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] || continue
        CTF_FILES+=("${root%/}/$entry")
    done < <(git -C "$root" "${gargs[@]}" 2>/dev/null)
}

discover_files_from() {
    local spec="$1" root="$2" line nul_count=0
    local -a raw=()
    if [[ "$spec" == '-' ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do raw+=("$line"); done
    else
        [[ -r "$spec" ]] || die2 "--files-from: cannot read '$spec'."
        if (( CTF_HAVE_OD && CTF_HAVE_AWK )); then
            nul_count="$(od -A n -v -t u1 -N 65536 -- "$spec" 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i==0) c++} END{print c+0}')"
        fi
        if (( nul_count > 0 )); then
            while IFS= read -r -d '' line; do raw+=("$line"); done < "$spec"
        else
            while IFS= read -r line || [[ -n "$line" ]]; do raw+=("$line"); done < "$spec"
        fi
    fi
    for line in ${raw[@]+"${raw[@]}"}; do
        [[ -n "$line" ]] || continue
        case "$line" in
            /*) CTF_FILES+=("$line") ;;
            *)  CTF_FILES+=("${root%/}/$line") ;;
        esac
    done
}

###############################################################################
# 9. Filtering
###############################################################################

declare -a CTF_EXCL_DIR_GLOBS=()

build_exclude_dir_globs() {
    CTF_EXCL_DIR_GLOBS=()
    local d
    if (( CTF_DEFAULT_EXCLUDES )); then
        for d in ${CTF_DEFAULT_EXCLUDE_DIRS[@]+"${CTF_DEFAULT_EXCLUDE_DIRS[@]}"}; do
            CTF_EXCL_DIR_GLOBS+=("*/$d/*" "$d/*")
        done
    fi
    for d in ${CTF_EXCLUDE_DIRS[@]+"${CTF_EXCLUDE_DIRS[@]}"}; do
        CTF_EXCL_DIR_GLOBS+=("*/$d/*" "$d/*")
    done
}

# Собственные временные файлы создаются в каталоге вывода, чтобы финальный
# mv(1) был атомарным в пределах одной файловой системы. Когда каталог вывода
# лежит внутри сканируемого дерева (обычный случай `ctf -o ./bundle.md .`),
# find их увидит — и без этого фильтра они попали бы в документ как содержимое.
is_own_temp_file() { # is_own_temp_file <abs-path> <basename>
    local f="$1" base="$2"
    [[ -n "$CTF_OUT_DIR_ABS" ]] || return 1
    case "$base" in
        .ctf-head.*|.ctf-body.*|.ctf-final.*) ;;
        *) return 1 ;;
    esac
    local d
    d="$(dirname -- "$f")"
    [[ "$d" == "$CTF_OUT_DIR_ABS" ]]
}

CTF_DROP_REASON=''
keep_file() { # keep_file <rel-path>
    local rel="$1" base="${1##*/}" pat ok
    for pat in ${CTF_EXCL_DIR_GLOBS[@]+"${CTF_EXCL_DIR_GLOBS[@]}"}; do
        if glob_match "$pat" "$rel"; then CTF_DROP_REASON='excluded-dir'; return 1; fi
    done
    if (( CTF_DEFAULT_EXCLUDES )); then
        for pat in ${CTF_DEFAULT_EXCLUDE_GLOBS[@]+"${CTF_DEFAULT_EXCLUDE_GLOBS[@]}"}; do
            if glob_match "$pat" "$rel" || glob_match "$pat" "$base"; then
                CTF_DROP_REASON='default-exclude'; return 1
            fi
        done
    fi
    for pat in ${CTF_EXCLUDE[@]+"${CTF_EXCLUDE[@]}"}; do
        if glob_match "$pat" "$rel" || glob_match "$pat" "$base"; then
            CTF_DROP_REASON="exclude(${pat})"; return 1
        fi
    done
    if (( ${#CTF_INCLUDE[@]} > 0 )); then
        ok=0
        for pat in ${CTF_INCLUDE[@]+"${CTF_INCLUDE[@]}"}; do
            if glob_match "$pat" "$rel" || glob_match "$pat" "$base"; then ok=1; break; fi
        done
        (( ok )) || { CTF_DROP_REASON='not-included'; return 1; }
    fi
    return 0
}

ext_match() { # ext_match <basename>
    local base="$1" lower e
    (( ${#CTF_EXTS[@]} == 0 )) && return 0
    lower="${base,,}"
    for e in ${CTF_EXTS[@]+"${CTF_EXTS[@]}"}; do
        [[ "$lower" == *".$e" ]] && return 0
        [[ "$lower" == "$e" ]] && return 0
    done
    return 1
}

###############################################################################
# 10. HTTP transport for --check-update / --update
###############################################################################

CTF_HTTP_TOOL=''

http_detect() {
    if   (( CTF_HAVE_CURL )); then CTF_HTTP_TOOL='curl'
    elif (( CTF_HAVE_WGET )); then CTF_HTTP_TOOL='wget'
    elif (( CTF_HAVE_PY3 ));  then CTF_HTTP_TOOL='python3'
    elif (( CTF_HAVE_PERL )); then CTF_HTTP_TOOL='perl'
    else CTF_HTTP_TOOL='bash-tcp'; fi
    verb "http transport: $CTF_HTTP_TOOL"
}

http_get() { # http_get URL -> body on stdout, non-zero on failure
    local url="$1" tmo="$CTF_UPDATE_TIMEOUT"
    [[ "$tmo" =~ ^[0-9]+$ ]] || tmo=15
    case "$CTF_HTTP_TOOL" in
        curl) curl -fsSL --max-time "$tmo" -- "$url" ;;
        wget) wget -q -T "$tmo" -t 1 -O - -- "$url" ;;
        python3)
            CTF_URL="$url" CTF_TIMEOUT="$tmo" python3 - <<'PY'
import os, sys, urllib.request
url = os.environ["CTF_URL"]
t = int(os.environ.get("CTF_TIMEOUT") or 15)
req = urllib.request.Request(url, headers={"User-Agent": "ctf-selfupdate"})
try:
    with urllib.request.urlopen(req, timeout=t) as r:
        if not (200 <= r.status < 300):
            sys.exit(22)
        sys.stdout.buffer.write(r.read())
except SystemExit:
    raise
except Exception:
    sys.exit(22)
PY
            ;;
        perl)
            CTF_URL="$url" CTF_TIMEOUT="$tmo" perl - <<'PL'
use strict; use warnings;
eval { require HTTP::Tiny; 1 } or exit 22;
my $r = HTTP::Tiny->new(timeout => ($ENV{CTF_TIMEOUT} || 15),
                        agent => 'ctf-selfupdate')->get($ENV{CTF_URL});
exit 22 unless $r->{success};
binmode STDOUT; print $r->{content};
PL
            ;;
        bash-tcp) http_get_bash_tcp "$url" ;;
        *) return 22 ;;
    esac
}

# Dependency-free HTTP/1.0 GET over bash's /dev/tcp: no TLS, so HTTPS requires
# curl, wget, python3 or perl. Follows up to 5 redirects.
http_get_bash_tcp() {
    local url="$1" hops=0 host port path scheme body status location line headers_done
    while (( hops < 5 )); do
        if [[ ! "$url" =~ ^(https?)://([^/]+)(/.*)?$ ]]; then
            printf 'ctf: unsupported URL: %s\n' "$url" >&2; return 22
        fi
        scheme="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"; path="${BASH_REMATCH[3]:-/}"
        port=80
        [[ "$scheme" == https ]] && port=443
        if [[ "$host" == *:* ]]; then port="${host##*:}"; host="${host%%:*}"; fi
        if [[ "$scheme" == https ]]; then
            printf '%s\n' 'ctf: HTTPS requires curl, wget, python3 or perl (bash /dev/tcp has no TLS).' >&2
            return 22
        fi
        body=''; status=''; location=''; headers_done=0
        if ! exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null; then return 22; fi
        printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: ctf-selfupdate\r\nConnection: close\r\n\r\n' \
            "$path" "$host" >&3
        while IFS= read -r line <&3; do
            line="${line%$'\r'}"
            if (( ! headers_done )); then
                if [[ -z "$line" ]]; then headers_done=1; continue; fi
                [[ "$line" =~ ^HTTP/[0-9.]+[[:space:]]+([0-9]{3}) ]] && status="${BASH_REMATCH[1]}"
                if [[ "${line,,}" == location:* ]]; then
                    location="${line#*:}"
                    location="${location#"${location%%[![:space:]]*}"}"
                fi
            else
                body+="${line}"$'\n'
            fi
        done
        exec 3<&- || true
        exec 3>&- || true
        case "$status" in
            2??) printf '%s' "${body%$'\n'}"; return 0 ;;
            3??) [[ -n "$location" ]] || return 22; url="$location"; hops=$(( hops + 1 )) ;;
            *)   return 22 ;;
        esac
    done
    return 22
}

###############################################################################
# 11. Self-update
###############################################################################

update_base_url() { # -> "<raw base url>/<ref>"
    local ch="$CTF_UPDATE_CHANNEL" tag=''
    if [[ "$ch" == latest ]]; then
        tag="$(http_get "${CTF_API_BASE}/releases/latest" 2>/dev/null \
               | awk -F'"' '/"tag_name"[[:space:]]*:/{print $4; exit}')" || tag=''
        if [[ -n "$tag" ]]; then ch="$tag"; else ch='main'; fi
    fi
    printf '%s/%s' "$CTF_RAW_BASE" "$ch"
}

remote_version() { # remote_version <base-url>
    local base="$1" v
    v="$(http_get "${base}/VERSION" 2>/dev/null | tr -d ' \t\r\n')" || return 1
    [[ "$v" =~ ^v?[0-9]+(\.[0-9]+)*$ ]] || return 1
    printf '%s' "${v#v}"
}

do_check_update() {
    http_detect
    local base rv status
    base="$(update_base_url)" || die3 "Cannot resolve update channel '${CTF_UPDATE_CHANNEL}'."
    info "Update channel: ${CTF_UPDATE_CHANNEL} → ${base}"
    if ! rv="$(remote_version "$base")"; then
        printf 'local=%s remote=unknown channel=%s status=unreachable\n' \
            "$CTF_SCRIPT_VERSION" "$CTF_UPDATE_CHANNEL"
        warn "Cannot read ${base}/VERSION (offline, blocked by a proxy, or the file is missing)."
        return "$EX_UPDATE"
    fi
    if version_gt "$rv" "$CTF_SCRIPT_VERSION"; then status=newer; else status=up-to-date; fi
    printf 'local=%s remote=%s channel=%s status=%s\n' \
        "$CTF_SCRIPT_VERSION" "$rv" "$CTF_UPDATE_CHANNEL" "$status"
    if [[ "$status" == newer ]]; then
        info "Newer version available: ${rv} (installed ${CTF_SCRIPT_VERSION}). Re-run with --update."
        return "$EX_UPDATE"
    fi
    info "Already up to date (${CTF_SCRIPT_VERSION})."
    return 0
}

do_update() {
    http_detect
    local base rv tmp target backup mode embedded size first dir sibling sib_path
    base="$(update_base_url)" || die3 "Cannot resolve update channel '${CTF_UPDATE_CHANNEL}'."
    info "Update source: ${base}"
    rv="$(remote_version "$base")" \
        || die3 "Cannot read ${base}/VERSION — check the network, proxy or channel name."
    if (( ! CTF_UPDATE_FORCE )) && ! version_gt "$rv" "$CTF_SCRIPT_VERSION"; then
        info "Already up to date (${CTF_SCRIPT_VERSION})."
        return 0
    fi
    info "Updating ${CTF_SCRIPT_VERSION} → ${rv}"
    (( CTF_HAVE_MKTEMP )) || die3 "mktemp(1) is required for a safe self-update."

    tmp="$(mktemp -- "${TMPDIR:-/tmp}/ctf-update.XXXXXX")" || die3 "Cannot create a temporary file."
    if ! http_get "${base}/ctf.sh" > "$tmp"; then
        rm -f -- "$tmp"; die3 "Download of ${base}/ctf.sh failed."
    fi

    # --- validation: never install anything we cannot prove is a script ------
    size="$(stat_size "$tmp")"
    (( size >= 4096 )) || { rm -f -- "$tmp"; die3 "Downloaded only ${size} bytes — refusing (probably an error page)."; }
    first="$(head -n 1 -- "$tmp")"
    [[ "$first" == '#!'* ]] || { rm -f -- "$tmp"; die3 "Downloaded file does not start with a shebang — refusing."; }
    bash -n "$tmp" 2>/dev/null || { rm -f -- "$tmp"; die3 "Downloaded file fails 'bash -n' — refusing to install."; }
    embedded="$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$tmp")"
    if [[ -n "$embedded" && "$embedded" != "$rv" ]]; then
        warn "Remote VERSION says ${rv}, the script embeds ${embedded}. Trusting the script."
        rv="$embedded"
    fi

    # --- installation --------------------------------------------------------
    target="$CTF_SCRIPT_PATH"
    [[ -L "$target" ]] && target="$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")"
    if [[ ! -w "$target" ]]; then
        die3 "'${target}' is not writable. The download is kept at '${tmp}'.
  Install manually:  cp '${tmp}' '${target}'"
    fi
    mode="$(stat_mode "$target")"
    backup="${target}.bak-$(date -u +%Y%m%d%H%M%S)"
    if cp -p -- "$target" "$backup" 2>/dev/null; then
        info "Backup: ${backup}"
    else
        backup=''; warn "Could not create a backup copy."
    fi
    # Write through the existing inode so ownership, hard links and the mode
    # survive; fall back to mv(1) only if that is impossible.
    if ! cat -- "$tmp" > "$target" 2>/dev/null; then
        if ! mv -f -- "$tmp" "$target"; then
            [[ -n "$backup" ]] && cp -p -- "$backup" "$target" 2>/dev/null || true
            rm -f -- "$tmp"
            die3 "Cannot write '${target}'. The previous version was restored."
        fi
    fi
    [[ -n "$mode" ]] && chmod "$mode" -- "$target" 2>/dev/null || true
    rm -f -- "$tmp"
    info "Installed ctf v${rv} → ${target}"

    # Keep sibling release files in sync when they already exist next to us.
    dir="$(dirname -- "$target")"
    for sibling in VERSION ctf.ps1 ctf.bat; do
        sib_path="${dir}/${sibling}"
        [[ -f "$sib_path" ]] || continue
        if http_get "${base}/${sibling}" > "${sib_path}.new" 2>/dev/null && [[ -s "${sib_path}.new" ]]; then
            if mv -f -- "${sib_path}.new" "$sib_path"; then info "Updated ${sibling}"; else rm -f -- "${sib_path}.new"; fi
        else
            rm -f -- "${sib_path}.new"
            warn "Could not update ${sibling}."
        fi
    done
    return 0
}

###############################################################################
# 12. Configuration file: VAR=VALUE only, CTF_* whitelist, no code execution
###############################################################################

readonly CTF_CONFIG_VARS=' CTF_SRC_DIR CTF_OUT_FILE CTF_FORMAT CTF_HEADING_LEVEL CTF_PATH_STYLE
CTF_SORT CTF_TITLE CTF_HEADER CTF_SUMMARY CTF_TIMESTAMP CTF_TOC CTF_METADATA CTF_LINE_NUMBERS
CTF_LANG_STYLE CTF_STRIP_BOM CTF_TRUNCATE_LINES CTF_TOKEN_BUDGET CTF_BUDGET_ACTION CTF_DEDUP
CTF_DEFAULT_EXCLUDES CTF_MAX_DEPTH CTF_FOLLOW CTF_MAX_SIZE CTF_MIN_SIZE CTF_GIT_MODE
CTF_BINARY_MODE CTF_STRICT CTF_COLOR CTF_QUIET CTF_VERBOSE CTF_UPDATE_CHANNEL CTF_UPDATE_TIMEOUT '

config_var_allowed() { [[ "$CTF_CONFIG_VARS" == *" $1 "* ]]; }

load_config() {
    local f="$1" line key val perms g o
    [[ -n "$f" ]] || return 0
    [[ -f "$f" ]] || die2 "Config file '$f' does not exist."
    [[ -r "$f" ]] || die2 "Config file '$f' is not readable."
    perms="$(stat_mode "$f")"
    if [[ -n "$perms" && ${#perms} -ge 2 ]]; then
        g="${perms: -2:1}"; o="${perms: -1}"
        case "$g$o" in
            *[2367]*) warn "Config '$f' is group/world writable (mode ${perms}) — ignored for safety."
                      return 0 ;;
        esac
    fi
    verb "loading config: $f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue
        line="${line#export }"
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            warn "Config line ignored (not VAR=VALUE): ${line:0:60}"; continue
        fi
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        if ! config_var_allowed "$key"; then
            warn "Config variable ignored (not in the CTF_* whitelist): ${key}"; continue
        fi
        if [[ "$val" == '"'*'"' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
        elif [[ "$val" == "'"*"'" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
        # shellcheck disable=SC2016  # these are literal characters, not expansions
        case "$val" in
            *'$('*|*"$BACKTICK"*|*';'*|*'|'*|*'&'*|*'>'*|*'<'*|*'$'*|*'`'*)
                warn "Config value rejected (shell metacharacters): ${key}"; continue ;;
        esac
        printf -v "$key" '%s' "$val"
        [[ "$key" == CTF_SRC_DIR ]] && CTF_SRC_SET=1
        [[ "$key" == CTF_OUT_FILE ]] && CTF_OUT_FILE="$val"
        verb "config: ${key}=${val}"
    done < "$f"
    return 0
}

print_config() {
    local ifs_save="$IFS"
    printf 'script            %s v%s\n' "$CTF_SCRIPT_NAME" "$CTF_SCRIPT_VERSION"
    printf 'path              %s\n' "$CTF_SCRIPT_PATH"
    IFS=,;   printf 'ext               %s\n' "$( (( ${#CTF_EXTS[@]} > 0 )) && printf '%s' "${CTF_EXTS[*]}" || printf '*' )"; IFS="$ifs_save"
    printf 'source            %s\n' "$CTF_SRC_DIR"
    printf 'output            %s\n' "${CTF_OUT_FILE:-<default>}"
    printf 'format            %s\n' "$CTF_FORMAT"
    printf 'title             %s\n' "$CTF_TITLE"
    printf 'git-mode          %s\n' "${CTF_GIT_MODE:-<find>}"
    printf 'follow-symlinks   %s\n' "$CTF_FOLLOW"
    printf 'max-depth         %s\n' "$CTF_MAX_DEPTH"
    printf 'max-size          %s\n' "${CTF_MAX_SIZE:-<none>}"
    printf 'min-size          %s\n' "${CTF_MIN_SIZE:-<none>}"
    printf 'binary-mode       %s\n' "$CTF_BINARY_MODE"
    printf 'default-excludes  %s\n' "$CTF_DEFAULT_EXCLUDES"
    IFS='|'; printf 'include           %s\n' "${CTF_INCLUDE[*]-}"
    printf 'exclude           %s\n' "${CTF_EXCLUDE[*]-}"
    printf 'exclude-dir       %s\n' "${CTF_EXCLUDE_DIRS[*]-}"; IFS="$ifs_save"
    printf 'sort              %s\n' "$CTF_SORT"
    printf 'toc               %s\n' "$CTF_TOC"
    printf 'metadata          %s\n' "$CTF_METADATA"
    printf 'line-numbers      %s\n' "$CTF_LINE_NUMBERS"
    printf 'lang-style        %s\n' "$CTF_LANG_STYLE"
    printf 'strip-bom         %s\n' "$CTF_STRIP_BOM"
    printf 'truncate-lines    %s\n' "$CTF_TRUNCATE_LINES"
    printf 'token-budget      %s\n' "$CTF_TOKEN_BUDGET"
    printf 'budget-action     %s\n' "$CTF_BUDGET_ACTION"
    printf 'dedup             %s\n' "$CTF_DEDUP"
    printf 'strict            %s\n' "$CTF_STRICT"
    printf 'timestamp         %s\n' "$CTF_TIMESTAMP"
    printf 'color             %s\n' "$CTF_COLOR"
    printf 'update-channel    %s\n' "$CTF_UPDATE_CHANNEL"
    printf 'update-base       %s\n' "$CTF_RAW_BASE"
    printf 'update-timeout    %s\n' "$CTF_UPDATE_TIMEOUT"
    printf 'tools             awk=%d file=%d od=%d find=%d git=%d curl=%d wget=%d python3=%d perl=%d\n' \
        "$CTF_HAVE_AWK" "$CTF_HAVE_FILE" "$CTF_HAVE_OD" "$CTF_HAVE_FIND" "$CTF_HAVE_GIT" \
        "$CTF_HAVE_CURL" "$CTF_HAVE_WGET" "$CTF_HAVE_PY3" "$CTF_HAVE_PERL"
    printf '                  sha256sum=%d stat_c=%d stat_f=%d stat_printf=%d grep_IZ=%d\n' \
        "$CTF_HAVE_SHA256SUM" "$CTF_HAVE_STAT_C" "$CTF_HAVE_STAT_F" \
        "$CTF_HAVE_STAT_PRINTF" "$CTF_HAVE_GREP_IZ"
}

###############################################################################
# 13. Argument parsing
###############################################################################

need_val() { [[ -n "${2:-}" ]] || die2 "Option $1 requires a value."; }

append_list() { # append_list <exts|xdirs> <comma-list>
    local -a parts=()
    local p save="$IFS"
    IFS=',' read -r -a parts <<< "$2"
    IFS="$save"
    for p in ${parts[@]+"${parts[@]}"}; do
        p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] || continue
        case "$1" in
            exts)  CTF_EXTS+=("$p") ;;
            xdirs) CTF_EXCLUDE_DIRS+=("$p") ;;
        esac
    done
}

parse_args() {
    local -a positional=()
    local ext
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)              usage; exit "$EX_OK" ;;
            -V|--version)           printf 'ctf v%s\n' "$CTF_SCRIPT_VERSION"; exit "$EX_OK" ;;
            --)                     shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            -e|--ext)               need_val "$1" "${2:-}"; append_list exts "$2"; shift 2 ;;
            --ext=*)                append_list exts "${1#*=}"; shift ;;
            -E|--exclude)           need_val "$1" "${2:-}"; CTF_EXCLUDE+=("$2"); shift 2 ;;
            --exclude=*)            CTF_EXCLUDE+=("${1#*=}"); shift ;;
            -I|--include)           need_val "$1" "${2:-}"; CTF_INCLUDE+=("$2"); shift 2 ;;
            --include=*)            CTF_INCLUDE+=("${1#*=}"); shift ;;
            --exclude-dir)          need_val "$1" "${2:-}"; append_list xdirs "$2"; shift 2 ;;
            --exclude-dir=*)        append_list xdirs "${1#*=}"; shift ;;
            --no-default-excludes)  CTF_DEFAULT_EXCLUDES=0; shift ;;
            --list-default-excludes) CTF_LIST_DEFAULT_EXCLUDES=1; shift ;;
            -d|--max-depth)         need_val "$1" "${2:-}"; CTF_MAX_DEPTH="$2"; shift 2 ;;
            --max-depth=*)          CTF_MAX_DEPTH="${1#*=}"; shift ;;
            -L|--follow)            CTF_FOLLOW=1; shift ;;
            --max-size)             need_val "$1" "${2:-}"; CTF_MAX_SIZE="$(parse_size "$2")"; shift 2 ;;
            --max-size=*)           CTF_MAX_SIZE="$(parse_size "${1#*=}")"; shift ;;
            --min-size)             need_val "$1" "${2:-}"; CTF_MIN_SIZE="$(parse_size "$2")"; shift 2 ;;
            --min-size=*)           CTF_MIN_SIZE="$(parse_size "${1#*=}")"; shift ;;
            --files-from)           need_val "$1" "${2:-}"; CTF_FILES_FROM+=("$2"); shift 2 ;;
            --files-from=*)         CTF_FILES_FROM+=("${1#*=}"); shift ;;
            --git)                  need_val "$1" "${2:-}"; CTF_GIT_MODE="$2"; shift 2 ;;
            --git=*)                CTF_GIT_MODE="${1#*=}"; shift ;;
            --binary)               need_val "$1" "${2:-}"; CTF_BINARY_MODE="$2"; shift 2 ;;
            --binary=*)             CTF_BINARY_MODE="${1#*=}"; shift ;;
            -o|--output)            need_val "$1" "${2:-}"; CTF_OUT_FILE="$2"; shift 2 ;;
            --output=*)             CTF_OUT_FILE="${1#*=}"; shift ;;
            -F|--format)            need_val "$1" "${2:-}"; CTF_FORMAT="$2"; shift 2 ;;
            --format=*)             CTF_FORMAT="${1#*=}"; shift ;;
            --heading-level)        need_val "$1" "${2:-}"; CTF_HEADING_LEVEL="$2"; shift 2 ;;
            --heading-level=*)      CTF_HEADING_LEVEL="${1#*=}"; shift ;;
            --path-style)           need_val "$1" "${2:-}"; CTF_PATH_STYLE="$2"; shift 2 ;;
            --path-style=*)         CTF_PATH_STYLE="${1#*=}"; shift ;;
            --sort)                 need_val "$1" "${2:-}"; CTF_SORT="$2"; shift 2 ;;
            --sort=*)               CTF_SORT="${1#*=}"; shift ;;
            --title)                need_val "$1" "${2:-}"; CTF_TITLE="$2"; shift 2 ;;
            --title=*)              CTF_TITLE="${1#*=}"; shift ;;
            --no-header)            CTF_HEADER=0; shift ;;
            --no-summary)           CTF_SUMMARY=0; shift ;;
            --no-timestamp)         CTF_TIMESTAMP=0; shift ;;
            --toc)                  CTF_TOC=1; shift ;;
            --metadata)             CTF_METADATA=1; shift ;;
            --line-numbers)         CTF_LINE_NUMBERS=1; shift ;;
            --lang-style)           need_val "$1" "${2:-}"; CTF_LANG_STYLE="$2"; shift 2 ;;
            --lang-style=*)         CTF_LANG_STYLE="${1#*=}"; shift ;;
            --strip-bom)            CTF_STRIP_BOM=1; shift ;;
            --truncate-lines)       need_val "$1" "${2:-}"; CTF_TRUNCATE_LINES="$2"; shift 2 ;;
            --truncate-lines=*)     CTF_TRUNCATE_LINES="${1#*=}"; shift ;;
            --token-budget)         need_val "$1" "${2:-}"; CTF_TOKEN_BUDGET="$2"; shift 2 ;;
            --token-budget=*)       CTF_TOKEN_BUDGET="${1#*=}"; shift ;;
            --budget-action)        need_val "$1" "${2:-}"; CTF_BUDGET_ACTION="$2"; shift 2 ;;
            --budget-action=*)      CTF_BUDGET_ACTION="${1#*=}"; shift ;;
            --dedup)                CTF_DEDUP=1; shift ;;
            -n|--dry-run)           CTF_DRY_RUN=1; shift ;;
            --stats)                CTF_STATS=1; shift ;;
            --strict)               CTF_STRICT=1; shift ;;
            -c|--config)            need_val "$1" "${2:-}"; CTF_CONFIG_FILE="$2"; shift 2 ;;
            --config=*)             CTF_CONFIG_FILE="${1#*=}"; shift ;;
            --print-config)         CTF_PRINT_CONFIG=1; shift ;;
            -q|--quiet)             CTF_QUIET=1; shift ;;
            -v|--verbose)           CTF_VERBOSE=1; shift ;;
            --color)                need_val "$1" "${2:-}"; CTF_COLOR="$2"; shift 2 ;;
            --color=*)              CTF_COLOR="${1#*=}"; shift ;;
            --check-update)         CTF_DO_CHECK_UPDATE=1; shift ;;
            --update)               CTF_DO_UPDATE=1; shift ;;
            --update-channel)       need_val "$1" "${2:-}"; CTF_UPDATE_CHANNEL="$2"; shift 2 ;;
            --update-channel=*)     CTF_UPDATE_CHANNEL="${1#*=}"; shift ;;
            --update-force)         CTF_UPDATE_FORCE=1; shift ;;
            --update-timeout)       need_val "$1" "${2:-}"; CTF_UPDATE_TIMEOUT="$2"; shift 2 ;;
            --update-timeout=*)     CTF_UPDATE_TIMEOUT="${1#*=}"; shift ;;
            -*)                     die2 "Unknown option: $1 (try --help)" ;;
            *)                      positional+=("$1"); shift ;;
        esac
    done

    (( ${#positional[@]} <= 3 )) \
        || die2 "Too many positional arguments (max 3: EXTENSION SOURCE_DIR OUTPUT_FILE)."

    # Positional arguments fill the slots EXTENSION, SOURCE_DIR, OUTPUT_FILE in
    # that order, but only slots that no explicit option has already filled.
    # So `-e php src/` means "extension php, source src/", not "extension php,
    # extension src/". Documented in --help and covered by tests/test_cli.sh.
    # Slot filling. A positional that names an existing directory can only be
    # SOURCE_DIR, so `ctf ./src` and `ctf --dedup ./src` work as expected while
    # `ctf php ./src out.md` keeps the legacy EXT/SRC/OUT meaning.
    local ext_filled=0 src_filled="$CTF_SRC_SET" out_filled=0
    [[ -n "$CTF_OUT_FILE" ]] && out_filled=1
    (( ${#CTF_EXTS[@]} > 0 )) && ext_filled=1
    for ext in ${positional[@]+"${positional[@]}"}; do
        if (( ! src_filled )) && [[ -d "$ext" ]]; then
            CTF_SRC_DIR="$ext"; src_filled=1; continue
        fi
        if (( ! ext_filled )); then
            if [[ -n "$ext" && "$ext" != '*' && "$ext" != '.*' ]]; then append_list exts "$ext"; fi
            ext_filled=1; continue
        fi
        if (( ! src_filled )); then CTF_SRC_DIR="$ext"; src_filled=1; continue; fi
        if (( ! out_filled )); then CTF_OUT_FILE="$ext"; out_filled=1; continue; fi
        die2 "Unexpected extra argument: '$ext'."
    done
    return 0
}

###############################################################################
# 14. Validation
###############################################################################

validate() {
    local e clean spec joined
    local -a norm=()
    for e in ${CTF_EXTS[@]+"${CTF_EXTS[@]}"}; do
        clean="$e"
        while [[ "$clean" == .* ]]; do clean="${clean#.}"; done
        [[ -n "$clean" ]] || continue
        if [[ "$clean" == */* || "$clean" == *[[:space:]]* || "$clean" == *'*'* \
           || "$clean" == *'?'* || "$clean" == *'['* || "$clean" == *']'* ]]; then
            die2 "Invalid extension '$e'. Use a simple extension without path or wildcard characters."
        fi
        norm+=("${clean,,}")
    done
    CTF_EXTS=(${norm[@]+"${norm[@]}"})

    case "$CTF_BINARY_MODE"  in auto|never|always) ;; *) die2 "--binary accepts auto|never|always." ;; esac
    case "$CTF_FORMAT"       in md|markdown) CTF_FORMAT='md' ;; json|jsonl) ;; txt|text) CTF_FORMAT='txt' ;; *) die2 "--format accepts md|json|jsonl|txt." ;; esac
    case "$CTF_PATH_STYLE"   in rel|abs) ;; *) die2 "--path-style accepts rel|abs." ;; esac
    case "$CTF_SORT"         in path|name|size|mtime) ;; *) die2 "--sort accepts path|name|size|mtime." ;; esac
    case "$CTF_LANG_STYLE"   in fenced|indent4|none) ;; *) die2 "--lang-style accepts fenced|indent4|none." ;; esac
    case "$CTF_BUDGET_ACTION" in truncate|drop) ;; *) die2 "--budget-action accepts truncate|drop." ;; esac
    [[ "$CTF_UPDATE_CHANNEL" =~ ^[A-Za-z0-9._/-]+$ ]] || die2 "Invalid --update-channel '$CTF_UPDATE_CHANNEL'."
    [[ "$CTF_MAX_DEPTH"      =~ ^[0-9]+$ ]] || die2 "--max-depth must be a non-negative integer."
    [[ "$CTF_HEADING_LEVEL"  =~ ^[1-6]$   ]] || die2 "--heading-level must be between 1 and 6."
    [[ "$CTF_TRUNCATE_LINES" =~ ^[0-9]+$ ]] || die2 "--truncate-lines must be a non-negative integer."
    [[ "$CTF_TOKEN_BUDGET"   =~ ^[0-9]+$ ]] || die2 "--token-budget must be a non-negative integer."
    [[ "$CTF_UPDATE_TIMEOUT" =~ ^[0-9]+$ ]] || die2 "--update-timeout must be a non-negative integer."
    color_setup "$CTF_COLOR" || die2 "--color accepts auto|always|never."

    if [[ -n "$CTF_GIT_MODE" ]]; then
        case "$CTF_GIT_MODE" in tracked|all) ;; *) die2 "--git accepts tracked|all." ;; esac
        (( CTF_HAVE_GIT )) || die2 "--git requires git(1)."
    fi
    (( CTF_HAVE_AWK )) || die "Required command 'awk' is not available."
    if (( ${#CTF_FILES_FROM[@]} == 0 )) && [[ -z "$CTF_GIT_MODE" ]]; then
        (( CTF_HAVE_FIND )) || die "Required command 'find' is not available."
    fi
    if (( CTF_DEDUP )) && ! (( CTF_HAVE_SHA256SUM || CTF_HAVE_SHASUM )); then
        warn "No sha256sum/shasum found — --dedup cannot detect duplicates."
    fi

    [[ -n "$CTF_SRC_DIR" ]] || CTF_SRC_DIR='.'
    [[ -d "$CTF_SRC_DIR" ]] || die2 "Source directory '$CTF_SRC_DIR' does not exist or is not a directory."
    [[ -r "$CTF_SRC_DIR" && -x "$CTF_SRC_DIR" ]] || die2 "Source directory '$CTF_SRC_DIR' is not readable/searchable."
    CTF_SRC_ABS="$(cd -- "$CTF_SRC_DIR" 2>/dev/null && pwd -P)" || die "Cannot resolve source directory '$CTF_SRC_DIR'."
    for spec in ${CTF_FILES_FROM[@]+"${CTF_FILES_FROM[@]}"}; do
        [[ "$spec" == '-' || -r "$spec" ]] || die2 "--files-from: cannot read '$spec'."
    done
    build_exclude_dir_globs
    return 0
}

resolve_output() {
    local d b joined
    if [[ -z "$CTF_OUT_FILE" ]] && (( ! CTF_STATS )) && (( ! CTF_DRY_RUN )); then
        if (( ${#CTF_EXTS[@]} == 1 )); then
            CTF_OUT_FILE="all-${CTF_EXTS[0]}-files.md"
        elif (( ${#CTF_EXTS[@]} > 1 )); then
            joined="${CTF_EXTS[0]}"
            for b in "${CTF_EXTS[@]:1}"; do joined="${joined}-${b}"; done
            CTF_OUT_FILE="all-${joined}-files.md"
        else
            CTF_OUT_FILE='All-Project-Files.md'
        fi
        case "$CTF_FORMAT" in
            json)  CTF_OUT_FILE="${CTF_OUT_FILE%.md}.json" ;;
            jsonl) CTF_OUT_FILE="${CTF_OUT_FILE%.md}.jsonl" ;;
            txt)   CTF_OUT_FILE="${CTF_OUT_FILE%.md}.txt" ;;
        esac
    fi
    [[ -z "$CTF_OUT_FILE" || "$CTF_OUT_FILE" == '-' ]] && return 0
    [[ "$CTF_OUT_FILE" == */ ]] && die2 "Output file '$CTF_OUT_FILE' must not end with '/'."
    [[ -d "$CTF_OUT_FILE" ]] && die2 "Output path '$CTF_OUT_FILE' is a directory."
    d="$(dirname -- "$CTF_OUT_FILE")"; b="$(basename -- "$CTF_OUT_FILE")"
    [[ -n "$b" && "$b" != '.' && "$b" != '..' ]] || die2 "Invalid output file name '$CTF_OUT_FILE'."
    [[ -d "$d" ]] || die2 "Output directory '$d' does not exist."
    [[ -w "$d" ]] || die2 "Output directory '$d' is not writable."
    CTF_OUT_DIR_ABS="$(cd -- "$d" 2>/dev/null && pwd -P)" || die "Cannot resolve output directory '$d'."
    if [[ "$CTF_OUT_DIR_ABS" == '/' ]]; then CTF_OUT_ABS="/${b}"; else CTF_OUT_ABS="${CTF_OUT_DIR_ABS}/${b}"; fi
    if [[ -e "$CTF_OUT_ABS" || -L "$CTF_OUT_ABS" ]]; then
        if [[ ! -f "$CTF_OUT_ABS" && ! -L "$CTF_OUT_ABS" ]]; then
            die2 "Output path '$CTF_OUT_ABS' exists and is not a regular file or symlink."
        fi
        [[ -w "$CTF_OUT_ABS" ]] || die "Output file '$CTF_OUT_ABS' exists but is not writable."
        warn "Output file '$CTF_OUT_FILE' exists — overwriting."
    fi
    return 0
}

###############################################################################
# 15b. Batched metadata
#
#   Process creation dominates the runtime on a large tree: a per-file
#   `stat` + `od | awk` + `awk` costs three to four forks per file, which
#   measured ~20 ms/file in a container. All three are batched here, so the
#   per-file cost drops to the single `cat` that copies the content.
#
#   Every batch emits NUL-separated records with the numbers FIRST and the path
#   LAST, because a path may legally contain TAB, space or newline but never NUL.
###############################################################################

CTF_BATCH_FILES=200          # max files per child process
CTF_BATCH_ARGV_BYTES=90000   # max accumulated path length per child process

declare -A CTF_SIZE_CACHE=()
declare -A CTF_MTIME_CACHE=()
declare -A CTF_TEXT_CACHE=()
declare -A CTF_SCAN_CACHE=()

cached_size() {
    local f="$1"
    if [[ -n "${CTF_SIZE_CACHE[$f]+set}" ]]; then printf '%s' "${CTF_SIZE_CACHE[$f]}"; return 0; fi
    stat_size "$f"
}

batched_mtime() {
    local f="$1"
    if [[ -n "${CTF_MTIME_CACHE[$f]+set}" ]]; then printf '%s' "${CTF_MTIME_CACHE[$f]}"; return 0; fi
    stat_mtime "$f"
}

# bash 4.2 has no namerefs, so batches are driven by index ranges over a global
# source array instead of by passing arrays by reference.
declare -a CTF_BATCH=()
declare -a CTF_BATCH_SRC=()
batch_ranges() { # batch_ranges -> prints "from to" pairs, one per line
    local n="${#CTF_BATCH_SRC[@]}" i=0 from bytes
    while (( i < n )); do
        from=$i; bytes=0
        while (( i < n )); do
            bytes=$(( bytes + ${#CTF_BATCH_SRC[i]} + 1 ))
            i=$(( i + 1 ))
            (( i - from >= CTF_BATCH_FILES )) && break
            (( bytes >= CTF_BATCH_ARGV_BYTES )) && break
        done
        printf '%d %d\n' "$from" "$(( i - 1 ))"
    done
}

fill_batch() { # fill_batch <from> <to>
    local from="$1" to="$2" i
    CTF_BATCH=()
    for (( i = from; i <= to; i++ )); do CTF_BATCH+=("${CTF_BATCH_SRC[i]}"); done
}

# --- sizes -------------------------------------------------------------------
batch_sizes() { # batch_sizes <file...> ; fills CTF_SIZE_CACHE
    CTF_BATCH_SRC=("$@")
    local from to rec size path range
    while read -r range; do
        from="${range% *}"; to="${range#* }"
        fill_batch "$from" "$to"
        if (( CTF_HAVE_STAT_PRINTF )); then
            while IFS= read -r -d '' rec; do
                size="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
                [[ "$size" =~ ^[0-9]+$ ]] && CTF_SIZE_CACHE["$path"]="$size"
            done < <(stat --printf '%s\t%n\0' -- "${CTF_BATCH[@]}" 2>/dev/null)
        else
            local f
            for f in ${CTF_BATCH[@]+"${CTF_BATCH[@]}"}; do
                CTF_SIZE_CACHE["$f"]="$(stat_size "$f")"
            done
        fi
    done < <(batch_ranges)
}

batch_mtimes() { # batch_mtimes <file...> ; fills CTF_MTIME_CACHE
    CTF_BATCH_SRC=("$@")
    local from to rec mtime path range f
    while read -r range; do
        from="${range% *}"; to="${range#* }"
        fill_batch "$from" "$to"
        if (( CTF_HAVE_STAT_PRINTF )); then
            while IFS= read -r -d '' rec; do
                mtime="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
                [[ "$mtime" =~ ^[0-9]+$ ]] && CTF_MTIME_CACHE["$path"]="$mtime"
            done < <(stat --printf '%Y\t%n\0' -- "${CTF_BATCH[@]}" 2>/dev/null)
        else
            for f in ${CTF_BATCH[@]+"${CTF_BATCH[@]}"}; do
                CTF_MTIME_CACHE["$f"]="$(stat_mtime "$f")"
            done
        fi
    done < <(batch_ranges)
}

# --- binary classification ---------------------------------------------------
# grep -IlZ '' lists exactly the files it considers text (an empty pattern
# matches any line, so a file is listed iff it has at least one line and grep
# did not classify it as binary). Zero-byte files are text by definition and are
# handled explicitly, because grep never lists a file with no lines.
batch_binary() { # batch_binary <file...> ; fills CTF_TEXT_CACHE (1 = text)
    CTF_BATCH_SRC=("$@")
    local from to range path
    while read -r range; do
        from="${range% *}"; to="${range#* }"
        fill_batch "$from" "$to"
        if (( CTF_HAVE_GREP_IZ )); then
            while IFS= read -r -d '' path; do
                [[ -n "$path" ]] && CTF_TEXT_CACHE["$path"]=1
            done < <(grep -IlZ '' -- "${CTF_BATCH[@]}" 2>/dev/null)
        else
            local f
            for f in ${CTF_BATCH[@]+"${CTF_BATCH[@]}"}; do
                is_binary "$f" || CTF_TEXT_CACHE["$f"]=1
            done
        fi
    done < <(batch_ranges)
    # Zero-byte files are text; grep cannot list them.
    local f sz
    for f in "$@"; do
        [[ -n "${CTF_TEXT_CACHE[$f]+set}" ]] && continue
        sz="${CTF_SIZE_CACHE[$f]:-}"
        [[ -z "$sz" ]] && sz="$(stat_size "$f")"
        (( sz == 0 )) && CTF_TEXT_CACHE["$f"]=1
    done
    return 0
}

CTF_BINARY_CTRL_PCT="${CTF_BINARY_CTRL_PCT:-5}"

# A file is text when BOTH batched signals say so:
#   * grep -I listed it  -> no NUL byte in the scanned buffer;
#   * control-byte share <= CTF_BINARY_CTRL_PCT % -> not random/structured binary.
# When grep -I/-Z is unavailable, CTF_TEXT_CACHE stays empty for the file and we
# fall back to the per-file od|awk scan in is_binary().
is_text_cached() { # 0 = text, 1 = binary
    local f="$1" scan lines mb mt bsum ctrl
    case "$CTF_BINARY_MODE" in
        never)  return 0 ;;
        always) return 1 ;;
    esac
    if (( CTF_HAVE_GREP_IZ )); then
        # Not listed by grep -I  =>  the file contains a NUL byte  =>  binary.
        [[ -n "${CTF_TEXT_CACHE[$f]+set}" ]] || return 1
        scan="${CTF_SCAN_CACHE[$f]:-}"
        if [[ -n "$scan" ]]; then
            read -r lines mb mt bsum ctrl <<< "$scan"
            [[ "$ctrl" =~ ^[0-9]+$ ]] || ctrl=0
            [[ "$bsum" =~ ^[0-9]+$ ]] || bsum=0
            if (( bsum > 0 )) && (( ctrl * 100 > bsum * CTF_BINARY_CTRL_PCT )); then
                return 1
            fi
        fi
        return 0
    fi
    if is_binary "$f"; then return 1; fi
    return 0
}

# --- lines / fence runs / byte sum ------------------------------------------
# One awk process per batch. Numbers first, path last, NUL-separated.
batch_scan() { # batch_scan <file...> ; fills CTF_SCAN_CACHE="lines mb mt bsum ctrl"
    CTF_BATCH_SRC=("$@")
    local from to range rec nums path
    while read -r range; do
        from="${range% *}"; to="${range#* }"
        fill_batch "$from" "$to"
        # Record layout: "<lines> <mb> <mt> <bsum> <ctrl>" TAB "<path>" NUL.
        # The five numbers share ONE tab-separated field so that a path
        # containing tabs stays intact; NUL cannot occur in a path.
        # NOTE: awk options must precede the program text, otherwise awk treats
        # them as file operands and the batch silently produces nothing.
        while IFS= read -r -d '' rec; do
            nums="${rec%%$'\t'*}"
            path="${rec#*$'\t'}"
            [[ -n "$path" ]] && CTF_SCAN_CACHE["$path"]="$nums"
        done < <(awk -v b="$(printf '\140')" -v t='~' '
            function flush(   ) {
                if (started) printf "%d %d %d %d %d\t%s%c", lines, mb, mt, sum + lines, ctrl, prev, 0
            }
            FILENAME != prev {
                flush()
                prev = FILENAME; started = 1
                lines = 0; mb = 0; mt = 0; sum = 0; ctrl = 0
            }
            {
                lines++
                sum += length($0)
                tmp = $0
                ctrl += gsub(/[\001-\010\016-\037\177]/, "", tmp)
                line = $0
                sp = 0
                while (sp < 3 && substr(line, sp + 1, 1) == " ") sp++
                line = substr(line, sp + 1)
                c = substr(line, 1, 1)
                if (c == b || c == t) {
                    k = 0
                    while (substr(line, k + 1, 1) == c) k++
                    if (substr(line, k + 1) == "") {
                        if (c == b) { if (k > mb) mb = k } else { if (k > mt) mt = k }
                    }
                }
            }
            END { flush() }
        ' "${CTF_BATCH[@]}" 2>/dev/null)
    done < <(batch_ranges)
    return 0
}

scan_cached() { # scan_cached <file> -> "lines mb mt bsum"
    local f="$1"
    if [[ -n "${CTF_SCAN_CACHE[$f]+set}" ]]; then printf '%s' "${CTF_SCAN_CACHE[$f]}"; return 0; fi
    scan_file "$f"
}

###############################################################################
# 15. Selection and sorting
###############################################################################

skip_count() {
    local r="$1"
    CTF_SKIPPED=$(( CTF_SKIPPED + 1 ))
    CTF_SKIP_COUNT["$r"]=$(( ${CTF_SKIP_COUNT["$r"]:-0} + 1 ))
}

# Sets CTF_RET instead of printing: one command substitution per file costs a
# subshell, and on a 10k-file tree that is seconds of pure fork overhead.
CTF_RET=''
rel_of() {
    if [[ "$CTF_SRC_ABS" == '/' ]]; then CTF_RET="${1#/}"
    else CTF_RET="${1#"$CTF_SRC_ABS"/}"; fi
}

declare -a CTF_KEPT=() CTF_KEPT_REL=()

select_files() {
    CTF_KEPT=(); CTF_KEPT_REL=()
    local f rel base size
    for f in ${CTF_FILES[@]+"${CTF_FILES[@]}"}; do
        if [[ -d "$f" ]]; then skip_count directory; continue; fi
        if [[ ! -e "$f" && ! -L "$f" ]]; then skip_count missing; verb "skip (missing): $f"; continue; fi
        if [[ -L "$f" ]] && (( ! CTF_FOLLOW )); then
            skip_count symlink; rel_of "$f"; verb "skip (symlink): $CTF_RET"; continue
        fi
        if [[ ! -f "$f" ]]; then skip_count non-regular; rel_of "$f"; verb "skip (non-regular): $CTF_RET"; continue; fi
        if [[ ! -r "$f" ]]; then skip_count unreadable; rel_of "$f"; warn "Skip (unreadable): $CTF_RET"; continue; fi
        rel_of "$f"; rel="$CTF_RET"; base="${rel##*/}"
        if is_own_temp_file "$f" "$base"; then
            skip_count temporary-file; verb "skip (own temporary file): $rel"; continue
        fi
        ext_match "$base" || { skip_count extension; verb "skip (extension): $rel"; continue; }
        keep_file "$rel"  || { skip_count "$CTF_DROP_REASON"; verb "skip (${CTF_DROP_REASON}): $rel"; continue; }
        size="${CTF_SIZE_CACHE[$f]:-}"
        [[ -n "$size" ]] || size="$(stat_size "$f")"
        if [[ -n "$CTF_MAX_SIZE" ]] && (( size > CTF_MAX_SIZE )); then
            skip_count too-large; verb "skip (${size} B exceeds --max-size): $rel"; continue
        fi
        if [[ -n "$CTF_MIN_SIZE" ]] && (( size < CTF_MIN_SIZE )); then
            skip_count too-small; verb "skip (${size} B below --min-size): $rel"; continue
        fi
        CTF_KEPT+=("$f"); CTF_KEPT_REL+=("$rel")
    done
}

# Sort by "key <TAB> index". TAB and LF inside a key are replaced by a space,
# because both would corrupt the two-column table (a file name may legally
# contain either). That affects the ORDER of such names only, never the set of
# collected files; the invariant "output count == input count" is asserted
# afterwards and a mismatch falls back to discovery order with a warning.
sort_key() {
    local k="$1"
    k="${k//$'\t'/ }"
    k="${k//$'\n'/ }"
    k="${k//$'\r'/ }"
    printf '%s' "$k"
}

sort_selection() {
    local n="${#CTF_KEPT[@]}" i key tmpf idx tab got=0
    (( n > 0 )) || return 0
    tab="$(printf '\t')"
    if (( CTF_HAVE_MKTEMP )); then
        tmpf="$(mktemp -- "${TMPDIR:-/tmp}/.ctf-sort.XXXXXX")" || tmpf="${TMPDIR:-/tmp}/.ctf-sort.$$"
    else
        tmpf="${TMPDIR:-/tmp}/.ctf-sort.$$"
    fi
    case "$CTF_SORT" in
        size)
            # Ключи: размер (по убыв.), затем путь (ordinal), затем индекс.
            # Третий ключ обязателен: без него файлы равного размера идут в
            # порядке выдачи find, который зависит от файловой системы.
            for (( i = 0; i < n; i++ )); do
                printf '%s\t%s\t%s\n' "$(cached_size "${CTF_KEPT[i]}")" "$(sort_key "${CTF_KEPT_REL[i]}")" "$i"
            done | sort -t "$tab" -k1,1nr -k2,2 -k3,3n | cut -f3 > "$tmpf" ;;
        mtime)
            for (( i = 0; i < n; i++ )); do
                printf '%s\t%s\t%s\n' "$(batched_mtime "${CTF_KEPT[i]}")" "$(sort_key "${CTF_KEPT_REL[i]}")" "$i"
            done | sort -t "$tab" -k1,1nr -k2,2 -k3,3n | cut -f3 > "$tmpf" ;;
        name)
            for (( i = 0; i < n; i++ )); do
                key="${CTF_KEPT_REL[i]##*/}"; printf '%s\t%s\n' "$(sort_key "$key")" "$i"
            done | sort -t "$tab" -k1,1 -k2,2n | cut -f2 > "$tmpf" ;;
        *)
            for (( i = 0; i < n; i++ )); do
                printf '%s\t%s\n' "$(sort_key "${CTF_KEPT_REL[i]}")" "$i"
            done | sort -t "$tab" -k1,1 -k2,2n | cut -f2 > "$tmpf" ;;
    esac
    CTF_SELECTED=(); CTF_REL=()
    while IFS= read -r idx; do
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        (( idx < n )) || continue
        CTF_SELECTED+=("${CTF_KEPT[idx]}")
        CTF_REL+=("${CTF_KEPT_REL[idx]}")
        got=$(( got + 1 ))
    done < "$tmpf"
    rm -f -- "$tmpf"
    if (( got != n )); then
        warn "Internal: sorting produced ${got} of ${n} entries; keeping discovery order."
        CTF_SELECTED=("${CTF_KEPT[@]}"); CTF_REL=("${CTF_KEPT_REL[@]}")
    fi
    return 0
}

###############################################################################
# 16. Temporary files and output assembly
###############################################################################

CTF_TMP_HEAD=''
CTF_TMP_BODY=''
CTF_TMP_FINAL=''

ctf_cleanup() {
    local f
    for f in "$CTF_TMP_HEAD" "$CTF_TMP_BODY" "$CTF_TMP_FINAL"; do
        [[ -n "$f" && -f "$f" ]] && rm -f -- "$f" 2>/dev/null || true
    done
    CTF_TMP_HEAD=''; CTF_TMP_BODY=''; CTF_TMP_FINAL=''
}

make_temps() {
    local dir="${CTF_OUT_DIR_ABS:-}"
    (( CTF_HAVE_MKTEMP )) || die "mktemp(1) is required."
    if [[ -z "$dir" || ! -d "$dir" || ! -w "$dir" ]]; then dir="${TMPDIR:-/tmp}"; fi
    CTF_TMP_HEAD="$(mktemp -- "${dir}/.ctf-head.XXXXXX")"  || die "Cannot create a temporary file in '$dir'."
    CTF_TMP_BODY="$(mktemp -- "${dir}/.ctf-body.XXXXXX")"  || die "Cannot create a temporary file in '$dir'."
    CTF_TMP_FINAL="$(mktemp -- "${dir}/.ctf-final.XXXXXX")" || die "Cannot create a temporary file in '$dir'."
    trap ctf_cleanup EXIT
}

###############################################################################
# 17. Emitters
###############################################################################

md_escape_cell() { printf '%s' "${1//|/\\|}"; }

# A file name may legally contain CR/LF (POSIX allows any byte but '/' and NUL).
# Such a name would break a Markdown heading, a TOC line and any TSV column, so
# it is flattened for display purposes only — the file itself is read verbatim.
sanitize_display() { # -> CTF_RET
    local s="$1"
    s="${s//$'\n'/␤}"
    s="${s//$'\r'/␤}"
    s="${s//$'\t'/ }"
    CTF_RET="$s"
}

heading_marks() { printf '%*s' "$1" '' | tr ' ' '#'; }

# GitHub anchor for the heading text "### `path`": lowercase, backticks and
# punctuation removed, spaces to hyphens.
# GitHub-style anchor for a heading text: lowercase, backticks and punctuation
# removed, spaces to hyphens. Returns via CTF_RET (no subshell in the hot path).
md_anchor() { # -> CTF_RET
    local s="$1"
    s="${s,,}"
    s="${s//$BACKTICK/}"
    s="${s//[^a-z0-9 _-]/}"
    s="${s// /-}"
    CTF_RET="$s"
}
md_anchor_print() { md_anchor "$1"; printf '%s' "$CTF_RET"; }

# emit_content FILE DEST [INDENT:0|1]
#   Honours --strip-bom, --truncate-lines and --line-numbers. Content is
#   appended to DEST, never passed through the shell, so arbitrary bytes and
#   file names are safe.
emit_content() {
    local f="$1" dest="$2" indent="${3:-0}" start=1 head3
    if (( CTF_STRIP_BOM )); then
        head3="$(head -c 3 -- "$f" 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' \n')"
        [[ "$head3" == efbbbf* ]] && start=4
    fi
    if (( CTF_LINE_NUMBERS )); then
        if (( CTF_TRUNCATE_LINES > 0 )); then
            tail -c "+${start}" -- "$f" | head -n "$CTF_TRUNCATE_LINES" \
                | awk '{ printf "%6d| %s\n", NR, $0 }' >> "$dest"
        else
            tail -c "+${start}" -- "$f" | awk '{ printf "%6d| %s\n", NR, $0 }' >> "$dest"
        fi
    elif (( indent )); then
        if (( CTF_TRUNCATE_LINES > 0 )); then
            tail -c "+${start}" -- "$f" | head -n "$CTF_TRUNCATE_LINES" | sed 's/^/    /' >> "$dest"
        else
            tail -c "+${start}" -- "$f" | sed 's/^/    /' >> "$dest"
        fi
    else
        if (( CTF_TRUNCATE_LINES > 0 )); then
            tail -c "+${start}" -- "$f" | head -n "$CTF_TRUNCATE_LINES" >> "$dest"
        elif (( start > 1 )); then
            tail -c "+${start}" -- "$f" >> "$dest"
        else
            cat -- "$f" >> "$dest"
        fi
    fi
    return 0
}

emit_header() {
    (( CTF_HEADER )) || return 0
    local ts='' h exts
    (( CTF_TIMESTAMP )) && ts="$(now_stamp)"
    if (( ${#CTF_EXTS[@]} > 0 )); then
        local ifs_save="$IFS"; IFS=,; exts="${CTF_EXTS[*]}"; IFS="$ifs_save"
    else
        exts='*'
    fi
    case "$CTF_FORMAT" in
      md)
        h="$(heading_marks $(( CTF_HEADING_LEVEL > 2 ? CTF_HEADING_LEVEL - 2 : 1 )))"
        {
            printf '%s %s\n\n' "$h" "$CTF_TITLE"
            printf '| Field | Value |\n|:------|:------|\n'
            [[ -n "$ts" ]] && printf '| Generated (UTC) | %s |\n' "$ts"
            printf '| Tool | %s v%s |\n' "$CTF_SCRIPT_NAME" "$CTF_SCRIPT_VERSION"
            printf '| Source | %s |\n' "$(md_escape_cell "$CTF_SRC_ABS")"
            printf '| Extensions | %s |\n' "$(md_escape_cell "$exts")"
            printf '| Candidates | %d |\n' "$CTF_TOTAL_CANDIDATES"
            printf '| Collected | %d |\n\n' "$CTF_WRITTEN"
            printf '%s\n\n' '---'
        } >> "$CTF_TMP_HEAD" ;;
      txt)
        {
            printf '%s\n' "$CTF_TITLE"
            [[ -n "$ts" ]] && printf 'generated: %s\n' "$ts"
            printf 'tool:      %s v%s\n' "$CTF_SCRIPT_NAME" "$CTF_SCRIPT_VERSION"
            printf 'source:    %s\n' "$CTF_SRC_ABS"
            printf 'collected: %d of %d candidate(s)\n\n' "$CTF_WRITTEN" "$CTF_TOTAL_CANDIDATES"
            printf '%s\n\n' '================================================================================'
        } >> "$CTF_TMP_HEAD" ;;
      json|jsonl) : ;;
    esac
    return 0
}

emit_toc() {
    (( CTF_TOC )) || return 0
    [[ "$CTF_FORMAT" == md ]] || return 0
    local rel shown anchor
    {
        printf '## Table of contents\n\n'
        for rel in ${CTF_REL_RENDERED[@]+"${CTF_REL_RENDERED[@]}"}; do
            sanitize_display "$rel"; shown="$CTF_RET"
            md_anchor "$shown"; anchor="$CTF_RET"
            # shellcheck disable=SC2016  # backticks are literal Markdown here
            printf -- '- [`%s`](#%s)\n' "$shown" "$anchor"
        done
        printf '\n%s\n\n' '---'
    } >> "$CTF_TMP_HEAD"
    return 0
}

emit_file_md() { # <abs> <rel> <lang> <fence> <bytes> <lines> <hash> <ends_nl> <budget_truncated>
    local f="$1" rel="$2" lang="$3" fence="$4" bytes="$5" lines="$6" hash="$7" ends_nl="$8"
    local budget_trunc="${9:-0}"
    local h="$CTF_HEAD_MARKS" shown meta indent=0
    shown="$rel"
    [[ "$CTF_PATH_STYLE" == abs ]] && shown="$f"
    sanitize_display "$shown"; shown="$CTF_RET"
    if [[ "$shown" == *"$BACKTICK"* ]]; then
        printf '%s %s\n\n' "$h" "$shown" >> "$CTF_TMP_BODY"
    else
        printf '%s %s%s%s\n\n' "$h" "$BACKTICK" "$shown" "$BACKTICK" >> "$CTF_TMP_BODY"
    fi
    if (( CTF_METADATA )); then
        meta="<!-- ${bytes} bytes · ${lines} lines · $(human_size "$bytes")"
        [[ -n "$hash" ]] && meta+=" · sha256:${hash:0:12}"
        printf '%s -->\n\n' "$meta" >> "$CTF_TMP_BODY"
    fi
    [[ "$CTF_LANG_STYLE" == indent4 ]] && indent=1
    case "$CTF_LANG_STYLE" in
        fenced)
            printf '%s%s\n' "$fence" "$lang" >> "$CTF_TMP_BODY"
            emit_content "$f" "$CTF_TMP_BODY" 0
            (( ends_nl )) || printf '\n' >> "$CTF_TMP_BODY"
            printf '%s\n\n' "$fence" >> "$CTF_TMP_BODY" ;;
        indent4|none)
            emit_content "$f" "$CTF_TMP_BODY" "$indent"
            (( ends_nl )) || printf '\n' >> "$CTF_TMP_BODY"
            printf '\n' >> "$CTF_TMP_BODY" ;;
    esac
    if (( budget_trunc )); then
        printf '%s\n\n' '<!-- truncated to fit the token budget -->' >> "$CTF_TMP_BODY"
    fi
    printf '%s\n\n' '---' >> "$CTF_TMP_BODY"
    return 0
}

emit_summary() {
    (( CTF_SUMMARY )) || return 0
    local reason
    case "$CTF_FORMAT" in
      md)
        {
            printf '## Summary\n\n'
            printf '| Metric | Value |\n|:-------|------:|\n'
            printf '| Candidates | %d |\n' "$CTF_TOTAL_CANDIDATES"
            printf '| Collected | %d |\n' "$CTF_WRITTEN"
            printf '| Skipped | %d |\n' "$CTF_SKIPPED"
            printf '| Source bytes | %d (%s) |\n' "$CTF_BYTES_IN" "$(human_size "$CTF_BYTES_IN")"
            printf '| Estimated tokens | %d |\n' "$CTF_TOKENS_EST"
            (( CTF_TRUNCATED_FILES > 0 )) && printf '| Truncated files | %d |\n' "$CTF_TRUNCATED_FILES"
            (( CTF_BUDGET_DROPPED  > 0 )) && printf '| Dropped by token budget | %d |\n' "$CTF_BUDGET_DROPPED"
            (( CTF_DUPLICATES      > 0 )) && printf '| Duplicates omitted | %d |\n' "$CTF_DUPLICATES"
        } >> "$CTF_TMP_BODY"
        if (( ${#CTF_SKIP_COUNT[@]} > 0 )); then
            {
                printf '\n**Skip reasons**\n\n| Reason | Count |\n|:-------|------:|\n'
                for reason in $(printf '%s\n' "${!CTF_SKIP_COUNT[@]}" | sort); do
                    printf '| %s | %d |\n' "$(md_escape_cell "$reason")" "${CTF_SKIP_COUNT[$reason]}"
                done
                printf '\n'
            } >> "$CTF_TMP_BODY"
        fi ;;
      txt)
        {
            printf '%s\n' '================================================================================'
            printf 'candidates=%d collected=%d skipped=%d source_bytes=%d est_tokens=%d\n' \
                "$CTF_TOTAL_CANDIDATES" "$CTF_WRITTEN" "$CTF_SKIPPED" "$CTF_BYTES_IN" "$CTF_TOKENS_EST"
        } >> "$CTF_TMP_BODY" ;;
    esac
    return 0
}

print_stats() {
    local reason
    printf 'candidates=%d\n' "$CTF_TOTAL_CANDIDATES"
    printf 'collected=%d\n' "$CTF_WRITTEN"
    printf 'skipped=%d\n' "$CTF_SKIPPED"
    printf 'source_bytes=%d\n' "$CTF_BYTES_IN"
    printf 'est_tokens=%d\n' "$CTF_TOKENS_EST"
    printf 'truncated_files=%d\n' "$CTF_TRUNCATED_FILES"
    printf 'budget_dropped=%d\n' "$CTF_BUDGET_DROPPED"
    printf 'duplicates=%d\n' "$CTF_DUPLICATES"
    for reason in $(printf '%s\n' "${!CTF_SKIP_COUNT[@]}" | sort); do
        printf 'skip_%s=%d\n' "${reason//[^A-Za-z0-9_]/_}" "${CTF_SKIP_COUNT[$reason]}"
    done
    return 0
}

###############################################################################
# 18. Render pass
###############################################################################

render() {
    local i f rel lang fence lines mb mt bsum ctrl bytes hash est ends_nl scan_rec
    local budget_left="$CTF_TOKEN_BUDGET" keep_lines avg_line allowed_bytes
    local save_trunc first=1 ctmp

    if [[ "$CTF_FORMAT" == json ]]; then
        printf '{"tool":"%s","version":"%s","source":"%s","generated":"%s","files":[' \
            "$(json_escape_str "$CTF_SCRIPT_NAME")" "$CTF_SCRIPT_VERSION" \
            "$(json_escape_str "$CTF_SRC_ABS")" \
            "$( (( CTF_TIMESTAMP )) && now_stamp || printf '' )" >> "$CTF_TMP_BODY"
    fi

    # Classify and scan the selected files in batches before rendering.
    if (( ${#CTF_SELECTED[@]} > 0 )); then
        batch_binary "${CTF_SELECTED[@]}"
        batch_scan   "${CTF_SELECTED[@]}"
    fi

    for i in "${!CTF_SELECTED[@]}"; do
        f="${CTF_SELECTED[i]}"; rel="${CTF_REL[i]}"
        bytes="${CTF_SIZE_CACHE[$f]:-}"
        [[ -n "$bytes" ]] || { bytes="$(stat_size "$f")"; CTF_SIZE_CACHE["$f"]="$bytes"; }

        if [[ -n "$CTF_OUT_ABS" && -e "$CTF_OUT_ABS" && "$f" -ef "$CTF_OUT_ABS" ]]; then
            skip_count output-file; warn "Skip (output file): $rel"; continue
        fi
        local tf
        for tf in "$CTF_TMP_HEAD" "$CTF_TMP_BODY" "$CTF_TMP_FINAL"; do
            [[ -n "$tf" && -e "$tf" && "$f" -ef "$tf" ]] && { skip_count temporary-file; continue 2; }
        done
        if ! is_text_cached "$f"; then skip_count binary; verb "skip (binary): $rel"; continue; fi

        hash=''
        if (( CTF_DEDUP )) || (( CTF_METADATA )); then hash="$(sha256_of "$f")"; fi
        if (( CTF_DEDUP )) && [[ -n "$hash" ]]; then
            if [[ -n "${CTF_SEEN_HASH[$hash]:-}" ]]; then
                CTF_DUPLICATES=$(( CTF_DUPLICATES + 1 ))
                skip_count duplicate; verb "skip (duplicate of ${CTF_SEEN_HASH[$hash]}): $rel"; continue
            fi
            CTF_SEEN_HASH["$hash"]="$rel"
        fi

        local scan_rec="${CTF_SCAN_CACHE[$f]:-}"
        [[ -n "$scan_rec" ]] || scan_rec="$(scan_file "$f")"
        read -r lines mb mt bsum ctrl <<< "$scan_rec"
        [[ "$ctrl" =~ ^[0-9]+$ ]] || ctrl=0
        [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
        [[ "$bsum"   =~ ^[0-9]+$ ]] || bsum=0
        ends_nl=1
        (( bytes > 0 && bsum != bytes )) && ends_nl=0

        est=$(( ( bytes + 3 ) / 4 ))
        keep_lines=0
        if (( CTF_TOKEN_BUDGET > 0 )); then
            if (( est > budget_left )); then
                if [[ "$CTF_BUDGET_ACTION" == drop ]] || (( budget_left <= 0 )); then
                    CTF_BUDGET_DROPPED=$(( CTF_BUDGET_DROPPED + 1 ))
                    skip_count token-budget; verb "skip (token budget): $rel"; continue
                fi
                allowed_bytes=$(( budget_left * 4 ))
                if (( lines > 0 && bsum > 0 )); then
                    avg_line=$(( bsum / lines )); (( avg_line < 1 )) && avg_line=1
                    keep_lines=$(( allowed_bytes / avg_line ))
                else
                    keep_lines=0
                fi
                (( keep_lines < 1 )) && keep_lines=1
                est=$(( budget_left ))
            fi
            budget_left=$(( budget_left - est ))
            (( budget_left < 0 )) && budget_left=0
        fi
        # В режимах --line-numbers и при обрезке по бюджету содержимое проходит
        # через awk/head, которые всегда завершают последнюю строку переводом,
        # поэтому компенсация «файл без \n в конце» давала лишнюю пустую строку.
        # Проверка стоит ПОСЛЕ блока бюджета: keep_lines к этому моменту задан
        # (обращение к нему раньше под set -u дало бы unbound variable).
        if (( CTF_LINE_NUMBERS )) || (( keep_lines > 0 )); then ends_nl=1; fi

        choose_fence "$mb" "$mt"; fence="$CTF_RET_FENCE"
        map_lang "$f"; lang="$CTF_RET_LANG"

        CTF_WRITTEN=$(( CTF_WRITTEN + 1 ))
        CTF_BYTES_IN=$(( CTF_BYTES_IN + bytes ))
        CTF_TOKENS_EST=$(( CTF_TOKENS_EST + est ))
        CTF_REL_RENDERED+=("$rel")
        if (( keep_lines > 0 && keep_lines < lines )); then
            CTF_TRUNCATED_FILES=$(( CTF_TRUNCATED_FILES + 1 ))
        fi

        if (( CTF_DRY_RUN )); then
            sanitize_display "$rel"
            printf '%s\t%s\t%s\t%s\t%s\n' "$CTF_RET" "$lang" "$bytes" "$lines" "${hash:0:12}"
            continue
        fi
        if (( CTF_STATS )); then continue; fi

        case "$CTF_FORMAT" in
            md)
                save_trunc="$CTF_TRUNCATE_LINES"
                if (( keep_lines > 0 )) && (( CTF_TRUNCATE_LINES == 0 || keep_lines < CTF_TRUNCATE_LINES )); then
                    CTF_TRUNCATE_LINES="$keep_lines"
                fi
                local btrunc=0
                (( keep_lines > 0 && keep_lines < lines )) && btrunc=1
                emit_file_md "$f" "$rel" "$lang" "$fence" "$bytes" "$lines" "$hash" "$ends_nl" "$btrunc"
                CTF_TRUNCATE_LINES="$save_trunc"
                ;;
            txt)
                sanitize_display "$rel"
                printf '===== %s (%s, %s) =====\n' "$CTF_RET" "$lang" "$(human_size "$bytes")" >> "$CTF_TMP_BODY"
                save_trunc="$CTF_TRUNCATE_LINES"
                (( keep_lines > 0 && CTF_TRUNCATE_LINES == 0 )) && CTF_TRUNCATE_LINES="$keep_lines"
                emit_content "$f" "$CTF_TMP_BODY" 0
                CTF_TRUNCATE_LINES="$save_trunc"
                (( ends_nl )) || printf '\n' >> "$CTF_TMP_BODY"
                printf '\n' >> "$CTF_TMP_BODY"
                ;;
            json|jsonl)
                if [[ "$CTF_FORMAT" == json ]]; then
                    (( first )) || printf ',' >> "$CTF_TMP_BODY"
                    first=0
                fi
                printf '{"path":"%s","lang":"%s","bytes":%d,"lines":%d' \
                    "$(json_escape_str "$rel")" "$(json_escape_str "$lang")" "$bytes" "$lines" >> "$CTF_TMP_BODY"
                [[ -n "$hash" ]] && printf ',"sha256":"%s"' "$hash" >> "$CTF_TMP_BODY"
                printf ',"content":"' >> "$CTF_TMP_BODY"
                save_trunc="$CTF_TRUNCATE_LINES"
                (( keep_lines > 0 && CTF_TRUNCATE_LINES == 0 )) && CTF_TRUNCATE_LINES="$keep_lines"
                if (( CTF_TRUNCATE_LINES > 0 )) || (( CTF_STRIP_BOM )); then
                    ctmp="${TMPDIR:-/tmp}/.ctf-json.$$"
                    emit_content "$f" "$ctmp" 0
                    json_escape_file "$ctmp" 1 >> "$CTF_TMP_BODY"
                    rm -f -- "$ctmp"
                else
                    json_escape_file "$f" "$ends_nl" >> "$CTF_TMP_BODY"
                fi
                CTF_TRUNCATE_LINES="$save_trunc"
                printf '"' >> "$CTF_TMP_BODY"
                if [[ "$CTF_FORMAT" == json ]]; then printf '}' >> "$CTF_TMP_BODY"
                else printf '}\n' >> "$CTF_TMP_BODY"; fi
                ;;
        esac
        verb "collected: $rel (${bytes} B, ${lines} lines)"
    done

    [[ "$CTF_FORMAT" == json ]] && printf ']}\n' >> "$CTF_TMP_BODY"
    return 0
}

finalize_output() {
    if (( CTF_DRY_RUN )) || (( CTF_STATS )); then return 0; fi
    cat -- "$CTF_TMP_HEAD" "$CTF_TMP_BODY" > "$CTF_TMP_FINAL" \
        || die "Cannot assemble the output document."
    CTF_BYTES_OUT="$(stat_size "$CTF_TMP_FINAL")"
    if [[ -z "$CTF_OUT_FILE" || "$CTF_OUT_FILE" == '-' ]]; then
        cat -- "$CTF_TMP_FINAL"
        return 0
    fi
    if [[ -L "$CTF_OUT_ABS" ]]; then
        cat -- "$CTF_TMP_FINAL" > "$CTF_OUT_ABS" || die "Cannot write output file '$CTF_OUT_ABS'."
    else
        mv -f -- "$CTF_TMP_FINAL" "$CTF_OUT_ABS" || die "Cannot finalize output file '$CTF_OUT_ABS'."
        CTF_TMP_FINAL=''
        # mktemp создаёт файл с mode 0600; у итогового документа права должны
        # соответствовать umask пользователя, иначе его не сможет прочитать никто.
        local um m
        um="$(umask 2>/dev/null || printf 022)"
        um=$(( 8#$um ))
        m=$(( 0666 & ~um ))
        chmod "$(printf '%03o' "$m")" -- "$CTF_OUT_ABS" 2>/dev/null || true
    fi
    return 0
}

###############################################################################
# 19. main
###############################################################################

main() {
    parse_args "$@"

    if (( CTF_LIST_DEFAULT_EXCLUDES )); then
        printf 'Default excluded directories (%d):\n' "${#CTF_DEFAULT_EXCLUDE_DIRS[@]}"
        printf '  %s\n' ${CTF_DEFAULT_EXCLUDE_DIRS[@]+"${CTF_DEFAULT_EXCLUDE_DIRS[@]}"}
        printf 'Default excluded file globs (%d):\n' "${#CTF_DEFAULT_EXCLUDE_GLOBS[@]}"
        printf '  %s\n' ${CTF_DEFAULT_EXCLUDE_GLOBS[@]+"${CTF_DEFAULT_EXCLUDE_GLOBS[@]}"}
        exit "$EX_OK"
    fi

    load_config "$CTF_CONFIG_FILE"

    if (( CTF_DO_UPDATE )); then
        do_update || exit "$EX_UPDATE"
        exit "$EX_OK"
    fi
    if (( CTF_DO_CHECK_UPDATE )); then
        do_check_update || exit "$EX_UPDATE"
        exit "$EX_OK"
    fi

    validate
    CTF_HEAD_MARKS="$(heading_marks "$CTF_HEADING_LEVEL")"
    if (( CTF_PRINT_CONFIG )); then print_config; exit "$EX_OK"; fi
    resolve_output
    make_temps

    CTF_FILES=()
    if (( ${#CTF_FILES_FROM[@]} > 0 )); then
        local spec
        for spec in ${CTF_FILES_FROM[@]+"${CTF_FILES_FROM[@]}"}; do
            discover_files_from "$spec" "$CTF_SRC_ABS"
        done
    elif [[ -n "$CTF_GIT_MODE" ]]; then
        discover_git "$CTF_SRC_ABS"
    else
        discover_find "$CTF_SRC_ABS"
    fi
    CTF_TOTAL_CANDIDATES="${#CTF_FILES[@]}"
    info "Found ${CTF_TOTAL_CANDIDATES} candidate file(s) in '${CTF_SRC_ABS}'."

    # Sizes are needed by the filters and by --sort size, so they are read in
    # batches before selection rather than one fork per file.
    if (( CTF_TOTAL_CANDIDATES > 0 )); then
        batch_sizes "${CTF_FILES[@]}"
        [[ "$CTF_SORT" == mtime ]] && batch_mtimes "${CTF_FILES[@]}"
    fi

    select_files
    sort_selection
    info "After filtering: ${#CTF_SELECTED[@]} file(s) selected."

    # The body is rendered first: only then do we know which files survived
    # binary filtering, which the header counters and the TOC both need.
    render
    emit_summary
    emit_header
    emit_toc

    if (( CTF_STATS )); then
        print_stats
        ctf_cleanup
        exit "$EX_OK"
    fi

    finalize_output

    if (( CTF_DRY_RUN )); then
        info "Dry run: ${CTF_WRITTEN} file(s) would be collected, ${CTF_SKIPPED} skipped."
    else
        local dest="$CTF_OUT_ABS"
        [[ -z "$CTF_OUT_FILE" || "$CTF_OUT_FILE" == '-' ]] && dest='<stdout>'
        info "Done: ${CTF_WRITTEN} file(s) written, ${CTF_SKIPPED} skipped."
        info "Output → ${dest} ($(human_size "$CTF_BYTES_OUT")), ~${CTF_TOKENS_EST} est. tokens"
    fi

    ctf_cleanup
    if (( CTF_STRICT && CTF_WRITTEN == 0 )); then
        warn "Nothing was collected (--strict)."
        exit "$EX_EMPTY"
    fi
    exit "$EX_OK"
}

# Source guard: tests source this file to exercise the functions directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
