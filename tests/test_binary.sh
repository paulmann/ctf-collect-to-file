#!/usr/bin/env bash
# Определение бинарных файлов. Главный регрессионный тест v3: детерминированность.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Бинарность: детерминированность и ложные срабатывания"

T="$CTF_TEST_TMP/bin"; rm -rf "$T"; mkdir -p "$T"
printf 'plain ascii\n'                        > "$T/ascii.txt"
printf 'caf\303\251 \320\277\321\200\320\270\320\262\320\265\321\202\n' > "$T/utf8_ru.txt"
printf '\360\237\230\200 emoji \344\270\255\346\226\207\n'             > "$T/utf8_emoji.txt"
# Однобайтовая кириллица (CP1251 «привет»). Важно задавать байты через \xNN:
# восьмеричный \348 bash-printf трактует как \34 + '8' и подмешивает 0x1C.
printf '\xef\xf0\xe8\xe2\xe5\xf2\n'            > "$T/cp1251_ru.txt"
printf 'tab\there\nform\014feed\n'            > "$T/ctrl_mild.txt"     # допустимые управляющие
printf '\000\001\002\003'                     > "$T/with_nul.bin"
printf '\211PNG\r\n\032\n\000\000\000\rIHDR'  > "$T/fake.png"
printf 'MZ\220\000\003\000\000\000'           > "$T/fake.exe"
:                                              > "$T/empty.txt"
mk_binary "$T/rand_4k.bin" 4096
mk_binary "$T/rand_300k.bin" 300000
mk_binary "$T/rand_64.bin" 64

# 1. ДЕТЕРМИНИРОВАННОСТЬ: 8 identical прогонов обязаны дать одинаковый sha256.
#    В v3 здесь было 3/2/4/4/3/4 из-за SIGPIPE+pipefail в head|od|tr|grep -q.
# Выходные файлы кладём ВНЕ сканируемого дерева: иначе каждый следующий прогон
# видит документ предыдущего и выборка растёт — это ломает и детерминированность,
# и все последующие утверждения.
O="$CTF_TEST_TMP/bin-out"; rm -rf "$O"; mkdir -p "$O"
declare -a hashes=()
for i in 1 2 3 4 5 6 7 8; do
    ctf_run -q --no-timestamp -o "$O/run$i.md" "$T"
    hashes+=("$(sha256sum < "$O/run$i.md" | cut -d' ' -f1)")
done
uniq_h="$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)"
assert_eq "1" "${uniq_h//[!0-9]/}" "8 identical прогонов дают байт-в-байт одинаковый документ (v3: 3 разных исхода)"

# 2. Ни одного NUL-байта в документе.
if has_nul "$O/run1.md"; then pass "в документе нет NUL-байтов"; else fail "в документе есть NUL-байты (бинарник просочился)"; fi

# 3. Бинарные файлы исключены.
for f in with_nul.bin fake.png fake.exe rand_4k.bin rand_300k.bin; do
    if grep -aq "$f" "$O/run1.md"; then fail "$f присутствует в документе"; else pass "$f отсутствует в документе"; fi
done

# 4. Текстовые файлы ЛЮБЫХ кодировок не должны отбраковываться.
for f in ascii.txt utf8_ru.txt utf8_emoji.txt cp1251_ru.txt ctrl_mild.txt empty.txt; do
    if grep -aq "$f" "$O/run1.md"; then pass "текст $f собран (ложного срабатывания нет)"; else fail "текст $f НЕ собран — ложное срабатывание детектора"; fi
done

# 5. Явные режимы --binary.
ctf_stats --binary never "$T"
assert_eq "0" "${STAT[skip_binary]:-0}" "--binary never: ничего не отброшено как бинарное"
ctf_stats --binary always "$T"
assert_eq "0" "${STAT[collected]}" "--binary always: не собрано ничего"

# 6. Счётчики сходятся: candidates == collected + skipped.
ctf_stats "$T"
sum=$(( ${STAT[collected]} + ${STAT[skipped]} ))
assert_eq "${STAT[candidates]}" "$sum" "candidates == collected + skipped (учёт полный, потерь нет)"

exit "$CTF_FAILED"
