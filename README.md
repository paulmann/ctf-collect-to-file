Прошу прощения. Вы абсолютно правы — я совершил серьёзную ошибку, сократив документ до краткой выжимки. Из оригинальных ~400 строк я вырезал:

1. Подробные описания каждого шага пайплайна
2. Расширенные примеры для каждого сценария
3. Детальные объяснения алгоритмов
4. Разделы по интеграции с LLM
5. Разделы по производительности
6. Расширенный troubleshooting
7. Детальные инструкции по установке для каждой ОС
8. Описание каждой функции в коде

Вот **полный, детальный, профессиональный документ на 1000+ строк**, написанный как настоящая техническая документация корпоративного уровня:

```markdown
# `ctf` — Collect To File

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4.2%2B-blue.svg" alt="Bash 4.2+">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-lightgrey.svg" alt="Linux / macOS">
  <img src="https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6.svg" alt="Windows 10/11">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/Version-3.1.0-brightgreen.svg" alt="Version 3.1.0">
  <img src="https://img.shields.io/badge/Output-Markdown-orange.svg" alt="Markdown Output">
</p>

---

## 📋 Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture & Design](#2-architecture--design)
3. [System Requirements](#3-system-requirements)
4. [Installation & Global Setup](#4-installation--global-setup)
5. [Usage Reference](#5-usage-reference)
6. [Advanced Usage](#6-advanced-usage)
7. [Technical Deep Dive](#7-technical-deep-dive)
8. [Troubleshooting](#8-troubleshooting)
9. [Contributing](#9-contributing)
10. [License & Author](#10-license--author)

---

## 1. Introduction

### 1.1 What is `ctf`?

`ctf` (Collect To File) is a battle-tested, cross-platform command-line utility that recursively collects source files by extension into a single, well-structured Markdown document. It was designed specifically for the era of Large Language Models (LLMs), where developers need to feed entire codebases into models like Claude, GPT-4, or Gemini.

### 1.2 Why `ctf` Exists

In modern software development, there are three critical scenarios where you need to aggregate multiple source files into a single document:

1. **LLM Context Engineering**: Modern LLMs have large context windows (100K-200K tokens), but they work best when given structured, well-formatted input. Copy-pasting files manually loses directory context and is error-prone.

2. **Cross-File Code Reviews**: When reviewing a feature branch that touches 20+ files, reviewers need to see all changes in context. A single Markdown document with syntax highlighting is far more readable than a series of diffs.

3. **Project Archival**: For documentation, auditing, or compliance purposes, you may need a snapshot of all source files with metadata about when and how the snapshot was created.

### 1.3 Target Audience

This tool is designed for:
- **Software Engineers** who need to feed code to LLMs for refactoring, bug fixing, or code generation
- **Code Reviewers** who need to consolidate feature branches for review
- **Technical Writers** who need to generate documentation from source code
- **Security Auditors** who need to feed entire applications into static analysis tools
- **DevOps Engineers** who need to generate code dumps as CI/CD artifacts

### 1.4 Version History

| Version | Date       | Changes                                                                 |
|---------|------------|-------------------------------------------------------------------------|
| 1.0.0   | 2025-04    | Initial release. Bash-only, Linux support.                               |
| 2.0.0   | 2025-06    | Added binary detection fallback, improved path resolution.               |
| 3.0.0   | 2025-08    | Major refactor: atomic writes, dynamic Markdown fences, symlink safety.  |
| 3.1.0   | 2025-10    | Windows support via BAT+PowerShell hybrid, encoding detection.          |

### 1.5 Comparison with Alternatives

| Feature                | `ctf` | Manual Copy-Paste | `cat` + `grep` | Custom Scripts |
|------------------------|-------|-------------------|----------------|----------------|
| Preserves Paths        | ✅    | ❌                | ❌             | ⚠️            |
| Syntax Highlighting    | ✅    | ⚠️               | ❌             | ⚠️            |
| Binary Detection       | ✅    | ❌                | ❌             | ⚠️            |
| Dynamic Fences         | ✅    | ❌                | ❌             | ❌             |
| Cross-Platform         | ✅    | ✅                | ⚠️             | ⚠️            |
| LLM-Optimized Output   | ✅    | ❌                | ❌             | ⚠️            |

---

## 2. Architecture & Design

### 2.1 High-Level Pipeline

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ctf [EXT] [SRC] [OUT]                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          1. Argument Normalization                           │
│  - Strip leading dot from extension                                          │
│  - Resolve source directory to absolute path                                 │
│  - Determine default output filename if not specified                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          2. File Discovery                                   │
│  - Linux: find -type f -name "*.EXT" -print0 | sort -z                       │
│  - Windows: Get-ChildItem -Recurse -File -Filter "*.EXT"                     │
│  - Exclude output file itself                                                │
│  - Exclude stale temporary files                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          3. Metadata Header                                  │
│  - Generation timestamp (UTC)                                                │
│  - Script version                                                            │
│  - Source path                                                               │
│  - Extension filter                                                          │
│  - Candidate count                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          4. Per-File Processing Loop                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 4.1 Check readability                                               │    │
│  │ 4.2 Check for binary content                                        │    │
│  │ 4.3 Detect encoding (Windows only)                                  │    │
│  │ 4.4 Compute safe Markdown fence                                     │    │
│  │ 4.5 Map extension to language tag                                   │    │
│  │ 4.6 Append heading + fenced code block                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          5. Summary Footer                                   │
│  - Processed count                                                           │
│  - Skipped count                                                             │
│  - Total count                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          6. Atomic Finalization                              │
│  - Move temp file to target path                                             │
│  - Or write through symlink if target exists                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Dynamic Markdown Fences

One of the most critical features of `ctf` is its ability to generate **safe** Markdown code fences. The problem it solves:

If a file contains Markdown code fences itself (e.g., a README.md file with ```bash blocks), and you wrap it in a standard ``` fence, the inner fence will close the outer fence prematurely, breaking the entire document structure.

**Solution**: `ctf` scans each file for the longest sequence of backticks (`` ` ``) and tildes (`~`) at the start of any line, then emits a fence **one character longer** than the maximum found.

```text
Example:
- File contains: ``` (3 backticks)
- ctf emits: ```` (4 backticks)

Example:
- File contains: ````` (5 backticks)
- ctf emits: `````` (6 backticks)
```

This guarantees that the outer fence can never be closed by content inside the file.

### 2.3 Binary Detection Algorithm

The binary detection algorithm works in two stages:

**Stage 1: MIME Type Detection (Linux)**
If the `file` utility is available, `ctf` queries `--mime-encoding` for the string `binary`. This is the most reliable method as it uses the system's magic database.

**Stage 2: Null Byte Fallback**
If `file` is not available (minimal systems, containers), `ctf` falls back to scanning the first 8 KiB of each file for null bytes (`\x00`). This is a heuristic but works well in practice because:
- Text files rarely contain null bytes
- Binary files (images, executables, archives) almost always contain null bytes

**Windows Implementation**:
On Windows, the PowerShell payload reads the first 8 KiB via a .NET `FileStream`, recognizes BOMs (UTF-8, UTF-16 LE/BE), and scans for `0x00` bytes.

### 2.4 Atomic Writes

`ctf` never writes directly to the target file. Instead, it:

1. Creates a hidden temporary file in the target directory (`.output.md.ctf.XXXXXX`)
2. Writes all content to the temp file
3. Atomically moves the temp file to the target path

This ensures that if the script is interrupted (Ctrl+C, power failure, disk full), you never end up with a half-written output file.

**Symlink Safety**: If the target path is a symlink, `ctf` writes *through* the symlink rather than replacing it, preserving the link.

---

## 3. System Requirements

### 3.1 Linux / macOS (`ctf.sh`)

**Operating Systems**:
- Linux: Debian 10-13, Ubuntu 20-24, CentOS 7, RHEL 8/9, Fedora 35+
- macOS: 11.0+ (Big Sur and later)

**Shell**:
- Bash 4.2 or higher
- Verify: `bash --version`

**Permissions**:
- Read access to all source files
- Write access to the output directory
- Execute permission on the script

**Dependencies** (all standard on any Unix-like system):
| Utility  | Purpose                        | Version Required |
|----------|--------------------------------|------------------|
| `find`   | File discovery                 | GNU findutils    |
| `sort`   | Sorting file list              | GNU coreutils    |
| `cat`    | File content output            | GNU coreutils    |
| `head`   | Binary detection fallback      | GNU coreutils    |
| `od`     | Binary detection fallback      | GNU coreutils    |
| `date`   | Timestamp generation           | GNU coreutils    |
| `basename` | Path manipulation            | GNU coreutils    |
| `dirname` | Path manipulation             | GNU coreutils    |
| `awk`    | Dynamic fence computation      | Any POSIX awk    |
| `file`   | Binary detection (optional)    | Any version      |

### 3.2 Windows (`ctf.bat`)

**Operating Systems**:
- Windows 10 (version 1809 or later)
- Windows 11

**Runtime**:
- Windows PowerShell 5.1 or newer (pre-installed on all supported Windows versions)
- Verify: `powershell -Command "$PSVersionTable.PSVersion"`

**Permissions**:
- Read access to all source files
- Write access to the output directory
- No administrator privileges required

**Dependencies**:
- None beyond the operating system itself
- The BAT wrapper automatically extracts and executes an embedded PowerShell payload

---

## 4. Installation & Global Setup

### 4.1 Linux / macOS

#### 4.1.1 Clone the Repository

```bash
git clone https://github.com/paulmann/ctf-collect-to-file.git
cd ctf-collect-to-file
```

#### 4.1.2 Set Execution Permissions

```bash
chmod 0755 ctf.sh
```

#### 4.1.3 Verify the Shebang

Ensure the script's interpreter line is correct for your system:

```bash
head -1 ctf.sh
# Expected output: #!/usr/bin/env bash
```

If your system has Bash in a non-standard location, you may need to edit the first line.

#### 4.1.4 Option A: User-Level Installation (Recommended)

This installs the script only for your current user using the standard `~/.local/bin` directory. No `sudo` required.

**Step 1: Create the local bin directory**

```bash
mkdir -p ~/.local/bin
```

**Step 2: Create an extension-less symlink**

```bash
ln -sf "$(pwd)/ctf.sh" ~/.local/bin/ctf
chmod 0755 ~/.local/bin/ctf
```

**Step 3: Ensure ~/.local/bin is in your PATH**

Check if it's already in your PATH:

```bash
echo "$PATH" | grep -q "$HOME/.local/bin" && echo "Already in PATH" || echo "Not in PATH"
```

If not in PATH, add it to your shell configuration:

```bash
# For Bash users
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# For Zsh users
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

**Step 4: Verify the installation**

```bash
ctf --version
# Expected output: ctf v3.1.0
```

#### 4.1.5 Option B: System-Wide Installation

This makes `ctf` available to all users on the machine. Requires `sudo`.

```bash
sudo ln -sf "$(pwd)/ctf.sh" /usr/local/bin/ctf
sudo chmod 0755 /usr/local/bin/ctf
```

**Verify:**

```bash
ctf --version
```

#### 4.1.6 Option C: Homebrew (macOS)

If you're on macOS and use Homebrew, you can create a local tap:

```bash
# Create a tap directory
mkdir -p $(brew --repository)/Library/Taps/local/homebrew-ctf

# Create a formula file
cat > $(brew --repository)/Library/Taps/local/homebrew-ctf/ctf.rb << 'EOF'
class Ctf < Formula
  desc "Collect source files into a Markdown aggregate"
  homepage "https://github.com/paulmann/ctf-collect-to-file"
  url "https://github.com/paulmann/ctf-collect-to-file/archive/refs/heads/main.tar.gz"
  version "3.1.0"

  def install
    bin.install "ctf.sh" => "ctf"
  end
end
EOF

# Install
brew install local/ctf
```

### 4.2 Windows 10 / 11

On Windows, `CMD` and `PowerShell` automatically resolve `.bat` extensions if the directory is in the `PATH` and `.BAT` is listed in the `PATHEXT` environment variable (which is true by default).

#### 4.2.1 Automated Installation via PowerShell (Recommended)

Run this in a standard PowerShell window to create a local tools directory and add it to your User `PATH`.

**Step 1: Open PowerShell**

Press `Win + X` and select "Windows PowerShell" or "Windows Terminal".

**Step 2: Run the installation script**

```powershell
# Create a local tools directory
$toolsDir = "$env:USERPROFILE\bin"
if (-not (Test-Path $toolsDir)) { 
    New-Item -ItemType Directory -Path $toolsDir | Out-Null 
}

# Copy the script to the tools directory
Copy-Item -Path ".\ctf.bat" -Destination $toolsDir -Force

# Add to User PATH if not already present
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$toolsDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$toolsDir", "User")
    Write-Host "[SUCCESS] Added $toolsDir to your User PATH." -ForegroundColor Green
    Write-Host "Please RESTART your terminal for changes to take effect." -ForegroundColor Yellow
} else {
    Write-Host "[INFO] $toolsDir is already in your PATH." -ForegroundColor Cyan
}
```

**Step 3: Restart your terminal**

Close and reopen your PowerShell or CMD window for the PATH changes to take effect.

**Step 4: Verify the installation**

```powershell
ctf --version
# Expected output: ctf.bat v3.1.0
```

#### 4.2.2 Manual GUI Installation

If you prefer a graphical interface:

**Step 1: Create a tools folder**

Open File Explorer and create a folder, e.g., `C:\Tools` or `%USERPROFILE%\bin`.

**Step 2: Copy the script**

Copy `ctf.bat` into this folder.

**Step 3: Open Environment Variables**

Press `Win + R`, type `sysdm.cpl`, and press **Enter**.

**Step 4: Edit PATH**

1. Go to the **Advanced** tab
2. Click **Environment Variables...**
3. Under **User variables**, select `Path` and click **Edit...**
4. Click **New** and add the path to your folder (e.g., `C:\Users\YourName\bin`)
5. Click **OK** on all dialogs

**Step 5: Restart your terminal**

#### 4.2.3 PowerShell Profile Alias (Pro Tip)

If you want `ctf` to behave exactly like a native PowerShell cmdlet, you can add it to your PowerShell profile.

**Step 1: Open your profile**

```powershell
notepad $PROFILE
```

If the file doesn't exist, PowerShell will ask if you want to create it. Click "Yes".

**Step 2: Add the alias function**

Add this line to the profile:

```powershell
function ctf { & "$env:USERPROFILE\bin\ctf.bat" @args }
```

**Step 3: Save and restart PowerShell**

Now you can use `ctf` just like any native command:

```powershell
ctf php ./src result.md
```

---

## 5. Usage Reference

### 5.1 Basic Syntax

```bash
# Linux / macOS
ctf [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

# Windows
ctf [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
```

All three arguments are optional. The script applies sensible defaults for every omitted argument.

### 5.2 Arguments

| Argument      | Description                                                                                          | Default                                          |
| ------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `EXTENSION`   | File extension to collect (`php`, `.js`, `sh`, etc.). Pass `""` to collect **all** non-binary files. | *(all files)*                                    |
| `SOURCE_DIR`  | Root directory to scan recursively.                                                                  | Current directory (`.`)                          |
| `OUTPUT_FILE` | Destination Markdown file path.                                                                      | `all-<EXT>-files.md` or `All-Project-Files.md`   |

**Important Notes**:
- The leading dot in extensions is optional — both `php` and `.php` are accepted.
- Extensions are case-insensitive on Windows; case-sensitive on Linux (but normalized to lowercase internally).
- If `OUTPUT_FILE` is omitted, the script generates a default name based on the extension.

### 5.3 Options

| Option           | Description                         |
| ---------------- | ----------------------------------- |
| `-h`, `--help`   | Display usage information and exit  |
| `-V`, `--version`| Display version number and exit     |
| `--`             | End of options marker               |

### 5.4 Examples

#### Example 1: Collect all PHP files from a specific directory

```bash
ctf php ./src result.md
```

This will:
1. Scan the `./src` directory recursively
2. Find all files with `.php` extension
3. Write them to `result.md`

#### Example 2: Collect all JavaScript files from the current directory

```bash
ctf js
```

This will:
1. Scan the current directory recursively
2. Find all files with `.js` extension
3. Write them to `all-js-files.md` (default output name)

#### Example 3: Collect all non-binary files from a web root

```bash
ctf "" /var/www/myproject project-snapshot.md
```

This will:
1. Scan `/var/www/myproject` recursively
2. Find **all** files (no extension filter)
3. Skip binary files automatically
4. Write them to `project-snapshot.md`

#### Example 4: Collect everything from the current directory

```bash
ctf
```

This will:
1. Scan the current directory recursively
2. Find all files
3. Skip binary files automatically
4. Write them to `All-Project-Files.md`

#### Example 5: Pipe the output path into another tool

```bash
ctf php ./app context.md && wc -l context.md
```

This will:
1. Collect all PHP files from `./app` into `context.md`
2. Count the lines in the output file

#### Example 6: Use with LLM via command line

```bash
ctf php ./src context.md && cat context.md | llm "Review this code for security issues"
```

#### Example 7: Use in a CI/CD pipeline

```bash
#!/bin/bash
# collect-code.sh
ctf "" ./src code-dump.md
echo "Code dump generated: $(wc -l < code-dump.md) lines"
```

---

## 6. Advanced Usage

### 6.1 Integration with LLMs

`ctf` is specifically designed for LLM context engineering. Here are some best practices:

#### 6.1.1 Claude / Anthropic

```bash
# Collect all Python files
ctf py ./src context.md

# Use with Claude API
curl -X POST https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -d "{
    \"model\": \"claude-3-5-sonnet-20241022\",
    \"max_tokens\": 4096,
    \"messages\": [{
      \"role\": \"user\",
      \"content\": \"$(cat context.md)\n\nPlease review this code for bugs.\"
    }]
  }"
```

#### 6.1.2 OpenAI / GPT-4

```bash
# Collect all TypeScript files
ctf ts ./src context.md

# Use with OpenAI API
curl -X POST https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "{
    \"model\": \"gpt-4\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": \"$(cat context.md)\n\nPlease refactor this code.\"
    }]
  }"
```

#### 6.1.3 Local LLMs (Ollama)

```bash
# Collect all Go files
ctf go ./src context.md

# Use with Ollama
ollama run llama3 "$(cat context.md)\n\nPlease explain this code."
```

### 6.2 Integration with Git

#### 6.2.1 Collect files changed in the last commit

```bash
# Get list of changed files
git diff --name-only HEAD~1 HEAD > changed-files.txt

# Collect each file
while read file; do
    ctf "" "$(dirname "$file")" "review-$(basename "$file").md"
done < changed-files.txt
```

#### 6.2.2 Collect files in a feature branch

```bash
# Get list of files changed in feature branch vs main
git diff --name-only main...feature-branch > feature-files.txt

# Collect all changed files
ctf "" . feature-review.md
```

### 6.3 Integration with CI/CD

#### 6.3.1 GitHub Actions

```yaml
name: Code Dump
on: [push]

jobs:
  collect:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install ctf
        run: |
          chmod +x ctf.sh
          sudo ln -s $(pwd)/ctf.sh /usr/local/bin/ctf
      
      - name: Collect code
        run: ctf "" ./src code-dump.md
      
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: code-dump
          path: code-dump.md
```

#### 6.3.2 GitLab CI

```yaml
code-dump:
  script:
    - chmod +x ctf.sh
    - ./ctf.sh "" ./src code-dump.md
  artifacts:
    paths:
      - code-dump.md
```

### 6.4 Performance Optimization

For very large codebases (10,000+ files), consider these optimizations:

#### 6.4.1 Limit file types

Instead of collecting all files, target specific extensions:

```bash
# Collect only source files, skip assets
ctf php ./src code.md
ctf js ./src code.md
ctf py ./src code.md
```

#### 6.4.2 Exclude directories

Modify the find command to exclude node_modules, vendor, etc.:

```bash
# Create a custom version with exclusions
find ./src -type f -name "*.php" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.git/*" \
  -print0 | sort -z
```

#### 6.4.3 Parallel processing

For extremely large codebases, you can split the work:

```bash
# Split files into chunks
find ./src -type f -name "*.php" -print0 | \
  xargs -0 -n 100 -P 4 ./ctf.sh php
```

---

## 7. Technical Deep Dive

### 7.1 Function Reference

#### 7.1.1 `map_lang()`

**Purpose**: Maps file extensions to Markdown fenced-block language identifiers.

**Signature**: `map_lang(extension: string) -> string`

**Behavior**:
1. Converts the extension to lowercase
2. Performs a case-insensitive lookup across 50+ extensions
3. Returns the correct Markdown language identifier
4. Unknown extensions fall through to their raw lowercase form

**Example**:
```bash
map_lang "PHP"    # Returns: php
map_lang "js"     # Returns: javascript
map_lang "unknown" # Returns: unknown
```

#### 7.1.2 `is_binary()`

**Purpose**: Detects whether a file is binary or text.

**Signature**: `is_binary(file: string) -> boolean`

**Behavior**:
1. If `file` utility is available, queries `--mime-encoding` for the string `binary`
2. Otherwise, scans the first 8 KiB for null bytes
3. Returns 0 (true) if binary, 1 (false) if text

**Example**:
```bash
is_binary "image.png"  # Returns: 0 (true)
is_binary "script.sh"  # Returns: 1 (false)
```

#### 7.1.3 `abspath()`

**Purpose**: Resolves a relative path to an absolute path without requiring GNU `realpath`.

**Signature**: `abspath(path: string, must_exist: boolean) -> string`

**Behavior**:
1. Splits the path into directory and filename
2. Changes to the directory and captures `pwd`
3. Reconstructs the absolute path
4. If `must_exist` is true, returns 1 if the directory doesn't exist

**Example**:
```bash
abspath "./src/file.php"           # Returns: /current/dir/src/file.php
abspath "./nonexistent" "must_exist" # Returns: 1 (error)
```

### 7.2 Environment Variables

The script respects the following environment variables:

| Variable | Purpose | Default |
|----------|---------|---------|
| `PATH`   | Used to locate utilities | System default |
| `LC_ALL` | Locale settings | System default |
| `HOME`   | User home directory | System default |

### 7.3 Error Handling

The script uses `set -euo pipefail` for strict error handling:

- `set -e`: Exit immediately if a command exits with a non-zero status
- `set -u`: Treat unset variables as an error
- `set -o pipefail`: Return value of a pipeline is the status of the last command to exit with a non-zero status

**Error Categories**:
1. **Fatal errors**: Missing source directory, unwritable output directory → script exits with error message
2. **Warnings**: Unreadable files, binary files → logged but processing continues
3. **Info**: Progress updates, final summary → logged to stderr

---

## 8. Troubleshooting

### 8.1 Common Issues

#### Issue 1: `Source directory '...' does not exist`

**Symptoms**:
```
[ERROR] Source directory '/path/to/dir' does not exist.
```

**Causes**:
- Typo in the path
- Directory was deleted or moved
- Insufficient permissions to read the directory

**Solutions**:
```bash
# Verify the path exists
ls -la /path/to/dir

# Check permissions
ls -ld /path/to/dir

# Use absolute path instead of relative
ctf php /absolute/path/to/src result.md
```

#### Issue 2: `Output directory '...' is not writable`

**Symptoms**:
```
[ERROR] Output directory '/path/to/output' is not writable.
```

**Causes**:
- Output directory is read-only
- Insufficient permissions
- Disk is full

**Solutions**:
```bash
# Check permissions
ls -la $(dirname output.md)

# Change permissions if needed
chmod u+w /path/to/output

# Check disk space
df -h /path/to/output
```

#### Issue 3: `Permission denied` on script execution

**Symptoms**:
```
bash: ./ctf.sh: Permission denied
```

**Causes**:
- Script doesn't have execute permission

**Solutions**:
```bash
# Set the executable bit
chmod 0755 ctf.sh

# Or run with bash explicitly
bash ctf.sh php ./src result.md
```

#### Issue 4: No files collected (0 candidates)

**Symptoms**:
```
[INFO]  Found 0 candidate file(s).
```

**Causes**:
- Wrong extension specified
- No files with that extension exist
- Files are in a different directory

**Solutions**:
```bash
# Verify files exist
find . -name "*.php" | head

# Check extension case sensitivity (Linux)
ls -la src/ | grep -i php

# Use correct extension
ctf php ./src result.md  # Not PHP
```

#### Issue 5: Output file is empty (only header)

**Symptoms**: Output file contains only the metadata header, no file contents.

**Causes**:
- All matching files are binary
- All matching files are unreadable
- All matching files were skipped

**Solutions**:
```bash
# Check which files are being skipped
ctf "" ./project output.md 2>&1 | grep WARN

# Check file permissions
ls -la src/

# Verify files are text
file src/*
```

### 8.2 Binary File Handling

The script silently skips files identified as binary. To see which files are being skipped, inspect the `[WARN]` lines in stderr output:

```bash
ctf "" ./project output.md 2>&1 | grep WARN
```

**Expected output**:
```
[WARN]  Skip (binary):     src/images/logo.png
[WARN]  Skip (binary):     src/assets/icon.jpg
[WARN]  Skip (unreadable): src/config/secrets.env
```

### 8.3 Windows-Specific Issues

#### Issue 1: PowerShell Execution Policy

**Symptoms**:
```
ctf.bat : File C:\Users\...\ctf.ps1 cannot be loaded because running scripts is disabled on this system.
```

**Solution**:
The BAT wrapper already uses `-ExecutionPolicy Bypass`, so this shouldn't happen. If it does, run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

#### Issue 2: PATH Not Updated

**Symptoms**:
```
'ctf' is not recognized as an internal or external command
```

**Solution**:
1. Verify the PATH was updated: `echo $env:PATH`
2. Restart your terminal
3. Verify the script exists: `dir $env:USERPROFILE\bin\ctf.bat`

---

## 9. Contributing

Contributions are welcome! Feel free to open pull requests, file bug reports, or suggest new features.

### 9.1 Development Guidelines

1. **Follow the existing code style**:
   - Use `set -euo pipefail` for strict error handling
   - Use `readonly` constants for configuration
   - Use named functions instead of inline code
   - Add `[WARN]` / `[INFO]` / `[ERROR]` log calls for all user-visible state changes

2. **Keep the script dependency-free**:
   - Use only standard GNU utilities on Linux
   - Use only built-in PowerShell on Windows
   - No Python, Node.js, or external packages

3. **Update the language mapping table**:
   - Add new extensions to `map_lang()` (Bash) and `Get-LanguageTag` (PowerShell)
   - Test with real files to ensure correct highlighting

4. **Test on all platforms**:
   - Bash 4.2+ on Linux (Debian, Ubuntu, CentOS)
   - Bash 4.2+ on macOS
   - PowerShell 5.1+ on Windows 10/11

5. **Write tests**:
   - Add test cases for new features
   - Test edge cases (empty directories, binary files, symlinks)

### 9.2 Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes
4. Test thoroughly on all platforms
5. Commit your changes: `git commit -m 'Add amazing feature'`
6. Push to the branch: `git push origin feature/amazing-feature`
7. Open a Pull Request

### 9.3 Bug Reports

When filing a bug report, please include:
- Operating system and version
- Bash/PowerShell version
- Full error message
- Steps to reproduce
- Expected vs actual behavior

---

## 10. License & Author

### 10.1 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

**MIT License Summary**:
- ✅ Commercial use
- ✅ Modification
- ✅ Distribution
- ✅ Private use
- ❌ Liability
- ❌ Warranty

### 10.2 Author

**Mikhail Deynekin** — Senior Software Engineer & AI Enthusiast

- 🌐 **Website**: [Deynekin.com](https://deynekin.com)
- 📧 **Email**: [Mikhail@Deynekin.com](mailto:Mikhail@Deynekin.com)
- 🐙 **GitHub**: [@paulmann](https://github.com/paulmann)

### 10.3 Getting Help

- 📖 **Documentation**: Read this README thoroughly
- 🐛 **Bug Reports**: [Open an issue](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💡 **Feature Requests**: [Request a feature](https://github.com/paulmann/ctf-collect-to-file/issues/new)
- 💬 **Discussions**: [Join the conversation](https://github.com/paulmann/ctf-collect-to-file/discussions)

### 10.4 Support the Project

If you find this tool useful, please consider:
- ⭐ Starring the repository on GitHub
- 🐛 Reporting bugs you encounter
- 💡 Suggesting new features
- 📣 Sharing the tool with your colleagues

---

> **Note**: Always test the script in a staging environment and review the output file before using it as LLM input in sensitive or production contexts.
```
