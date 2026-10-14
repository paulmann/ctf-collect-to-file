# REWORK-STATE — for_ctf-collect-to-file (forensics + improvement prompt)

**Last updated:** 2026-10-14
**Задача:** по итогам тестового прогона (developer упаковал поставку
`for_github-wiki-llm-writer/code/` своим ctf v3.0.0 → `uploads/All-Project-Files.md`)
разобраться, что реально сломалось, и выдать разработчику
`paulmann/ctf-collect-to-file` промт на доработку + инструменты.

## Статус: ВЫПОЛНЕНО

- [x] Клон ctf (wiki-work/tools-ctf, HEAD b11ac44, v4.0.0) + git-история.
- [x] Форензика field-документа: байты ВСЕХ 4 файлов полны; probe встроен в
      ~~~-fence (строки 226/1750); документ CRLF (2 202 CR); хешей нет.
      Прежняя атрибуция «ctf обрезал файлы» — НЕВЕРНА: обрезал мой наивный
      regex-экстрактор. Исправление внесено в PROMPT §0 и в §A11 отчёта
      for_github-wiki-llm-writer.
- [x] Прогон тест-сьюта v4: 209 проверок, 2 падения (test_meta.sh): exec-bit
      (100644 в индексе) + SC2015 ×3 (shellcheck 0.9.0, --severity=style).
- [x] Pre-v4 ctf.sh (7737cf5^) из истории: фиксированные ```-fences;
      на батарее 13 фикстур → 5 BROKEN + binary встроен (0 skipped).
- [x] v4.0.0 + батарея: 13/13 verified 0 problems (--metadata --no-timestamp,
      round-trip побайтово через --sources; CRLF/BOM/emoji/no-NL/4-backtick/
      indented/meta-spoof/unicode-path/binary-skip/counters).
- [x] Инструменты: verify_ctf_output.py (verify + --diagnose с fence-aware
      resync), make_fixtures.py (13), aggregate_sources.py (docstring исправлен),
      run_e2e.sh; evidence/ (3 лога + 2 агрегата).
- [x] PROMPT-FOR-CTF-DEVELOPER.md (R1..R9, TL;DR EN, приложения).
- [x] README.md, MANIFEST.sha256, mirror.sh → /home/user/backup/for_ctf-collect-to-file/.
- [x] Корректировки в for_github-wiki-llm-writer: §A11 переписан (corrected
      attribution), aggregate_sources docstring, dist перегенерирован, MANIFEST,
      зеркала; wiki-work REWORK-STATE — запись о корректировке.

## Ключевые факты для преемника

- v4.0.0 УЖЕ исправляет fence-класс (choose_fence: max чистых прогонов +1,
  min 3, короткий из двух символов; DR-09 считает только ЧИСТЫЕ fence-строки
  с отступом ≤3 — mid-line backticks не в счёт). Не «переизобретать» это в
  промте — требования R1..R9 про ОСТАВШИЕСЯ зазоры.
- Мой diagnose-парсер: fence-aware + resync по заголовкам `### <BT>name<BT>`
  (инвариант ctf); resync СБРАСЫВАЕТ fence-состояние (баг первой версии —
  последняя секция ложно BROKEN; исправлено).
- verify читает документ БАЙТАМИ (read_bytes+decode) — text-mode universal
  newlines съедал CRLF и ронял crlf.txt (исправлено; урок в docstring).
- Контракт v4-вывода: `### <BT>rel<BT>` · `<!-- N bytes · L lines · H · sha256:HEX12 -->` ·
  fence dynamic-rank+lang · контент verbatim · ends_nl=0 → ровно один
  добавленный \n · `<!-- truncated to fit the token budget -->` · `---` ·
  Summary (Candidates/Collected/Skipped + skip reasons).
- Ловушки среды (повторяются!): B4 — абсолютные пути /home/user в heredoc
  манглятся в "$ARENA_WORKSPACE" (3 раза за сессию; лечение: env-переменные,
  write_file, cd+относительные); B11-класс — длинные скрипты после spawn/kill
  периодически не видят существующие файлы (лечение: retry/fallback, сверка
  из shell); silent no-op у str.replace — ВСЕГДА assert'ить.

## Log (append-only)

- 2026-10-14 Клон ctf; v4.0.0 HEAD b11ac44; тест-сьют 209/2 fail; pre-v4 из
  истории; батарея 13 фикстур: v4 → 13/13 verified; pre-v4 → 5 BROKEN + binary
  embedded; field-документ → 4/4 intact (байты полны, ~~~-fence, CRLF 2202).
  Инструменты + evidence + PROMPT (R1..R9) + README + MANIFEST + mirror.
  Корректировки прежних утверждений внесены во все затронутые артефакты.
