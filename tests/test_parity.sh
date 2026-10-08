#!/usr/bin/env bash
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
#
# Паритет платформ: ctf.sh (bash) и ctf.ps1 (PowerShell) обязаны выдавать
# байт-в-байт одинаковый документ для одинаковых входных данных и принимать
# один и тот же набор длинных опций. Тест выполняется только если в системе
# есть PowerShell (pwsh); в CI он есть на ubuntu-latest.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Паритет ctf.sh <-> ctf.ps1"

PWSH_BIN="${PWSH:-}"
if [[ -z "$PWSH_BIN" ]]; then
    for c in pwsh pwsh-preview powershell; do
        command -v "$c" >/dev/null 2>&1 && { PWSH_BIN="$(command -v "$c")"; break; }
    done
fi
# В контейнерах без ICU PowerShell требует явного инвариантного режима.
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="${DOTNET_SYSTEM_GLOBALIZATION_INVARIANT:-1}"

if [[ -z "$PWSH_BIN" ]] || ! "$PWSH_BIN" -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
    printf '  %sSKIP%s PowerShell не найден — паритет платформ не проверяется.\n' "$_c_ylw" "$_c_rst"
    printf '       Установите pwsh или задайте PWSH=/path/to/pwsh.\n'
    exit "$CTF_FAILED"
fi
PS1="$CTF_ROOT/ctf.ps1"
if [[ ! -f "$PS1" ]]; then
    fail "ctf.ps1 отсутствует в $CTF_ROOT"
    exit "$CTF_FAILED"
fi
pass "PowerShell найден: $PWSH_BIN ($("$PWSH_BIN" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null))"

T="$CTF_TEST_TMP/parity"; mk_fixture_tree "$T"; S="$T/src"
O="$CTF_TEST_TMP/parity-out"; rm -rf "$O"; mkdir -p "$O"

ps_run() { "$PWSH_BIN" -NoProfile -File "$PS1" "$@"; }

# --- 1. синтаксис PS-скрипта ------------------------------------------------
parse_errs="$(ps_run -NoProfile 2>/dev/null; "$PWSH_BIN" -NoProfile -Command "
\$t=\$null;\$e=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$PS1',[ref]\$t,[ref]\$e)
if(\$e){\$e.Count}else{0}" 2>/dev/null | tail -1)"
assert_eq "0" "${parse_errs//[!0-9]/}" "ctf.ps1 разбирается без синтаксических ошибок"

# --- 2. идентичность документа для набора опций -----------------------------
compare() { # compare <имя> <bash-opts...> -- <ps-opts...>
    local name="$1"; shift
    local -a bo=()
    while [[ "${1:-}" != "--" && $# -gt 0 ]]; do bo+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    ctf_run -q --no-timestamp ${bo[@]+"${bo[@]}"} -o "$O/b.md" "$S"
    ps_run -Quiet -NoTimestamp "$@" -OutputFile "$O/p.md" "$S" >"$O/ps.log" 2>&1
    # Строка с именем инструмента различается по определению — сравниваем без неё.
    if diff -q <(grep -v '| Tool |' "$O/b.md" 2>/dev/null) \
               <(grep -v '| Tool |' "$O/p.md" 2>/dev/null) >/dev/null 2>&1; then
        pass "идентичный документ: $name"
    else
        fail "документы различаются: $name"
        diff <(grep -v '| Tool |' "$O/b.md") <(grep -v '| Tool |' "$O/p.md") 2>/dev/null | head -6 | sed 's/^/       /'
    fi
}
compare "все файлы"        "" -- ""
compare "-e sh"            -e sh -- -Ext sh
compare "-e php,txt"       -e php,txt -- -Ext php,txt
compare "--sort name"      --sort name "" -- -Sort name ""
compare "--sort size"      --sort size "" -- -Sort size ""
compare "--max-size 20"    --max-size 20 "" -- -MaxSize 20 ""
compare "--toc"            --toc "" -- -Toc ""
compare "--metadata"       --metadata "" -- -Metadata ""
compare "--line-numbers"   --line-numbers "" -- -LineNumbers ""
compare "--truncate-lines 2" --truncate-lines 2 "" -- -TruncateLines 2 ""
compare "--token-budget 5" --token-budget 5 "" -- -TokenBudget 5 ""
compare "--lang-style indent4" --lang-style indent4 "" -- -LangStyle indent4 ""
compare "--lang-style none" --lang-style none "" -- -LangStyle none ""
compare "--strip-bom"      --strip-bom "" -- -StripBom ""
compare "--heading-level 2" --heading-level 2 "" -- -HeadingLevel 2 ""
compare "--path-style abs" --path-style abs "" -- -PathStyle abs ""
compare "-E b/*"           -E 'b/*' "" -- -Exclude 'b/*' ""
compare "-I a/*"           -I 'a/*' "" -- -Include 'a/*' ""
compare "--dedup"          --dedup "" -- -Dedup ""
compare "--title"          --title "Bundle" "" -- -Title "Bundle" ""
compare "--no-header --no-summary" --no-header --no-summary "" -- -NoHeader -NoSummary ""

# --- 2b. точечные файлы видны обеим платформам -----------------------------
# На Unix PowerShell считает записи, начинающиеся с точки, скрытыми: без -Force
# они молча исчезали из выборки, и кандидаты расходились (25 против 21).
bash_dot="$(ctf_run -q --dry-run "$S"; printf '%s' "$CTF_OUT" | cut -f1 | grep -c '^\.' || true)"
ps_dot="$(ps_run -Quiet -DryRun "$S" 2>/dev/null | cut -f1 | grep -c '^\.' || true)"
assert_ne "0" "${bash_dot//[!0-9]/}" "ctf.sh собирает точечные файлы (.editorconfig, .gitattributes)"
assert_eq "${bash_dot//[!0-9]/}" "${ps_dot//[!0-9]/}" "ctf.ps1 собирает те же точечные файлы (Get-ChildItem -Force)"

# --- 2c. паритет тегов языка -------------------------------------------------
# Тег языка попадает в fence-строку документа, поэтому таблицы map_lang()
# (bash) и Get-LanguageTag (PowerShell) обязаны совпадать поимённо.
LANGDIR="$CTF_TEST_TMP/langnames"; rm -rf "$LANGDIR"; mkdir -p "$LANGDIR"
for n in .editorconfig .gitignore .gitattributes .env .dockerignore Dockerfile \
         Dockerfile.prod Makefile GNUmakefile CMakeLists.txt Jenkinsfile README \
         LICENSE COPYING a.php b.sh c.PY d.tsx e.vue f.proto g.unknownext noext \
         h.rs i.kt j.ex k.clj l.zig m.nim n.tf o.scss p.jsonl q.diff; do
    printf 'x\n' > "$LANGDIR/$n"
done
bash_lang="$(ctf_run -q --dry-run "$LANGDIR"; printf '%s' "$CTF_OUT" | sort)"
ps_lang="$(ps_run -Quiet -DryRun "$LANGDIR" 2>/dev/null | sort)"
if [[ "$bash_lang" == "$ps_lang" ]]; then
    pass "теги языка совпадают для всех 27 пробных имён (включая dotfiles и Dockerfile.prod)"
else
    fail "теги языка расходятся между ctf.sh и ctf.ps1"
    diff <(printf '%s\n' "$bash_lang") <(printf '%s\n' "$ps_lang") | head -10 | sed 's/^/       /'
fi

# --- 2d. паритет human_size (округление и формат) ---------------------------
# Регрессия: bash усечал дробную часть (8699 -> "8.4 KiB"), а .NET округлял
# ("8.5 KiB"), из-за чего строка метаданных расходилась на каждом файле.
# PS-код вынесен во временный файл: вложенные кавычки bash/PowerShell в одной
# строке читаются плохо и легко ломают синтаксис.
HS_SIZES="0 1 999 1023 1024 1536 8699 10239 65536 53135 1048575 1048576 1572864 29043 1073741823 1073741824 3221225472 500000 123456 999999999"
HS_PS="$CTF_TEST_TMP/humansize.ps1"
cat > "$HS_PS" <<'PSEOF'
# Одна строка со списком, а не массив: при запуске через `pwsh -File` несколько
# слов после -Sizes не привязываются к [string[]] — первое уходит параметру,
# остальные теряются.
param([string] $Sizes)
$inv  = [System.Globalization.CultureInfo]::InvariantCulture
$away = [System.MidpointRounding]::AwayFromZero
function Get-HS {
    param([long] $b)
    if ($b -ge 1GB) { return [Math]::Round($b / 1GB, 2, $away).ToString('0.00', $inv) + ' GiB' }
    if ($b -ge 1MB) { return [Math]::Round($b / 1MB, 2, $away).ToString('0.00', $inv) + ' MiB' }
    if ($b -ge 1KB) { return [Math]::Round($b / 1KB, 1, $away).ToString('0.0', $inv) + ' KiB' }
    return "$b B"
}
foreach ($s in ($Sizes -split ' ')) {
    if ($s -ne '') { "$s $(Get-HS ([long] $s))" }
}
PSEOF
"$PWSH_BIN" -NoProfile -File "$HS_PS" -Sizes "$HS_SIZES" 2>/dev/null | tr -d '\r' > "$CTF_TEST_TMP/hs_ps.txt"
( source "$CTF"
  for b in $HS_SIZES; do printf '%s %s\n' "$b" "$(human_size "$b")"; done ) > "$CTF_TEST_TMP/hs_bash.txt"
hs_diff="$(diff "$CTF_TEST_TMP/hs_bash.txt" "$CTF_TEST_TMP/hs_ps.txt" | head -6)"
if [[ -z "$hs_diff" && -s "$CTF_TEST_TMP/hs_ps.txt" ]]; then
    pass "human_size совпадает на 20 размерах (0 Б … 3,2 ГБ): $(wc -l < "$CTF_TEST_TMP/hs_bash.txt") значений"
else
    fail "human_size расходится между ctf.sh и ctf.ps1"
    printf '%s\n' "$hs_diff" | sed 's/^/       /'
fi

# --- 3. идентичность статистики --------------------------------------------
bash_stats="$(ctf_run -q --stats "$S"; printf '%s' "$CTF_OUT" | sort | tr '\n' ';')"
ps_stats="$(ps_run -Quiet -Stats "$S" 2>/dev/null | sort | tr '\n' ';')"
assert_eq "$bash_stats" "$ps_stats" "--stats даёт одинаковые числа на обеих платформах"

# --- 4. паритет интерфейса: каждая длинная опция ctf.sh принимается ctf.ps1 --
# Не портируются: --config/--print-config (конфиг-файл — POSIX-механика) и
# --verbose (в PowerShell -Verbose является общим параметром; используется -Trace).
NOT_PORTED=" --config --print-config --verbose "
opt_list="$(grep -E '^[[:space:]]+(-[a-zA-Z]\|)?--[a-z][a-z0-9-]*(=\*)?\)' "$CTF" \
    | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)"

# Значения для опций, принимающих аргумент, намеренно ВАЛИДНЫЕ: зонд проверяет
# привязку параметров, а не валидацию значений. Невалидное значение уронило бы
# PowerShell на ValidateSet и дало ложное «опция не принимается».
PROBE_LIST="$CTF_TEST_TMP/probe-list.txt"
printf 'a/one.sh\n' > "$PROBE_LIST"
probe_args() {
    case "$1" in
        --ext)            printf -- '--ext sh' ;;
        --exclude)        printf -- "--exclude b/*" ;;
        --include)        printf -- "--include a/*" ;;
        --exclude-dir)    printf -- '--exclude-dir tmp' ;;
        --files-from)     printf -- '--files-from %s' "$PROBE_LIST" ;;
        --git)            printf -- '--git all' ;;
        --binary)         printf -- '--binary never' ;;
        --output)         printf -- '--output %s/probe.md' "$O" ;;
        --format)         printf -- '--format md' ;;
        --path-style)     printf -- '--path-style rel' ;;
        --sort)           printf -- '--sort path' ;;
        --title)          printf -- '--title Probe' ;;
        --lang-style)     printf -- '--lang-style fenced' ;;
        --budget-action)  printf -- '--budget-action drop' ;;
        --update-channel) printf -- '--update-channel main' ;;
        --max-size)       printf -- '--max-size 1K' ;;
        --min-size)       printf -- '--min-size 0' ;;
        --max-depth)      printf -- '--max-depth 2' ;;
        --heading-level)  printf -- '--heading-level 3' ;;
        --truncate-lines) printf -- '--truncate-lines 2' ;;
        --token-budget)   printf -- '--token-budget 100000' ;;
        --update-timeout) printf -- '--update-timeout 1' ;;
        --color)          printf -- '--color never' ;;
        *)                printf -- '%s' "$1" ;;
    esac
}

accepted=0; rejected=0; notported=0
while IFS= read -r o; do
    [[ -n "$o" ]] || continue
    if [[ "$NOT_PORTED" == *" $o "* ]]; then notported=$(( notported + 1 )); continue; fi
    args="$(probe_args "$o")"
    # Каждая итерация обязана писать только в явный файл внутри $O: иначе
    # имена по умолчанию (All-Project-Files.md, all-sh-files.md) падали бы
    # в дерево репозитория.
    case "$o" in
        --output|--dry-run|--stats|--help|--version|--list-default-excludes|\
        --check-update|--update|--update-force) : ;;
        *) args="$args -OutputFile $O/probe.md" ;;
    esac
    case "$o" in
        --git)           probe_dir="$CTF_TEST_TMP/langnames" ;;   # не git-репозиторий: ждём контролируемую ошибку
        --update|--check-update|--update-force)
                         args="--update-timeout 1 --update-channel no-such-channel-xyz"; probe_dir="$S" ;;
        *)               probe_dir="$S" ;;
    esac
    # shellcheck disable=SC2086  # args намеренно передаётся без кавычек
    out="$(cd "$O" && ps_run $args "$probe_dir" 2>&1 | head -3 | tr '\n' ' ')"
    if printf '%s' "$out" | grep -qiE 'MetadataError|not recognized|MissingArgument|ParameterBinding|Cannot convert|cannot be found|AmbiguousParameter|ValidateSet'; then
        rejected=$(( rejected + 1 )); fail "ctf.ps1 не принимает опцию $o: ${out:0:90}"
    else
        accepted=$(( accepted + 1 ))
    fi
done <<< "$opt_list"
assert_eq "0" "$rejected" "все портируемые длинные опции ctf.sh приняты ctf.ps1 ($accepted принято, $notported не портируется)"

# --- 5. bat-лаунчер ---------------------------------------------------------
# Ни один тест не имеет права оставить файлы в дереве репозитория.
stray="$(cd "$CTF_ROOT" && find . -maxdepth 1 \( -name 'All-Project-Files.md' -o -name 'all-*-files.md' -o -name '.ctf-*' -o -name 'probe.md' -o -name 'x' \) -print 2>/dev/null | wc -l)"
assert_eq "0" "${stray//[!0-9]/}" "тесты не оставили файлов в дереве репозитория"

if [[ -f "$CTF_ROOT/ctf.bat" ]]; then
    if grep -q $'\r' "$CTF_ROOT/ctf.bat"; then pass "ctf.bat хранится с CRLF (иначе cmd.exe ломает метки/goto)"
    else fail "ctf.bat хранится с LF — cmd.exe может сломать метки и goto"; fi
    if grep -q 'ctf.ps1' "$CTF_ROOT/ctf.bat"; then pass "ctf.bat вызывает ctf.ps1 (одна реализация на платформу)"
    else fail "ctf.bat не ссылается на ctf.ps1"; fi
    # Проверяем только исполняемые строки: упоминание приёма в комментарии
    # (объяснение, почему от него отказались) ошибкой не является.
    if grep -v '^[[:space:]]*rem' "$CTF_ROOT/ctf.bat" | grep -qE '(^|[[:space:]&|(])more[[:space:]]+\+'; then
        fail "ctf.bat всё ещё извлекает встроенный payload через more +N"
    else
        pass "в ctf.bat нет хрупкого самораспаковщика через more +N"
    fi
fi

exit "$CTF_FAILED"
