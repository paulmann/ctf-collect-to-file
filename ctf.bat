@echo off
rem ###############################################################################
rem # Script:  ctf.bat (Collect To File for Windows)
rem # Author:  Mikhail Deynekin <Mikhail@Deynekin.com> | https://deynekin.com
rem # Version: 3.1.0-win
rem #
rem # Description:
rem #   Windows BAT port of ctf.sh. Recursively collects source files by
rem #   extension into a single Markdown aggregate, preserving paths relative
rem #   to the root search directory.
rem #
rem #   Pure CMD cannot reliably implement binary detection, encoding handling,
rem #   Unicode-safe paths, arbitrary file names, and dynamic Markdown fences.
rem #   Therefore this BAT file uses an embedded PowerShell payload while
rem #   remaining a normal .bat entry point.
rem #
rem # Usage:
rem #   ctf.bat [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
rem #
rem # Compatibility:
rem #   Windows 10/11, Windows PowerShell 5.1 or newer.
rem #
rem # Changes in 3.1.0-win:
rem #   - Improved text encoding detection: BOM, UTF-8 validation, ANSI fallback.
rem #   - Output Markdown is written as UTF-8 without BOM.
rem #   - Dynamic Markdown fences are computed from decoded text content.
rem #   - Temporary-file based output writing is preserved.
rem #   - Binary guard and unreadable-file skipping are preserved.
rem ###############################################################################

setlocal EnableExtensions

set "CTF_SCRIPT_NAME=%~nx0"
set "CTF_SCRIPT_VERSION=3.1.0-win"
set "SELF=%~f0"
set "TMP_PS1=%TEMP%\%~n0_%RANDOM%%RANDOM%.ps1"
set "MARKER=::CTF_POWERSHELL_SCRIPT::"

rem Prefer UTF-8 console output when possible.
chcp 65001 >nul 2>&1

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell is required for this script. >&2
    exit /b 1
)

set "MARKER_LINE="
for /f "tokens=1 delims=:" %%L in ('findstr /n /c:"%MARKER%" "%SELF%"') do set /a MARKER_LINE=%%L

if not defined MARKER_LINE (
    echo [ERROR] Embedded PowerShell payload not found. >&2
    exit /b 1
)

set /a MARKER_LINE+=1

more +%MARKER_LINE% "%SELF%" > "%TMP_PS1%"
if errorlevel 1 (
    echo [ERROR] Cannot extract embedded PowerShell payload. >&2
    exit /b 1
)

set "CTF_TMP_PS1=%TMP_PS1%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMP_PS1%" %*
set "CTF_ERR=%ERRORLEVEL%"

del /q /f "%TMP_PS1%" >nul 2>&1
exit /b %CTF_ERR%

::CTF_POWERSHELL_SCRIPT::
#Requires -Version 5.1

# PowerShell payload embedded inside the BAT file.
# All comments in this payload are intentionally in English.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = if ($env:CTF_SCRIPT_NAME) { $env:CTF_SCRIPT_NAME } else { 'ctf.bat' }
$ScriptVersion = if ($env:CTF_SCRIPT_VERSION) { $env:CTF_SCRIPT_VERSION } else { '3.1.0-win' }

$UseColor = $false
try {
    $UseColor = -not [System.Console]::IsErrorRedirected
} catch {
    $UseColor = $false
}

function Write-ColoredError {
    param(
        [System.ConsoleColor]$Color,
        [string]$Text
    )

    if ($UseColor) {
        $old = $null
        try {
            $old = [System.Console]::ForegroundColor
            [System.Console]::ForegroundColor = $Color
            [System.Console]::Error.WriteLine($Text)
        } catch {
            [System.Console]::Error.WriteLine($Text)
        } finally {
            if ($null -ne $old) {
                try {
                    [System.Console]::ForegroundColor = $old
                } catch {
                    # Ignore console restore errors.
                }
            }
        }
    } else {
        [System.Console]::Error.WriteLine($Text)
    }
}

function Invoke-Die {
    param([string]$Message)

    Write-ColoredError Red "[ERROR] $Message"
    exit 1
}

function Write-LogInfo {
    param([string]$Message)

    Write-ColoredError Green "[INFO]  $Message"
}

function Write-LogWarn {
    param([string]$Message)

    Write-ColoredError Yellow "[WARN]  $Message"
}

function Show-Usage {
    $text = @"
$ScriptName v$ScriptVersion - Collect source files into a Markdown aggregate

USAGE
  $ScriptName [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]

ARGUMENTS
  EXTENSION    Extension to collect (e.g. php, js, sh).
               Pass "" or omit to collect all non-binary files.
  SOURCE_DIR   Root search directory. Default: current directory.
  OUTPUT_FILE  Destination Markdown file.
               Default: all-<EXTENSION>-files.md or All-Project-Files.md

OPTIONS
  -h, --help      Show this help and exit.
  -V, --version   Show version and exit.
  --              End of options, useful for paths beginning with dash.

EXAMPLES
  $ScriptName php ./src result.md
  $ScriptName js
  $ScriptName "" C:\Projects proj.md
  $ScriptName
"@

    [System.Console]::WriteLine($text)
    exit 0
}

function Get-HumanSize {
    param([long]$Bytes)

    if ($Bytes -ge 1048576) {
        return ('{0} MiB' -f [math]::Floor($Bytes / 1048576))
    } elseif ($Bytes -ge 1024) {
        return ('{0} KiB' -f [math]::Floor($Bytes / 1024))
    } else {
        return ('{0} B' -f $Bytes)
    }
}

function ConvertTo-MarkdownTableValue {
    param([string]$Value)

    $Value = $Value -replace "`r", ' '
    $Value = $Value -replace "`n", ' '
    $Value = $Value -replace '\|', '\|'

    return $Value
}

function Get-RelativePath {
    param(
        [string]$Root,
        [string]$FullPath
    )

    if ($Root.EndsWith('\')) {
        $prefix = $Root
    } else {
        $prefix = $Root + '\'
    }

    if ($FullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($prefix.Length)
        if ([string]::IsNullOrEmpty($rel)) {
            return $FullPath
        }

        return $rel
    }

    return $FullPath
}

function Test-FileBinary {
    param([string]$Path)

    $fs = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )

    try {
        if ($fs.Length -eq 0) {
            return $false
        }

        $buffer = New-Object byte[] 8192
        $read = $fs.Read($buffer, 0, $buffer.Length)

        # UTF-32 files are treated as binary for simplicity.
        if ($read -ge 4) {
            if (($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE -and $buffer[2] -eq 0x00 -and $buffer[3] -eq 0x00) -or
                ($buffer[0] -eq 0x00 -and $buffer[1] -eq 0x00 -and $buffer[2] -eq 0xFE -and $buffer[3] -eq 0xFF)) {
                return $true
            }
        }

        # Recognize common text BOMs before scanning for NUL bytes.
        if ($read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
            return $false
        }

        if ($read -ge 2) {
            if (($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) -or
                ($buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF)) {
                return $false
            }
        }

        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) {
                return $true
            }
        }

        return $false
    } finally {
        $fs.Dispose()
    }
}

function Get-TextEncoding {
    param([string]$Path)

    $fs = [System.IO.File]::OpenRead($Path)

    try {
        if ($fs.Length -eq 0) {
            return [System.Text.Encoding]::UTF8
        }

        $head = New-Object byte[] 4096
        $read = $fs.Read($head, 0, $head.Length)

        if ($read -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            return [System.Text.Encoding]::UTF8
        }

        if ($read -ge 2) {
            if ($head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
                return [System.Text.Encoding]::Unicode
            }

            if ($head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
                return [System.Text.Encoding]::BigEndianUnicode
            }
        }

        # If there is no BOM, try to detect UTF-8 without falling over
        # a possible truncated multi-byte sequence at the sample boundary.
        $len = $read
        if ($len -eq $head.Length -and $len -gt 4) {
            $len -= 4
        }

        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

        try {
            [void]$utf8Strict.GetString($head, 0, $len)
            return [System.Text.Encoding]::UTF8
        } catch {
            return [System.Text.Encoding]::Default
        }
    } finally {
        $fs.Dispose()
    }
}

function Get-MarkdownFence {
    param(
        [string]$Path,
        [System.Text.Encoding]$Encoding
    )

    $bt = [char]96
    $tilde = [char]126

    $maxBackticks = 0
    $maxTildes = 0

    try {
        $sr = New-Object System.IO.StreamReader($Path, $Encoding, $true)
    } catch {
        return ([string]::new($bt, 3))
    }

    try {
        $buffer = New-Object char[] 65536

        $afterNewline = $true
        $spaces = 0
        $prefixValid = $true
        $currentChar = [char]0
        $currentCount = 0

        while (($read = $sr.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($i = 0; $i -lt $read; $i++) {
                $c = $buffer[$i]

                # Treat LF and CR as line separators for fence detection.
                if ($c -eq [char]10 -or $c -eq [char]13) {
                    if ($currentChar -ne [char]0) {
                        if ($currentChar -eq $bt) {
                            if ($currentCount -gt $maxBackticks) {
                                $maxBackticks = $currentCount
                            }
                        } elseif ($currentChar -eq $tilde) {
                            if ($currentCount -gt $maxTildes) {
                                $maxTildes = $currentCount
                            }
                        }

                        $currentChar = [char]0
                        $currentCount = 0
                    }

                    $afterNewline = $true
                    $spaces = 0
                    $prefixValid = $true
                    continue
                }

                if ($afterNewline) {
                    if ($c -eq [char]32) {
                        if ($spaces -lt 3) {
                            $spaces++
                        } else {
                            $prefixValid = $false
                        }

                        continue
                    }

                    $afterNewline = $false

                    if (($c -eq $bt -or $c -eq $tilde) -and $prefixValid) {
                        $currentChar = $c
                        $currentCount = 1
                    } else {
                        $prefixValid = $false
                    }
                } else {
                    if ($currentChar -ne [char]0) {
                        if ($c -eq $currentChar) {
                            $currentCount++
                        } else {
                            if ($currentChar -eq $bt) {
                                if ($currentCount -gt $maxBackticks) {
                                    $maxBackticks = $currentCount
                                }
                            } elseif ($currentChar -eq $tilde) {
                                if ($currentCount -gt $maxTildes) {
                                    $maxTildes = $currentCount
                                }
                            }

                            $currentChar = [char]0
                            $currentCount = 0
                            $prefixValid = $false
                        }
                    }
                }
            }
        }

        if ($currentChar -ne [char]0) {
            if ($currentChar -eq $bt) {
                if ($currentCount -gt $maxBackticks) {
                    $maxBackticks = $currentCount
                }
            } elseif ($currentChar -eq $tilde) {
                if ($currentCount -gt $maxTildes) {
                    $maxTildes = $currentCount
                }
            }
        }
    } finally {
        $sr.Dispose()
    }

    $backtickLen = [math]::Max(3, $maxBackticks + 1)
    $tildeLen = [math]::Max(3, $maxTildes + 1)

    if ($backtickLen -le $tildeLen) {
        return ([string]::new($bt, $backtickLen))
    }

    return ([string]::new($tilde, $tildeLen))
}

function Get-LanguageTag {
    param([string]$FilePath)

    $base = [System.IO.Path]::GetFileName($FilePath).ToLowerInvariant()

    switch -Wildcard ($base) {
        'dockerfile*'     { return 'dockerfile' }
        'containerfile*'  { return 'dockerfile' }
        'makefile*'       { return 'makefile' }
        'gnumakefile*'    { return 'makefile' }
        'jenkinsfile'     { return 'groovy' }
        'cmakelists.txt'  { return 'cmake' }
        'readme'          { return 'markdown' }
    }

    $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLowerInvariant()

    switch ($ext) {
        'sh'       { return 'bash' }
        'bash'     { return 'bash' }
        'zsh'      { return 'bash' }
        'ksh'      { return 'bash' }
        'fish'     { return 'bash' }
        'py'       { return 'python' }
        'pyw'      { return 'python' }
        'rb'       { return 'ruby' }
        'pl'       { return 'perl' }
        'pm'       { return 'perl' }
        'php'      { return 'php' }
        'php5'     { return 'php' }
        'php7'     { return 'php' }
        'php8'     { return 'php' }
        'js'       { return 'javascript' }
        'mjs'      { return 'javascript' }
        'cjs'      { return 'javascript' }
        'ts'       { return 'typescript' }
        'tsx'      { return 'tsx' }
        'jsx'      { return 'jsx' }
        'html'     { return 'html' }
        'htm'      { return 'html' }
        'xhtml'    { return 'html' }
        'xml'      { return 'xml' }
        'xsl'      { return 'xml' }
        'xsd'      { return 'xml' }
        'rss'      { return 'xml' }
        'atom'     { return 'xml' }
        'svg'      { return 'xml' }
        'css'      { return 'css' }
        'scss'     { return 'scss' }
        'sass'     { return 'sass' }
        'less'     { return 'less' }
        'json'     { return 'json' }
        'jsonc'    { return 'json' }
        'json5'    { return 'json' }
        'yaml'     { return 'yaml' }
        'yml'      { return 'yaml' }
        'toml'     { return 'toml' }
        'sql'      { return 'sql' }
        'go'       { return 'go' }
        'rs'       { return 'rust' }
        'c'        { return 'c' }
        'cpp'      { return 'cpp' }
        'cc'       { return 'cpp' }
        'cxx'      { return 'cpp' }
        'c++'      { return 'cpp' }
        'h'        { return 'c' }
        'hh'       { return 'c' }
        'hpp'      { return 'cpp' }
        'hxx'      { return 'cpp' }
        'java'     { return 'java' }
        'kt'       { return 'kotlin' }
        'kts'      { return 'kotlin' }
        'swift'    { return 'swift' }
        'cs'       { return 'csharp' }
        'lua'      { return 'lua' }
        'r'        { return 'r' }
        'ps1'      { return 'powershell' }
        'psm1'     { return 'powershell' }
        'psd1'     { return 'powershell' }
        'md'       { return 'markdown' }
        'markdown' { return 'markdown' }
        'dockerfile' { return 'dockerfile' }
        'makefile' { return 'makefile' }
        'mk'       { return 'makefile' }
        'conf'     { return 'ini' }
        'cfg'      { return 'ini' }
        'ini'      { return 'ini' }
        'env'      { return 'bash' }
        'envrc'    { return 'bash' }
        'nginx'    { return 'nginx' }
        'tf'       { return 'hcl' }
        'tfvars'   { return 'hcl' }
        'cmake'    { return 'cmake' }
        'rst'      { return 'rst' }
        'txt'      { return 'text' }
        'text'     { return 'text' }
        'log'      { return 'text' }
        default {
            if ($ext -match '^[a-z0-9_+.-]+$') {
                return $ext
            }

            return ''
        }
    }
}

# Parse command-line arguments.
$positional = New-Object System.Collections.Generic.List[object]
$endOptions = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]

    if (-not $endOptions) {
        if ($a -eq '-h' -or $a -eq '--help' -or $a -eq '/?' -or $a -eq '-?') {
            Show-Usage
        } elseif ($a -eq '-V' -or $a -eq '--version') {
            [System.Console]::WriteLine("$ScriptName v$ScriptVersion")
            exit 0
        } elseif ($a -eq '--') {
            $endOptions = $true
            continue
        } elseif ($a.StartsWith('-')) {
            Invoke-Die "Unknown option: $a (use --help)"
        }
    }

    $positional.Add($a)
}

if ($positional.Count -gt 3) {
    Invoke-Die 'Too many arguments. Use --help.'
}

$Ext = if ($positional.Count -ge 1) { [string]$positional[0] } else { '' }
$Src = if ($positional.Count -ge 2) { [string]$positional[1] } else { '.' }
$Out = if ($positional.Count -ge 3) { [string]$positional[2] } else { '' }

if ([string]::IsNullOrEmpty($Src)) {
    $Src = '.'
}

# Normalize extension.
if ($Ext -eq '*' -or $Ext -eq '.*') {
    $Ext = ''
}

while ($Ext.StartsWith('.')) {
    $Ext = $Ext.Substring(1)
}

$Ext = $Ext.ToLowerInvariant()

if ($Ext -match '[\\/:*?"<>|\s\[\]]') {
    Invoke-Die "Invalid extension '$Ext'. Use a simple extension without path or wildcard characters."
}

# Normalize and validate source directory.
if ($Src -match '^[A-Za-z]:$') {
    $Src += '\'
}

if (-not (Test-Path -LiteralPath $Src -PathType Container)) {
    Invoke-Die "Source directory '$Src' does not exist or is not a directory."
}

try {
    $srcAbs = [System.IO.Path]::GetFullPath($Src)
} catch {
    Invoke-Die "Cannot resolve source directory '$Src'."
}

# Determine default output file name.
if ([string]::IsNullOrEmpty($Out)) {
    if ($Ext) {
        $Out = "all-$Ext-files.md"
    } else {
        $Out = 'All-Project-Files.md'
    }
}

if ($Out.EndsWith('\') -or $Out.EndsWith('/')) {
    Invoke-Die "Output file '$Out' must not end with a path separator."
}

if (Test-Path -LiteralPath $Out -PathType Container) {
    Invoke-Die "Output path '$Out' is a directory."
}

try {
    $outAbs = [System.IO.Path]::GetFullPath($Out)
} catch {
    Invoke-Die "Cannot resolve output file '$Out'."
}

$outDirAbs = [System.IO.Path]::GetDirectoryName($outAbs)
$outBase = [System.IO.Path]::GetFileName($outAbs)

if ([string]::IsNullOrWhiteSpace($outBase) -or $outBase -eq '.' -or $outBase -eq '..') {
    Invoke-Die "Invalid output file name '$Out'."
}

if ([string]::IsNullOrEmpty($outDirAbs)) {
    $outDirAbs = [System.IO.Path]::GetPathRoot($outAbs)
}

if (-not (Test-Path -LiteralPath $outDirAbs -PathType Container)) {
    Invoke-Die "Output directory '$outDirAbs' does not exist."
}

# If output already exists, validate that it is writable.
if (Test-Path -LiteralPath $outAbs) {
    $item = Get-Item -LiteralPath $outAbs -Force

    if ($item.PSIsContainer) {
        Invoke-Die "Output path '$outAbs' is a directory."
    }

    try {
        $check = [System.IO.File]::Open(
            $outAbs,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $check.Dispose()
    } catch {
        Invoke-Die "Output file '$Out' exists and is not writable."
    }

    Write-LogWarn "Output file '$Out' exists - overwriting."
}

Write-LogInfo "Scanning '$srcAbs' for '$(if ($Ext) { $Ext } else { '*' })' files..."

# Collect candidate file list.
$files = New-Object System.Collections.Generic.List[string]

try {
    if ($Ext) {
        $filter = "*.$Ext"

        Get-ChildItem -LiteralPath $srcAbs -Recurse -File -Force -Filter $filter -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    } else {
        Get-ChildItem -LiteralPath $srcAbs -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    }
} catch {
    # Enumeration errors are intentionally ignored; inaccessible branches are skipped.
}

$files.Sort([System.StringComparer]::OrdinalIgnoreCase)

$Total = $files.Count
Write-LogInfo "Found $Total candidate file(s)."

# Create temporary output file in the destination directory.
$tempName = '.' + $outBase + '.ctf.' + [System.Guid]::NewGuid().ToString('N')
$tmpFile = Join-Path $outDirAbs $tempName

try {
    [System.IO.File]::Create($tmpFile).Dispose()
} catch {
    Invoke-Die "Cannot create temporary file in '$outDirAbs'."
}

$FileCount = 0
$SkipCount = 0
$completed = $false
$btChar = [char]96

try {
    $outStream = [System.IO.File]::Create($tmpFile)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($outStream, $utf8NoBom)

    try {
        $generated = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

        $writer.Write("# Project Source Code Aggregate`r`n`r`n")
        $writer.Write("| Field | Value |`r`n")
        $writer.Write("|:------|:------|`r`n")
        $writer.Write('| Generated | ' + (ConvertTo-MarkdownTableValue $generated) + " |`r`n")
        $writer.Write('| Script | ' + (ConvertTo-MarkdownTableValue "$ScriptName v$ScriptVersion") + " |`r`n")
        $writer.Write('| Source | ' + (ConvertTo-MarkdownTableValue $srcAbs) + " |`r`n")
        $writer.Write('| Extension | ' + (ConvertTo-MarkdownTableValue $(if ($Ext) { $Ext } else { '*' })) + " |`r`n")
        $writer.Write('| Candidates | ' + (ConvertTo-MarkdownTableValue ([string]$Total)) + " |`r`n")
        $writer.Write("`r`n---`r`n`r`n")
        $writer.Flush()

        $tempPrefix = Join-Path $outDirAbs ('.' + $outBase + '.ctf.')

        foreach ($file in $files) {
            $rel = Get-RelativePath -Root $srcAbs -FullPath $file
            $relDisplay = ($rel -replace "`r", ' ') -replace "`n", ' '

            # Never include the final output file itself.
            if ($file.Equals($outAbs, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-LogWarn "Skip (output file): $relDisplay"
                $SkipCount++
                continue
            }

            # Skip stale temporary files from previous interrupted runs.
            if ($file.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-LogWarn "Skip (temporary file): $relDisplay"
                $SkipCount++
                continue
            }

            # Skip the temporary PowerShell payload extracted by the BAT wrapper.
            if ($env:CTF_TMP_PS1 -and $file.Equals($env:CTF_TMP_PS1, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-LogWarn "Skip (payload file): $relDisplay"
                $SkipCount++
                continue
            }

            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                Write-LogWarn "Skip (non-regular): $relDisplay"
                $SkipCount++
                continue
            }

            try {
                if (Test-FileBinary -Path $file) {
                    Write-LogWarn "Skip (binary): $relDisplay"
                    $SkipCount++
                    continue
                }

                $encoding = Get-TextEncoding -Path $file
                $lang = Get-LanguageTag -FilePath $file
                $fence = Get-MarkdownFence -Path $file -Encoding $encoding
            } catch {
                Write-LogWarn "Skip (unreadable): $relDisplay"
                $SkipCount++
                continue
            }

            $FileCount++

            if ($relDisplay.IndexOf($btChar) -ge 0) {
                $writer.Write("### $relDisplay`r`n`r`n")
            } else {
                $writer.Write('### ' + $btChar + $relDisplay + $btChar + "`r`n`r`n")
            }

            $writer.Write($fence + $lang + "`r`n")
            $writer.Flush()

            $sr = New-Object System.IO.StreamReader($file, $encoding, $true)
            $lastChar = [char]0

            try {
                $charBuffer = New-Object char[] 65536

                while (($read = $sr.Read($charBuffer, 0, $charBuffer.Length)) -gt 0) {
                    $writer.Write([string]::new($charBuffer, 0, $read))
                    $lastChar = $charBuffer[$read - 1]
                }
            } finally {
                $sr.Dispose()
            }

            # Ensure the closing fence always starts on its own line.
            if ($lastChar -ne [char]0 -and $lastChar -ne [char]10) {
                $writer.Write("`r`n")
            }

            $writer.Write($fence + "`r`n`r`n---`r`n`r`n")
            $writer.Flush()
        }

        $writer.Write("`r`n## Summary`r`n`r`n")
        $writer.Write("| Metric | Count |`r`n")
        $writer.Write("|:-------|------:|`r`n")
        $writer.Write('| Processed | ' + [string]$FileCount + " |`r`n")
        $writer.Write('| Skipped | ' + [string]$SkipCount + " |`r`n")
        $writer.Write('| Total | ' + [string]$Total + " |`r`n")
        $writer.Flush()
    } finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }

        if ($null -ne $outStream) {
            $outStream.Dispose()
        }
    }

    # Clear read-only attribute if needed before replacing an existing file.
    if (Test-Path -LiteralPath $outAbs) {
        try {
            Set-ItemProperty -LiteralPath $outAbs -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        } catch {
            # Ignore; Move-Item will report a fatal error if replacement fails.
        }
    }

    Move-Item -LiteralPath $tmpFile -Destination $outAbs -Force
    $completed = $true

    $size = (Get-Item -LiteralPath $outAbs).Length

    Write-LogInfo "Done: $FileCount file(s) written, $SkipCount skipped."
    Write-LogInfo "Output -> $outAbs ($(Get-HumanSize $size))"
} finally {
    if (-not $completed) {
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    }
}
