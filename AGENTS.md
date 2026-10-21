# AGENTS.md - ctf - Collect To File 4.1.0

Agent-facing guide: how to install `ctf`, run it safely, and report problems with evidence.
Human documentation: [README.md](README.md), [SKILL.md](SKILL.md), [docs/](docs/).

> Verified against repository state on 2026-10-22. Version covered: 4.1.0 (`VERSION`,
> `CTF_SCRIPT_VERSION` in `ctf.sh`, release tag `v4.1.0`). Help output was executed on this host
> (Git Bash 5.3.15, `pwsh` 7.6.6); installers, the test suite and collection runs were not.

## 1. What it is

`ctf` walks a source tree and writes one Markdown, JSON, JSONL or plain-text document, keeping
paths relative to the source root. It filters by extension, prunes built-in VCS/dependency/build
directories, classifies binary files deterministically, and can fit an estimated token budget.
It is for LLM context, multi-file review and auditable source snapshots. It is not a parser,
indexer or analyser: it copies text bytes and never executes anything it reads.

| | |
|---|---|
| Runtime / platform | Bash 4.2+ on Linux/macOS for `ctf.sh`; Windows through `ctf.ps1` (PowerShell 5.1+), installer needs `pwsh` 7.6+ |
| Entry point | Bash: `ctf.sh`, installed as `ctf`; Windows: `ctf.ps1`, `ctf.bat`, or the launcher `bin\ctf.cmd` |
| Writes to | one output document (default `all-<ext>-files.md` or `All-Project-Files.md` in the current directory), assembled in temporary files next to that destination |
| Network access | none during collection; `--check-update` and `--update` contact `raw.githubusercontent.com` and `api.github.com`, or the `CTF_UPDATE_BASE_URL` override |

## 2. Preconditions

| Requirement | Why | Check |
|---|---|---|
| Bash 4.2 or newer | `ctf.sh` refuses older shells at startup | `bash --version` |
| `awk`, `find`, `sort`, `sed`, `head`, `tail`, `od`, `cat`, `wc`, `mktemp`, `stat` | required by the collection path; `validate` aborts when `awk` or `find` is missing | `ctf --print-config .` (the `tools` line) |
| Optional: `file`, `git`, `sha256sum`/`shasum`, `curl`/`wget`/`python3`/`perl` | faster binary check, `--git`, `--dedup`/`--metadata`, self-update | same `tools` line |
| A writable destination directory | the document is built in temp files next to the output | `test -w <dir>` |
| Windows: `pwsh` 7.6+ for the installer; engine also runs on PowerShell 5.1 | `install-ctf.ps1` has `#Requires -Version 7.6` | `pwsh -NoProfile -Command '$PSVersionTable.PSVersion'` |

If a check fails, stop and report; do not substitute another toolchain silently.

## 3. Install

`gh release list -R paulmann/ctf-collect-to-file` reports one release, `v4.1.0` (Latest,
2026-10-14). `gh release view v4.1.0 -R paulmann/ctf-collect-to-file` shows **no release
assets**, so the release is installed from the tagged source tree; there is no binary to download.

### 3.1 From the release tag

```bash
git clone --branch v4.1.0 --depth 1 https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
bash ./install.sh --prefix "$HOME/.local"   # installs into ~/.local/bin
```

`install.sh` is committed without the executable bit, so call it through `bash` (see section 7).

### 3.2 From the current source (main)

```bash
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
bash ./install.sh --prefix "$HOME/.local"     # ~/.local/bin
sudo bash ./install.sh --prefix /usr/local    # system-wide, needs root
```

`make install` / `sudo make install PREFIX=/usr/local` run the same installer, but the `Makefile` calls `./install.sh`, which needs the executable bit first (`chmod +x install.sh ctf.sh`) - see section 7.

The installer copies `ctf.sh`, `ctf.ps1`, `ctf.bat` and `VERSION` into `$PREFIX/bin`, makes
`ctf.sh` executable, and creates the short name `ctf` as a symlink to it. It does not edit `PATH`;
it prints the `export PATH=...` line to add.

### 3.3 Windows

```powershell
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
pwsh -NoLogo -NoProfile -NonInteractive -File .\install-ctf.ps1
```

Default root: `%LOCALAPPDATA%\Programs\ctf`; `-InstallRoot C:\tools\ctf` for another location.
Layout: `bin\ctf.cmd` (the only directory added to the user `PATH`), `lib\ctf.ps1`,
`lib\ctf.bat`, `install-ctf.ps1`, plus copied `README.md` and `LICENSE`. The engine is deliberately
not on `PATH`; always call `ctf`, never `ctf.ps1`, with `--long-option` arguments.

### 3.4 Verify

```bash
ctf --version          # ctf v4.1.0
ctf --print-config .   # effective settings and detected tools
```

Measured first lines of `--print-config`: `script            ctf.sh v4.1.0`, then `path`, `ext`,
`source`, `output`, `format`, `title`, and a `tools             awk=1 file=1 od=1 find=1 ...` line.
Windows: `ctf --version` prints `ctf v4.1.0`; `cmd /c "where ctf"` and
`pwsh -NoProfile -Command "(Get-Command ctf).Source"` both resolve to `...\bin\ctf.cmd`.

## 4. Configure

No configuration is required. Defaults may be set in a plain `VAR=VALUE` file passed with
`-c`/`--config FILE` or named by `CTF_CONFIG` (README example: `~/.ctfrc`).

- Only names on the `CTF_*` whitelist are accepted; anything else is ignored with a warning.
  The whitelist (`CTF_CONFIG_VARS` in `ctf.sh`): `CTF_SRC_DIR`, `CTF_OUT_FILE`, `CTF_FORMAT`,
  `CTF_HEADING_LEVEL`, `CTF_PATH_STYLE`, `CTF_SORT`, `CTF_TITLE`, `CTF_HEADER`, `CTF_SUMMARY`,
  `CTF_TIMESTAMP`, `CTF_TOC`, `CTF_METADATA`, `CTF_LINE_NUMBERS`, `CTF_LANG_STYLE`,
  `CTF_STRIP_BOM`, `CTF_TRUNCATE_LINES`, `CTF_TOKEN_BUDGET`, `CTF_BUDGET_ACTION`, `CTF_DEDUP`,
  `CTF_DEFAULT_EXCLUDES`, `CTF_MAX_DEPTH`, `CTF_FOLLOW`, `CTF_MAX_SIZE`, `CTF_MIN_SIZE`,
  `CTF_GIT_MODE`, `CTF_BINARY_MODE`, `CTF_STRICT`, `CTF_COLOR`, `CTF_QUIET`, `CTF_VERBOSE`,
  `CTF_UPDATE_CHANNEL`, `CTF_UPDATE_TIMEOUT`.
- Values containing `$(`, backticks, `;`, `|`, `&`, `<`, `>` or `$` are rejected; the file is data,
  there is no `eval`.
- A group- or world-writable config file is ignored with a warning.
- No credentials are needed; do not put tokens in this file, it is plain text.
- The Windows port supports neither a config file nor `--print-config`.

Environment: `NO_COLOR`, `SOURCE_DATE_EPOCH` (reproducible output), `CTF_UPDATE_CHANNEL`,
`CTF_UPDATE_TIMEOUT`, `CTF_UPDATE_BASE_URL`, `CTF_BINARY_SCAN_BYTES`, `CTF_BINARY_CTRL_PCT`.

## 5. Use

Always pass an explicit `-o`; otherwise the document is written into the current directory.

| Purpose | Command | Expected result |
|---|---|---|
| Inventory, writes nothing | `ctf --dry-run -e py ./src` | TSV on stdout: `path`, `lang`, `bytes`, `lines`, `sha256/12` |
| Counters only | `ctf --stats -e py ./src` | `candidates=`, `collected=`, `skipped=`, `source_bytes=`, `est_tokens=`, `truncated_files=`, `budget_dropped=`, `duplicates=`, `skip_<reason>=` |
| Repository context, honours `.gitignore` | `ctf --git all -o /tmp/context.md .` | one Markdown document; `[INFO] Done: N file(s) written, M skipped.` on stderr |
| Several extensions | `ctf -e php,js,ts -o bundle.md ./src` | same, extensions matched case-insensitively |
| Fit a token budget | `ctf -e py --token-budget 120000 -o ctx.md .` | files taken in `--sort` order; estimate is `ceil(bytes / 4)`; the file that does not fit is truncated at a line boundary (default `--budget-action truncate`) |
| Structured output | `ctf -F jsonl -o ctx.jsonl .` | one JSON object per line with `path`, `lang`, `bytes`, `lines`, `sha256`, `content` |
| Check for a newer version | `ctf --check-update` | `local=4.1.0 remote=... channel=main status=up-to-date|newer|unreachable` |

`-o -` writes the document to stdout and nothing else goes to that stream.
When a file you expected is absent, read the skip-reasons table at the end of the document:
`binary`, `symlink`, `extension`, `excluded-dir`, `too-large`, `too-small`, `token-budget`, `duplicate`, `output-file`, `unreadable`, and related reasons.

**Output / exit codes:** `0` success; `1` runtime error (I/O, permissions); `2` usage error
(unknown option, invalid value, unreadable source); `3` update/network error, also "a newer version
exists"; `4` nothing collected with `--strict`. The Windows launcher adds `90` when `ctf.ps1` or
`pwsh` is missing. Code `3` covers both "newer" and "unreachable", so parse the `status=` token when
the answer matters.

## 6. Safety and rollback

- Changes on a host: the bash installer creates `$PREFIX/bin` if needed and puts five entries there
  (`ctf` symlink, `ctf.sh`, `ctf.ps1`, `ctf.bat`, `VERSION`). The Windows installer creates the
  install root with `bin\`/`lib\`, copies `README.md` and `LICENSE`, and appends one directory to the
  **user** `PATH`. No services, cron jobs, registry keys or firewall rules are created.
- A collection run writes exactly one document (mode `0666 & ~umask`, normally `0644`) and cleans its
  temporary files through an EXIT trap.
- Never does: execute what it reads, write outside the requested output, collect its own output file, or modify the scanned tree.
- `--update` is the only self-modifying operation: it downloads a newer script, validates it
  (minimum size, shebang, `bash -n`), keeps `ctf.sh.bak-<timestamp>`, writes through the existing
  inode, and refreshes sibling `VERSION`/`ctf.ps1`/`ctf.bat` when present. Do not run it unattended
  in CI or on a shared host.
- Undo, bash: `make uninstall`, or `bash ./install.sh --prefix "$HOME/.local" --uninstall`.
- Undo, Windows: `pwsh -NoProfile -File .\install-ctf.ps1 -Uninstall` (removes the files and the
  launcher directory from the user `PATH`).

**Safe first-run order (do not skip):**
1. `ctf --help` and `ctf --print-config .` - confirm version and detected tools;
2. `ctf --dry-run ...` and `ctf --stats ...` - inspect selection and counters without writing;
3. one small subdirectory with an explicit `-o` into a scratch path, then read the skip-reasons table;
4. the full tree, still with an explicit `-o`.

## 7. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `ctf: Bash 4.2 or newer is required` / non-bash warning | wrong shell or older bash | run with `bash`, upgrade bash; do not patch the guard |
| `Required command 'awk' is not available` | minimal container image | install the required userland; re-run `--print-config` |
| Exit `2`: source directory does not exist | wrong path or unreadable directory | verify the path; `--dry-run` is not a substitute for a valid source |
| Expected files missing from the document | default excludes (`build`, `dist`, `out`, lock files), binary verdict, `--git` mode, depth/size limits | read the skip-reasons table, then `--dry-run` or `--verbose`; use `--no-default-excludes` or `-I` deliberately |
| `--dedup` finds no duplicates | no `sha256sum`/`shasum` (warning only, exit stays `0`) | install one, or drop `--dedup` |
| `ctf --version` starts a collection and writes `all---version-files.md` | the engine `.ps1` itself was put on `PATH`; PowerShell binds `--long-option` as a positional value | reinstall with `install-ctf.ps1` and call the `bin\ctf.cmd` launcher |
| Windows: `-V` prints debug, `--verbose` adds nothing | on Windows `-V` is `--verbose`; `--verbose` binds to PowerShell's common `-Verbose` and is silently ignored | use `--version`, `-v` or `-Trace`, and `--exclude` instead of `-E` |
| Windows: `A positional parameter cannot be found` | `ctf.ps1` called directly with long options | call the launcher, or `pwsh -File` with PowerShell parameter names |
| `--check-update` exits `3` | newer version, or the lookup failed | treat as "investigate", not "upgrade now"; a human decides on `--update` |
| Update refused | download failed validation (size, shebang, `bash -n`) | installed copy is untouched; retry later or install from source |
| `make install` prints `Permission denied: ./install.sh` | `ctf.sh`/`install.sh` are committed as mode `100644` (open finding in `CHANGELOG.md` 4.1.0) | run `bash ./install.sh ...` or `chmod +x` locally; do not change file modes in a shared clone |
| `make test` reports failures in `tests/test_meta.sh` | the suite asserts `LICENSE` is MIT and that `ctf.sh` has an executable bit; `LICENSE` is PolyForm Noncommercial 1.0.0 and the index mode is `100644` | known discrepancy - report it, do not "fix" the licence or add unrelated changes |

## 8. Limits

- Text assembly only: no parsing, symbol extraction, minification or secret scanning. Anything in
  the tree that counts as text will be embedded verbatim, including credentials - review the
  selection with `--dry-run` before publishing a document.
- Binary detection: NUL in the first 8 KiB or more than 5 % C0 control bytes; `file(1)` first when
  present. A file under about 1 KiB of high-entropy data can pass as text (README section 12).
- The token figure is `ceil(bytes / 4)`, not a model tokenizer count.
- Symlinked files are skipped and counted (`symlink`) unless `-L` is given.
- Bash baseline is 4.2 with GNU or BSD userland; no bash 4.3+ constructs are used. Minimum
  coreutils/findutils/sed versions: Not documented in this repository. CI runs the suite on
  `ubuntu-latest` and `macos-latest`; the bash 4.2 baseline is checked statically, not by a CI job.
- Windows port gaps: no config file, no `--print-config`, `--files-from -` (stdin) exits `2`, `--git tracked`
  outside a repository exits `2`, `--verbose` is a silent no-op, a binding error exits `1`, not `2`.
- Releases publish no assets, so there is no checksummed download; integrity comes from the Git tag.
- The repository does not document a support matrix beyond the above, nor a deprecation policy.

## 9. Sources of truth

- `README.md` - install paths, option reference, output formats, exit codes, Windows sections 10.1-10.4.
- `VERSION` - `4.1.0`; `ctf.sh` header - `CTF_SCRIPT_VERSION='4.1.0'`.
- `ctf.sh` - `usage()`, `parse_args()`, `validate()`, `print_stats()`, dry-run TSV format, `main()`.
- `ctf.ps1` - `-Help` text, parameter aliases, `$ScriptVersion`.
- `ctf.bat`, `install-ctf.ps1` - launcher behaviour, exit code `90`, `-InstallRoot`/`-Uninstall`, user `PATH`.
- `install.sh`, `Makefile` - installed file names, `--prefix`/`--bindir`/`--uninstall`, `make` targets.
- `tests/run_tests.sh`, `tests/test_meta.sh` - suite entry point and the meta assertions above.
- `CHANGELOG.md` - 4.1.0 notes and the open findings (missing executable bit, `test_meta.sh` licence check).
- `gh release list`, `gh release view v4.1.0` - release existence and the absence of assets.
- Executed read-only on this host: `bash ./ctf.sh --version`, `--help`, `--print-config .`,
  `pwsh -File .\ctf.ps1 --version`, `-Help`; installers, `make test`, collection runs and
  `--update` were not executed here, so their facts come from the files above.

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique distribution / bash / coreutils version combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
