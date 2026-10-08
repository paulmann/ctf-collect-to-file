#!/usr/bin/env bash
# Структура выходного документа: заголовки, fence-и, форматы, TOC, метаданные.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Выходной документ: разметка и форматы"

T="$CTF_TEST_TMP/out"; mk_fixture_tree "$T"

# --- CommonMark: fence обязан быть длиннее любой «закрывающей» строки файла ----
# tricky.md содержит строки ``` и `````, поэтому блок из обратных кавычек
# невозможен: его закрывающая строка совпала бы с содержимым. Инструмент обязан
# выбрать тильды (DR-09).
#
# Проверяется fence самого блока tricky.md, а не «любая строка из 3+ кавычек
# во всём документе»: законный открывающий fence ```markdown (11 символов) есть
# в документе всегда, поэтому поиск по всему файлу находил его и падал
# независимо от того, правильно ли обёрнут tricky.md.
ctf_run -q --no-timestamp --no-header --no-summary -I 'tricky.md' -o "$T/tr.md" -e md "$T/src/b"
tricky_block="$(awk '/^### `tricky.md`$/{f=1} f{print} f&&/^---$/{exit}' "$T/tr.md")"
assert_contains '~~~markdown' "$tricky_block" "tricky.md (строки из \`) обёрнут в fence из тильд"
close_tilde="$(printf '%s\n' "$tricky_block" | grep -c '^~~~$')"
assert_eq "1" "$close_tilde" "закрывающий fence tricky.md — тильды, а не обратные кавычки"
# Строка из тильд НЕ закрывает fence из обратных кавычек, поэтому достаточно
# трёх обратных — это корректный CommonMark и более короткий fence.
ctf_run -q --no-timestamp --no-header --no-summary -I 'tilde.md' -o "$T/ti.md" "$T/src/b"
assert_contains '```markdown' "$(cat "$T/ti.md")" "tilde.md обёрнут в fence из трёх обратных кавычек (тильды его не закрывают)"
assert_contains '~~~' "$(cat "$T/ti.md")" "содержимое с ~~~ сохранено внутри блока"

# --- файл без завершающего \n: закрывающий fence на своей строке ------------
ctf_run -q --no-timestamp --no-header --no-summary -I 'nonl.txt' -o "$T/nl.md" "$T/src/b"
last_content_line="$(sed -n '4p' "$T/nl.md")"
assert_eq 'no trailing newline' "$last_content_line" "содержимое файла без \\n сохранено"
# Открывающий fence несёт суффикс языка (```text), поэтому «голая» fence-строка
# ровно одна — закрывающая. Важно, что она стоит ОТДЕЛЬНО от последней строки
# содержимого: иначе файл без завершающего \n сломал бы блок.
bare="$(awk '/^```$/{c++} END{print c+0}' "$T/nl.md")"
assert_eq "1" "$bare" "закрывающий fence — один и на своей строке"
content_line="$(awk '/^```text$/{getline; print; exit}' "$T/nl.md")"
assert_eq 'no trailing newline' "$content_line" "содержимое идёт сразу после открывающего fence"
if awk '/^```text$/{f=1;next} /^```$/{if(f){g=1}} END{exit (g?0:1)}' "$T/nl.md"; then
    pass "блок открыт и закрыт корректно (файл без \\n не сломал разметку)"
else fail "структура fenced-блока нарушена"; fi

# --- CRLF сохраняется байт-в-байт -------------------------------------------
ctf_run -q --no-timestamp --no-header --no-summary -I 'crlf.txt' -o "$T/crlf.md" "$T/src/b"
if grep -aq $'line1\r$' "$T/crlf.md"; then pass "CRLF-переводы строк сохранены"; else fail "CRLF потерян"; fi

# --- UTF-8 содержимое не искажается -----------------------------------------
ctf_run -q --no-timestamp --no-header --no-summary -I 'unicode.txt' -o "$T/uni.md" "$T/src/b"
assert_contains 'привет' "$(cat "$T/uni.md")" "UTF-8 (кириллица) сохранён"

# --- заголовок/сводка/TOC ---------------------------------------------------
ctf_run -q --no-timestamp --toc -e sh -o "$T/full.md" "$T/src"
assert_contains '# Project Source Code Aggregate' "$(cat "$T/full.md")" "заголовок документа присутствует"
assert_contains '## Table of contents' "$(cat "$T/full.md")" "--toc добавляет оглавление"
assert_contains '- [`a/one.sh`](#aonesh)' "$(cat "$T/full.md")" "якорь TOC соответствует правилам GitHub"
assert_contains '## Summary' "$(cat "$T/full.md")" "сводка присутствует"
assert_contains '| Collected | 2 |' "$(cat "$T/full.md")" "сводка содержит точное число собранных файлов"

ctf_run -q --no-timestamp --no-header -e sh -o "$T/nh.md" "$T/src"
assert_not_contains 'Project Source Code Aggregate' "$(cat "$T/nh.md")" "--no-header убирает шапку"
ctf_run -q --no-timestamp --no-summary -e sh -o "$T/ns.md" "$T/src"
assert_not_contains '## Summary' "$(cat "$T/ns.md")" "--no-summary убирает сводку"
ctf_run -q --no-timestamp --title 'Мой бандл' -e sh -o "$T/ti2.md" "$T/src"
assert_contains '# Мой бандл' "$(cat "$T/ti2.md")" "--title задаёт заголовок (UTF-8)"
ctf_run -q --no-timestamp --heading-level 4 -e sh -o "$T/h4.md" "$T/src"
assert_contains '#### `a/one.sh`' "$(cat "$T/h4.md")" "--heading-level 4 меняет уровень заголовков"
ctf_run -q --no-timestamp --path-style abs -e sh -o "$T/abs.md" "$T/src"
assert_contains "$T/src/a/one.sh" "$(cat "$T/abs.md")" "--path-style abs печатает абсолютные пути"

# --- воспроизводимость ------------------------------------------------------
ctf_run -q --no-timestamp -e sh -o "$T/r1.md" "$T/src"
ctf_run -q --no-timestamp -e sh -o "$T/r2.md" "$T/src"
if cmp -s "$T/r1.md" "$T/r2.md"; then pass "--no-timestamp даёт воспроизводимый вывод"; else fail "--no-timestamp не обеспечивает воспроизводимость"; fi
ctf_run -q -e sh -o "$T/ts.md" "$T/src"
assert_contains 'Generated (UTC)' "$(cat "$T/ts.md")" "по умолчанию в шапке есть метка времени"

# --- метаданные и нумерация строк ------------------------------------------
ctf_run -q --no-timestamp --no-header --no-summary --metadata -e sh -o "$T/meta.md" "$T/src"
assert_match '<!-- 11 bytes . 1 lines . 11 B . sha256:[0-9a-f]{12} -->' "$(cat "$T/meta.md")" "--metadata добавляет размер, число строк и sha256/12"
ctf_run -q --no-timestamp --no-header --no-summary --line-numbers -e sh -o "$T/ln.md" "$T/src"
assert_contains '     1| echo hello' "$(cat "$T/ln.md")" "--line-numbers нумерует строки"

# --- truncate / budget ------------------------------------------------------
printf 'l1\nl2\nl3\nl4\nl5\n' > "$T/five.txt"
ctf_run -q --no-timestamp --no-header --no-summary --truncate-lines 2 -e txt -o "$T/tr2.md" "$T"
assert_not_contains 'l3' "$(cat "$T/tr2.md")" "--truncate-lines 2 обрезает содержимое"
assert_contains 'l2' "$(cat "$T/tr2.md")" "--truncate-lines 2 сохраняет первые строки"

# five.txt = 5 строк / 15 байт (~4 токена). Бюджет в 2 токена заставляет
# именно УРЕЗАТЬ его, а не отбросить; для drop-режима берём бюджет в 1 токен.
ctf_stats --token-budget 1 --budget-action drop -I 'five.txt' "$T"
assert_ne "0" "${STAT[budget_dropped]:-0}" "--budget-action drop отбрасывает файл сверх бюджета"
ctf_stats --token-budget 2 --budget-action truncate -I 'five.txt' "$T"
assert_ne "0" "${STAT[truncated_files]:-0}" "--budget-action truncate урезает файл под бюджет"
assert_eq "1" "${STAT[collected]}" "урезанный файл остаётся в документе"
ctf_run -q --no-timestamp --no-header --no-summary --token-budget 2 --budget-action truncate -I 'five.txt' -o "$T/bud.md" "$T"
assert_contains 'truncated to fit the token budget' "$(cat "$T/bud.md")" "в документе помечено, что файл урезан"
# Файл, который бюджет не урезал, «урезанным» считаться не должен.
ctf_stats --token-budget 1000 --budget-action truncate -I 'five.txt' "$T"
assert_eq "0" "${STAT[truncated_files]:-0}" "при достаточном бюджете truncated_files = 0"

# --- форматы json / jsonl / txt --------------------------------------------
ctf_run -q --no-timestamp -e sh -F json -o "$T/f.json" "$T/src"
if python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert len(d['files'])==2;assert {k for k in d['files'][0]} >= {'path','lang','bytes','lines','content'}" "$T/f.json" 2>/dev/null; then
    pass "--format json: валидный JSON с полями path/lang/bytes/lines/content"
elif command -v python3 >/dev/null 2>&1; then
    fail "--format json: невалидный JSON или неверный набор полей"
else
    printf '  %sSKIP%s --format json (нет python3 для валидации)\n' "$_c_ylw" "$_c_rst"
fi
ctf_run -q --no-timestamp -e sh -F jsonl -o "$T/f.jsonl" "$T/src"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json,sys;n=sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l));assert n==2" "$T/f.jsonl" 2>/dev/null; then
        pass "--format jsonl: 2 валидные JSON-строки"
    else fail "--format jsonl: невалидные строки"; fi
fi
ctf_run -q --no-timestamp -e sh -F txt -o "$T/f.txt" "$T/src"
assert_contains '===== a/one.sh (bash, 11 B) =====' "$(cat "$T/f.txt")" "--format txt печатает разделители файлов"
assert_not_contains '```' "$(cat "$T/f.txt")" "--format txt не содержит Markdown-fence"

# --- JSON: round-trip содержимого со служебными символами ------------------
# Регрессия: экранирование через gsub(/\\/, "\\\\") выдавало ОДИН обратный
# слэш вместо двух, и документ с Windows-путями или regex-ами становился
# невалидным JSON.
J="$T/json"; rm -rf "$J"; mkdir -p "$J"
printf 'back\\\\slash "quotes" and\ttab\n' > "$J/hard.txt"
printf 'regex: /^\\\\d+$/\n'                 > "$J/re.txt"
printf '{"a":"b","c":[1,2,3]}\n'                 > "$J/nested.json"
printf '\x01\x02control\x03\n'                > "$J/ctrl.txt"
ctf_run -q --no-timestamp -F json -o "$J/all.json" "$J"
if command -v python3 >/dev/null 2>&1; then
    if python3 - "$J" <<'PYCHK'
import json, sys, os, filecmp, io
d = os.sys.argv[1] if False else sys.argv[1]
doc = json.load(open(os.path.join(d, 'all.json')))
ok = True
for f in doc['files']:
    p = os.path.join(d, f['path'])
    with open(p, 'rb') as fh:
        raw = fh.read()
    got = f['content'].encode('utf-8')
    # управляющие символы, кроме \t \n \r, по контракту удаляются
    expected = bytes(b for b in raw if b in (9, 10, 13) or b >= 32)
    if got != expected:
        sys.stderr.write('MISMATCH %s\n  want %r\n  got  %r\n' % (f['path'], expected[:60], got[:60]))
        ok = False
    if f['bytes'] != len(raw):
        sys.stderr.write('BYTES MISMATCH %s: %d != %d\n' % (f['path'], f['bytes'], len(raw)))
        ok = False
sys.exit(0 if ok else 1)
PYCHK
    then pass "--format json: содержимое восстанавливается байт-в-байт (слэши, кавычки, TAB, управляющие)"
    else fail "--format json: содержимое не совпадает с исходным файлом"; fi
    ctf_run -q --no-timestamp -F jsonl -o "$J/all.jsonl" "$J"
    if python3 -c "
import json,sys
n=0
for l in open(sys.argv[1]):
    if l.strip(): json.loads(l); n+=1
assert n==4, n
" "$J/all.jsonl" 2>/dev/null; then pass "--format jsonl: все 4 строки валидны"
    else fail "--format jsonl: есть невалидные строки"; fi
else
    printf '  %sSKIP%s JSON round-trip (нет python3)\n' "$_c_ylw" "$_c_rst"
fi

# --- BOM --------------------------------------------------------------------
printf '\357\273\277BOM line\n' > "$T/bom.txt"
ctf_run -q --no-timestamp --no-header --no-summary -I 'bom.txt' -o "$T/bom_kept.md" "$T"
if grep -aq $'\357\273\277BOM' "$T/bom_kept.md"; then pass "без --strip-bom BOM сохраняется"; else fail "BOM неожиданно удалён"; fi
ctf_run -q --no-timestamp --no-header --no-summary --strip-bom -I 'bom.txt' -o "$T/bom_gone.md" "$T"
if grep -aq $'\357\273\277' "$T/bom_gone.md"; then fail "--strip-bom не убрал BOM"; else pass "--strip-bom убирает BOM"; fi

exit "$CTF_FAILED"
