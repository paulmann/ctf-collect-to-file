# ctf.sh — Collect To File

A battle-tested Bash utility that **recursively collects source files** by extension into a single, well-structured Markdown document — perfect for feeding entire codebases to LLMs, conducting cross-file code reviews, or archiving project snapshots.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Version](https://img.shields.io/badge/Version-1.0.0-brightgreen.svg)
![Markdown](https://img.shields.io/badge/Output-Markdown-orange.svg)

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
8. [Troubleshooting](#8-troubleshooting)
   - 8.1 [Common Issues](#81-common-issues)
   - 8.2 [Binary File Handling](#82-binary-file-handling)
9. [Use Cases](#9-use-cases)
10. [Contributing](#10-contributing)
11. [License](#11-license)
12. [Author & Support](#12-author--support)

---

## 1. Features

- **Recursive collection**: Traverses entire directory trees with `find(1)`, preserving relative paths
- **Extension filtering**: Target a specific file type (`php`, `js`, `py`, etc.) or collect everything at once
- **Automatic language tags**: Maps 40+ file extensions to correct Markdown fenced-block identifiers for syntax highlighting
- **Binary-file guard**: Automatically detects and skips binary files using `file --mime-encoding` with a null-byte fallback
- **Portable path resolution**: Works without GNU `realpath` — pure Bash `cd`-and-`pwd` technique
- **TTY-aware colorized output**: Full ANSI color logging on interactive terminals; clean plain text in scripts/cron
- **Safe output handling**: Validates output directory existence and writability before writing a single byte
- **Self-exclusion**: The output file is never included in its own collection run
- **Structured Markdown output**: Generates a metadata header table, per-file fenced code blocks, and a summary table
- **Zero external dependencies**: Requires only standard GNU/Linux utilities — no Python, no Node, no packages to install

---

## 2. How It Works

### 2.1 Collection Pipeline

```
ctf.sh [EXT] [SRC_DIR] [OUT_FILE]
       │         │          │
       │         │          └─► Markdown output file
       │         └─────────────► Root directory to scan
       └───────────────────────► File extension filter (or "" for all)
```

1. **Argument normalization** — strips the leading dot from the extension and resolves the source directory to an absolute path
2. **File discovery** — runs `find -type f -name "*.EXT" -print0 | sort -z` to get a null-delimited, sorted file list
3. **Metadata header** — writes a Markdown table with generation timestamp, script version, source path, and candidate count
4. **Per-file processing** — for each file: checks readability → checks for binary content → maps extension to language tag → appends a `### \`relative/path\`` heading + fenced code block
5. **Summary footer** — appends a processed/skipped/total count table

### 2.2 Extension-to-Language Mapping

The `map_lang()` function performs a case-insensitive lookup across 40+ extensions and returns the correct Markdown language identifier. Unknown extensions fall through to their raw lowercase form.

### 2.3 Binary Detection

When the `file` utility is available, the script queries `--mime-encoding` for the string `binary`. On minimal systems without `file`, it falls back to scanning the first 8 KiB of each file for null bytes using `grep -P '\x00'`.

---

## 3. Prerequisites

- **Operating System**: Linux (Debian 10–13, Ubuntu 20–24, CentOS 7)
- **Shell**: Bash 4.2 or higher
- **Permissions**: Read access to source files; write access to the output directory
- **Dependencies** (all standard on any Linux system):
  - `find` (GNU findutils)
  - `sort`
  - `cat`, `du`, `date`, `basename`, `dirname`
  - `file` *(optional — used for binary detection; fallback available)*

---

## 4. Installation

### 4.1 Clone the Repository

```bash
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
```

### 4.2 Set Execution Permissions

```bash
chmod 0755 ctf.sh
```

### 4.3 Install System-Wide (Optional)

To make `ctf.sh` available from anywhere on the system:

```bash
sudo cp ctf.sh /usr/local/bin/ctf
sudo chmod 0755 /usr/local/bin/ctf
```

Verify the installation:

```bash
ctf --version
```

### 4.4 Verify the Shebang

Ensure the script's interpreter line is correct for your system:

```bash
head -1 ctf.sh
# Expected: #!/usr/bin/env bash
```

---

## 5. Usage

### 5.1 Basic Syntax

```bash
ctf.sh [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
```

All three arguments are **optional**. The script applies sensible defaults for every omitted argument.

### 5.2 Arguments

| Argument | Description | Default |
|:---------|:------------|:--------|
| `EXTENSION` | File extension to collect (`php`, `.js`, `sh`, etc.). Pass `""` to collect **all** non-binary files. | *(all files)* |
| `SOURCE_DIR` | Root directory to scan recursively. | Current directory (`.`) |
| `OUTPUT_FILE` | Destination Markdown file path. | `all-<EXT>-files.md` or `All-Project-Files.md` |

> **Tip:** The leading dot in extensions is optional — both `php` and `.php` are accepted.

### 5.3 Options

| Option | Description |
|:-------|:------------|
| `-h`, `--help` | Display usage information and exit |
| `-V`, `--version` | Display version number and exit |

### 5.4 Examples

Collect all PHP files from `./src` into a named output file:

```bash
./ctf.sh php ./src result.md
```

Collect all JavaScript files from the current directory:

```bash
./ctf.sh js
# Output → all-js-files.md
```

Collect **all** non-binary files from `/var/www/myproject`:

```bash
./ctf.sh "" /var/www/myproject project-snapshot.md
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
# ctf.sh v1.0.0
```

---

## 6. Language Detection

The `map_lang()` function maps file extensions to Markdown fenced-block language identifiers:

| Extensions | Language Tag |
|:-----------|:-------------|
| `sh`, `bash`, `zsh`, `ksh`, `fish` | `bash` |
| `py`, `pyw` | `python` |
| `php`, `php5`, `php7`, `php8` | `php` |
| `js`, `mjs`, `cjs` | `javascript` |
| `ts` | `typescript` |
| `html`, `htm`, `xhtml` | `html` |
| `xml`, `xsl`, `xsd`, `svg` | `xml` |
| `css` | `css` |
| `scss` | `scss` |
| `json`, `jsonc`, `json5` | `json` |
| `yaml`, `yml` | `yaml` |
| `toml` | `toml` |
| `sql` | `sql` |
| `go` | `go` |
| `rs` | `rust` |
| `c`, `h` | `c` |
| `cpp`, `cc`, `cxx`, `hpp` | `cpp` |
| `java` | `java` |
| `kt`, `kts` | `kotlin` |
| `cs` | `csharp` |
| `ps1`, `psm1`, `psd1` | `powershell` |
| `tf`, `tfvars` | `hcl` |
| `dockerfile` | `dockerfile` |
| `conf`, `cfg`, `ini` | `ini` |
| *unknown* | *(raw extension)* |

---

## 7. Output Format

Every run produces a single `.md` file with the following structure:

```markdown
# Project Source Code Aggregate

| Field      | Value                    |
|:-----------|:-------------------------|
| Generated  | `2025-04-07T14:00:00Z`   |
| Script     | `ctf.sh v1.0.0`          |
| Source     | `/var/www/myproject`     |
| Extension  | `php`                    |
| Candidates | 42                       |

---

### `src/Controller/HomeController.php`

```php
<?php
// ... file contents ...
```

---

## Summary

| Metric    | Count |
|:----------|------:|
| Processed | 41    |
| Skipped   |  1    |
| Total     | 42    |
```

---

## 8. Troubleshooting

### 8.1 Common Issues

**`Source directory '...' does not exist`**
- Verify the path passed as `SOURCE_DIR` is correct
- Ensure the directory exists: `ls -la /path/to/dir`

**`Output directory '...' is not writable`**
- Check permissions: `ls -la $(dirname output.md)`
- Use a directory where your user has write access

**`Permission denied` on script execution**
- Set the executable bit: `chmod 0755 ctf.sh`

**No files collected (0 candidates)**
- Confirm the extension is correct (e.g., `php` not `PHP`)
- The script normalizes to lowercase internally, but verify the files actually have that extension
- Run a manual check: `find . -name "*.php" | head`

**Output file is empty (only header)**
- All matching files may be binary or unreadable
- Check file permissions: `ls -la src/`

### 8.2 Binary File Handling

The script silently skips files identified as binary. To see which files are being skipped, inspect the `[WARN]` lines in stderr output:

```bash
./ctf.sh "" ./project output.md 2>&1 | grep WARN
```

---

## 9. Use Cases

- **LLM context preparation**: Aggregate an entire codebase into one file to feed into ChatGPT, Claude, or any LLM with a large context window
- **Code review**: Consolidate a feature branch's files for human review in a single document
- **Project archival**: Snapshot all source files with metadata for documentation or auditing
- **CI/CD reporting**: Generate a Markdown code dump as a build artifact
- **Security auditing**: Feed entire application source into a static analysis or security review pipeline
- **Documentation generation**: Use the structured output as raw input for doc generators

---

## 10. Contributing

Contributions are welcome! Feel free to open pull requests, file bug reports, or suggest new features.

### Development Guidelines

1. Follow the existing code style — `set -euo pipefail`, `readonly` constants, named functions
2. Keep the script dependency-free (standard GNU utilities only)
3. Add `[WARN]` / `[INFO]` / `[ERROR]` log calls for all user-visible state changes
4. Update the `map_lang()` table for any new extension support
5. Test on Bash 4.2+ before submitting

---

## 11. License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 12. Author & Support

**Mikhail Deynekin**

- 🌐 **Website**: [deynekin.com](https://deynekin.com)
- 📧 **Email**: [mid1977@gmail.com](mailto:mid1977@gmail.com)
- 🐙 **GitHub**: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: Read this README thoroughly
- 🐛 **Bug Reports**: [Open an issue](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💡 **Feature Requests**: [Request a feature](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💬 **Discussions**: [Join the conversation](https://github.com/paulmann/ctf-collect-to-file/discussions)

---

> **Note:** Always test the script in a staging environment and review the output file before using it as LLM input in sensitive or production contexts.
