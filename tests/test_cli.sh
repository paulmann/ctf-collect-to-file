#!/usr/bin/env bash
# Интерфейс командной строки: опции, позиционная форма v1–v3, коды выхода.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "CLI: опции, позиционные аргументы, коды выхода"

ctf_run --help;              assert_rc 0 "$CTF_RC" "--help завершается с кодом 0"
assert_contains "USAGE" "$CTF_OUT" "--help печатает раздел USAGE"
assert_contains "--token-budget" "$CTF_OUT" "--help документирует --token-budget"
assert_contains "--update" "$CTF_OUT" "--help документирует --update"

ctf_run --version;           assert_rc 0 "$CTF_RC" "--version завершается с кодом 0"
assert_match '^ctf v[0-9]+\.[0-9]+\.[0-9]+$' "$CTF_OUT" "--version печатает 'ctf vX.Y.Z'"

ctf_run --definitely-not-an-option;  assert_rc 2 "$CTF_RC" "неизвестная опция -> код 2 (usage)"
ctf_run -e php /nonexistent-dir-xyz; assert_rc 2 "$CTF_RC" "несуществующий каталог -> код 2"
ctf_run a b c d;                     assert_rc 2 "$CTF_RC" "4 позиционных аргумента -> код 2"
ctf_run --ext;                       assert_rc 2 "$CTF_RC" "--ext без значения -> код 2"
ctf_run --format xml "$CTF_TEST_TMP"; assert_rc 2 "$CTF_RC" "--format xml (неподдерживаемый) -> код 2"
ctf_run --sort random "$CTF_TEST_TMP"; assert_rc 2 "$CTF_RC" "--sort random -> код 2"
ctf_run --heading-level 9 "$CTF_TEST_TMP"; assert_rc 2 "$CTF_RC" "--heading-level 9 -> код 2"
ctf_run --max-depth x "$CTF_TEST_TMP"; assert_rc 2 "$CTF_RC" "--max-depth x -> код 2"
ctf_run -e 'ph*p' "$CTF_TEST_TMP";   assert_rc 2 "$CTF_RC" "расширение с wildcard -> код 2"
ctf_run -e 'a/b' "$CTF_TEST_TMP";    assert_rc 2 "$CTF_RC" "расширение со слэшем -> код 2"

# --- позиционная форма (обратная совместимость с v1–v3) ---
T="$CTF_TEST_TMP/cli"; mk_fixture_tree "$T"
ctf_run sh "$T/src" "$T/out.md"
assert_rc 0 "$CTF_RC" "legacy-форма 'EXT SRC OUT' работает"
assert_file_exists "$T/out.md" "legacy-форма создала файл"

ctf_stats sh "$T/src"
assert_eq "2" "${STAT[collected]}" "legacy 'sh SRC': собрано 2 файла (one.sh, deep/nested/x.sh)"

# Один позиционный аргумент-каталог после -e должен трактоваться как SOURCE_DIR,
# а не как второе расширение (регрессия черновика v4).
ctf_stats -e php "$T/src"
assert_eq "2" "${STAT[collected]}" "-e php <каталог>: каталог распознан как SOURCE_DIR"

# Каталог без -e тоже SOURCE_DIR.
ctf_stats "$T/src/a"
assert_ne "0" "${STAT[candidates]}" "единственный позиционный каталог = SOURCE_DIR"

# Пустое расширение = все текстовые файлы.
ctf_stats "" "$T/src/a"
assert_eq "${STAT[candidates]}" "${STAT[collected]}" "пустое расширение собирает все текстовые файлы"

# Длинная форма --opt=value.
ctf_run -q --stats --format=json --sort=size "$T/src/a"
assert_rc 0 "$CTF_RC" "форма --opt=value принимается"

# -- завершает разбор опций.
ctf_run -q --stats -- "$T/src/a"
assert_rc 0 "$CTF_RC" "'--' корректно завершает разбор опций"

exit "$CTF_FAILED"
