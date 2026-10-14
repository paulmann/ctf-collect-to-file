# ПРОМТ разработчику ctf-collect-to-file на доработку

> **Кому:** maintainer `paulmann/ctf-collect-to-file`
> **От:** агента, чья поставка прошла через ctf v3.0.0 (2026-10-14) и который затем независимо протестировал ctf v4.0.0 (HEAD `b11ac44`)
> **Дата:** 2026-10-14
> **Формат:** промт на доработку. Факты → доказательства → требования (R1–R9) с критериями приёмки. Сопроводительный код — в `code/`, сырые логи — в `evidence/`.
>
> **Оговорка о ролях.** Я НЕ использовал ctf в своей работе и не знал о существовании репозитория: я увидел только его продукт — `All-Project-Files.md` (заголовок: `Script | ctf v3.0.0`, `Source | /3TB/4`), которым разработчик упаковал мою поставку `for_github-wiki-llm-writer/code/` для обратной передачи. Свой `aggregate_sources.py` я написал как ответ на наблюдаемое повреждение, до знакомства с кодом ctf. Получив ссылку на репозиторий, я склонировал его, прогнал тесты и независимую батарею — результаты ниже.

---

## TL;DR (English, paste-ready)

```text
Field report + improvement prompt for ctf-collect-to-file, from the agent whose
delivery was packaged by ctf v3.0.0 (Windows build) on 2026-10-14 and who then
independently tested v4.0.0 (HEAD b11ac44) on Debian 12 / bash 5.2 /
shellcheck 0.9.0 / Python 3.11.

CORRECTION FIRST (integrity): my earlier incident report claimed v3 "truncated
fix_toc.py to 2,356 B and destroyed a 74,558-B probe script to 1 B". That was
WRONG as attribution: the v3 document contains ALL bytes of all four files and
is fully recoverable by a CommonMark-conformant parser — the Windows v3 build
even switched the probe's fence to ~~~ because the content contained backtick
fences. The "truncation" was an artifact of MY OWN naive regex extractor
(stopped at any triple-backtick occurrence, mid-line included, and did not
understand tilde fences). Real defects of that v3 document, all evidenced:
  1. CRLF conversion — every embedded file's bytes were rewritten to CRLF
     (2,202 lines), silently breaking byte fidelity vs the LF originals;
  2. no per-file integrity metadata — defect 1 is undetectable by the consumer;
  3. content-borne headings ("### Sub section" inside an embedded Python
     string) create phantom structure for fence-unaware parsers (it fooled my
     first diagnoser pass too);
  4. the repo-era pre-v4 ctf.sh (fixed rank-3 backtick fences, per git history
     7737cf5^) breaks 5 of 13 adversarial fixtures and embeds binary files
     (v3's flaky binary detection — reproduced live).

v4.0.0 VERIFIED INDEPENDENTLY: dynamic fence rank (choose_fence, DR-09) +
deterministic binary skip + --metadata sha256/12 + byte-preserving CRLF/BOM/
emoji/no-trailing-newline round trip — my 13-fixture battery verifies 13/13
with 0 problems, counters consistent (Collected+Skipped=Candidates).

REMAINING DEFECTS AT HEAD (repro on a clean clone):
  * tests/run_tests.sh: 209 checks, 2 FAIL (test_meta.sh):
      - "ctf.sh без бита исполнения" — ctf.sh & install.sh committed mode 100644;
      - "shellcheck --severity=style: 0 замечаний (ожидалось [0], получено [4])"
        — SC2015 x3 in the --update write path (~line 1048: A && B || C).
  * no round-trip VERIFY mode (the shipped hashes cannot be checked by ctf
    itself); sha256 truncated to 12 hex (48 bits — fine for accidents, weak
    for audit); no fence-safety/capability marker for consumers to reject
    pre-v4 aggregates; extraction contract undocumented; ps1 CRLF policy
    undeclared (untestable here — no pwsh in my sandbox).

ASKS: R1 fix own test suite (P0) · R2 ship --verify, reference implementation
provided (P0) · R3 full-hash option (P1) · R4 capability marker + v3-recovery
troubleshooting (P1) · R5 document the extraction contract (P1) · R6 CRLF
policy declaration (P2) · R7 adopt the adversarial fixture battery (P2) ·
R8 keep the backticked-heading invariant / document it (P2) · R9 binary
policy: keep skip-with-reason, consider --binary=base64 (P2).
Deliverables in this folder: verify_ctf_output.py (verifier + v3 diagnoser),
make_fixtures.py (13-file battery), aggregate_sources.py (independent
fence-safe reference aggregator), run_e2e.sh, evidence/ logs.
```

---

## 0. Важное исправление моего прежнего отчёта (честность прежде всего)

В `for_github-wiki-llm-writer/DEVELOPER-REPORT.md` §A11 я утверждал, что ctf
v3.0.0 «обрезал fix_toc.py до 2 356 B» и «уничтожил батарею до 1 B». **Это
неверная атрибуция.** Побайтовая форензика оригинального документа
(`uploads/All-Project-Files.md`):

- все четыре файла присутствуют **полностью** (хвостовые маркеры на месте:
  `SELF-TEST PASSED — the fixer cannot eat surrounding prose.` у fix_toc;
  `== summary: {passed} pass` у батареи);
- probe-файл встроен в **тильдовый fence** `~~~python … ~~~` (строки 226 и
  1750 документа) — сборка v3.0.0 на машине разработчика переключала символ
  fence при наличии backtick-строк в контенте, т.е. базовая защита была;
- «обрезанные» 2 356 B / 1 B — результат **моего** наивного regex-экстрактора
  (`.*?` до первых ``` в любой позиции строки, тильды не понимал): он закрыл
  блок fix_toc на середине строки `startswith("```")`, а блок probe — на
  первой же внутренней чистой ``` (фикстура markdown внутри Python-строки).

Уроки для обеих сторон: (а) потребитель агрегатов обязан парсить fence по
правилам CommonMark (чистая строка, тот же символ, ранг ≥ открывающего);
(б) агрегатор обязан делать повреждения **обнаружимыми** — байты-на-месте
не означают извлекаемость, а CRLF-конверсия v3 (п.2 ниже) ломает побайтовую
идентичность вообще без следов. Мой верификатор (`code/verify_ctf_output.py`)
закрывает обе стороны: fence-aware извлечение + resync + `--diagnose`.

## 1. Хронология и роли

| Когда | Что |
|---|---|
| 2026-10-08 | Выпущен ctf **4.0.0** (CHANGELOG: динамические fence — DR-09, детерминированная бинарная детекция, `--metadata` sha256/12, тест-сьют, self-update, exit-коды) |
| 2026-10-14 10:27Z | Разработчик упаковывает мою поставку **сборкой v3.0.0** (Windows, `/3TB/4`) → `All-Project-Files.md` (CRLF, без хешей) |
| 2026-10-14 | Я диагностирую «повреждение» по своему наивному извлечению (частично неверно — см. §0), пишу `aggregate_sources.py` и §A11 |
| 2026-10-14 (сейчас) | Получив URL репозитория: клон, прогон тестов v4, независимая батарея, форензика field-документа, исправленный отчёт |

**Ключевой системный вывод:** релиз v4.0.0, уже содержавший фикс fence-правил,
НЕ попал на машину, где делалась упаковка (там стоял v3). Разрыв между
«выпущено» и «используется» — сам по себе дефект процесса; R4 адресует его.

## 2. Форензика field-документа (v3.0.0, Windows)

Доказательства (воспроизводимо командами из §7):

1. **CRLF-конверсия контента.** Документ содержит 2 202 `\r\n`; встроенный
   контент LF-файлов переписан в CRLF (probe: 74 558 B оригинал → 76 080
   символов в извлечении ≈ +1 520 = по `\r` на строку). Побайтовая идентичность
   нарушена для ВСЕХ файлов; без хешей потребитель этого не видит. Мой
   верификатор поэтому сравнивает кандидаты {exact, ±trailing-NL, CRLF→LF} —
   и фиксирует факт нормализации в отчёте.
2. **Хешей нет** — `--metadata` в v3 отсутствовал; Summary «Processed 4 /
   Skipped 0 / Total 4» рапортовал успех при молча изменённых байтах.
3. **Фантомная структура.** `### Sub section` (строка SELF_TEST_FIXTURE внутри
   fix_toc.py) для fence-неосведомлённых парсеров выглядит заголовком секции —
   мой первый проход diagnose дал ложные BROKEN/«no-block: Sub section».
   Лечится fence-aware парсингом + инвариантом «настоящие заголовки секций
   ctf всегда в backtick'ах» (R8).
4. **Репозиторный pre-v4 ctf.sh** (`git show 7737cf5^:ctf.sh`, строки 227–231:
   `printf '```%s\n' "${lang}"` … `printf '```\n\n---\n\n'` — фиксированный
   ранг 3, без choose_fence) на моей батарее **ломает 5 из 13** файлов
   (fence3_pure, fence4_pure, fence_indented, meta_spoof, mixed — 6-й
   «BROKEN» в первом прогоне был артефактом парсера, устранён) и **встраивает
   binary.bin** (NUL-байты в документе; «13 written, 0 skipped») — та самая
   недетерминированная бинарная детекция из CHANGELOG 4.0.0, воспроизведённая
   вживую. Логи: `evidence/diagnose-v3-fixtures.log`, `evidence/ctf-adv-v3.md`.

## 3. Независимая верификация v4.0.0 (HEAD b11ac44)

Батарея `code/make_fixtures.py` (13 файлов) → `bash ctf.sh /tmp/ctf-adv -o … --metadata --no-timestamp` → `verify_ctf_output.py --sources`:

```text
verify: 13 file(s) verified, 0 problem(s), 12 section(s) total   (exit 0)
  counters: Candidates=13 Collected=12 Skipped=1 sections=12  ✓
  bom.txt / fence3_pure / fence4_pure / fence_indented / inline_backticks /
  meta_spoof / mixed / no_trailing_nl / sub dir/файл with space.md /
  tildes / unicode_emoji / crlf.txt — verified via meta (sha256/12) ✓
  binary.bin — skipped with reason ✓
```

Что доказано: динамический ранг (файл с чистыми ```` из 4 backtick'ов получает
fence ранга 5), правило CommonMark-закрытия (отступ 0–3 пробела закрывает,
4 — контент; mid-line backticks не закрывают), тильды vs backticks, CRLF и BOM
сохраняются побайтово, файл без финального NL восстанавливается точно
(`ends_nl` + один добавленный `\n`), metadata-spoof строка внутри контента не
сбивает парсинг, юникод+пробелы в путях, бинарник детерминированно скипается,
счётчики сходятся. Полный лог: `evidence/verify-v4.log`.

## 4. Дефекты HEAD, найденные его же тест-сьютом (чистый клон, Debian 12)

```text
$ bash tests/run_tests.sh
ИТОГ: 8 файлов, 209 проверок, 2 падений
Упавшие файлы: test_meta.sh
  FAIL shellcheck --severity=style: 0 замечаний (ожидалось: [0], получено: [4])
       SC2015 (info) ×3 — путь записи --update, ~строка 1048:
       `[[ -n "$backup" ]] && cp -p -- "$backup" "$target" 2>/dev/null || true`
  FAIL ctf.sh без бита исполнения
       git ls-files -s: ctf.sh 100644, install.sh 100644
```

Плюс контекст: badge README заявляет «shellcheck clean», а CI ставит shellcheck
из apt ubuntu-latest — результат зависит от версии линтера (у меня 0.9.0 —
4 замечания). «Каждый исправленный дефект воспроизводится тестом» (их же
принцип) сейчас работает против них: сьют красный на HEAD.

## 5. Требования на доработку (приоритизированы)

### R1 (P0) — починить собственный тест-сьют на HEAD
1. `git update-index --chmod=+x ctf.sh install.sh` (проверить, что test_meta
   больше не падает; на Windows-чекауте поведение не меняется).
2. SC2015 ×3: заменить `A && B || C` на явный `if` в write-through-inode пути
   `--update` (строки ~1046–1050).
3. В CI: зафиксировать версию shellcheck (pin через release-тарболл или
   `shellcheck-version:` у action) ИЛИ документировать поддерживаемый диапазон
   в tests/test_meta.sh; локальный прогон и CI должны давать одинаковый вердикт.
**Приёмка:** `bash tests/run_tests.sh` на чистом клоне (Debian 12, shellcheck
0.9.0, bash 5.2, без pwsh) → 0 падений; CI зелёный с заявленной версией.

### R2 (P0) — режим верификации round-trip
`ctf --verify DOC [--sources DIR]` (или компаньон-скрипт): перечитать
собственный md-документ, извлечь каждый блок по CommonMark-правилам, сверить
sha256 из `--metadata` (и, при `--sources`, побайтово с оригиналами, допуская
только задокументированные трансформации: один добавленный финальный `\n`,
CRLF-нормализация транспорта). Ненулевой exit при любом расхождении; проверка
инварианта счётчиков (Collected+Skipped=Candidates; sections=Collected).
**Референс-реализация прилагается:** `code/verify_ctf_output.py` (плюс режим
`--diagnose` для legacy-документов без метаданных — находит структурно
сломанные блоки и сообщает, что байты присутствуют, но не извлекаются).
**Приёмка:** на батарее R7 verify зелёный; на искусственно испорченном
документе (1 байт в контенте) → exit 1 с именем файла; на field-документе v3
`--diagnose` → «4 intact» (bytes complete), на v3-прогоне батареи → «5 BROKEN».

### R3 (P1) — полные хеши и явный ends-nl
`--metadata=full` (или `--hash-length 64`): sha256/12 = 48 бит — достаточно
для ловли случайной порчи, мало для аудита/дедуп-гарантий; в `--dedup` уже
используется полный хеш — единообразие. В metadata-комментарий добавить явный
`ends-nl:yes|no` (сейчас выводится из bytes и знания контракта) — парсеры не
должны гадать.

### R4 (P1) — маркер пригодности в шапке + troubleshooting для v3
В таблицу заголовка: `| Fence-Safety | dynamic (DR-09) |` (или
`fixed-3` для старых) — потребитель (LLM-пайплайн, CI) может отбраковать
pre-v4 агрегаты машинно. В README раздел «Recovering pre-v4 aggregates»:
симптомы (фиксированные ранги, CRLF-конверсия, отсутствие хешей), команда
`verify_ctf_output.py --diagnose`, рекомендация перегенерировать v4.
История этого отчёта — готовый кейс: разрыв «выпущено v4 / использован v3»
стоил ложного инцидент-репорта.

### R5 (P1) — документировать контракт извлечения
Для авторов парсеров (docs/EXTRACTION.md или README §12): точная грамматика —
заголовок `### <BT>rel<BT>` (и поведение для путей, содержащих backtick —
сейчас имя печатается БЕЗ backtick'ов, что ломает инвариант R8; предложить
экранирование или явный маркер), формат metadata-комментария, правило ранга
(`choose_fence`: max(чистые backtick-строки, чистые tilde-строки)+1, min 3,
короткий из двух), CommonMark-правило закрытия, политика финального newline
(`ends_nl` → добавляется ровно один `\n`), маркер budget-усечения
(`<!-- truncated to fit the token budget -->`), словарь skip-reason.
Мой верификатор реализует этот контракт — используйте как executable-spec.

### R6 (P2) — объявить CRLF-политику (кросс-платформа)
Field-документ v3 (Windows) конвертировал контент в CRLF молча. v4 sh
сохраняет байты (подтверждено round-trip'ом crlf.txt/bom.txt). Для ctf.ps1:
проверить и ЗАДОКУМЕНТИРОВАТЬ — пишет ли ps1 документ LF или CRLF и меняет ли
байты встроенного контента (у меня нет pwsh в песочнице — не проверено;
tests/test_parity.sh SKIP'ается без PowerShell). Хеш в metadata должен
считаться от ОРИГИНАЛЬНЫХ байтов файла (в v4 так и есть) — тогда любая
транспортная конверсия ловится верификацией. Опция `--newline lf|native`
для явного управления.

### R7 (P2) — принять adversarial-батарею в tests/
`code/make_fixtures.py` генерирует 13 файлов: чистые fence-строки рангов 3 и 4;
closers с отступом 0–3 пробела и «контентные» 4 пробела; тильды; реалистичный
md с вложенными блоками; mid-line backticks; файл без финального newline;
CRLF; BOM; emoji+кириллица (бинарная детекция не должна их ронять — регресс
v3 из CHANGELOG); metadata-spoof строка внутри контента; NUL-бинарник;
путь `sub dir/файл with space.md`. Тест: агрегировать → извлечь fence-aware →
побайтово сверить (или `verify_ctf_output.py --sources`).

### R8 (P2) — инвариант заголовков секций
Настоящие заголовки ctf всегда `### <BT>name<BT>` — это якорь resync для
парсеров на структурно-сломанных документах (используется моим diagnose).
Случай пути с backtick'ами сейчас печатает заголовок БЕЗ backtick'ов —
предлагаю: экранировать backtick в имени (удвоение) или печатать
`### <BT><name><BT>` всегда, заменяя backtick в имени на U+FF40 с пометкой.
Задокументировать выбор в R5.

### R9 (P2) — бинарная политика
v4-поведение (skip + причина в Summary) — оставить как дефолт (подтверждено
батареёй). Опционально `--binary base64` для полноты снимка (аудит-кейс),
с явной меткой блока `lang: base64` и хешем оригинала.

## 6. Состав этой папки

| Файл | Назначение |
|---|---|
| `PROMPT-FOR-CTF-DEVELOPER.md` | этот документ |
| `code/verify_ctf_output.py` | **главный инструмент**: round-trip верификатор v4-документов (`--sources` для побайтовой сверки) + `--diagnose` для legacy v3 (fence-aware + resync по backticked-заголовкам); exit 0/1/2; сам fence-free |
| `code/make_fixtures.py` | генератор 13-file adversarial батареи (R7) |
| `code/aggregate_sources.py` | независимый fence-safe агрегатор (написан ДО знакомства с v4; динамический ранг, sha256, --verify, --self-test) — вторая референс-реализация тех же правил |
| `run_e2e.sh` | приёмочная цепочка: fixtures → ctf v4 → verify (ожидание 0) → pre-v4 ctf.sh из git-истории → diagnose (ожидание BROKEN) |
| `evidence/verify-v4.log` | 13/13 verified, 0 problems (v4.0.0 + батарея) |
| `evidence/diagnose-v3-fixtures.log` | pre-v4 ctf.sh: 8 intact / 5 BROKEN |
| `evidence/diagnose-field-doc.log` | field-документ v3.0.0: 4/4 intact (байты полны) |
| `evidence/ctf-adv-v4.md`, `evidence/ctf-adv-v3.md` | сами агрегаты батареи (v4 и pre-v4) |
| `MANIFEST.sha256` | контрольные суммы поставки; `mirror.sh` — бэкап-дисциплина |

## 7. Приложение: воспроизведение доказательств

```bash
# 1. Тест-сьют HEAD (2 падения)
git clone https://github.com/paulmann/ctf-collect-to-file.git && cd ctf-collect-to-file
bash tests/run_tests.sh | tail -4
git ls-files -s ctf.sh install.sh          # → 100644 100644 (нет +x)
shellcheck --severity=style ctf.sh | grep -c SC2015   # → 3 (shellcheck 0.9.0)

# 2. Батарея против v4
python3 <this>/code/make_fixtures.py /tmp/ctf-adv
bash ctf.sh /tmp/ctf-adv -o /tmp/ctf-adv-v4.md --metadata --no-timestamp
python3 <this>/code/verify_ctf_output.py /tmp/ctf-adv-v4.md --sources /tmp/ctf-adv
#    → verify: 13 file(s) verified, 0 problem(s)

# 3. Батарея против pre-v4 (репродукция дефекта)
git show 7737cf5^:ctf.sh > /tmp/ctf_v3.sh
bash /tmp/ctf_v3.sh '*' /tmp/ctf-adv /tmp/ctf-adv-v3.md
python3 <this>/code/verify_ctf_output.py /tmp/ctf-adv-v3.md --diagnose
#    → 13 sections — intact: 8, BROKEN: 5  (fence3/fence4/indented/meta_spoof/mixed)

# 4. Форензика field-документа v3.0.0
python3 <this>/code/verify_ctf_output.py All-Project-Files.md --diagnose
#    → 4 sections — intact: 4  (байты полны; probe встроен в ~~~-fence, строки 226/1750)
grep -c $'\r' All-Project-Files.md          # → 2202  (CRLF-конверсия контента)
```

---

*Этот промт сам является fence-safe документом: единственный блок с тройными
backtick'ами — TL;DR, и он не содержит чистых fence-строк внутри; ранги всех
блоков ≥ 3 и содержимое их не закрывает. `MANIFEST.sha256` прилагается.*
