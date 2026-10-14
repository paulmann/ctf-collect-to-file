# for_ctf-collect-to-file — forensic report + tools for ctf v4

Материалы для разработчика `paulmann/ctf-collect-to-file` по итогам полевого
инцидента (2026-10-14: упаковка поставки агента сборкой **v3.0.0** на Windows)
и независимого тестирования **v4.0.0** (HEAD `b11ac44`).

## Главное

1. **Исправление атрибуции (честность):** байты всех 4 файлов в v3-документе
   присутствовали полностью (probe был встроен даже в tildes-fence `~~~` —
   сборка v3 переключала символ). «Обрезание до 2 356 B / 1 B» — артефакт
   наивного regex-экстрактора потребителя (агентской стороны). Реальные
   дефекты v3-документа: молчаливая CRLF-конверсия контента (2 202 строки),
   отсутствие хешей, фантомные заголовки из контента для fence-неосведомлённых
   парсеров; репозиторный pre-v4 `ctf.sh` (фиксированный ранг-3) ломает 5/13
   adversarial-фикстур и встраивает бинарники — воспроизведено.
2. **v4.0.0 проверен независимо:** динамический ранг fence (DR-09),
   детерминированный binary-skip, `--metadata` sha256/12, байт-точный
   round-trip (CRLF/BOM/emoji/no-trailing-newline/4-backtick/indented-closers/
   meta-spoof/unicode-пути) — **13/13 verified, 0 problems**, счётчики сходятся.
3. **Дефекты HEAD его же тест-сьютом:** `tests/run_tests.sh` → 209 проверок,
   **2 падения** (test_meta.sh): `ctf.sh`/`install.sh` без executable bit
   (mode 100644 в индексе) и shellcheck `--severity=style` → 4 замечания
   (SC2015 ×3 в пути записи `--update`).
4. **Промт на доработку:** `PROMPT-FOR-CTF-DEVELOPER.md` — R1..R9 с
   критериями приёмки (P0: починить свой сьют + добавить `--verify`;
   P1: полные хеши, capability-маркер, контракт извлечения; P2: CRLF-политика
   ps1, батарея фикстур в tests/, инвариант заголовков, base64-бинарники).

## Состав

| Файл | Назначение |
|---|---|
| `PROMPT-FOR-CTF-DEVELOPER.md` | отчёт-промт (TL;DR на английском для issue + полная русская версия с доказательствами) |
| `code/verify_ctf_output.py` | round-trip верификатор v4-агрегатов (`--sources` — побайтово) + `--diagnose` для legacy v3-документов (fence-aware парсинг, resync по backticked-заголовкам); exit 0/1/2; fence-free |
| `code/make_fixtures.py` | генератор 13-файловой adversarial батареи |
| `code/aggregate_sources.py` | независимый fence-safe агрегатор (вторая референс-реализация; docstring содержит исправленную хронологию инцидента) |
| `run_e2e.sh` | приёмочная цепочка: fixtures → v4 verify (0) → pre-v4 diagnose (1) → опционально field-документ |
| `evidence/verify-v4.log` | 13/13 verified, 0 problems |
| `evidence/diagnose-v3-fixtures.log` | pre-v4: 13 секций, 8 intact / 5 BROKEN |
| `evidence/diagnose-field-doc.log` | field-документ v3.0.0: 4/4 intact (байты полны) |
| `evidence/ctf-adv-v4.md` / `ctf-adv-v3.md` | агрегаты батареи (v4 / pre-v4) |
| `REWORK-STATE.md` | состояние задачи, лог, ловушки среды (B4/B11) |
| `mirror.sh` + `/home/user/backup/for_ctf-collect-to-file/` | бэкап-дисциплина (требование ENV) |
| `MANIFEST.sha256` | контрольные суммы: `sha256sum -c MANIFEST.sha256` |

## Быстрый прогон

```bash
# всё сразу (нужен клон ctf; путь через CTF_REPO):
CTF_REPO=~/wiki-work/tools-ctf bash run_e2e.sh

# или вручную:
python3 code/make_fixtures.py /tmp/adv
bash "$CTF_REPO/ctf.sh" /tmp/adv -o /tmp/adv-v4.md --metadata --no-timestamp
python3 code/verify_ctf_output.py /tmp/adv-v4.md --sources /tmp/adv   # → 13/13, exit 0
python3 code/verify_ctf_output.py OLD_V3_DOC.md --diagnose            # → intact/BROKEN per file
python3 code/aggregate_sources.py --self-test                         # → PASSED
```
