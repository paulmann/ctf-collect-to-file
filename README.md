# `ctf` — Collect To File

A battle-tested, cross-platform utility that recursively collects source files by extension into a single, well-structured Markdown document. Perfect for feeding entire codebases to LLMs, conducting cross-file code reviews, or archiving project snapshots.

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4.2%2B-blue.svg" alt="Bash 4.2+">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Platform-Linux-lightgrey.svg" alt="Linux">
  <img src="https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6.svg" alt="Windows 10/11">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/Version-3.0.0-brightgreen.svg" alt="Version 3.0.0">
  <img src="https://img.shields.io/badge/Output-Markdown-orange.svg" alt="Markdown Output">
</p>

---

## 📋 Table of Contents

1. [Features](#1-features)
2. [How It Works](#2-how-it-works)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Usage](#5-usage)
   - 5.1 [Basic Syntax](#51-basic-syntax)
   - 5.2 [Arguments](#52-arguments)
   - 5.3 [Options](#53-options)
   - 5.4 [Examples](#54-examples)
6. [Language Detection](#6-language-detection)
7. [Output Format](#7-output-format)
8. [Advanced Features](#8-advanced-features)
9. [Troubleshooting](#9-troubleshooting)
10. [Use Cases](#10-use-cases)
11. [Contributing](#11-contributing)
12. [License](#12-license)
13. [Author & Support](#13-author--support)

---

## 1. Features

- **Cross-platform:** Native Bash script for Linux/macOS (`ctf.sh`) and a BAT + PowerShell hybrid for Windows (`ctf.bat`).
- **Recursive collection:** Traverses entire directory trees preserving relative paths.
- **Extension filtering:** Target a specific file type (`php`, `js`, `py`, etc.) or collect everything at once.
- **Dynamic Markdown fences:** Automatically picks `` ``` `` or `~~~` (and their length) so file content can never accidentally close a code block.
- **Automatic language tags:** Maps 50+ file extensions to correct Markdown fenced-block identifiers for syntax highlighting.
- **Binary-file guard:** Detects and skips binary files via `file --mime-encoding` (Linux) or `.NET` stream analysis (Windows), with null-byte fallbacks.
- **Smart encoding detection (Windows):** Recognizes UTF-8 (with/without BOM), UTF-16 LE/BE, and ANSI fallbacks.
- **Atomic writes:** Writes to a temporary file first, then atomically publishes the result, preserving symlinks when the target already exists.
- **Portable path resolution:** Works without GNU `realpath` — pure Bash `cd`-and-`pwd` technique on Linux, `[System.IO.Path]::GetFullPath` on Windows.
- **TTY-aware colorized output:** Full ANSI/Console color logging on interactive terminals; clean plain text in scripts/cron.
- **Safe output handling:** Validates output directory existence and writability before writing a single byte.
- **Self-exclusion:** The output file and stale temporary files are never included in their own collection run.
- **Structured Markdown output:** Generates a metadata header table, per-file fenced code blocks, and a summary table.
- **Zero external dependencies (Linux):** Requires only standard GNU/Linux utilities. Windows relies on built-in PowerShell 5.1+.

---

## 2. How It Works

### 2.1 Collection Pipeline

```text
ctf [EXT] [SRC_DIR] [OUT_FILE]
      │         │          │
      │         │          └─► Markdown output file
      │         └─────────────► Root directory to scan
      └───────────────────────► File extension filter (or "" for all)
```

1. **Argument normalization** — strips the leading dot from the extension and resolves the source directory to an absolute path.
2. **File discovery** — uses `find -type f -name "*.EXT" -print0 | sort -z` (Linux) or `Get-ChildItem -Recurse -File` (Windows) to get a sorted, safe file list.
3. **Metadata header** — writes a Markdown table with generation timestamp, script version, source path, and candidate count.
4. **Per-file processing** — for each file: checks readability → checks for binary content → detects encoding → computes a safe Markdown fence → maps extension to language tag → appends a `### \`relative/path\`` heading + fenced code block.
5. **Atomic finalization** — moves the temporary file to the target path (or writes through an existing symlink).
6. **Summary footer** — appends a processed/skipped/total count table.

### 2.2 Extension-to-Language Mapping

The `map_lang()` function (Bash) / `Get-LanguageTag` (PowerShell) performs a case-insensitive lookup across 50+ extensions and returns the correct Markdown language identifier. Unknown extensions fall through to their raw lowercase form.

### 2.3 Binary Detection

- **Linux:** When `file` is available, queries `--mime-encoding` for `binary`. Otherwise falls back to scanning the first 8 KiB for null bytes via `head | od`.
- **Windows:** Reads the first 8 KiB via a .NET `FileStream`, recognizes BOMs (UTF-8, UTF-16 LE/BE), and scans for `0x00` bytes.

### 2.4 Dynamic Markdown Fences

Instead of hardcoding `` ``` ``, the script scans each file for the longest sequence of backticks (`` ` ``) and tildes (`~`) at the start of any line, then emits a fence **one character longer** than the maximum found. This guarantees that file contents containing Markdown fences (e.g., a README inside a repo) will never break the outer aggregate document.

---

## 3. Prerequisites

### Linux (`ctf.sh`)

- **Operating System:** Linux (Debian 10–13, Ubuntu 20–24, CentOS 7, RHEL 8/9, Fedora)
- **Shell:** Bash 4.2 or higher
- **Permissions:** Read access to source files; write access to the output directory
- **Dependencies (all standard on any Linux system):**
  - `find` (GNU findutils)
  - `sort` (with `-z` support preferred)
  - `cat`, `head`, `od`, `date`, `basename`, `dirname`, `awk`
  - `file` *(optional — used for binary detection; fallback available)*

### Windows (`ctf.bat`)

- **Operating System:** Windows 10 / Windows 11
- **Runtime:** Windows PowerShell 5.1 or newer (pre-installed)
- **Permissions:** Read access to source files; write access to the output directory
- **Dependencies:** None beyond the OS itself

---

## 4. Installation

### 4.1 Linux — Clone the Repository

```bash
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
chmod 0755 ctf.sh
```

### 4.2 Linux — Install System-Wide (Optional)

```bash
sudo cp ctf.sh /usr/local/bin/ctf
sudo chmod 0755 /usr/local/bin/ctf
ctf --version
```

### 4.3 Windows

Simply place `ctf.bat` anywhere on your `PATH` (e.g., `C:\Users\<you>\bin\`) or run it directly from the repository folder. No compilation or installer is required.

```powershell
# Verify
.\ctf.bat --version
```

### 4.4 Verify the Shebang (Linux)

```bash
head -1 ctf.sh
# Expected: #!/usr/bin/env bash
```

---

## 5. Usage

### 5.1 Basic Syntax

```bash
# Linux / macOS
./ctf.sh [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

# Windows
.\ctf.bat [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
```

All three arguments are optional. The script applies sensible defaults for every omitted argument.

### 5.2 Arguments

| Argument     | Description                                                                                              | Default                                          |
| ------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `EXTENSION`  | File extension to collect (`php`, `.js`, `sh`, etc.). Pass `""` to collect **all** non-binary files.     | *(all files)*                                    |
| `SOURCE_DIR` | Root directory to scan recursively.                                                                    | Current directory (`.`)                          |
| `OUTPUT_FILE`| Destination Markdown file path.                                                                          | `all-<EXT>-files.md` or `All-Project-Files.md`   |

> **Tip:** The leading dot in extensions is optional — both `php` and `.php` are accepted.

### 5.3 Options

| Option           | Description                         |
| ---------------- | ----------------------------------- |
| `-h`, `--help`   | Display usage information and exit  |
| `-V`, `--version`| Display version number and exit     |
| `--`             | End of options marker               |

### 5.4 Examples

Collect all PHP files from `./src` into a named output file:

```bash
# Linux
./ctf.sh php ./src result.md

# Windows
.\ctf.bat php .\src result.md
```

Collect all JavaScript files from the current directory:

```bash
./ctf.sh js
# Output → all-js-files.md
```

Collect all non-binary files from a web root:

```bash
# Linux
./ctf.sh "" /var/www/myproject project-snapshot.md

# Windows
.\ctf.bat "" C:\inetpub\wwwroot project-snapshot.md
```

Collect everything from the current directory (zero arguments):

```bash
./ctf.sh
# Output → All-Project-Files.md
```

Pipe the output path into another tool:

```bash
./ctf.sh php ./app context.md && wc -l context.md
```

Check version:

```bash
./ctf.sh --version
# ctf.sh v3.0.0
```

---

## 6. Language Detection

The language mapper supports 50+ extensions. A representative subset:

| Extensions                                | Language Tag  |
| ----------------------------------------- | ------------- |
| `sh`, `bash`, `zsh`, `ksh`, `fish`        | `bash`        |
| `py`, `pyw`                               | `python`      |
| `php`, `php5`, `php7`, `php8`             | `php`         |
| `js`, `mjs`, `cjs`                        | `javascript`  |
| `ts`                                      | `typescript`  |
| `tsx`, `jsx`                              | `tsx` / `jsx` |
| `html`, `htm`, `xhtml`                    | `html`        |
| `xml`, `xsl`, `xsd`, `svg`, `rss`, `atom` | `xml`         |
| `css`, `scss`, `sass`, `less`             | `css` / `scss`|
| `json`, `jsonc`, `json5`                  | `json`        |
| `yaml`, `yml`                             | `yaml`        |
| `toml`                                    | `toml`        |
| `sql`                                     | `sql`         |
| `go`                                      | `go`          |
| `rs`                                      | `rust`        |
| `c`, `h`                                  | `c`           |
| `cpp`, `cc`, `cxx`, `hpp`, `hxx`          | `cpp`         |
| `java`                                    | `java`        |
| `kt`, `kts`                               | `kotlin`      |
| `swift`                                   | `swift`       |
| `cs`                                      | `csharp`      |
| `lua`                                     | `lua`         |
| `r`                                       | `r`           |
| `ps1`, `psm1`, `psd1`                     | `powershell`  |
| `tf`, `tfvars`                            | `hcl`         |
| `dockerfile`, `containerfile`             | `dockerfile`  |
| `makefile`, `mk`                          | `makefile`    |
| `cmake`, `cmakelists.txt`                 | `cmake`       |
| `conf`, `cfg`, `ini`                      | `ini`         |
| `nginx`                                   | `nginx`       |
| `md`, `markdown`, `readme`                | `markdown`    |
| `jenkinsfile`                             | `groovy`      |
| `env`, `envrc`                            | `bash`        |
| `rst`                                     | `rst`         |
| `txt`, `text`, `log`                      | `text`        |
| *(unknown)*                               | *(raw ext)*   |

---

## 7. Output Format

Every run produces a single `.md` file with the following structure:

```markdown
# Project Source Code Aggregate

| Field      | Value                    |
|:-----------|:-------------------------|
| Generated  | `2026-10-05T14:00:00Z`   |
| Script     | `ctf.sh v3.0.0`          |
| Source     | `/var/www/myproject`     |
| Extension  | `php`                    |
| Candidates | 42                       |

---

### `src/Controller/HomeController.php`

````php
<?php
// ... file contents ...
````

---

## Summary

| Metric    | Count |
|:----------|------:|
| Processed | 41    |
| Skipped   | 1     |
| Total     | 42    |
```

> Notice the four-backtick fence — it was chosen dynamically because the file itself contained three-backtick sequences.

---

## 8. Advanced Features

### 8.1 Atomic Output & Symlink Safety

The script writes into a hidden temporary file (`.out.md.ctf.XXXXXX`) inside the target directory. On success it:

- **If the target is a symlink:** writes *through* the symlink, preserving the link.
- **Otherwise:** atomically `mv`s the temp file onto the target path.

If the script is interrupted, the `trap cleanup EXIT` handler (Bash) or `finally` block (PowerShell) removes the temp file, so you never end up with a half-written `.md`.

### 8.2 Self-Exclusion

The script never includes:

- The final output file itself.
- Stale temporary files from previous interrupted runs (`.filename.md.ctf.*`).
- The extracted PowerShell payload file (Windows only).

### 8.3 Encoding Awareness (Windows)

The PowerShell payload reads files as bytes, detects the BOM, validates UTF-8 strictly, and falls back to the system ANSI codepage only when necessary. The resulting Markdown is always written as **UTF-8 without BOM**, which is the de-facto standard for LLM ingestion.

---

## 9. Troubleshooting

### 9.1 Common Issues

**`Source directory '...' does not exist`**
- Verify the path passed as `SOURCE_DIR` is correct.
- Ensure the directory exists: `ls -la /path/to/dir` / `dir C:\path\to\dir`.

**`Output directory '...' is not writable`**
- Check permissions: `ls -la $(dirname output.md)` / `icacls C:\path\to\dir`.
- Use a directory where your user has write access.

**`Permission denied` on script execution (Linux)**
- Set the executable bit: `chmod 0755 ctf.sh`.

**No files collected (0 candidates)**
- Confirm the extension is correct (e.g., `php` not `PHP`).
- The script normalizes to lowercase internally, but verify the files actually have that extension.
- Run a manual check: `find . -name "*.php" | head`.

**Output file is empty (only header)**
- All matching files may be binary or unreadable.
- Check file permissions: `ls -la src/`.

### 9.2 Binary File Handling

The script silently skips files identified as binary. To see which files are being skipped, inspect the `[WARN]` lines in stderr output:

```bash
./ctf.sh "" ./project output.md 2>&1 | grep WARN
```

### 9.3 Windows-Specific Notes

- The BAT wrapper extracts the PowerShell payload to `%TEMP%` and deletes it on exit. If the script is killed hard (e.g., Task Manager), a stray `.ps1` may remain in `%TEMP%` — safe to delete.
- PowerShell execution policy is bypassed for the embedded payload via `-ExecutionPolicy Bypass`, so no admin rights are needed.

---

## 10. Use Cases

- **LLM context preparation:** Aggregate an entire codebase into one file to feed into ChatGPT, Claude, Gemini, or any LLM with a large context window.
- **Code review:** Consolidate a feature branch's files for human review in a single document.
- **Project archival:** Snapshot all source files with metadata for documentation or auditing.
- **CI/CD reporting:** Generate a Markdown code dump as a build artifact.
- **Security auditing:** Feed entire application source into a static analysis or security review pipeline.
- **Documentation generation:** Use the structured output as raw input for doc generators.

---

## 11. Contributing

Contributions are welcome! Feel free to open pull requests, file bug reports, or suggest new features.

### Development Guidelines

- Follow the existing code style — `set -euo pipefail`, `readonly` constants, named functions (Bash).
- Keep the script dependency-free (standard GNU utilities on Linux, built-in PowerShell on Windows).
- Add `[WARN]` / `[INFO]` / `[ERROR]` log calls for all user-visible state changes.
- Update the `map_lang()` / `Get-LanguageTag` table for any new extension support.
- Test on Bash 4.2+ (Linux) and PowerShell 5.1+ (Windows) before submitting.
- Keep both `ctf.sh` and `ctf.bat` behaviorally aligned when possible.

---

## 12. License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 13. Author & Support

**Mikhail Deynekin** — Senior Software Engineer & AI Enthusiast

- 🌐 **Website:** [deynekin.com](https://deynekin.com)
- 📧 **Email:** [Mikhail@Deynekin.com](mailto:Mikhail@Deynekin.com)
- 🐙 **GitHub:** [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation:** Read this README thoroughly.
- 🐛 **Bug Reports:** [Open an issue](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💡 **Feature Requests:** [Request a feature](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💬 **Discussions:** [Join the conversation](https://github.com/paulmann/ctf-collect-to-file/discussions)

> **Note:** Always test the script in a staging environment and review the output file before using it as LLM input in sensitive or production contexts.
