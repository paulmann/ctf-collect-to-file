# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.0] — 2026-10-08

Major release: correctness of the collected document, self-update, and a
test suite. Every fixed defect below is reproduced by a test in `tests/`.

### Fixed — correctness (these changed the bytes of the output)

- **Non-deterministic binary detection.** v3 piped
  `head -c 8192 file | od | tr | grep -q '00'`. Under `set -o pipefail`,
  `grep -q` exits at the first match and closes the pipe; `od` then dies of
  SIGPIPE and the pipeline reports 141, so the file was classified as *text*.
  The outcome depended on process scheduling: six identical runs over the same
  tree collected 3, 2, 4, 4, 3 and 4 files, and the document contained NUL
  bytes. Detection is now a single `od | awk` pass with no early-exiting
  consumer. `tests/test_binary.sh` asserts that 8 runs are byte-identical.
- **Binary detection no longer depends on `file(1)`.** Where v3 fell back to
  the fragile pipeline, v4 uses two independent signals: a NUL byte in the
  first 8 KiB, or more than 5 % C0 control bytes. High bytes are *not*
  evidence of binary, so UTF-8, CP1251, KOI8-R and emoji-bearing sources are
  no longer dropped.
- **A source root named like an excluded directory was skipped entirely.**
  `find "$root" -name out -prune` matches the starting point itself, so
  `ctf js ./dist`, `./build`, `./out`, `./target`, `./obj`, `./release` and
  `./coverage` collected **0 files** and reported success. Fixed with
  `-mindepth 1` (plus a post-filter fallback for `find` builds without it).
- **A file name containing a newline broke the Markdown structure**: the
  heading was split across lines. Display strings are now flattened
  (`sanitize_display`); file *content* is still copied verbatim.
- **A file name containing a TAB corrupted the sort table** and the file was
  silently dropped — the counter invariant `candidates = collected + skipped`
  was violated. Sort keys are sanitised and the invariant is asserted at
  runtime, falling back to discovery order with a warning.
- **Exit codes.** v3 returned 1 for everything, including usage errors. v4
  distinguishes `0` success, `1` runtime, `2` usage, `3` update/network,
  `4` nothing collected with `--strict`.
- **Output file permissions.** The document was left with mode `0600`
  inherited from `mktemp`; it is now created with `0666 & ~umask` (normally
  `0644`), so other users and CI artefact collectors can read it.
- **Version drift.** `ctf.sh` said 3.0.0 while `README.md` and `ctf.bat` said
  3.1.0. A single `VERSION` file is now the source of truth, and
  `tests/test_meta.sh` fails the build if it disagrees with the script.

### Added — self-update

- `--check-update` — queries GitHub and prints a machine-readable line
  `local=… remote=… channel=… status=up-to-date|newer|unreachable`.
  Exit `0` when current, `3` when a newer version exists or the lookup fails.
- `--update` — downloads and installs the new version over the running script:
  a timestamped `.bak-` copy is taken first, the download is validated
  (minimum size, leading shebang, `bash -n`, embedded version), the write goes
  through the existing inode so ownership, mode and hard links survive, and
  sibling `VERSION` / `ctf.ps1` / `ctf.bat` files are refreshed when present.
  A failed validation never touches the installed script.
- `--update-channel main|latest|<ref>`, `--update-force`, `--update-timeout S`.
- `CTF_UPDATE_BASE_URL` overrides the download root — for an internal mirror,
  an air-gapped artifact store, and the test suite (which runs the whole flow
  against a local HTTP server, no internet required).
- Transport fallback chain: `curl` → `wget` → `python3` → `perl` →
  bash `/dev/tcp` (plain HTTP only; the lack of TLS is reported explicitly).

### Added — collection

- `--git tracked|all` — enumerate with `git ls-files` instead of `find`;
  `all` includes untracked files and honours `.gitignore`, which is the most
  useful mode for assembling LLM context from a repository.
- `--files-from FILE` (`-` = stdin), newline- or NUL-separated.
- `-e/--ext` accepts a comma-separated list (`php,js,sh`); matching is
  case-insensitive; a leading dot is optional.
- `-E/--exclude GLOB`, `-I/--include GLOB`, `--exclude-dir NAME` (repeatable).
- Default excludes for VCS metadata, dependency trees, build output, caches
  and lock files; `--no-default-excludes` and `--list-default-excludes`.
- `-d/--max-depth`, `--max-size`, `--min-size` (with `K/M/G/T` suffixes),
  `-L/--follow` for symlinks, `--binary auto|never|always`.

### Added — output

- `-F/--format md|json|jsonl|txt`.
- `--token-budget N` with `--budget-action truncate|drop` and a documented
  estimate (`ceil(bytes / 4)`): assemble context that provably fits a window.
- `--toc` with GitHub-compatible anchors, `--metadata` (bytes, lines,
  `sha256/12` as an HTML comment), `--line-numbers`, `--truncate-lines N`,
  `--strip-bom`, `--lang-style fenced|indent4|none`, `--heading-level N`,
  `--path-style rel|abs`, `--sort path|name|size|mtime`, `--title`,
  `--no-header`, `--no-summary`, `--no-timestamp`.
- `--dedup` emits byte-identical files once (needs `sha256sum`/`shasum`).
- The summary now reports *why* files were skipped
  (`binary`, `symlink`, `extension`, `excluded-dir`, `too-large`, …) instead of
  a single opaque counter.
- `-o -` writes the document to stdout with nothing else on that stream.
- `--dry-run` prints the selection as TSV; `--stats` prints
  `key=value` statistics for scripts and CI.
- `--no-timestamp` and `SOURCE_DATE_EPOCH` make the output byte-reproducible.

### Added — engineering

- A test suite (`tests/run_tests.sh`, 7 files, 150+ assertions) covering the
  CLI, selection, binary detection, document structure, safety, self-update
  and release metadata. No network, no root, no external test framework.
- `--print-config` shows the effective configuration *and* which optional
  tools were detected — the first thing to check when behaviour looks odd.
- `-c/--config FILE` reads defaults as `VAR=VALUE` data: a `CTF_*` whitelist,
  no `eval`, shell metacharacters rejected, and group/world-writable files are
  ignored with a warning.
- The script can be `source`d without executing (`BASH_SOURCE` guard), so the
  tests exercise internal functions directly.
- `shellcheck --severity=style` is clean; a source-guard test asserts that no
  bash ≥ 4.3 construct is used (`local -n`, `wait -n`, `mapfile -d`, `${v@Q}`).
- Metadata: `VERSION`, `CHANGELOG.md`, `.gitattributes` (`.bat`/`.ps1` are
  CRLF, everything else LF), `.editorconfig`, `Makefile`, `install.sh`,
  GitHub Actions CI, and `docs/ANALYSIS.md` — the audit of v3.1.0 with
  reproduction commands.

### Changed — performance

- Metadata reads are batched: sizes via `stat --printf`, binary classification
  via `grep -IlZ`, and lines/fence-runs/byte-sums via one `awk` pass per ~200
  files. The only remaining per-file process is the `cat` that copies content.
- Hot-path helpers return through globals instead of command substitution, so
  no subshell is forked per file.
- Measured on 2 000 small files: **19.0 s → 9.0 s**. On 600 files / 13 MiB:
  2.7 s. Output is byte-identical to the unbatched implementation.

### Removed

- The BAT+PowerShell polyglot that extracted its own payload with `more +N`.
  `ctf.bat` is now a thin launcher and `ctf.ps1` is a first-class script, so
  there is one implementation per platform and the PowerShell code can be
  linted in CI.

### Compatibility

- Bash 4.2+ (CentOS/RHEL 7 baseline). No bash ≥ 4.3 features are used.
- The v1–v3 positional form `ctf.sh [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]`
  still works. One deliberate refinement: when `-e/--ext` or `-o/--output`
  already filled a slot, the remaining positional arguments fill the *unset*
  slots in order, and an argument that names an existing directory is always
  taken as `SOURCE_DIR`. So `ctf -e php ./src` means "extension php, source
  ./src" instead of silently treating `./src` as a second extension.

[4.0.0]: https://github.com/paulmann/ctf-collect-to-file/releases/tag/v4.0.0

## [3.1.0] — 2025-10

- Windows support via a BAT + embedded PowerShell hybrid; encoding detection.

## [3.0.0] — 2025-08

- Atomic writes, dynamic Markdown fences, symlink-aware finalisation.

## [2.0.0] — 2025-06

- Binary detection fallback, improved path resolution.

## [1.0.0] — 2025-04

- Initial release: `ctf.sh`, Bash-only, Linux.
