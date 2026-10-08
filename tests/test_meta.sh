#!/usr/bin/env bash
# Мета-проверки поставки: версии, синтаксис, статический анализ, переносимость
# bash 4.2, переводы строк, согласованность README/help/парсера.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Мета: версии, shellcheck, bash 4.2, согласованность документов"

# --- версии ------------------------------------------------------------------
if [[ -f "$CTF_ROOT/VERSION" ]]; then
    file_ver="$(tr -d ' \t\r\n' < "$CTF_ROOT/VERSION")"
    code_ver="$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$CTF")"
    assert_eq "$code_ver" "$file_ver" "VERSION совпадает с CTF_SCRIPT_VERSION в ctf.sh"
else
    fail "файл VERSION отсутствует (необходим для --check-update/--update)"
fi
ctf_run --version
ver_out="${CTF_OUT#ctf v}"
code_ver="$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$CTF")"
assert_eq "$code_ver" "$ver_out" "--version печатает ту же версию, что в коде"
if [[ -f "$CTF_ROOT/CHANGELOG.md" ]]; then
    if grep -q "^## \[${code_ver}\]" "$CTF_ROOT/CHANGELOG.md" || grep -q "^## ${code_ver}" "$CTF_ROOT/CHANGELOG.md"; then
        pass "CHANGELOG.md содержит запись для версии ${code_ver}"
    else fail "CHANGELOG.md не содержит записи для версии ${code_ver}"; fi
else fail "CHANGELOG.md отсутствует"; fi

# --- синтаксис и статический анализ -----------------------------------------
if bash -n "$CTF" 2>/dev/null; then pass "bash -n: синтаксических ошибок нет"; else fail "bash -n: синтаксическая ошибка"; fi
bash_code_only "$CTF" > "$CTF_TEST_TMP/bash_only.sh"
if grep -nE '^[[:space:]]*eval[[:space:]]' "$CTF_TEST_TMP/bash_only.sh" | grep -q .; then
    fail "в bash-коде ctf.sh есть eval (конфиг не должен исполнять код)"
else
    pass "в bash-коде ctf.sh нет eval"
fi
if command -v shellcheck >/dev/null 2>&1; then
    sc_out="$(shellcheck --severity=style "$CTF" 2>&1)"
    sc_n="$(printf '%s' "$sc_out" | grep -c 'SC[0-9]\{4\}' || true)"
    assert_eq "0" "${sc_n//[!0-9]/}" "shellcheck --severity=style: 0 замечаний"
    [[ "${sc_n//[!0-9]/}" != 0 ]] && printf '%s\n' "$sc_out" | sed 's/^/      /'
    for f in "$CTF_ROOT"/tests/*.sh; do
        n="$(shellcheck --severity=warning "$f" 2>&1 | grep -c 'SC[0-9]\{4\}' || true)"
        if [[ "${n//[!0-9]/}" == 0 ]]; then pass "shellcheck (warning): $(basename "$f") чист"
        else fail "shellcheck (warning): $(basename "$f") — ${n} замечаний"; fi
    done
else
    printf '  %sSKIP%s shellcheck не установлен\n' "$_c_ylw" "$_c_rst"
fi

# --- переносимость: никакого bash >= 4.3 ------------------------------------
banned='local -n|declare -n|wait -n|mapfile -d|readarray -d|EPOCHREALTIME|\$\{[A-Za-z_][A-Za-z0-9_]*@(Q|q|U|u|E|P|A|a|K|k|L|l)\}'
hits="$(grep -nE "$banned" "$CTF" | grep -v '^\s*[0-9]*:\s*#' || true)"
if [[ -z "$hits" ]]; then pass "в ctf.sh нет конструкций bash >= 4.3 (nameref, wait -n, mapfile -d, \${v@Q})"
else fail "найдены конструкции bash >= 4.3: $hits"; fi
if grep -q 'BASH_VERSINFO\[0\] < 4' "$CTF"; then pass "есть проверка версии bash на входе"
else fail "нет проверки версии bash"; fi
if grep -q 'BASH_VERSION' "$CTF"; then pass "есть защита от запуска не-bash оболочкой"
else fail "нет защиты от запуска не-bash оболочкой"; fi

# --- переводы строк ---------------------------------------------------------
for f in ctf.sh tests/lib.sh install.sh; do
    [[ -f "$CTF_ROOT/$f" ]] || continue
    if grep -q $'\r' "$CTF_ROOT/$f"; then fail "$f содержит CRLF (должен быть LF)"
    else pass "$f: переводы строк LF"; fi
done
for f in ctf.bat ctf.ps1; do
    [[ -f "$CTF_ROOT/$f" ]] || continue
    case "$f" in
        *.bat) if grep -q $'\r' "$CTF_ROOT/$f"; then pass "ctf.bat: CRLF (обязателен для cmd.exe)"
               else fail "ctf.bat: LF вместо CRLF — cmd.exe может сломать метки/goto"; fi ;;
    esac
done
if [[ -f "$CTF_ROOT/.gitattributes" ]]; then
    if grep -qE '\*\.bat .*eol=crlf|\*\.bat.*text eol=crlf' "$CTF_ROOT/.gitattributes"; then
        pass ".gitattributes принудительно задаёт CRLF для *.bat"
    else fail ".gitattributes не задаёт eol=crlf для *.bat"; fi
    if grep -qE '\*\.sh .*eol=lf|\*\.sh.*text eol=lf' "$CTF_ROOT/.gitattributes"; then
        pass ".gitattributes принудительно задаёт LF для *.sh"
    else fail ".gitattributes не задаёт eol=lf для *.sh"; fi
else fail ".gitattributes отсутствует"; fi

# --- исполняемый бит --------------------------------------------------------
if [[ -x "$CTF" ]]; then pass "ctf.sh имеет бит исполнения"; else fail "ctf.sh без бита исполнения"; fi

# --- согласованность: help == парсер == README -----------------------------
# Из --help берём только те строки, где опция стоит в позиции описания
# (начало строки, возможно после короткой формы), иначе в список попадают
# упоминания вроде `git ls-files --cached`.
help_opts="$(bash "$CTF" --help | grep -oE '^[[:space:]]+(-[a-zA-Z],[[:space:]]|--)?--[a-z][a-z0-9-]*' \
    | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)"
# Из парсера: только ветки case, т.е. строки вида `-x|--long)` или `--long=*)`.
parse_opts="$(grep -E '^[[:space:]]+(-[a-zA-Z]\|)?--[a-z][a-z0-9-]*(=\*)?\)' "$CTF" \
    | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)"
missing_in_help="$(comm -23 <(printf '%s\n' "$parse_opts") <(printf '%s\n' "$help_opts") || true)"
missing_in_parse="$(comm -13 <(printf '%s\n' "$parse_opts") <(printf '%s\n' "$help_opts") || true)"
if [[ -z "$missing_in_help" ]]; then pass "каждая опция парсера описана в --help"
else fail "опции парсера не описаны в --help: $(printf '%s' "$missing_in_help" | tr '\n' ' ')"; fi
if [[ -z "$missing_in_parse" ]]; then pass "каждая опция из --help реально разбирается"
else fail "опции из --help не разбираются: $(printf '%s' "$missing_in_parse" | tr '\n' ' ')"; fi

if [[ -f "$CTF_ROOT/README.md" ]]; then
    undoc=""
    while IFS= read -r o; do
        [[ -n "$o" ]] || continue
        grep -q -- "$o" "$CTF_ROOT/README.md" || undoc+=" $o"
    done <<< "$parse_opts"
    if [[ -z "$undoc" ]]; then pass "README.md упоминает все длинные опции"
    else fail "в README.md не описаны опции:$undoc"; fi
else fail "README.md отсутствует"; fi

# --- лицензия ---------------------------------------------------------------
if [[ -f "$CTF_ROOT/LICENSE" ]] && head -1 "$CTF_ROOT/LICENSE" | grep -qi 'MIT'; then
    pass "LICENSE присутствует и это MIT"
else fail "LICENSE отсутствует или не MIT"; fi

exit "$CTF_FAILED"
