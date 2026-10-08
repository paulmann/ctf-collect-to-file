#!/usr/bin/env bash
# Запуск всех тестов ctf.
#
#   tests/run_tests.sh                 # весь набор
#   tests/run_tests.sh --filter binary # только test_binary.sh
#   tests/run_tests.sh --verbose       # печатать каждый успешный ассерт
#   tests/run_tests.sh --keep-tmp      # не удалять временный каталог
#   CTF=/path/to/ctf.sh tests/run_tests.sh   # прогнать набор против другой копии
#
# Код возврата: 0 — все тесты прошли, 1 — есть падения, 2 — ошибка запуска.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname -- "$HERE")"

FILTER=''
VERBOSE=0
KEEP=0
while (( $# > 0 )); do
    case "$1" in
        --filter|-f) FILTER="${2:-}"; shift 2 ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --keep-tmp|-k) KEEP=1; shift ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'Неизвестный аргумент: %s\n' "$1" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ctf-suite.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
trap 'if [[ "$KEEP" != 1 ]]; then chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; else echo "временный каталог сохранён: $TMP"; fi' EXIT

printf 'ctf test suite\n'
printf '  script : %s\n' "${CTF:-$ROOT/ctf.sh}"
printf '  bash   : %s\n' "$BASH_VERSION"
printf '  workdir: %s\n\n' "$TMP"

total_asserts=0 total_failed=0 failed_files=() ran=0
for t in "$HERE"/test_*.sh; do
    base="$(basename "$t")"
    if [[ -n "$FILTER" && "$base" != *"$FILTER"* ]]; then continue; fi
    ran=$(( ran + 1 ))
    res="$TMP/$base.res"
    mkdir -p -- "$TMP/$base.d"
    # cwd теста — его временный каталог: вызовы без явного -o используют имя
    # вывода по умолчанию и не должны засорять дерево репозитория.
    ( cd "$TMP/$base.d" && \
      CTF_TEST_TMP="$TMP/$base.d" CTF_RESULT_FILE="$res" CTF_VERBOSE_TESTS="$VERBOSE" \
      CTF_KEEP_TMP="$KEEP" bash "$t" )
    rc=$?
    if [[ -f "$res" ]]; then
        read -r a f < "$res"
    else
        a=0; f=1
    fi
    total_asserts=$(( total_asserts + a ))
    total_failed=$(( total_failed + f ))
    if (( f > 0 || rc != 0 )); then failed_files+=("$base"); fi
    printf '%s\n' "$TMP/$base.rcdone" > /dev/null
done

printf '\n%s\n' '---------------------------------------------------------------'
if (( ${#failed_files[@]} == 0 )); then
    printf 'ИТОГ: %d файлов, %d проверок, 0 падений — OK\n' "$ran" "$total_asserts"
    exit 0
fi
printf 'ИТОГ: %d файлов, %d проверок, %d падений\n' "$ran" "$total_asserts" "$total_failed"
printf 'Упавшие файлы: %s\n' "${failed_files[*]}"
exit 1
