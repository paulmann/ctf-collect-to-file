#!/usr/bin/env bash
# Безопасность и надёжность: атомарность, симлинк-приёмник, temp-очистка,
# конфиг-файл, «враждебные» имена файлов, отсутствие eval.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Безопасность: атомарная запись, конфиг, враждебные имена"

T="$CTF_TEST_TMP/safe"; mk_fixture_tree "$T"; S="$T/src"

# --- враждебные имена файлов не исполняются и не ломают разбор --------------
H="$T/hostile"; rm -rf "$H"; mkdir -p "$H"
printf 'x\n' > "$H/semi;colon.sh"
# Полезная нагрузка не должна содержать '/': иначе имя файла превращается в путь.
printf 'x\n' > "$H/dollar\$(touch PWNED_subst).sh"
printf 'x\n' > "$H/back\`touch PWNED_bt\`.sh"
printf 'x\n' > "$H/star*glob.sh"
printf 'x\n' > "$H/with space.sh"
printf 'x\n' > "$H/with'quote.sh"
printf 'x\n' > "$H/with\"dquote.sh"
printf 'x\n' > "$H/with"$'\n'"newline.sh"
printf 'x\n' > "$H/with"$'\t'"tab.sh"
printf 'x\n' > "$H/-dashfirst.sh"
rm -f "$T/PWNED_subst" "$T/PWNED_bt" "$H/PWNED_subst" "$H/PWNED_bt"
# Выходной файл кладём ВНЕ $H, иначе он сам попадёт в выборку.
ctf_run -q --no-timestamp -o "$T/hostile.md" "$H"
assert_rc 0 "$CTF_RC" "дерево с враждебными именами обрабатывается без падения"
assert_file_missing "$T/PWNED_subst" "\$(...) в имени файла НЕ исполняется"
assert_file_missing "$H/PWNED_subst" "\$(...) в имени файла НЕ исполняется (в каталоге источника)"
assert_file_missing "$T/PWNED_bt" "обратные кавычки в имени файла НЕ исполняются"
assert_file_missing "$H/PWNED_bt" "обратные кавычки в имени файла НЕ исполняются (в каталоге источника)"
assert_eq "10" "$(grep -ac '^### ' "$T/hostile.md")" "все 10 враждебных имён попали в документ"
if has_nul "$T/hostile.md"; then pass "документ не содержит NUL"; else fail "документ содержит NUL"; fi
# имя с переводом строки не должно ломать заголовок Markdown
if awk '/^### /{c++} END{exit (c==10)?0:1}' "$T/hostile.md"; then pass "каждый заголовок — на своей строке (LF в имени нейтрализован)"
else fail "LF в имени файла сломал структуру заголовков"; fi

# --- атомарность: временные файлы не остаются -------------------------------
before="$(find "$T" -name '.ctf-*' -o -name '.*.ctf.*' 2>/dev/null | wc -l)"
ctf_run -q --no-timestamp -o "$T/atomic.md" "$S"
after="$(find "$T" -name '.ctf-*' -o -name '.*.ctf.*' 2>/dev/null | wc -l)"
assert_eq "${before//[!0-9]/}" "${after//[!0-9]/}" "после успешного прогона временных файлов не осталось"
assert_file_exists "$T/atomic.md" "выходной файл создан"

# прерывание: temp-файл обязан убираться trap-ом
ctf_run -q --no-timestamp -o "$T/int.md" --max-size 1 "$S" >/dev/null 2>&1 || true
leak="$(find "$T" -name '.ctf-*' 2>/dev/null | wc -l)"
assert_eq "0" "${leak//[!0-9]/}" "trap убирает временные файлы (утечек нет)"

# --- выходной файл-симлинк: запись сквозь симлинк, цель не подменяется -------
printf 'OLD\n' > "$T/real.md"; ln -sf "$T/real.md" "$T/link.md"
ctf_run -q --no-timestamp -e sh -o "$T/link.md" "$S"
if [[ -L "$T/link.md" ]]; then pass "выходной симлинк остался симлинком (не подменён файлом)"
else fail "симлинк подменён обычным файлом"; fi
assert_not_contains 'OLD' "$(cat "$T/real.md")" "содержимое цели симлинка перезаписано"

# --- выходной файл внутри исходного каталога не собирает сам себя ------------
ctf_run -q --no-timestamp -e md -o "$S/selfdoc.md" "$S"
ctf_run -q --no-timestamp -e md -o "$S/selfdoc.md" "$S"
n_self="$(grep -ac 'selfdoc.md' "$S/selfdoc.md" || true)"
assert_eq "0" "${n_self//[!0-9]/}" "второй прогон НЕ включает свой же выходной файл (он пропускается)"
# Пропуск срабатывает только когда выходной файл уже существует и лежит
# внутри исходного дерева — поэтому мерим с тем же -o, что и прогоны выше.
ctf_stats -e md -o "$S/selfdoc.md" "$S"
assert_ne "0" "${STAT[skip_output_file]:-0}" "пропуск выходного файла учтён в skip_output_file"

# --- каталог вывода ВНУТРИ исходного дерева: свои temp-файлы не собираются ---
# Обычный сценарий `ctf -o ./bundle.md .`: временные файлы создаются рядом с
# результатом, то есть внутри сканируемого дерева, и find их видит.
OIN="$T/outin"; rm -rf "$OIN"; mkdir -p "$OIN/sub"
printf 'a\n' > "$OIN/one.txt"; printf 'b\n' > "$OIN/sub/two.txt"
ctf_run -q --no-timestamp --no-header --no-summary -o "$OIN/bundle.md" "$OIN"
assert_rc 0 "$CTF_RC" "вывод внутрь исходного дерева работает"
assert_eq "2" "$(grep -ac '^### ' "$OIN/bundle.md")" "собраны ровно 2 файла проекта"
assert_not_contains '.ctf-' "$(cat "$OIN/bundle.md")" "собственные временные файлы не попали в документ"
leftover="$(find "$OIN" -name '.ctf-*' 2>/dev/null | wc -l)"
assert_eq "0" "${leftover//[!0-9]/}" "временные файлы убраны"
ctf_stats -o "$OIN/bundle.md" "$OIN"
assert_ne "0" "${STAT[skip_temporary_file]:-0}" "пропуск temp-файлов учтён в статистике"
assert_eq "2" "${STAT[collected]}" "при повторном прогоне собираются те же 2 файла"

# --- каталог вывода не существует / не доступен для записи ------------------
ctf_run -o "$T/no-such-dir/out.md" "$S"; assert_rc 2 "$CTF_RC" "несуществующий каталог вывода -> код 2"
RO="$T/ro"; mkdir -p "$RO"; chmod 0555 "$RO"
if [[ "$(id -u)" != 0 ]]; then
    ctf_run -o "$RO/out.md" "$S"; assert_rc 2 "$CTF_RC" "недоступный для записи каталог -> код 2"
else
    printf '  %sSKIP%s проверка прав записи (прогон от root)\n' "$_c_ylw" "$_c_rst"
fi
chmod 0755 "$RO"

# --- конфигурационный файл ---------------------------------------------------
CONF="$T/ctf.conf"
printf 'CTF_FORMAT=txt\nCTF_SORT=size\nCTF_QUIET=1\n' > "$CONF"; chmod 0644 "$CONF"
ctf_run --config "$CONF" -e sh -o "$T/conf.out" "$S"
assert_rc 0 "$CTF_RC" "конфиг-файл принимается"
assert_contains '=====' "$(cat "$T/conf.out")" "CTF_FORMAT=txt из конфига применён"
ctf_run --config "$T/absent.conf" "$S"; assert_rc 2 "$CTF_RC" "несуществующий конфиг -> код 2"

# Конфиг с кодовой инъекцией обязан быть отвергнут (значения — данные, не код).
printf 'CTF_TITLE=$(touch %s/PWNED_conf)\n' "$T" > "$T/evil.conf"; chmod 0644 "$T/evil.conf"
rm -f "$T/PWNED_conf"
ctf_run --config "$T/evil.conf" -e sh -o "$T/evil.out" "$S"
assert_file_missing "$T/PWNED_conf" "\$(...) в конфиге НЕ исполняется"

# Не-CTF переменные и произвольные команды игнорируются.
printf 'PATH=/tmp\nrm -rf /\necho pwned\nCTF_TITLE=Ok\n' > "$T/mixed.conf"; chmod 0644 "$T/mixed.conf"
ctf_run --config "$T/mixed.conf" --print-config -e sh "$S"
assert_contains 'title             Ok' "$CTF_OUT" "допустимая CTF_TITLE из конфига применена"
assert_not_contains 'PATH' "$CTF_OUT" "переменные вне белого списка не принимаются"

# Групповая/мировая запись в конфиге -> файл игнорируется (защита от подмены).
printf 'CTF_FORMAT=txt\n' > "$T/loose.conf"; chmod 0666 "$T/loose.conf"
ctf_run --config "$T/loose.conf" -e sh -o "$T/loose.out" "$S"
assert_contains 'ignored for safety' "$CTF_ERR" "конфиг с mode 0666 игнорируется с предупреждением"
assert_not_contains '=====' "$(cat "$T/loose.out")" "значения из небезопасного конфига не применены"

# --- отсутствие eval и конкатенации команд в самом скрипте ------------------
# eval в bash-коде недопустим. Внутри perl-heredoc есть perl-eval — он не
# исполняется оболочкой, поэтому проверяем только bash-код (без тел heredoc).
bash_code_only "$CTF" > "$T/bash_only.sh"
if grep -nE '^[[:space:]]*eval[[:space:]]' "$T/bash_only.sh" | grep -q .; then
    fail "в bash-коде ctf.sh найден eval"
else
    pass "в bash-коде ctf.sh нет eval"
fi
# Команды не должны собираться строкой и исполняться через оболочку.
if grep -nE '(bash|sh|zsh)[[:space:]]+-c[[:space:]]+"?\$' "$T/bash_only.sh" | grep -q .; then
    fail 'в ctf.sh есть исполнение строки через оболочку: shell -c "$var"'
else
    pass "в ctf.sh нет исполнения командной строки из переменной"
fi

exit "$CTF_FAILED"
