#!/usr/bin/env bash
# Самообновление: сравнение версий, поиск канала, валидация загрузки, установка.
# Сеть не нужна: поднимается локальный HTTP-сервер (python3), а корень загрузки
# переопределяется через CTF_UPDATE_BASE_URL — это же используется для зеркал.
# shellcheck source=lib.sh
# shellcheck disable=SC2154  # _c_ylw/_c_rst и прочие общие задаются в lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
section "Самообновление (--check-update / --update)"

# --- 1. чистая функция сравнения версий (без сети) ---------------------------
( source "$CTF"
  vt() { if version_gt "$1" "$2"; then printf '>'; elif version_gt "$2" "$1"; then printf '<'; else printf '='; fi; }
  out=""
  out+="$(vt 4.0.1 4.0.0)"      # >
  out+="$(vt 4.0.0 4.0.0)"      # =
  out+="$(vt 4.0.0 4.1.0)"      # <
  out+="$(vt 4.10.0 4.9.0)"     # > (числовое, не лексикографическое)
  out+="$(vt 5.0.0 4.99.99)"    # >
  out+="$(vt v4.0.1 4.0.0)"     # > (префикс v)
  out+="$(vt 4.0.0.1 4.0.0)"    # > (разная длина)
  printf '%s\n' "$out" ) > "$CTF_TEST_TMP/vt.out"
assert_eq '>=<>>>>' "$(cat "$CTF_TEST_TMP/vt.out")" "version_gt: 7 случаев сравнения версий"

# --- 2. end-to-end против локального HTTP-сервера ---------------------------
if ! command -v python3 >/dev/null 2>&1; then
    printf '  %sSKIP%s end-to-end --update (нет python3 для HTTP-сервера)\n' "$_c_ylw" "$_c_rst"
    exit "$CTF_FAILED"
fi

SRV="$CTF_TEST_TMP/srv"; rm -rf "$SRV"; mkdir -p "$SRV"
WORK="$CTF_TEST_TMP/work"; rm -rf "$WORK"; mkdir -p "$WORK"
ORIG_CTF="$CTF"                       # неприкосновенный эталон репозитория
ORIG_SUM="$(sha256sum < "$ORIG_CTF" | cut -d' ' -f1)"
cp "$ORIG_CTF" "$WORK/ctf.sh"; chmod +x "$WORK/ctf.sh"
# ctf_run из lib.sh обращается к переменной CTF — переключаем её на копию,
# чтобы самообновление не затрагивало рабочий экземпляр в репозитории.
CTF="$WORK/ctf.sh"
LOCAL_VER="$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$WORK/ctf.sh")"

start_server() { # start_server <docroot> — порт выдаёт ОС (коллизии исключены)
    local root="$1" portfile="$CTF_TEST_TMP/port.txt"
    rm -f -- "$portfile"
    python3 - "$root" "$portfile" >"$CTF_TEST_TMP/srv.log" 2>&1 <<'PYSRV' &
import http.server, socketserver, sys, os
root, portfile = sys.argv[1], sys.argv[2]
os.chdir(root)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), H) as httpd:
    with open(portfile, "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PYSRV
    SRV_PID=$!
    local tries=0
    while (( tries < 60 )); do
        tries=$(( tries + 1 ))
        if [[ -s "$portfile" ]]; then cat -- "$portfile"; return 0; fi
        sleep 0.1
    done
    return 1
}

stop_server() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
        SRV_PID=''
    fi
}
trap 'stop_server; ctf_report_and_cleanup' EXIT

# «удалённая» версия: та же копия скрипта, но VERSION на единицу старше
NEW_VER="${LOCAL_VER%.*}.$(( ${LOCAL_VER##*.} + 1 ))"
# update_base_url добавляет к корню имя канала (ветка/тег), как это делает
# raw.githubusercontent.com, поэтому «удалённое» дерево живёт в $SRV/main/.
mkdir -p "$SRV/main"
printf '%s\n' "$NEW_VER" > "$SRV/main/VERSION"
sed "s/^readonly CTF_SCRIPT_VERSION='${LOCAL_VER}'/readonly CTF_SCRIPT_VERSION='${NEW_VER}'/" \
    "$WORK/ctf.sh" > "$SRV/main/ctf.sh"
chmod 0644 "$SRV/main/VERSION" "$SRV/main/ctf.sh"

PORT="$(start_server "$SRV")"
# Обязательно убеждаемся, что отвечаем именно мы: молчаливая проверка чужого
# процесса на том же порту превратила бы тест в ложноположительный.
if [[ -n "$PORT" ]]; then
    probe_body="$(CTF_UPDATE_PROBE_PORT="$PORT" CTF_UPDATE_PROBE_VER="$NEW_VER" python3 - <<'PYPROBE' 2>/dev/null
import os, urllib.request
try:
    u = "http://127.0.0.1:%s/main/VERSION" % os.environ["CTF_UPDATE_PROBE_PORT"]
    print(urllib.request.urlopen(u, timeout=3).read().decode().strip(), end="")
except Exception:
    pass
PYPROBE
)"
    [[ "$probe_body" == "$NEW_VER" ]] || PORT=''
fi
if [[ -z "$PORT" ]]; then
    printf '  %sSKIP%s end-to-end --update (не удалось поднять локальный HTTP-сервер)\n' "$_c_ylw" "$_c_rst"
    exit "$CTF_FAILED"
fi
export CTF_UPDATE_BASE_URL="http://127.0.0.1:${PORT}"

# --- 2a. --check-update видит новую версию и возвращает код 3 ---------------
ctf_run --check-update
assert_rc 3 "$CTF_RC" "--check-update при наличии новой версии -> код 3"
assert_contains "remote=${NEW_VER}" "$CTF_OUT" "--check-update печатает удалённую версию"
assert_contains "status=newer" "$CTF_OUT" "--check-update сообщает status=newer"

# --- 2b. --update устанавливает новую версию, делая бэкап -------------------
ctf_run --update
assert_rc 0 "$CTF_RC" "--update завершается успешно"
assert_eq "$NEW_VER" "$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$WORK/ctf.sh")" \
    "после --update скрипт содержит новую версию"
if compgen -G "$WORK/ctf.sh.bak-*" >/dev/null 2>&1; then pass "--update создаёт резервную копию"
else fail "--update не создал резервную копию"; fi
bak="$(compgen -G "$WORK/ctf.sh.bak-*" | head -1)"
[[ -n "$bak" ]] && assert_eq "$LOCAL_VER" "$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$bak")" \
    "в бэкапе осталась прежняя версия"
ctf_run --check-update
assert_rc 0 "$CTF_RC" "после обновления --check-update -> код 0 (up-to-date)"
assert_contains 'status=up-to-date' "$CTF_OUT" "после обновления status=up-to-date"

# --- 2c. повторный --update без новой версии ничего не делает ---------------
before_sum="$(sha256sum < "$WORK/ctf.sh" | cut -d' ' -f1)"
ctf_run --update
assert_rc 0 "$CTF_RC" "повторный --update успешен"
assert_contains 'Already up to date' "$CTF_ERR" "повторный --update сообщает об отсутствии обновлений"
assert_eq "$before_sum" "$(sha256sum < "$WORK/ctf.sh" | cut -d' ' -f1)" "повторный --update не меняет файл"
ctf_run --update --update-force
assert_rc 0 "$CTF_RC" "--update-force переустанавливает даже ту же версию"

# --- 2d. валидация загрузки: скрипт не ставится, если он повреждён ----------
restore() { cp "$ORIG_CTF" "$WORK/ctf.sh"; sed -i "s/^readonly CTF_SCRIPT_VERSION=.*/readonly CTF_SCRIPT_VERSION='0.0.1'/" "$WORK/ctf.sh"; chmod +x "$WORK/ctf.sh"; }
good_ctf="$(cat "$SRV/main/ctf.sh")"

pad() { awk 'BEGIN{for(i=0;i<300;i++) print "# padding line " i}'; }
restore
{ printf 'not a script at all\n'; pad; } > "$SRV/main/ctf.sh"
ctf_run --update
assert_rc 3 "$CTF_RC" "загрузка без shebang -> код 3, установка отклонена"
assert_eq '0.0.1' "$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$WORK/ctf.sh")" \
    "повреждённая загрузка НЕ перезаписала рабочий скрипт"
assert_contains 'shebang' "$CTF_ERR" "сообщение объясняет причину отказа"

restore
{ printf '#!/usr/bin/env bash\nthis is ( not valid bash ]]\n'; pad; } > "$SRV/main/ctf.sh"
ctf_run --update
assert_rc 3 "$CTF_RC" "загрузка с синтаксической ошибкой -> код 3"
assert_contains 'bash -n' "$CTF_ERR" "отказ объяснен провалом bash -n"
assert_eq '0.0.1' "$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$WORK/ctf.sh")" \
    "скрипт с ошибкой синтаксиса НЕ установлен"

restore
{ printf '<!DOCTYPE html><html><body>404 Not Found</body></html>\n'; pad; } > "$SRV/main/ctf.sh"
ctf_run --update
assert_rc 3 "$CTF_RC" "HTML-страница ошибки вместо скрипта -> код 3"
assert_eq '0.0.1' "$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$WORK/ctf.sh")" \
    "HTML-страница НЕ установлена поверх рабочего скрипта"

# Отдельно: короткая загрузка отсекается проверкой размера.
restore
printf 'tiny\n' > "$SRV/main/ctf.sh"
ctf_run --update
assert_rc 3 "$CTF_RC" "загрузка 6 байт -> код 3"
assert_contains 'bytes' "$CTF_ERR" "отказ объяснён подозрительным размером"

restore
printf '%s\n' "$good_ctf" > "$SRV/main/ctf.sh"
printf 'not-a-version\n' > "$SRV/main/VERSION"
ctf_run --check-update
assert_rc 3 "$CTF_RC" "нераспознанный VERSION -> код 3 (unreachable), а не тихий успех"
assert_contains 'status=unreachable' "$CTF_OUT" "сообщается status=unreachable"

# --- 2e. недоступный сервер --------------------------------------------------
stop_server
ctf_run --update-timeout 2 --check-update
assert_rc 3 "$CTF_RC" "недоступный сервер -> код 3"

# --- 3. тест не имел права трогать рабочий экземпляр ------------------------
CTF="$ORIG_CTF"
assert_eq "$ORIG_SUM" "$(sha256sum < "$ORIG_CTF" | cut -d' ' -f1)" \
    "прогон --update не изменил ctf.sh в репозитории"
if compgen -G "$CTF_ROOT/ctf.sh.bak-*" >/dev/null 2>&1; then
    fail "в репозитории остались резервные копии ctf.sh.bak-*"
else
    pass "в репозитории не осталось резервных копий"
fi

exit "$CTF_FAILED"
