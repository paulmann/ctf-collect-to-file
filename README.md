# ctf — Collect To File

Recursively collects source files into a single Markdown, JSON, JSONL or text
document, preserving paths relative to the source root. Built for assembling
LLM context, code-review bundles and auditable source snapshots.

<p>
  <img src="https://img.shields.io/badge/version-4.0.0-brightgreen" alt="version 4.0.0">
  <img src="https://img.shields.io/badge/bash-4.2%2B-blue" alt="bash 4.2+">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey" alt="Linux / macOS">
  <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6" alt="Windows 10/11">
  <img src="https://img.shields.io/badge/license-MIT-yellow" alt="MIT">
  <img src="https://img.shields.io/badge/shellcheck-clean-success" alt="shellcheck clean">
</p>

---

## Contents

1. [Why](#1-why)
2. [Install](#2-install)
3. [Quick start](#3-quick-start)
4. [Options reference](#4-options-reference)
5. [Output formats](#5-output-formats)
6. [Controlling what gets collected](#6-controlling-what-gets-collected)
7. [Fitting a token budget](#7-fitting-a-token-budget)
8. [Self-update](#8-self-update)
9. [Exit codes](#9-exit-codes)
10. [Windows](#10-windows)
11. [Configuration file](#11-configuration-file)
12. [Behaviour worth knowing](#12-behaviour-worth-knowing)
13. [Development](#13-development)
14. [Performance](#14-performance)
15. [License](#15-license)

---

## 1. Why

Three situations come up constantly:

- **LLM context.** A model reasons better over one structured document than
  over twenty pasted fragments: it keeps the directory layout, the file
  boundaries and the language of each file. `ctf` produces exactly that, and
  can cap it at a token budget you specify.
- **Cross-file review.** A branch touching 20 files is easier to read as a
  single syntax-highlighted document than as 20 diffs.
- **Snapshots and audits.** A reproducible, timestamped aggregate of the
  sources, with per-file hashes on request.

`ctf` is a single self-contained script with no dependencies beyond a POSIX
userland. It does not shell out to `eval`, it does not execute anything it
reads, and it never writes outside the file you asked for.

---

## 2. Install

```bash
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file

# user-level install into ~/.local/bin
make install

# or system-wide
sudo make install PREFIX=/usr/local

# or without make
./install.sh --prefix "$HOME/.local"
```

Verify:

```bash
ctf --version      # ctf v4.0.0
ctf --print-config .
```

Requirements: **bash 4.2+** (CentOS/RHEL 7 baseline), plus `awk`, `find`,
`sort`, `sed`, `head`, `tail`, `od`, `cat`, `wc`, `mktemp`, `stat`.
Optional and auto-detected: `file` (faster binary check), `git` (`--git`),
`sha256sum`/`shasum` (`--dedup`, `--metadata`), `curl`/`wget`/`python3`/`perl`
(`--update`). Run `ctf --print-config .` to see what was detected.

---

## 3. Quick start

```bash
# every PHP file under ./src into result.md
ctf php ./src result.md

# several extensions, modern option form
ctf -e php,js,ts -o bundle.md ./src

# everything the repository tracks or would track (honours .gitignore)
ctf --git all -o context.md .

# exactly 120k estimated tokens of Python, to the clipboard
ctf -e py --token-budget 120000 -o - . | pbcopy        # macOS
ctf -e py --token-budget 120000 -o - . | xclip         # Linux

# what would be collected, and how big would it be?
ctf --stats ./src
ctf --dry-run -e py ./src | head
```

---

## 4. Options reference

`ctf [OPTIONS] [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]`

The three positional arguments are kept for compatibility with v1–v3 and are
equivalent to `--ext`, the source directory and `--output`. See
[§12](#12-behaviour-worth-knowing) for how positional arguments are resolved
when options are also present.

### Collection

| Option | Meaning |
|:---|:---|
| `-e`, `--ext LIST` | Comma-separated extensions, e.g. `php,js,sh`. Repeatable. A leading dot is optional, matching is case-insensitive. Omit to collect every text file. |
| `-E`, `--exclude GLOB` | Exclude matching paths. Repeatable. `*` also crosses `/`; the bare file name is matched too. |
| `-I`, `--include GLOB` | Keep only matching paths. Repeatable. |
| `--exclude-dir NAME` | Exclude a directory name at any depth. Repeatable, comma-separated list accepted. |
| `--no-default-excludes` | Do not apply the built-in VCS/dependency/build excludes. |
| `--list-default-excludes` | Print the built-in exclude lists and exit. |
| `-d`, `--max-depth N` | Maximum depth below `SOURCE_DIR` (`0` = unlimited). |
| `-L`, `--follow` | Follow symlinks. Without it, symlinked files are counted as skipped and directory symlinks are not descended. |
| `--max-size SIZE` | Skip files larger than `SIZE` (bytes or `K`/`M`/`G`/`T` suffix). |
| `--min-size SIZE` | Skip files smaller than `SIZE`. |
| `--files-from FILE` | Take the file list from `FILE` (`-` = stdin), newline- or NUL-separated, relative to `SOURCE_DIR`. |
| `--git MODE` | Enumerate with git instead of find: `tracked` = `git ls-files --cached`; `all` = tracked + untracked, honouring `.gitignore`. |
| `--binary MODE` | Binary detection: `auto` (default), `never`, `always`. |

### Output

| Option | Meaning |
|:---|:---|
| `-o`, `--output FILE` | Destination. `-` writes to stdout. Default: `all-<ext>-files.md` or `All-Project-Files.md`. |
| `-F`, `--format FMT` | `md` (default), `json`, `jsonl`, `txt`. |
| `--heading-level N` | Markdown heading level for file paths (1–6, default 3). |
| `--path-style STYLE` | `rel` (default) or `abs`. |
| `--sort KEY` | `path` (default), `name`, `size`, `mtime`. `size`/`mtime` sort descending. |
| `--title TEXT` | Document title. |
| `--no-header` | Omit the metadata header. |
| `--no-summary` | Omit the trailing summary. |
| `--no-timestamp` | Omit the generation timestamp — makes the output byte-reproducible. |
| `--toc` | Add a table of contents with GitHub-compatible anchors. |
| `--metadata` | Add a per-file HTML comment: bytes, lines, `sha256/12`. |
| `--line-numbers` | Prefix every content line with its number. |
| `--lang-style STYLE` | `fenced` (default), `indent4`, `none`. |
| `--strip-bom` | Remove a leading UTF-8 BOM from each file. |
| `--truncate-lines N` | Keep at most `N` content lines per file (`0` = all). |
| `--token-budget N` | Estimated token budget for the whole document. |
| `--budget-action A` | What to do with a file that does not fit: `truncate` (default) or `drop`. |
| `--dedup` | Emit byte-identical files once (requires `sha256sum` or `shasum`). |

### Behaviour

| Option | Meaning |
|:---|:---|
| `-n`, `--dry-run` | Print the selection as TSV (`path`, `lang`, `bytes`, `lines`, `sha256/12`); write nothing. |
| `--stats` | Print `key=value` statistics and exit. |
| `--strict` | Exit `4` when nothing was collected. |
| `-c`, `--config FILE` | Read `VAR=VALUE` defaults from `FILE`. |
| `--print-config` | Show the effective configuration and detected tools, then exit. |
| `-q`, `--quiet` | Errors only on stderr. |
| `-v`, `--verbose` | Debug output on stderr, including every skip and its reason. |
| `--color WHEN` | `auto` (default), `always`, `never`. Colours go to stderr only. |
| `-h`, `--help` | Help. |
| `-V`, `--version` | Version. |

### Self-update

| Option | Meaning |
|:---|:---|
| `--check-update` | Query the remote and report; exit `0` when current, `3` when newer or unreachable. |
| `--update` | Download and install the newer version over this script. |
| `--update-channel CH` | `main` (default), `latest` (newest release tag) or any branch/tag. |
| `--update-force` | Reinstall even when the version is identical. |
| `--update-timeout S` | Per-request timeout in seconds (default 15). |

### Environment

| Variable | Meaning |
|:---|:---|
| `CTF_CONFIG` | Default configuration file (overridden by `--config`). |
| `NO_COLOR` | Any value disables colours. |
| `SOURCE_DATE_EPOCH` | Unix timestamp used instead of “now” — reproducible builds. |
| `CTF_UPDATE_CHANNEL` | Default update channel. |
| `CTF_UPDATE_TIMEOUT` | Default per-request timeout, seconds. |
| `CTF_UPDATE_BASE_URL` | Download root override: internal mirror, air-gapped artifact store, or a test server. |
| `CTF_BINARY_SCAN_BYTES` | Bytes inspected by the fallback binary scan (default 8192). |
| `CTF_BINARY_CTRL_PCT` | Control-byte percentage above which a file is binary (default 5). |

---

## 5. Output formats

### Markdown (default)

```markdown
# Project Source Code Aggregate

| Field | Value |
|:------|:------|
| Generated (UTC) | 2026-10-08T12:00:00Z |
| Tool | ctf.sh v4.0.0 |
| Source | /repo |
| Extensions | php |
| Candidates | 42 |
| Collected | 37 |

---

### `src/Api/Client.php`

```php
<?php
...
```

---

## Summary

| Metric | Value |
|:-------|------:|
| Candidates | 42 |
| Collected | 37 |
| Skipped | 5 |
| Source bytes | 184320 (180.00 KiB) |
| Estimated tokens | 46080 |

**Skip reasons**

| Reason | Count |
|:-------|------:|
| binary | 2 |
| excluded-dir | 3 |
```

The skip-reason table is the part that saves time: when a file you expected is
missing, the document itself tells you why.

### JSON / JSONL

`--format json` produces one object; `--format jsonl` produces one object per
line (streamable, `jq`-friendly):

```json
{"path":"src/Api/Client.php","lang":"php","bytes":4096,"lines":120,"sha256":"a1b2…","content":"<?php\n…"}
```

`content` is JSON-escaped; control characters other than `\t`, `\n` and `\r`
are removed, since JSON cannot carry them unescaped and source text never
contains them.

### Plain text

`--format txt` emits `===== path (lang, size) =====` separators and no Markdown
at all — convenient for `diff`, `grep` and diff-based review tools.

---

## 6. Controlling what gets collected

**Default excludes.** VCS metadata (`.git`, `.svn`, `.hg`), dependency trees
(`node_modules`, `vendor`, `.venv`, `__pycache__`), build output (`build`,
`dist`, `out`, `target`, `obj`, `release`), caches, IDE directories and
generated files (`*.min.js`, `*.map`, lock files, `*.pyc`, shared objects,
executables). Excluded directories are pruned by `find` before descent, so
large `node_modules` trees cost nothing. List them with
`--list-default-excludes`, disable with `--no-default-excludes`.

**The source root itself is never excluded.** A tree rooted at `./dist`,
`./build` or `./out` is scanned normally — only directories *below* the root
are matched against the exclude list.

**Patterns.** Globs use bash pattern syntax, where `*` also crosses `/`:

```bash
ctf -E 'tests/*' -E '*.md' -E 'docs/**' -o ctx.md .
ctf -I 'src/**' -o src-only.md .
ctf --exclude-dir legacy,tmp -o clean.md .
```

**Git-aware selection.** `--git all` is usually what you want inside a
repository: it uses the index plus untracked-but-not-ignored files, so
`.gitignore` does the filtering for you and build output never appears.

**Symlinks** are skipped by default and reported as `skip_symlink` — never
silently. Pass `-L` to follow them.

---

## 7. Fitting a token budget

The estimate is `ceil(bytes / 4)`, which is conservative for source code.

```bash
ctf -e py --token-budget 120000 --stats .        # will it fit?
ctf -e py --token-budget 120000 -o ctx.md .      # default: truncate to fit
ctf -e py --token-budget 120000 --budget-action drop -o ctx.md .
```

Files are taken in `--sort` order until the budget is exhausted. With
`--budget-action truncate` (default) the file that does not fit whole is cut at
a line boundary and marked with an HTML comment; with `drop` it is skipped and
counted in `budget_dropped`. Both are reported in the summary.

Combine with `--sort size` to prioritise the largest files, or with
`--max-size 64K` to keep one generated monster from eating the window.

---

## 8. Self-update

```bash
ctf --check-update          # local=4.0.0 remote=4.0.1 channel=main status=newer
ctf --update                # installs 4.0.1, keeps ctf.sh.bak-<timestamp>
ctf --update --update-channel latest
```

Safety properties, each covered by `tests/test_update.sh`:

- The download is validated **before** anything is overwritten: minimum size,
  a leading shebang, and a clean `bash -n`. An HTML error page, a truncated
  download or a syntactically broken script is refused and the installed copy
  is left untouched.
- A timestamped backup is created first; if the write fails, the previous
  version is restored.
- The new bytes are written **through the existing inode**, so ownership, mode
  and hard links survive.
- Sibling `VERSION`, `ctf.ps1` and `ctf.bat` files are refreshed only if they
  already exist next to the script.
- Transport fallback: `curl` → `wget` → `python3` → `perl` → bash `/dev/tcp`.
  The last one has no TLS, and says so instead of failing mysteriously.
- `CTF_UPDATE_BASE_URL` points the whole flow at a mirror (or a local test
  server), which is how the test suite exercises it without internet access.

---

## 9. Exit codes

| Code | Meaning |
|:---|:---|
| `0` | Success. |
| `1` | Runtime error: I/O failure, permissions, unexpected state. |
| `2` | Usage error: unknown option, invalid value, unreadable source. |
| `3` | Update or network error (`--check-update`, `--update`). |
| `4` | Nothing collected and `--strict` was given. |

`--check-update` uses `3` for “a newer version exists”, so it can be used
directly as a CI gate:

```bash
ctf --check-update && echo "up to date" || echo "update available"
```

---

## 10. Windows

`ctf.bat` is a thin launcher; the implementation lives in `ctf.ps1`
(Windows PowerShell 5.1+ or PowerShell 7+). Both are CRLF in the repository —
enforced by `.gitattributes`, because LF line endings break labels and `goto`
in `cmd.exe`.

```bat
ctf.bat php C:\projects\src C:\out\bundle.md
ctf.bat --check-update
```

```powershell
.\ctf.ps1 -Ext php,js -Source .\src -Output bundle.md
```

The PowerShell port implements the collection, filtering, binary detection,
fence selection and Markdown/JSON output. Options that depend on POSIX
semantics (`--files-from -` from stdin, symlink modes) behave as documented in
`ctf.ps1 -Help`.

---

## 11. Configuration file

```ini
# ~/.ctfrc — plain VAR=VALUE, no code
CTF_FORMAT=md
CTF_SORT=path
CTF_TOKEN_BUDGET=120000
CTF_DEFAULT_EXCLUDES=1
CTF_TITLE="Project sources"
```

```bash
ctf -c ~/.ctfrc -e py .
CTF_CONFIG=~/.ctfrc ctf -e py .
ctf --print-config .        # what is actually in effect, and why
```

The file is treated strictly as data:

- only variables on the `CTF_*` whitelist are accepted; anything else is
  ignored with a warning;
- values are never passed to `eval` — there is no `eval` in the bash code;
- values containing `$(`, backticks, `;`, `|`, `&`, `<`, `>` or `$` are
  rejected;
- a group- or world-writable config is **ignored** with a warning, because
  such a file could be planted by another local user.

---

## 12. Behaviour worth knowing

**Positional arguments** fill the slots `EXTENSION`, `SOURCE_DIR`,
`OUTPUT_FILE` in that order, but only slots that no option has already filled,
and an argument naming an existing directory is always taken as `SOURCE_DIR`:

| Invocation | Extension | Source | Output |
|:---|:---|:---|:---|
| `ctf php ./src out.md` | php | ./src | out.md |
| `ctf -e php ./src` | php | ./src | default |
| `ctf ./src` | — | ./src | default |
| `ctf -e php -o out.md ./src` | php | ./src | out.md |

**Binary detection** uses two signals, both false-positive-free for real text:
a NUL byte in the first 8 KiB, or more than 5 % C0 control bytes (excluding
`\t \n \v \f \r`). High bytes are *not* evidence of binary — otherwise every
non-English source file would be dropped. When `file(1)` is present its verdict
is used first. Known limitation: a file under ~1 KiB of high-entropy data with
no NUL and very few control bytes can pass as text; use `--ext` or
`--binary always` when that matters.

**Fences are computed per file.** A fenced block is closed only by a line
consisting of nothing but fence characters (optionally indented up to 3
spaces), so `ctf` finds the longest such run in the file and emits a fence one
character longer — choosing backticks or tildes, whichever is shorter. Content
is therefore never able to break out of its block.

**A file without a trailing newline** still gets its closing fence on a line of
its own.

**File names** may contain any byte except `/` and NUL, and `ctf` handles
spaces, quotes, backticks, `$`, `;`, tabs and newlines — verified by
`tests/test_safety.sh`, which also asserts that no payload inside a file name
is ever executed. Names containing CR/LF/TAB are flattened *for display only*
(headings, TOC, TSV); content is copied byte-for-byte.

**Reproducibility.** With `--no-timestamp` (or `SOURCE_DATE_EPOCH`), identical
input yields byte-identical output, so a snapshot can be committed and diffed.

**The output file is never collected into itself**, even when it lives inside
the scanned tree; the skip is reported as `skip_output_file`.

**Atomic writes.** The document is assembled in temporary files next to the
destination and moved into place; a symlinked destination is written through,
so the link is not replaced by a regular file. Temporary files are removed by
an EXIT trap.

---

## 13. Development

```bash
make test          # full suite: 8 files, 243 assertions, no network, no root
make lint          # shellcheck --severity=style on ctf.sh and tests
make check         # lint + test
make install       # install ctf.sh, ctf.ps1, ctf.bat
make uninstall
```

Or directly:

```bash
tests/run_tests.sh                 # everything
tests/run_tests.sh --filter binary # one file
tests/run_tests.sh --verbose       # print every passing assertion
tests/run_tests.sh --keep-tmp      # keep the scratch directory
CTF=/path/to/other/ctf.sh tests/run_tests.sh   # test a different copy
```

Layout:

```
ctf.sh             the tool (bash 4.2+, 2222 lines, shellcheck-clean at style level)
ctf.ps1            Windows implementation (PowerShell 5.1+, 1139 lines)
ctf.bat            Windows launcher (68 lines, CRLF)
VERSION            single source of truth for the version, read by --update
tests/             8 test files, 243 assertions; sources ctf.sh, no framework
  run_tests.sh     runner (--filter, --verbose, --keep-tmp)
  lib.sh           assertions, fixtures, ctf_run/ctf_stats helpers
  test_cli.sh      options, positional forms, exit codes
  test_collect.sh  extensions, excludes, symlinks, depth, size, git, --files-from
  test_binary.sh   binary detection: determinism and false positives
  test_output.sh   document structure, fences, formats, TOC, budget, BOM
  test_safety.sh   atomic writes, hostile file names, config file, temp hygiene
  test_update.sh   self-update end-to-end against a local HTTP server
  test_parity.sh   ctf.sh vs ctf.ps1: byte-identical output and CLI parity
  test_meta.sh     versions, shellcheck, bash 4.2 portability, docs consistency
docs/ANALYSIS.md   audit of v3.1.0: 20 defects with reproduction commands
docs/DECISIONS.md  20 design decisions: context, choice, cost
install.sh         POSIX installer (no make required)
Makefile           install / uninstall / test / lint / check / dist
.github/workflows/ci.yml
```

CI runs shellcheck, `bash -n`, the suite (Ubuntu and macOS), version
consistency across `VERSION`/`ctf.sh`/`README`/`CHANGELOG`, a PowerShell parse
check of `ctf.ps1`, and line-ending policy (`.bat`/`.ps1` CRLF, `.sh` LF).
When `pwsh` is present — it is on `ubuntu-latest` — `test_parity.sh` also
compares the two implementations byte-for-byte.

**Linting policy** (see `docs/DECISIONS.md`, DR-18): `ctf.sh` and `install.sh`
must be clean at `--severity=style`; tests must be clean at
`--severity=warning`; deliberate suppressions carry an explanatory directive
instead of a global `.shellcheckrc`.

---

## 14. Performance

Metadata reads are batched — sizes via `stat --printf`, binary classification
via `grep -IlZ`, and lines/fence-runs/byte-sums via one `awk` pass per ~200
files. The only per-file process left is the `cat` that copies content, and
hot-path helpers return through globals instead of command substitution, so no
subshell is forked per file.

Measured in a container, 2 CPU:

| Tree | v3.1.0 | v4.0.0 |
|:---|---:|---:|
| 2 000 small JS files | 19.0 s | 9.0 s |
| 600 files / 13 MiB | — | 2.7 s |

Measured in a container with 2 CPU. Batched output is byte-identical to the
unbatched implementation, which the determinism tests assert.

Batched output is byte-identical to the unbatched implementation (asserted by
the determinism tests).

---

## 15. License

MIT — see [LICENSE](LICENSE).

Author: Mikhail Deynekin — <Mikhail@Deynekin.com> — https://deynekin.com
