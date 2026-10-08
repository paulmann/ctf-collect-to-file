#!/usr/bin/env bash
# Отбор файлов: расширения, исключения, симлинки, глубина, размер, git, --files-from.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Отбор: расширения, исключения, симлинки, git"

T="$CTF_TEST_TMP/col"; mk_fixture_tree "$T"; S="$T/src"

# --- расширения --------------------------------------------------------------
ctf_stats -e sh "$S";        assert_eq "2" "${STAT[collected]}" "-e sh: 2 файла"
ctf_stats -e php "$S";       assert_eq "2" "${STAT[collected]}" "-e php: 2 файла (.php и .PHP — регистронезависимо)"
ctf_stats -e .php "$S";      assert_eq "2" "${STAT[collected]}" "-e .php: ведущая точка допустима"
ctf_stats -e php,sh "$S";    assert_eq "4" "${STAT[collected]}" "-e php,sh: несколько расширений сразу"
ctf_stats -e PHP,SH "$S";    assert_eq "4" "${STAT[collected]}" "-e PHP,SH: регистр не важен"
ctf_stats -e nonexistentext "$S"; assert_eq "0" "${STAT[collected]}" "несуществующее расширение: 0 файлов"
ctf_stats "$S";              assert_ne "0" "${STAT[collected]}" "без -e собираются все текстовые файлы"

# --- дефолтные исключения (VCS, зависимости) --------------------------------
# В фикстуре 25 файлов, из них 3 лежат в .git/ и node_modules/.
ctf_stats "$S"
assert_eq "22" "${STAT[candidates]}" "дефолтные исключения: .git/ и node_modules/ отсечены на уровне find (22 из 25)"
assert_ne "0" "$(printf '%s' "${STAT[candidates]}")" "точечные файлы (.editorconfig, .gitattributes) попадают в кандидаты"
ctf_run -q --no-timestamp -o "$S/../all.md" "$S"
assert_not_contains '.git/config' "$(cat "$T/all.md")" "в документе нет .git/config"
assert_not_contains 'node_modules' "$(cat "$T/all.md")" "в документе нет node_modules"
ctf_stats --no-default-excludes "$S"
assert_ne "0" "${STAT[candidates]}" "--no-default-excludes возвращает .git/node_modules в выборку"
ctf_run -q --list-default-excludes
assert_contains '.git' "$CTF_OUT" "--list-default-excludes показывает .git"
assert_contains 'node_modules' "$CTF_OUT" "--list-default-excludes показывает node_modules"

# --- пользовательские исключения -------------------------------------------
before="$(ctf_stats "$S"; printf '%s' "${STAT[collected]}")"
ctf_stats -E 'b/*' "$S"
if [[ "${STAT[collected]}" -lt "$before" ]]; then pass "-E 'b/*' уменьшает выборку"; else fail "-E 'b/*' не сработал"; fi
# В a/ три записи: one.sh, two.PHP и симлинк link.sh (без -L он не собирается).
ctf_stats -I 'a/*' "$S";  assert_eq "2" "${STAT[collected]}" "-I 'a/*' оставляет только каталог a (2 файла)"
ctf_stats --exclude-dir deep "$S"
assert_not_contains 'deep' "$(ctf_run -q --dry-run --exclude-dir deep "$S"; printf '%s' "$CTF_OUT")" "--exclude-dir deep убирает deep/"
ctf_stats --exclude-dir .git,node_modules "$S"
assert_rc 0 "$CTF_RC" "--exclude-dir принимает список через запятую"

# --- симлинки ----------------------------------------------------------------
# find -type f без -L не выдаёт симлинки вовсе, поэтому они не попадают даже в
# кандидаты; гарантия состоит в том, что -L добавляет ровно один файл.
ctf_stats "$S/a";      default_collected="${STAT[collected]}"
assert_eq "2" "$default_collected" "без -L: собираются 2 реальных файла из a/"
ctf_stats -L "$S/a";   assert_eq "3" "${STAT[collected]}" "с -L: симлинк добавляется (3 файла)"
# В режиме --files-from симлинк становится кандидатом и обязан учитываться как пропуск.
printf 'a/link.sh\n' > "$T/sym.txt"
ctf_stats --files-from "$T/sym.txt" "$S"
assert_ne "0" "${STAT[skip_symlink]:-0}" "симлинк из --files-from учтён в skip_symlink, а не потерян молча"

# --- глубина и размер --------------------------------------------------------
ctf_stats --max-depth 2 "$S"
deep_present="$(ctf_run -q --dry-run --max-depth 2 "$S"; printf '%s' "$CTF_OUT" | grep -c 'deep/nested' || true)"
assert_eq "0" "${deep_present//[!0-9]/}" "--max-depth 2 не опускается в deep/nested"
ctf_stats --max-size 5 "$S"
assert_ne "0" "${STAT[skip_too_large]:-0}" "--max-size отбрасывает большие файлы и считает их"
ctf_stats --min-size 1 "$S"
assert_ne "0" "${STAT[skip_too_small]:-0}" "--min-size отбрасывает пустые файлы и считает их"
ctf_stats --max-size 1K "$S"; assert_rc 0 "$CTF_RC" "--max-size принимает суффикс K"
ctf_run --max-size abc "$S";  assert_rc 2 "$CTF_RC" "--max-size abc -> код 2"

# --- --files-from ------------------------------------------------------------
printf 'a/one.sh\nb/three.php\n' > "$T/list.txt"
ctf_stats --files-from "$T/list.txt" "$S"
assert_eq "2" "${STAT[candidates]}" "--files-from: ровно 2 кандидата из списка"
assert_eq "2" "${STAT[collected]}" "--files-from: оба собраны"
printf 'a/one.sh\000b/three.php\000' > "$T/list.nul"
ctf_stats --files-from "$T/list.nul" "$S"
assert_eq "2" "${STAT[collected]}" "--files-from понимает NUL-разделённый список"
ctf_run --files-from "$T/does-not-exist" "$S"; assert_rc 2 "$CTF_RC" "--files-from с несуществующим файлом -> код 2"
# Конвейер создаёт подоболочку, поэтому утверждение обязано быть внутри неё.
printf 'deep/nested/x.sh\n' | { ctf_stats --files-from - "$S"
    assert_eq "1" "${STAT[collected]}" "--files-from - читает список из stdin"; }

# --- --git -------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    G="$CTF_TEST_TMP/gitrepo"; rm -rf "$G"; mkdir -p "$G/sub"
    printf 'a\n' > "$G/tracked.py"; printf 'b\n' > "$G/sub/also.py"
    printf 'c\n' > "$G/untracked.py"; printf 'secret\n' > "$G/ignored.log"
    printf 'ignored.log\n' > "$G/.gitignore"
    ( cd "$G" && git init -q . && git add tracked.py sub/also.py .gitignore >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1 )
    # В индексе три файла: tracked.py, sub/also.py и .gitignore.
    ctf_stats --git tracked "$G"
    assert_eq "3" "${STAT[candidates]}" "--git tracked: только файлы индекса (3)"
    ctf_stats --git all "$G"
    assert_eq "4" "${STAT[candidates]}" "--git all: индекс + untracked.py, ignored.log исключён .gitignore"
    ctf_run -q --dry-run --git all "$G"
    assert_not_contains 'ignored.log' "$CTF_OUT" "--git all уважает .gitignore"
    ctf_run --git bogus "$G"; assert_rc 2 "$CTF_RC" "--git с неверным режимом -> код 2"
    ctf_run --git all "$CTF_TEST_TMP"; assert_rc 2 "$CTF_RC" "--git вне репозитория -> код 2"
else
    printf '  %sSKIP%s --git (git не установлен)\n' "$_c_ylw" "$_c_rst"
fi

# --- сортировка --------------------------------------------------------------
o_path="$(ctf_run -q --dry-run --sort path "$S"; printf '%s' "$CTF_OUT" | cut -f1 | tr '\n' ',')"
o_name="$(ctf_run -q --dry-run --sort name "$S"; printf '%s' "$CTF_OUT" | cut -f1 | tr '\n' ',')"
assert_ne "$o_path" "$o_name" "--sort name даёт иной порядок, чем --sort path"
s1="$(ctf_run -q --dry-run --sort size "$S"; printf '%s' "$CTF_OUT" | cut -f3 | tr '\n' ' ')"
if [[ "$s1" == "$(printf '%s\n' $s1 | sort -nr | tr '\n' ' ')" ]]; then pass "--sort size упорядочивает по убыванию размера"
else fail "--sort size: порядок неверен ($s1)"; fi
first_path="$(printf '%s' "$o_path" | cut -d, -f1)"
# Точка (0x2E) меньше букв, поэтому при байтовой сортировке dotfiles идут первыми.
assert_eq ".editorconfig" "$first_path" "--sort path: байтовый порядок (LC_ALL=C), .editorconfig первый"

# --- dry-run ничего не пишет -------------------------------------------------
rm -f "$T/dry.md"
ctf_run -q --dry-run -e sh -o "$T/dry.md" "$S"
assert_file_missing "$T/dry.md" "--dry-run не создаёт выходной файл"
assert_contains 'one.sh' "$CTF_OUT" "--dry-run печатает список отобранного"

# --- strict ------------------------------------------------------------------
ctf_run -q --strict -e zzz -o "$T/none.md" "$S"
assert_rc 4 "$CTF_RC" "--strict при пустой выборке -> код 4"

exit "$CTF_FAILED"
