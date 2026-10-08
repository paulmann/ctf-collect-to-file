<#
.SYNOPSIS
    ctf.ps1 - Collect To File for Windows (PowerShell 5.1+).

.DESCRIPTION
    Recursively collects source files into a single Markdown / JSON / JSONL /
    text aggregate, preserving paths relative to the source root. This is the
    Windows counterpart of ctf.sh; the option names and the document layout are
    the same so that output produced on either platform is interchangeable.

    Design notes:
      * Windows PowerShell 5.1 compatible: no ternary operator, no '??',
        no -AsHashtable, no PS7-only cmdlets.
      * All file content is handled as bytes and decoded explicitly as UTF-8,
        because Get-Content's default encoding differs between 5.1 and 7.x.
      * Output is written as UTF-8 without BOM through a temporary file and
        then moved into place, so a failed run cannot truncate an existing
        document.
      * There is no `eval`-equivalent: nothing read from disk is executed.

.PARAMETER Extension
    Extension to collect (e.g. 'php'). Empty collects every text file.

.PARAMETER SourceDir
    Root search directory. Default: the current directory.

.PARAMETER OutputFile
    Destination Markdown file. '-' writes to stdout.

.EXAMPLE
    .\ctf.ps1 php .\src result.md
    .\ctf.ps1 -Ext php,js -SourceDir .\src -OutputFile bundle.md
    .\ctf.ps1 -Stats .\src
    .\ctf.ps1 -CheckUpdate

.NOTES
    Author:  Mikhail Deynekin <Mikhail@Deynekin.com> | https://deynekin.com
    Version: 4.0.0 (must match the VERSION file)
    License: MIT
#>

[CmdletBinding()]
# Имена параметров — идиоматичные для PowerShell, но каждому добавлен алиас с
# дефисом, точно совпадающий с длинной опцией ctf.sh: один и тот же командный
# интерфейс работает на Linux, macOS и Windows.
#
# Ограничение платформы: PowerShell сопоставляет имена БЕЗ УЧЁТА РЕГИСТРА,
# поэтому пары bash-опций, различающиеся только регистром (-e/--ext и
# -E/--exclude, -v/--verbose и -V/--version), не могут иметь обе короткие формы.
# На Windows доступны: -e -o -n -q -v -h -F -d -L -I, а --exclude и --version —
# только в длинной форме. Это задокументировано в README.
param(
    [Parameter(Position = 0)] [string] $Extension = '',
    [Parameter(Position = 1)] [string] $SourceDir = '',
    [Parameter(Position = 2)] [string] $OutputFile = '',

    [Alias('e')]                       [string[]] $Ext = @(),
                                              [string[]] $Exclude = @(),
    [Alias('I')]                   [string[]] $Include = @(),
    [Alias('exclude-dir')]                    [string[]] $ExcludeDir = @(),
    [Alias('no-default-excludes')]            [switch]   $NoDefaultExcludes,
    [Alias('list-default-excludes')]          [switch]   $ListDefaultExcludes,
    [Alias('d', 'max-depth')]                 [int]      $MaxDepth = 0,
    [Alias('L')]                    [switch]   $Follow,
    [Alias('max-size')]                       [string]   $MaxSize = '',
    [Alias('min-size')]                       [string]   $MinSize = '',
    [Alias('files-from')]                     [string]   $FilesFrom = '',
                                              [ValidateSet('', 'tracked', 'all')] [string] $Git = '',
                                              [ValidateSet('auto', 'never', 'always')] [string] $Binary = 'auto',

    [Alias('o')]                    [string] $Output = '',
    [Alias('F')]                    [ValidateSet('md', 'markdown', 'json', 'jsonl', 'txt', 'text')] [string] $Format = 'md',
    [Alias('heading-level')]                  [ValidateRange(1, 6)] [int] $HeadingLevel = 3,
    [Alias('path-style')]                     [ValidateSet('rel', 'abs')] [string] $PathStyle = 'rel',
                                              [ValidateSet('path', 'name', 'size', 'mtime')] [string] $Sort = 'path',
                                              [string] $Title = 'Project Source Code Aggregate',
    [Alias('no-header')]                      [switch] $NoHeader,
    [Alias('no-summary')]                     [switch] $NoSummary,
    [Alias('no-timestamp')]                   [switch] $NoTimestamp,
                                              [switch] $Toc,
                                              [switch] $Metadata,
    [Alias('line-numbers')]                   [switch] $LineNumbers,
    [Alias('lang-style')]                     [ValidateSet('fenced', 'indent4', 'none')] [string] $LangStyle = 'fenced',
    [Alias('strip-bom')]                      [switch] $StripBom,
    [Alias('truncate-lines')]                 [int] $TruncateLines = 0,
    [Alias('token-budget')]                   [long] $TokenBudget = 0,
    [Alias('budget-action')]                  [ValidateSet('truncate', 'drop')] [string] $BudgetAction = 'truncate',
                                              [switch] $Dedup,

    [Alias('n', 'dry-run')]                   [switch] $DryRun,
                                              [switch] $Stats,
                                              [switch] $Strict,
    [Alias('q')]                     [switch] $Quiet,
    [Alias('v')]          [switch] $Trace,
                                              [ValidateSet('auto', 'always', 'never')] [string] $Color = 'auto',

    [Alias('check-update')]                   [switch] $CheckUpdate,
                                              [switch] $Update,
    [Alias('update-channel')]                 [string] $UpdateChannel = 'main',
    [Alias('update-force')]                   [switch] $UpdateForce,
    [Alias('update-timeout')]                 [int]    $UpdateTimeout = 15,

    [Alias('h')]                      [switch] $Help,
    [Alias('version')]                        [switch] $ShowVersion
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- constants ---------------------------------------------------------------
$ScriptVersion = '4.0.0'
$ScriptName    = 'ctf.ps1'
$RepoOwner     = 'paulmann'
$RepoName      = 'ctf-collect-to-file'
$RawBase       = if ($env:CTF_UPDATE_BASE_URL) { $env:CTF_UPDATE_BASE_URL }
                 else { "https://raw.githubusercontent.com/$RepoOwner/$RepoName" }

$ExitOk       = 0
$ExitRuntime  = 1
$ExitUsage    = 2
$ExitUpdate   = 3
$ExitEmpty    = 4

$DefaultExcludeDirs = @(
    '.git', '.svn', '.hg', 'node_modules', 'bower_components',
    '.venv', 'venv', 'virtualenv', '.tox', '.nox',
    '__pycache__', '.mypy_cache', '.pytest_cache', '.ruff_cache',
    '.gradle', '.m2', '.sbt', '.terraform',
    'build', 'dist', 'out', 'output', 'release', 'target', 'obj',
    '.next', '.nuxt', '.svelte-kit', '.output', '.turbo', '.parcel-cache', '.vite',
    '.cache', '.npm', '.yarn',
    'coverage', 'htmlcov', '.nyc_output',
    '.idea', '.vscode', '.vs', '.settings',
    'bin\Debug', 'bin\Release'
)
$DefaultExcludeGlobs = @(
    '*.min.js', '*.min.css', '*.map', '*.bundle.js', '*.chunk.js',
    'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'composer.lock', 'poetry.lock',
    '*.pack', '*.idx', '*.pyc', '*.pyo', '*.class', '*.o', '*.a',
    '*.so', '*.dylib', '*.dll', '*.exe', '*.obj', '*.pdb'
)

# --- logging -----------------------------------------------------------------
$script:UseColor = $false
if ($Color -eq 'always') { $script:UseColor = $true }
elseif ($Color -eq 'auto') {
    try { $script:UseColor = -not [System.Console]::IsErrorRedirected } catch { $script:UseColor = $false }
}
if ($env:NO_COLOR) { $script:UseColor = $false }

function Write-ColorLine {
    param([System.ConsoleColor] $Fg, [string] $Text)
    if ($script:UseColor) {
        $old = $null
        try {
            $old = [System.Console]::ForegroundColor
            [System.Console]::ForegroundColor = $Fg
            [System.Console]::Error.WriteLine($Text)
        } catch {
            [System.Console]::Error.WriteLine($Text)
        } finally {
            if ($null -ne $old) { try { [System.Console]::ForegroundColor = $old } catch { } }
        }
    } else {
        [System.Console]::Error.WriteLine($Text)
    }
}
function Write-Info  { param([string] $m) if (-not $Quiet) { Write-ColorLine 'Green'   "[INFO] $m" } }
function Write-Warn2 { param([string] $m) if (-not $Quiet) { Write-ColorLine 'Yellow' "[WARN] $m" } }
function Write-Trace { param([string] $m) if ($Trace)      { Write-ColorLine 'Cyan'    "[DEBUG] $m" } }
function Stop-WithError {
    param([string] $Message, [int] $Code = $ExitRuntime)
    Write-ColorLine 'Red' "[ERROR] $Message"
    exit $Code
}

# --- help / version ----------------------------------------------------------
function Show-Usage {
    @'
ctf.ps1 v4.0.0 - collect source files into one aggregate document

USAGE
  ctf.ps1 [Extension] [SourceDir] [OutputFile]
  ctf.ps1 -Ext php,js -SourceDir .\src -OutputFile bundle.md

COLLECTION
  -Ext <list>              Extensions, comma-separated or repeated.
  -Exclude <glob>          Exclude matching paths (repeatable).
  -Include <glob>          Keep only matching paths (repeatable).
  -ExcludeDir <name>       Exclude a directory name at any depth (repeatable).
  -NoDefaultExcludes       Do not apply the built-in VCS/deps/build excludes.
  -ListDefaultExcludes     Print the built-in exclude lists and exit.
  -MaxDepth <n>            Maximum depth below SourceDir (0 = unlimited).
  -Follow                  Follow reparse points (junctions/symlinks).
  -MaxSize <size>          Skip files larger than size (bytes or K/M/G suffix).
  -MinSize <size>          Skip files smaller than size.
  -FilesFrom <file>        Read the file list from a file (newline separated).
  -Git tracked|all         Enumerate with git.exe instead of the filesystem.
  -Binary auto|never|always
                           Binary detection mode.

OUTPUT
  -Output <file>           Destination; '-' writes to stdout.
  -Format md|json|jsonl|txt
  -HeadingLevel <1-6>      Markdown heading level for paths (default 3).
  -PathStyle rel|abs
  -Sort path|name|size|mtime
  -Title <text>
  -NoHeader / -NoSummary / -NoTimestamp
  -Toc                     Add a table of contents.
  -Metadata                Per-file comment: bytes, lines, sha256/12.
  -LineNumbers             Prefix content lines with their number.
  -LangStyle fenced|indent4|none
  -StripBom                Remove a leading UTF-8 BOM from each file.
  -TruncateLines <n>       Keep at most n content lines per file.
  -TokenBudget <n>         Estimated token budget (estimate = ceil(bytes/4)).
  -BudgetAction truncate|drop
  -Dedup                   Emit byte-identical files once.

BEHAVIOUR
  -DryRun                  Print the selection; write nothing.
  -Stats                   Print key=value statistics and exit.
  -Strict                  Exit 4 when nothing was collected.
  -Quiet                   Errors only.
  -Trace                   Debug output (equivalent of the bash --verbose).
  -Color auto|always|never
  -Help / -ShowVersion

SELF-UPDATE
  -CheckUpdate             Report the remote version; exit 0 current, 3 newer.
  -Update                  Download and install the newer version.
  -UpdateChannel <ref>     main (default) | latest | <branch-or-tag>.
  -UpdateForce             Reinstall even when identical.
  -UpdateTimeout <sec>     Per-request timeout (default 15).

EXIT CODES
  0 success | 1 runtime error | 2 usage error | 3 update/network | 4 nothing collected

EXAMPLES
  ctf.ps1 php .\src result.md
  ctf.ps1 -Ext py -TokenBudget 120000 -Output - | Set-Clipboard
  ctf.ps1 -Stats .\src
  ctf.ps1 -CheckUpdate
'@
    exit $ExitOk
}

if ($Help) { Show-Usage }
if ($ShowVersion) { Write-Output "ctf v$ScriptVersion"; exit $ExitOk }

# --- helpers -----------------------------------------------------------------
function ConvertTo-Bytes {
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Value -match '^(\d+)([kKmMgGtT]?)[iI]?[bB]?$') {
        $n = [double]::Parse($Matches[1])
        switch ($Matches[2].ToLowerInvariant()) {
            'k' { $n = $n * 1KB }
            'm' { $n = $n * 1MB }
            'g' { $n = $n * 1GB }
            't' { $n = $n * 1TB }
        }
        return [long] $n
    }
    Stop-WithError "Invalid size '$Value'. Use a byte count with an optional K/M/G/T suffix." $ExitUsage
}

function Get-HumanSize {
    param([long] $Bytes)
    # Округление «от нуля» и инвариантная культура: формат '{0:N1}' по умолчанию
    # использует банковское округление и локальный разделитель, из-за чего вывод
    # расходился с ctf.sh (8699 байт -> "8.4 KiB" против "8.5 KiB").
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $away = [System.MidpointRounding]::AwayFromZero
    if ($Bytes -ge 1GB) { return ([Math]::Round($Bytes / 1GB, 2, $away).ToString('0.00', $inv) + ' GiB') }
    if ($Bytes -ge 1MB) { return ([Math]::Round($Bytes / 1MB, 2, $away).ToString('0.00', $inv) + ' MiB') }
    if ($Bytes -ge 1KB) { return ([Math]::Round($Bytes / 1KB, 1, $away).ToString('0.0', $inv) + ' KiB') }
    return "$Bytes B"
}

function Get-LanguageTag {
    param([string] $Path)
    $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    # Порядок и состав правил обязаны совпадать с map_lang() в ctf.sh: тег языка
    # попадает в документ, поэтому любое расхождение ломает побайтовый паритет.
    switch -Regex ($name) {
        '^(dockerfile|containerfile)'   { return 'dockerfile' }
        '^(makefile|gnumakefile)'       { return 'makefile' }
        '^jenkinsfile'                  { return 'groovy' }
        '^cmakelists\.txt$'            { return 'cmake' }
        '^(rakefile|gemfile|guardfile|vagrantfile|podfile|berksfile)$' { return 'ruby' }
        '^(readme|license|changelog|authors|contributors|notice|copying)$' { return 'markdown' }
        # Точечные файлы конфигурации: .NET считает всё имя расширением, поэтому
        # без этого правила .editorconfig получил бы тег «editorconfig».
        '^\.(gitignore|gitattributes|dockerignore|npmignore|editorconfig|env)$' { return 'text' }
    }
    $ext = [System.IO.Path]::GetExtension($name)
    if ($ext.StartsWith('.')) { $ext = $ext.Substring(1) }
    $map = @{
        'sh'='bash'; 'bash'='bash'; 'zsh'='bash'; 'ps1'='powershell'; 'psm1'='powershell';
        'psd1'='powershell'; 'bat'='batch'; 'cmd'='batch'; 'py'='python'; 'pyw'='python';
        'rb'='ruby'; 'pl'='perl'; 'pm'='perl'; 'php'='php'; 'phtml'='php';
        'js'='javascript'; 'mjs'='javascript'; 'cjs'='javascript'; 'ts'='typescript';
        'tsx'='tsx'; 'jsx'='jsx'; 'vue'='vue'; 'svelte'='svelte';
        'html'='html'; 'htm'='html'; 'xhtml'='html';
        'xml'='xml'; 'xsl'='xml'; 'xsd'='xml'; 'svg'='xml'; 'rss'='xml'; 'atom'='xml'; 'pom'='xml';
        'css'='css'; 'scss'='scss'; 'sass'='sass'; 'less'='less';
        'json'='json'; 'jsonc'='json'; 'json5'='json'; 'jsonl'='json'; 'har'='json';
        'yaml'='yaml'; 'yml'='yaml'; 'toml'='toml';
        'ini'='ini'; 'cfg'='ini'; 'conf'='ini'; 'config'='ini'; 'properties'='ini';
        'sql'='sql'; 'go'='go'; 'rs'='rust'; 'c'='c';
        'cpp'='cpp'; 'cc'='cpp'; 'cxx'='cpp'; 'hpp'='cpp'; 'hxx'='cpp'; 'h'='c';
        'java'='java'; 'kt'='kotlin'; 'kts'='kotlin'; 'groovy'='groovy'; 'gradle'='groovy';
        'scala'='scala'; 'swift'='swift'; 'cs'='csharp'; 'fs'='fsharp'; 'fsi'='fsharp';
        'vb'='vbnet'; 'lua'='lua'; 'r'='r'; 'jl'='julia'; 'dart'='dart';
        'ex'='elixir'; 'exs'='elixir'; 'erl'='erlang'; 'hrl'='erlang';
        'hs'='haskell'; 'ml'='ocaml'; 'mli'='ocaml';
        'clj'='clojure'; 'cljs'='clojure'; 'edn'='clojure';
        'nim'='nim'; 'zig'='zig'; 'proto'='protobuf'; 'graphql'='graphql'; 'gql'='graphql';
        'tf'='hcl'; 'tfvars'='hcl'; 'mk'='makefile'; 'make'='makefile'; 'cmake'='cmake';
        'nginx'='nginx'; 'rst'='rst'; 'adoc'='asciidoc'; 'tex'='latex'; 'bib'='bibtex';
        'diff'='diff'; 'patch'='diff'; 'csv'='text'; 'tsv'='text';
        'md'='markdown'; 'markdown'='markdown'; 'mdx'='markdown';
        'txt'='text'; 'text'='text'; 'log'='text'; 'lock'='text'; 'm'='objectivec'; 'mm'='objectivec'
    }
    if ($map.ContainsKey($ext)) { return $map[$ext] }
    if ($ext -match '^[a-z0-9_+.-]+$') { return $ext }
    return ''
}

# Binary detection: identical rules to ctf.sh so that both platforms agree.
#   * any NUL byte in the first 8 KiB  -> binary
#   * more than 5 % C0 control bytes (except \t \n \v \f \r) or DEL -> binary
# High bytes are NOT evidence of binary: they are ordinary UTF-8 text.
function Test-BinaryFile {
    param([string] $Path, [long] $Length)
    if ($Binary -eq 'never')  { return $false }
    if ($Binary -eq 'always') { return $true }
    if ($Length -le 0) { return $false }
    $scan = 8192
    if ($Length -lt $scan) { $scan = [int] $Length }
    $bytes = New-Object byte[] $scan
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $read = $fs.Read($bytes, 0, $scan)
    } catch {
        return $false
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
    $ctrl = 0
    for ($i = 0; $i -lt $read; $i++) {
        $b = $bytes[$i]
        if ($b -eq 0) { return $true }
        if (($b -lt 9) -or ($b -gt 13 -and $b -lt 32) -or ($b -eq 127)) { $ctrl++ }
    }
    if ($read -le 0) { return $false }
    return (($ctrl * 100) -gt ($read * 5))
}

# Longest line that consists ONLY of fence characters: only such a line can
# close a fenced block (CommonMark). Returns @(maxBackticks, maxTildes, lines, endsWithNewline)
function Get-FenceStats {
    param([string] $Path)
    $mb = 0; $mt = 0; $lines = 0; $endsWithNewline = $true
    $lastByte = -1
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $sr.ReadLine())) {
            $lines++
            $t = $line
            $sp = 0
            while ($sp -lt 3 -and $sp -lt $t.Length -and $t[$sp] -eq ' ') { $sp++ }
            $t = $t.Substring($sp)
            if ($t.Length -ge 3) {
                $c = $t[0]
                if ($c -eq [char]96 -or $c -eq '~') {
                    $k = 0
                    while ($k -lt $t.Length -and $t[$k] -eq $c) { $k++ }
                    if ($k -eq $t.Length) {
                        if ($c -eq [char]96) { if ($k -gt $mb) { $mb = $k } }
                        else { if ($k -gt $mt) { $mt = $k } }
                    }
                }
            }
        }
        if ($fs.Length -gt 0) {
            $pos = $fs.Seek(-1, [System.IO.SeekOrigin]::End)
            $lastByte = $fs.ReadByte()
            $endsWithNewline = ($lastByte -eq 10)
            [void] $fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
        } else {
            $endsWithNewline = $true
        }
    } finally {
        if ($null -ne $sr) { $sr.Dispose() }
        if ($null -ne $fs) { $fs.Dispose() }
    }
    return @($mb, $mt, $lines, $endsWithNewline)
}

function Get-Fence {
    param([int] $MaxBackticks, [int] $MaxTildes)
    $lb = $MaxBackticks + 1; $lt = $MaxTildes + 1
    if ($lb -lt 3) { $lb = 3 }
    if ($lt -lt 3) { $lt = 3 }
    if ($lb -le $lt) { return ([string][char]96) * $lb }
    return ('~') * $lt
}

function Read-TextContent {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($StripBom -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $start = 3
    }
    $enc = New-Object System.Text.UTF8Encoding($false, $false)
    return $enc.GetString($bytes, $start, $bytes.Length - $start)
}

function ConvertTo-JsonString {
    param([string] $Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int] $ch
        switch ($ch) {
            '\' { [void] $sb.Append('\\'); continue }
            '"' { [void] $sb.Append('\"'); continue }
            "`n" { [void] $sb.Append('\n'); continue }
            "`r" { [void] $sb.Append('\r'); continue }
            "`t" { [void] $sb.Append('\t'); continue }
        }
        if ($code -lt 32 -or $code -eq 127) { continue }   # strip other controls
        [void] $sb.Append($ch)
    }
    return $sb.ToString()
}

function Test-GlobMatch {
    param([string] $Pattern, [string] $Value)
    # В PowerShell оператор -like и так трактует '*' как «любая последовательность,
    # включая разделители пути», что совпадает с семантикой ctf.sh -E/-I.
    # Сравниваем оба варианта написания пути, потому что шаблон пользователь
    # может дать и со слэшами, и с обратными.
    if ($Value -like $Pattern) { return $true }
    $alt = $Value.Replace('\', '/')
    $pat = $Pattern.Replace('\', '/')
    return ($alt -like $pat)
}

function Get-RelativePath {
    param([string] $Root, [string] $Path)
    $r = $Root.TrimEnd('\', '/')
    if ($Path.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $Path.Substring($r.Length)
        return $rel.TrimStart('\', '/')
    }
    return $Path
}

function Get-MdAnchor {
    param([string] $Text)
    $a = $Text.ToLowerInvariant().Replace([string][char]96, '')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $a.ToCharArray()) {
        if (($ch -ge 'a' -and $ch -le 'z') -or ($ch -ge '0' -and $ch -le '9') -or $ch -eq '_' -or $ch -eq '-' -or $ch -eq ' ') {
            [void] $sb.Append($ch)
        }
    }
    return $sb.ToString().Replace(' ', '-')
}

# Append-Content — единственное место, где содержимое файла попадает в документ.
# $Verbatim = ни обрезки, ни нумерации: пишем текст как есть (байт-в-байт).
# Иначе пишем построчно, сохраняя стиль перевода строк исходного файла.
# Документ всегда заканчивается переводом строки, даже если исходник — нет.
function Append-Content {
    param(
        [System.Text.StringBuilder] $Sb,
        [string] $Text,
        [string[]] $Lines,
        [bool] $Verbatim,
        [string] $Eol,
        [bool] $EndsWithNewline,
        [string] $Prefix
    )
    if ($Verbatim -and $Prefix -eq '') {
        [void] $Sb.Append($Text)
        if (-not $EndsWithNewline -and $Text.Length -gt 0) { [void] $Sb.Append("`n") }
        return
    }
    if ($Verbatim) {
        $Lines = $Text -split "`r`n|`n|`r", 0
        if ($Lines.Count -ge 2 -and $Lines[$Lines.Count - 1] -eq '' -and $EndsWithNewline) {
            $Lines = $Lines[0..($Lines.Count - 2)]
        } elseif ($Lines.Count -eq 1 -and $Lines[0] -eq '' -and $EndsWithNewline) {
            $Lines = @()
        }
    }
    $n = 0
    foreach ($l in $Lines) {
        $n++
        if ($LineNumbers) { [void] $Sb.Append($Prefix + ('{0,6}| {1}' -f $n, $l) + $Eol) }
        else { [void] $Sb.Append($Prefix + $l + $Eol) }
    }
    if (-not $EndsWithNewline -and $Lines.Count -gt 0) { }
}

function Get-Sanitized {
    param([string] $Text)
    return $Text.Replace("`r", [string][char]0x2424).Replace("`n", [string][char]0x2424).Replace("`t", ' ')
}

# --- self-update -------------------------------------------------------------
function Get-RemoteText {
    param([string] $Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $UpdateTimeout * 1000
        $req.UserAgent = 'ctf-selfupdate'
        $resp = $req.GetResponse()
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            return $sr.ReadToEnd()
        } finally { $resp.Dispose() }
    } catch {
        return $null
    }
}

function Get-UpdateBase {
    $ch = $UpdateChannel
    if ($ch -eq 'latest') {
        $json = Get-RemoteText "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
        if ($json) {
            try {
                $obj = $json | ConvertFrom-Json
                if ($obj.tag_name) { $ch = $obj.tag_name }
            } catch { $ch = 'main' }
        } else { $ch = 'main' }
    }
    return "$RawBase/$ch"
}

function Compare-VersionGreater {
    param([string] $A, [string] $B)
    $pa = $A.TrimStart('v').Split('.')
    $pb = $B.TrimStart('v').Split('.')
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [void] [int]::TryParse(($pa[$i] -replace '[^0-9]', ''), [ref] $x) }
        if ($i -lt $pb.Count) { [void] [int]::TryParse(($pb[$i] -replace '[^0-9]', ''), [ref] $y) }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $false
}

function Invoke-CheckUpdate {
    $base = Get-UpdateBase
    Write-Info "Update channel: $UpdateChannel -> $base"
    $remote = (Get-RemoteText "$base/VERSION")
    if ($null -eq $remote) {
        Write-Output "local=$ScriptVersion remote=unknown channel=$UpdateChannel status=unreachable"
        Write-Warn2 "Cannot read $base/VERSION (offline, blocked by a proxy, or missing)."
        exit $ExitUpdate
    }
    $remote = $remote.Trim().TrimStart('v')
    if ($remote -notmatch '^[0-9]+(\.[0-9]+)*$') {
        Write-Output "local=$ScriptVersion remote=unknown channel=$UpdateChannel status=unreachable"
        exit $ExitUpdate
    }
    if (Compare-VersionGreater $remote $ScriptVersion) {
        Write-Output "local=$ScriptVersion remote=$remote channel=$UpdateChannel status=newer"
        Write-Info "Newer version available: $remote (installed $ScriptVersion). Re-run with -Update."
        exit $ExitUpdate
    }
    Write-Output "local=$ScriptVersion remote=$remote channel=$UpdateChannel status=up-to-date"
    Write-Info "Already up to date ($ScriptVersion)."
    exit $ExitOk
}

function Invoke-SelfUpdate {
    $base = Get-UpdateBase
    Write-Info "Update source: $base"
    $remote = (Get-RemoteText "$base/VERSION")
    if ($null -eq $remote) { Stop-WithError "Cannot read $base/VERSION." $ExitUpdate }
    $remote = $remote.Trim().TrimStart('v')
    if (-not $UpdateForce -and -not (Compare-VersionGreater $remote $ScriptVersion)) {
        Write-Info "Already up to date ($ScriptVersion)."
        exit $ExitOk
    }
    Write-Info "Updating $ScriptVersion -> $remote"

    $body = Get-RemoteText "$base/ctf.ps1"
    if ($null -eq $body) { Stop-WithError "Download of $base/ctf.ps1 failed." $ExitUpdate }

    # Validation before anything is overwritten.
    if ($body.Length -lt 4096) {
        Stop-WithError "Downloaded only $($body.Length) characters - refusing (probably an error page)." $ExitUpdate
    }
    if ($body -notmatch '(?m)^<#') {
        Stop-WithError "Downloaded file does not start with a PowerShell comment block - refusing." $ExitUpdate
    }
    $tokens = $null; $parseErrors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseInput($body, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Stop-WithError "Downloaded file has $($parseErrors.Count) parse error(s) - refusing to install." $ExitUpdate
    }

    $target = $PSCommandPath
    if ([string]::IsNullOrEmpty($target)) { Stop-WithError "Cannot determine the script path." $ExitUpdate }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $backup = "$target.bak-$stamp"
    try {
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Info "Backup: $backup"
    } catch {
        Write-Warn2 "Could not create a backup at $backup."
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $body, $enc)
        Move-Item -LiteralPath $tmp -Destination $target -Force
        Write-Info "Installed ctf v$remote -> $target"
    } catch {
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $target -Force }
        Stop-WithError "Cannot write '$target'. The previous version was restored." $ExitUpdate
    }

    foreach ($sib in @('VERSION', 'ctf.bat')) {
        $sibPath = Join-Path (Split-Path -Parent $target) $sib
        if (Test-Path -LiteralPath $sibPath) {
            $txt = Get-RemoteText "$base/$sib"
            if ($null -ne $txt -and $txt.Length -gt 0) {
                [System.IO.File]::WriteAllText($sibPath, $txt, $enc)
                Write-Info "Updated $sib"
            } else {
                Write-Warn2 "Could not update $sib."
            }
        }
    }
    exit $ExitOk
}

if ($CheckUpdate) { Invoke-CheckUpdate }
if ($Update)      { Invoke-SelfUpdate }

if ($ListDefaultExcludes) {
    Write-Output "Default excluded directories ($($DefaultExcludeDirs.Count)):"
    $DefaultExcludeDirs | ForEach-Object { Write-Output "  $_" }
    Write-Output "Default excluded file globs ($($DefaultExcludeGlobs.Count)):"
    $DefaultExcludeGlobs | ForEach-Object { Write-Output "  $_" }
    exit $ExitOk
}

# --- argument normalisation --------------------------------------------------
# Позиционный аргумент, указывающий на существующий каталог, — это всегда
# SOURCE_DIR, а не расширение. Разрешаем неоднозначность ДО разбора расширений,
# иначе `ctf.ps1 ./src` собирал бы файлы с «расширением ./src».
if ($SourceDir -eq '' -and $Extension -ne '' -and (Test-Path -LiteralPath $Extension -PathType Container)) {
    $SourceDir = $Extension
    $Extension = ''
}
# То же для третьего позиционного: если OUTPUT пуст, а третий аргумент — каталог.
if ($OutputFile -ne '' -and (Test-Path -LiteralPath $OutputFile -PathType Container) -and $Output -eq '') {
    if ($SourceDir -eq '') { $SourceDir = $OutputFile }
    $OutputFile = ''
}

$extList = @()
foreach ($e in $Ext) { foreach ($part in ($e -split ',')) { $p = $part.Trim(); if ($p) { $extList += $p.TrimStart('.').ToLowerInvariant() } } }
if ($extList.Count -eq 0 -and $Extension -ne '' -and $Extension -ne '*' -and $Extension -ne '.*') {
    foreach ($part in ($Extension -split ',')) { $p = $part.Trim(); if ($p) { $extList += $p.TrimStart('.').ToLowerInvariant() } }
}
if ($SourceDir -eq '') { $SourceDir = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Stop-WithError "Source directory '$SourceDir' does not exist or is not a directory." $ExitUsage
}
$RootFull = (Resolve-Path -LiteralPath $SourceDir).Path

if ($Output -ne '') { $OutputFile = $Output }
if ($OutputFile -eq '') {
    if ($extList.Count -eq 1) { $OutputFile = "all-$($extList[0])-files.md" }
    elseif ($extList.Count -gt 1) { $OutputFile = "all-$($extList -join '-')-files.md" }
    else { $OutputFile = 'All-Project-Files.md' }
    switch ($Format) {
        'json'  { $OutputFile = [System.IO.Path]::ChangeExtension($OutputFile, '.json') }
        'jsonl' { $OutputFile = [System.IO.Path]::ChangeExtension($OutputFile, '.jsonl') }
        'txt'   { $OutputFile = [System.IO.Path]::ChangeExtension($OutputFile, '.txt') }
        'text'  { $OutputFile = [System.IO.Path]::ChangeExtension($OutputFile, '.txt') }
    }
}
$ToStdout = ($OutputFile -eq '-')
if ($Format -eq 'markdown') { $Format = 'md' }
if ($Format -eq 'text')     { $Format = 'txt' }

$MaxSizeBytes = ConvertTo-Bytes $MaxSize
$MinSizeBytes = ConvertTo-Bytes $MinSize

# --- discovery ---------------------------------------------------------------
$candidates = New-Object System.Collections.Generic.List[object]

if ($FilesFrom -ne '') {
    if (-not (Test-Path -LiteralPath $FilesFrom)) {
        Stop-WithError "-FilesFrom: cannot read '$FilesFrom'." $ExitUsage
    }
    foreach ($line in [System.IO.File]::ReadAllLines($FilesFrom)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ([System.IO.Path]::IsPathRooted($line)) { $candidates.Add($line.Trim()) }
        else { $candidates.Add((Join-Path $RootFull $line.Trim())) }
    }
}
elseif ($Git -ne '') {
    $gitExe = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $gitExe) { Stop-WithError "-Git requires git.exe in PATH." $ExitUsage }
    $gitArgs = @('-C', $RootFull, 'ls-files', '-z')
    if ($Git -eq 'tracked') { $gitArgs += '--cached' } else { $gitArgs += @('--cached', '--others', '--exclude-standard') }
    $raw = & git.exe @gitArgs
    if ($LASTEXITCODE -ne 0) { Stop-WithError "-Git: '$RootFull' is not inside a git work tree." $ExitUsage }
    foreach ($entry in (($raw -join "`n") -split "`0")) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $candidates.Add((Join-Path $RootFull ($entry.Trim())))
    }
}
else {
    # -Force обязателен: на Unix PowerShell помечает записи, начинающиеся с
    # точки, как Hidden, и без -Force .gitignore/.editorconfig/.github/* молча
    # пропадали из выборки (на Windows это же открывает и заблокированные
    # файлы, что для инструмента чтения безвредно). Каталоги .git и прочие
    # отсеиваются ниже, до подсчёта кандидатов.
    $gciParams = @{ LiteralPath = $RootFull; Recurse = $true; File = $true; Force = $true; ErrorAction = 'SilentlyContinue' }
    if ($Follow) { $gciParams['FollowSymlink'] = $true }
    $items = Get-ChildItem @gciParams
    $rootDepth = ($RootFull.TrimEnd([char[]]@('\','/')).Split([char[]]@('\','/'))).Count
    # Исключённые каталоги отсекаются ДО подсчёта кандидатов: ctf.sh делает то
    # же самое через `find -prune`, и счётчик Candidates обязан означать одно и
    # то же на обеих платформах (иначе заголовок документа различается).
    $preExDir = @()
    if (-not $NoDefaultExcludes) {
        foreach ($d in $DefaultExcludeDirs) { $preExDir += "*\$d\*"; $preExDir += "$d\*" }
    }
    foreach ($d in $ExcludeDir) { $preExDir += "*\$d\*"; $preExDir += "$d\*" }
    foreach ($it in $items) {
        if (-not $Follow) {
            try {
                if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            } catch { }
        }
        if ($MaxDepth -gt 0) {
            $d = ($it.FullName.TrimEnd([char[]]@('\','/')).Split([char[]]@('\','/'))).Count - $rootDepth
            if ($d -gt $MaxDepth) { continue }
        }
        if ($preExDir.Count -gt 0) {
            $preRel = (Get-RelativePath $RootFull $it.FullName).Replace('/', '\')
            $skip = $false
            foreach ($g in $preExDir) { if ($preRel -like $g) { $skip = $true; break } }
            if ($skip) { continue }
        }
        $candidates.Add($it.FullName)
    }
}

$totalCandidates = $candidates.Count
Write-Info "Found $totalCandidates candidate file(s) in '$RootFull'."

# --- filtering ---------------------------------------------------------------
$skipCount = @{}
function Add-Skip { param([string] $Reason) if ($skipCount.ContainsKey($Reason)) { $skipCount[$Reason]++ } else { $skipCount[$Reason] = 1 } }

$exDirGlobs = @()
if (-not $NoDefaultExcludes) {
    foreach ($d in $DefaultExcludeDirs) { $exDirGlobs += "*\$d\*"; $exDirGlobs += "$d\*" }
}
foreach ($d in $ExcludeDir) { $exDirGlobs += "*\$d\*"; $exDirGlobs += "$d\*" }

$kept = New-Object System.Collections.Generic.List[object]
foreach ($path in $candidates) {
    $rel = Get-RelativePath $RootFull $path
    $relNorm = $rel.Replace('/', '\')
    $name = [System.IO.Path]::GetFileName($path)

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Skip 'missing'; continue }

    if ($extList.Count -gt 0) {
        $ext = [System.IO.Path]::GetExtension($name).TrimStart('.').ToLowerInvariant()
        $ok = $false
        foreach ($e in $extList) { if ($ext -eq $e -or $name.ToLowerInvariant() -eq $e) { $ok = $true; break } }
        if (-not $ok) { Add-Skip 'extension'; continue }
    }

    $dropped = $false
    foreach ($g in $exDirGlobs) { if (Test-GlobMatch $g $relNorm) { Add-Skip 'excluded-dir'; $dropped = $true; break } }
    if ($dropped) { continue }
    if (-not $NoDefaultExcludes) {
        foreach ($g in $DefaultExcludeGlobs) {
            if ((Test-GlobMatch $g $relNorm) -or (Test-GlobMatch $g $name)) { Add-Skip 'default-exclude'; $dropped = $true; break }
        }
        if ($dropped) { continue }
    }
    foreach ($g in $Exclude) {
        if ((Test-GlobMatch $g $relNorm) -or (Test-GlobMatch $g $name)) { Add-Skip "exclude($g)"; $dropped = $true; break }
    }
    if ($dropped) { continue }
    if ($Include.Count -gt 0) {
        $ok = $false
        foreach ($g in $Include) { if ((Test-GlobMatch $g $relNorm) -or (Test-GlobMatch $g $name)) { $ok = $true; break } }
        if (-not $ok) { Add-Skip 'not-included'; continue }
    }

    $len = -1
    # -Force обязателен: на Unix Get-Item без него не видит записи, начинающиеся
    # с точки, хотя Test-Path для того же пути возвращает True.
    try { $len = (Get-Item -LiteralPath $path -Force).Length } catch { Add-Skip 'unreadable'; Write-Warn2 "Skip (unreadable): $rel"; continue }
    if ($null -ne $MaxSizeBytes -and $len -gt $MaxSizeBytes) { Add-Skip 'too-large'; continue }
    if ($null -ne $MinSizeBytes -and $len -lt $MinSizeBytes) { Add-Skip 'too-small'; continue }

    $kept.Add([pscustomobject] @{ Path = $path; Rel = $rel; Bytes = $len })
}

# --- sorting -----------------------------------------------------------------
# Sort-Object по умолчанию сравнивает строки с учётом культуры и без учёта
# регистра, из-за чего `b/Makefile` оказывался ПОСЛЕ `b/crlf.txt`. ctf.sh
# сортирует байтово (LC_ALL=C), поэтому здесь явный ordinal-компаратор:
# документ, собранный на Windows и на Linux, обязан совпадать побайтово.
$ordinal = [System.StringComparer]::Ordinal
# Тот же ключ сортировки, что и sort_key() в ctf.sh: управляющие символы в имени
# файла заменяются пробелом. Без этого файлы с TAB (0x09) и LF (0x0A) в имени
# шли в разном порядке на разных платформах.
$sortKey = [Func[object, string]] {
    param($x)
    $x.Rel.Replace("`t", ' ').Replace("`n", ' ').Replace("`r", ' ')
}
$sortKeyName = [Func[object, string]] {
    param($x)
    [System.IO.Path]::GetFileName($x.Rel).Replace("`t", ' ').Replace("`n", ' ').Replace("`r", ' ')
}
switch ($Sort) {
    'path'  {
        $kept = @([System.Linq.Enumerable]::OrderBy([object[]] $kept, $sortKey, $ordinal))
    }
    'name'  {
        $kept = @([System.Linq.Enumerable]::OrderBy([object[]] $kept, $sortKeyName, $ordinal))
    }
    'size'  {
        # Sort-Object сравнивает строки с учётом культуры, поэтому для второго
        # ключа (путь при равном размере) используется LINQ ThenBy с ordinal-
        # компаратором: порядок обязан совпадать с ctf.sh (LC_ALL=C).
        $ord1 = [System.Linq.Enumerable]::OrderByDescending([object[]] $kept,
            [Func[object, long]] { param($x) $x.Bytes })
        $kept = @([System.Linq.Enumerable]::ThenBy($ord1, $sortKey, $ordinal))
    }
    'mtime' {
        $ord2 = [System.Linq.Enumerable]::OrderByDescending([object[]] $kept,
            [Func[object, datetime]] { param($x) (Get-Item -LiteralPath $x.Path -Force).LastWriteTimeUtc })
        $kept = @([System.Linq.Enumerable]::ThenBy($ord2, $sortKey, $ordinal))
    }
}
Write-Info "After filtering: $($kept.Count) file(s) selected."

# --- rendering ---------------------------------------------------------------
$head = New-Object System.Text.StringBuilder
$body = New-Object System.Text.StringBuilder
$rendered = New-Object System.Collections.Generic.List[string]
$collected = 0; $bytesIn = [long] 0; $tokensEst = [long] 0
$truncatedFiles = 0; $budgetDropped = 0; $duplicates = 0
$seenHash = @{}
$budgetLeft = $TokenBudget
$headMarks = ('#' * $HeadingLevel)
$enc = New-Object System.Text.UTF8Encoding($false)
$outFull = $null
if (-not $ToStdout -and -not $DryRun -and -not $Stats) {
    try { $outFull = [System.IO.Path]::GetFullPath($OutputFile) } catch { $outFull = $null }
}

foreach ($item in $kept) {
    $path = $item.Path; $rel = $item.Rel; $bytes = $item.Bytes

    if ($outFull -and ($path -eq $outFull)) { Add-Skip 'output-file'; continue }
    if (Test-BinaryFile -Path $path -Length $bytes) { Add-Skip 'binary'; Write-Trace "skip (binary): $rel"; continue }

    $hash = ''
    if ($Dedup -or $Metadata) {
        try { $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $hash = '' }
    }
    if ($Dedup -and $hash -ne '') {
        if ($seenHash.ContainsKey($hash)) { $duplicates++; Add-Skip 'duplicate'; continue }
        $seenHash[$hash] = $rel
    }

    $st = Get-FenceStats -Path $path
    $mb = [int] $st[0]; $mt = [int] $st[1]; $lines = [int] $st[2]; $endsNl = [bool] $st[3]
    $fence = Get-Fence -MaxBackticks $mb -MaxTildes $mt
    $lang = Get-LanguageTag -Path $path
    $est = [long] [Math]::Ceiling($bytes / 4.0)

    $keepLines = 0
    $budgetTruncated = $false
    if ($TokenBudget -gt 0) {
        if ($est -gt $budgetLeft) {
            if ($BudgetAction -eq 'drop' -or $budgetLeft -le 0) {
                $budgetDropped++; Add-Skip 'token-budget'; continue
            }
            $allowedBytes = $budgetLeft * 4
            $avg = 40; if ($lines -gt 0 -and $bytes -gt 0) { $avg = [int] [Math]::Max(1, [Math]::Floor($bytes / $lines)) }
            $keepLines = [int] [Math]::Max(1, [Math]::Floor($allowedBytes / $avg))
            if ($keepLines -lt $lines) { $budgetTruncated = $true }
            $est = $budgetLeft
        }
        $budgetLeft = $budgetLeft - $est
        if ($budgetLeft -lt 0) { $budgetLeft = 0 }
    }
    if ($TruncateLines -gt 0) {
        if ($keepLines -eq 0 -or $TruncateLines -lt $keepLines) { $keepLines = $TruncateLines }
    }

    $collected++
    $bytesIn += $bytes
    $tokensEst += $est
    if ($budgetTruncated) { $truncatedFiles++ }
    $rendered.Add($rel)

    if ($DryRun) {
        $short = ''
        if ($hash.Length -ge 12) { $short = $hash.Substring(0, 12) }
        Write-Output "$(Get-Sanitized $rel)`t$lang`t$bytes`t$lines`t$short"
        continue
    }
    if ($Stats) { continue }

    # Содержимое файла копируется дословно: split/join с единым разделителем
    # нормализовал бы CRLF в LF и документ перестал бы совпадать с исходником
    # (и с выдачей ctf.sh). Быстрый путь — когда ни обрезки, ни нумерации нет.
    $text = Read-TextContent -Path $path
    $eol = "`n"
    if ($text.Contains("`r`n")) { $eol = "`r`n" }
    $verbatim = ($keepLines -le 0 -and -not $LineNumbers)
    $textLines = @()
    if (-not $verbatim) {
        $textLines = $text -split "`r`n|`n|`r", 0
        # ВАЖНО: в PowerShell 0..-1 даёт @(0,-1), то есть ДВА индекса, поэтому
        # срез «все кроме последнего» обязан быть защищён проверкой длины.
        if ($textLines.Count -ge 2 -and $textLines[$textLines.Count - 1] -eq '' -and $endsNl) {
            $textLines = $textLines[0..($textLines.Count - 2)]
        } elseif ($textLines.Count -eq 1 -and $textLines[0] -eq '' -and $endsNl) {
            $textLines = @()
        }
        if ($keepLines -gt 0 -and $textLines.Count -gt $keepLines) {
            $textLines = $textLines[0..($keepLines - 1)]
        }
    }

    $shown = if ($PathStyle -eq 'abs') { $path } else { $rel }
    $shown = Get-Sanitized $shown

    switch ($Format) {
        'md' {
            if ($shown.Contains([string][char]96)) { [void] $body.AppendLine("$headMarks $shown").AppendLine('') }
            else { [void] $body.AppendLine("$headMarks ``$shown``").AppendLine('') }
            if ($Metadata) {
                $m = "<!-- $bytes bytes · $lines lines · $(Get-HumanSize $bytes)"
                if ($hash -ne '') { $m += " · sha256:$($hash.Substring(0, [Math]::Min(12, $hash.Length)))" }
                [void] $body.AppendLine("$m -->").AppendLine('')
            }
            switch ($LangStyle) {
                'fenced' {
                    [void] $body.Append("$fence$lang`n")
                    Append-Content $body $text $textLines $verbatim $eol $endsNl ''
                    [void] $body.Append("$fence`n`n")
                }
                'indent4' {
                    Append-Content $body $text $textLines $verbatim $eol $endsNl '    '
                    [void] $body.Append("`n")
                }
                default {
                    Append-Content $body $text $textLines $verbatim $eol $endsNl ''
                    [void] $body.Append("`n")
                }
            }
            if ($budgetTruncated) {
                [void] $body.Append('<!-- truncated to fit the token budget -->' + "`n`n")
            }
            [void] $body.Append('---' + "`n`n")
        }
        'txt' {
            [void] $body.Append("===== $shown ($lang, $(Get-HumanSize $bytes)) =====`n")
            Append-Content $body $text $textLines $verbatim $eol $endsNl ''
            [void] $body.Append("`n")
        }
        'json' {
            if ($collected -gt 1) { [void] $body.Append(',') }
            [void] $body.Append('{"path":"' + (ConvertTo-JsonString $rel) + '","lang":"' + (ConvertTo-JsonString $lang) + '","bytes":' + $bytes + ',"lines":' + $lines)
            if ($hash -ne '') { [void] $body.Append(',"sha256":"' + $hash + '"') }
            [void] $body.Append(',"content":"' + (ConvertTo-JsonString ($textLines -join "`n")) + '"}')
        }
        'jsonl' {
            [void] $body.Append('{"path":"' + (ConvertTo-JsonString $rel) + '","lang":"' + (ConvertTo-JsonString $lang) + '","bytes":' + $bytes + ',"lines":' + $lines)
            if ($hash -ne '') { [void] $body.Append(',"sha256":"' + $hash + '"') }
            [void] $body.AppendLine(',"content":"' + (ConvertTo-JsonString ($textLines -join "`n")) + '"}')
        }
    }
}

# Все пропуски уже учтены в $skipCount (Add-Skip), $skippedExtra дублировать не нужно.
$skipped = 0
foreach ($k in $skipCount.Keys) { $skipped += $skipCount[$k] }

# header and TOC are built after the body, so the counters and the TOC reflect
# only the files that really made it into the document
if (-not $NoHeader) {
    $ts = ''
    if (-not $NoTimestamp) { $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $extText = if ($extList.Count -gt 0) { $extList -join ',' } else { '*' }
    switch ($Format) {
        'md' {
            $h = if ($HeadingLevel -gt 2) { '#' * ($HeadingLevel - 2) } else { '#' }
            [void] $head.AppendLine("$h $Title").AppendLine('')
            [void] $head.AppendLine('| Field | Value |').AppendLine('|:------|:------|')
            if ($ts -ne '') { [void] $head.AppendLine("| Generated (UTC) | $ts |") }
            [void] $head.AppendLine("| Tool | $ScriptName v$ScriptVersion |")
            [void] $head.AppendLine("| Source | $RootFull |")
            [void] $head.AppendLine("| Extensions | $extText |")
            [void] $head.AppendLine("| Candidates | $totalCandidates |")
            [void] $head.AppendLine("| Collected | $collected |").AppendLine('')
            [void] $head.AppendLine('---').AppendLine('')
        }
        'txt' {
            [void] $head.AppendLine($Title)
            if ($ts -ne '') { [void] $head.AppendLine("generated: $ts") }
            [void] $head.AppendLine("tool:      $ScriptName v$ScriptVersion")
            [void] $head.AppendLine("source:    $RootFull")
            [void] $head.AppendLine("collected: $collected of $totalCandidates candidate(s)").AppendLine('')
            [void] $head.AppendLine(('=' * 80)).AppendLine('')
        }
    }
}
if ($Toc -and $Format -eq 'md') {
    [void] $head.AppendLine('## Table of contents').AppendLine('')
    foreach ($r in $rendered) {
        $s = Get-Sanitized $r
        [void] $head.AppendLine("- [``$s``](#$(Get-MdAnchor $s))")
    }
    [void] $head.AppendLine('').AppendLine('---').AppendLine('')
}

if ($Format -eq 'json') {
    $ts = ''
    if (-not $NoTimestamp) { $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $prefix = '{"tool":"' + (ConvertTo-JsonString $ScriptName) + '","version":"' + $ScriptVersion + '","source":"' + (ConvertTo-JsonString $RootFull) + '","generated":"' + $ts + '","files":['
    [void] $body.Insert(0, $prefix)
    [void] $body.Append("]}`n")
}

if (-not $NoSummary) {
    switch ($Format) {
        'md' {
            [void] $body.AppendLine('## Summary').AppendLine('')
            [void] $body.AppendLine('| Metric | Value |').AppendLine('|:-------|------:|')
            [void] $body.AppendLine("| Candidates | $totalCandidates |")
            [void] $body.AppendLine("| Collected | $collected |")
            [void] $body.AppendLine("| Skipped | $skipped |")
            [void] $body.AppendLine("| Source bytes | $bytesIn ($(Get-HumanSize $bytesIn)) |")
            [void] $body.AppendLine("| Estimated tokens | $tokensEst |")
            if ($truncatedFiles -gt 0) { [void] $body.AppendLine("| Truncated files | $truncatedFiles |") }
            if ($budgetDropped -gt 0)  { [void] $body.AppendLine("| Dropped by token budget | $budgetDropped |") }
            if ($duplicates -gt 0)     { [void] $body.AppendLine("| Duplicates omitted | $duplicates |") }
            if ($skipCount.Count -gt 0) {
                [void] $body.AppendLine('').AppendLine('**Skip reasons**').AppendLine('')
                [void] $body.AppendLine('| Reason | Count |').AppendLine('|:-------|------:|')
                foreach ($k in ($skipCount.Keys | Sort-Object)) { [void] $body.AppendLine("| $k | $($skipCount[$k]) |") }
            }
            [void] $body.AppendLine('')
        }
        'txt' {
            [void] $body.AppendLine(('=' * 80))
            [void] $body.AppendLine("candidates=$totalCandidates collected=$collected skipped=$skipped source_bytes=$bytesIn est_tokens=$tokensEst")
        }
    }
}

if ($Stats) {
    Write-Output "candidates=$totalCandidates"
    Write-Output "collected=$collected"
    Write-Output "skipped=$skipped"
    Write-Output "source_bytes=$bytesIn"
    Write-Output "est_tokens=$tokensEst"
    Write-Output "truncated_files=$truncatedFiles"
    Write-Output "budget_dropped=$budgetDropped"
    Write-Output "duplicates=$duplicates"
    foreach ($k in ($skipCount.Keys | Sort-Object)) {
        Write-Output ("skip_" + ($k -replace '[^A-Za-z0-9_]', '_') + "=" + $skipCount[$k])
    }
    exit $ExitOk
}

$document = $head.ToString() + $body.ToString()

if ($DryRun) {
    Write-Info "Dry run: $collected file(s) would be collected, $skipped skipped."
    exit $ExitOk
}

$bytesOut = $enc.GetByteCount($document)
if ($ToStdout) {
    $stdout = New-Object System.IO.StreamWriter([System.Console]::OpenStandardOutput(), $enc)
    $stdout.Write($document)
    $stdout.Flush()
} else {
    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputFile))
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        Stop-WithError "Output directory '$dir' does not exist." $ExitUsage
    }
    if (Test-Path -LiteralPath $OutputFile) { Write-Warn2 "Output file '$OutputFile' exists - overwriting." }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $document, $enc)
        Move-Item -LiteralPath $tmp -Destination $OutputFile -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        Stop-WithError "Cannot write output file '$OutputFile': $($_.Exception.Message)" $ExitRuntime
    }
}

Write-Info "Done: $collected file(s) written, $skipped skipped."
$dest = if ($ToStdout) { '<stdout>' } else { [System.IO.Path]::GetFullPath($OutputFile) }
Write-Info "Output -> $dest ($(Get-HumanSize $bytesOut)), ~$tokensEst est. tokens"

if ($Strict -and $collected -eq 0) {
    Write-Warn2 'Nothing was collected (-Strict).'
    exit $ExitEmpty
}
exit $ExitOk
