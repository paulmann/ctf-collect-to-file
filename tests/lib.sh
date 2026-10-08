#!/usr/bin/env bash
# tests/lib.sh — общий каркас тестов ctf.
# Подключается через `source` каждым тестовым файлом. Внешних зависимостей нет:
# ни bats, ни pytest, ни сети — только bash 4.2+ и стандартные утилиты.

# Каталог репозитория (родительский для tests/).
# shellcheck disable=SC2034  # CTF_OUT/CTF_ERR/CTF_RC/STAT — API каркаса, их читают test_*.sh
CTF_ROOT="${CTF_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
CTF="${CTF:-$CTF_ROOT/ctf.sh}"

# Рабочая область прогона: создаётся один раз, удаляется по завершении.
CTF_TEST_TMP="${CTF_TEST_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/ctf-tests.XXXXXX")}"
mkdir -p -- "$CTF_TEST_TMP" || { printf 'cannot create %s\n' "$CTF_TEST_TMP" >&2; exit 2; }

CTF_ASSERTS=0
CTF_FAILED=0
declare -a CTF_FAILURES=()

_c_red='' _c_grn='' _c_ylw='' _c_rst=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _c_red=$'\033[0;31m'; _c_grn=$'\033[0;32m'; _c_ylw=$'\033[0;33m'; _c_rst=$'\033[0m'
fi

# --- базовые утверждения -----------------------------------------------------

fail() { # fail <сообщение>
    CTF_FAILED=$(( CTF_FAILED + 1 ))
    CTF_FAILURES+=("$1")
    printf '  %sFAIL%s %s\n' "$_c_red" "$_c_rst" "$1"
}

pass() { # pass <сообщение>
    CTF_ASSERTS=$(( CTF_ASSERTS + 1 ))
    (( CTF_VERBOSE_TESTS )) && printf '  %sok%s   %s\n' "$_c_grn" "$_c_rst" "$1"
    return 0
}

assert_eq() { # assert_eq <ожидалось> <получено> <сообщение>
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (ожидалось: [$1], получено: [$2])"; fi
}

assert_ne() { # assert_ne <не-ожидалось> <получено> <сообщение>
    if [[ "$1" != "$2" ]]; then pass "$3"; else fail "$3 (значение совпало с запрещённым: [$1])"; fi
}

assert_rc() { # assert_rc <ожидаемый код> <фактический код> <сообщение>
    if [[ "$1" == "$2" ]]; then pass "$3 (rc=$2)"; else fail "$3 (ожидался rc=$1, получен rc=$2)"; fi
}

assert_contains() { # assert_contains <подстрока> <текст> <сообщение>
    if [[ "$2" == *"$1"* ]]; then pass "$3"; else fail "$3 (не найдено: [$1])"; fi
}

assert_not_contains() { # assert_not_contains <подстрока> <текст> <сообщение>
    if [[ "$2" != *"$1"* ]]; then pass "$3"; else fail "$3 (найдено запрещённое: [$1])"; fi
}

assert_file_exists() { # assert_file_exists <путь> <сообщение>
    if [[ -e "$1" ]]; then pass "$2"; else fail "$2 (файл не существует: $1)"; fi
}

assert_file_missing() { # assert_file_missing <путь> <сообщение>
    if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 (файл существует: $1)"; fi
}

assert_match() { # assert_match <regex> <текст> <сообщение>
    if [[ "$2" =~ $1 ]]; then pass "$3"; else fail "$3 (regex [$1] не совпал)"; fi
}

# --- запуск ctf --------------------------------------------------------------

# ctf_run <аргументы...> ; результат: CTF_OUT, CTF_ERR, CTF_RC.
# Эти переменные (а также массив STAT) — часть API каркаса: их читают файлы
# test_*.sh после вызова, поэтому shellcheck и считает их «неиспользуемыми».
# shellcheck disable=SC2034
CTF_OUT='' CTF_ERR='' CTF_RC=0
ctf_run() {
    local o="$CTF_TEST_TMP/.out.$$" e="$CTF_TEST_TMP/.err.$$"
    bash "$CTF" "$@" >"$o" 2>"$e"
    CTF_RC=$?
    CTF_OUT="$(cat -- "$o")"
    CTF_ERR="$(cat -- "$e")"
    rm -f -- "$o" "$e"
    return 0
}

# ctf_stats <аргументы...> ; результат: ассоциативный массив STAT (key=value из --stats)
# shellcheck disable=SC2034  # STAT читается тестами после вызова
declare -A STAT=()
ctf_stats() {
    local line k v
    STAT=()
    ctf_run --stats --quiet "$@"
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        STAT["$k"]="$v"
    done <<< "$CTF_OUT"
    return 0
}

# --- фикстуры ----------------------------------------------------------------

# mk_fixture_tree <каталог> — создаёт дерево, покрывающее пограничные случаи.
mk_fixture_tree() {
    local root="$1"
    rm -rf -- "$root"; mkdir -p -- "$root/src/a" "$root/src/b/.git" "$root/src/deep/nested" "$root/src/node_modules/pkg"
    printf 'echo hello\n'                     > "$root/src/a/one.sh"
    printf 'x=1\n'                            > "$root/src/a/two.PHP"      # регистр расширения
    printf '<?php\n'                          > "$root/src/b/three.php"
    printf ''                                 > "$root/src/b/empty.txt"     # пустой файл
    printf 'no trailing newline'              > "$root/src/b/nonl.txt"      # без \n в конце
    printf 'line1\r\nline2\r\n'               > "$root/src/b/crlf.txt"      # CRLF
    printf 'has ``` backticks\nand ```` four\n' > "$root/src/b/fences.md"   #_fence-зонд
    printf 'before\n```\nafter\n`````\nend\n' > "$root/src/b/tricky.md"     # fence только из обратных
    printf '~~~\ncode\n~~~\n'                 > "$root/src/b/tilde.md"      # fence из тильд
    printf 'caf\303\251 \320\277\321\200\320\270\320\262\320\265\321\202\n' > "$root/src/b/unicode.txt"
    printf '\001\002\003\004binary'           > "$root/src/b/blob.bin"      # NUL-содержимое
    printf 'obj\n'                            > "$root/src/b/.git/config"   # VCS-мусор
    printf 'export A=1\n'                     > "$root/src/node_modules/pkg/index.js"
    printf 'deep\n'                           > "$root/src/deep/nested/x.sh"
    # Точечные файлы обязаны собираться: на Unix PowerShell помечает их Hidden,
    # и без -Force они молча пропадали (регрессия паритета платформ).
    printf 'root = true\n'                    > "$root/src/.editorconfig"
    printf '*.sh text eol=lf\n'               > "$root/src/.gitattributes"
    printf 'sp\n'                             > "$root/src/b/with space.txt"
    printf 'q\n'                              > "$root/src/b/with'quote.txt"
    printf 'd\n'                              > "$root/src/b/with\$dollar.txt"
    printf 'nl\n'                             > "$root/src/b/with"$'\n'"newline.txt"
    printf 'tb\n'                             > "$root/src/b/with"$'\t'"tab.txt"
    printf 'bt\n'                             > "$root/src/b/with\`backtick.txt"
    ln -s one.sh                              "$root/src/a/link.sh"        # симлинк на файл
    mkdir -p "$root/src/b/dir.php"; printf 'in dir\n' > "$root/src/b/dir.php/inner.txt"
    head -c 200000 /dev/urandom               > "$root/src/b/rand.bin" 2>/dev/null || \
        printf '\000\377\376\375' > "$root/src/b/rand.bin"
    return 0
}

# mk_binary <файл> <байт> — детерминированный псевдослучайный бинарник (без /dev/urandom).
mk_binary() {
    local f="$1" n="${2:-4096}"
    awk -v n="$n" 'BEGIN { srand(42); for (i = 0; i < n; i++) printf "%c", int(rand() * 256) }' > "$f"
}

# --- служебное ---------------------------------------------------------------

section() { printf '\n%s%s%s\n' "$_c_ylw" "$1" "$_c_rst"; }

# bash_code_only <файл> — печатает файл БЕЗ тел quoted-heredoc (<<'PY' ... PY,
# <<'PL' ... PL). Нужен, чтобы проверки «нет eval» не срабатывали на perl-eval
# внутри встроенной полезной нагрузки HTTP-транспорта.
bash_code_only() {
    awk '
        # Маркер heredoc может стоять в середине строки (после команды),
        # поэтому ищем `<<'TAG'` в любом месте, а не только в начале.
        /<<-?[[:space:]]*'"'"'[A-Za-z_][A-Za-z0-9_]*'"'"'/ {
            line = $0
            sub(/.*<<-?[[:space:]]*'"'"'/, "", line); sub(/'"'"'.*/, "", line)
            if (line != "") { delim = line; inhere = 1; next }
        }
        inhere && $0 == delim { inhere = 0; next }
        !inhere { print }
    ' "$1"
}

# Проверяет, что в файле нет NUL-байтов (главный критерий «документ не испорчен»).
has_nul() { LC_ALL=C tr -d '\0' < "$1" | cmp -s - "$1"; }

ctf_report_and_cleanup() {
    if [[ -n "${CTF_RESULT_FILE:-}" ]]; then
        printf '%s %s\n' "$CTF_ASSERTS" "$CTF_FAILED" > "$CTF_RESULT_FILE"
    fi
    ctf_lib_cleanup
}
trap ctf_report_and_cleanup EXIT

ctf_lib_cleanup() {
    if [[ -n "${CTF_TEST_TMP:-}" && -d "$CTF_TEST_TMP" && "${CTF_KEEP_TMP:-0}" != 1 ]]; then
        chmod -R u+rwX -- "$CTF_TEST_TMP" 2>/dev/null || true
        rm -rf -- "$CTF_TEST_TMP"
    fi
}
