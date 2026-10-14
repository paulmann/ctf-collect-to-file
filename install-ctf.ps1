#Requires -Version 7.6
#Requires -PSEdition Core
<#
.SYNOPSIS
    Install ctf (Collect To File) on Windows and expose the short command `ctf`.

.DESCRIPTION
    Copies the engine into an installation directory, writes a launcher that
    cmd.exe and PowerShell both resolve for the bare name `ctf`, and appends the
    launcher directory to the user PATH.

    The layout is deliberately split into bin\ and lib\ rather than putting the
    engine next to the launcher. Two measured defects make a flat layout unsafe
    on Windows:

    1. PowerShell resolves a bare command name to a .ps1 file in preference to a
       .cmd or .bat, and it does NOT bind "--long-option" style arguments to
       script parameters. With the engine on PATH,
         ctf --version
       passed the literal string "--version" as the positional Extension and
       started a real collection run: it wrote all---version-files.md into the
       current directory instead of printing the version. Options that take a
       value, such as
         ctf --ext php --output out.md .\src
       failed outright with "A positional parameter cannot be found".

    2. cmd.exe would resolve the bare name to a .bat file, and the upstream
       ctf.bat enables delayed expansion, which deletes `!` characters from
       every argument. A path such as B:\!1\src was silently truncated to "B:",
       and the wrong directory was scanned with no error at all.

    Therefore only the launcher bin\ctf.cmd goes on PATH. It disables delayed
    expansion explicitly and forwards both the arguments and the exit code.

.PARAMETER InstallRoot
    Root of the installation. bin\ and lib\ are created inside it, and only
    bin\ is added to PATH. Default: %LOCALAPPDATA%\Programs\ctf, which needs no
    administrator rights. Use e.g. C:\tools\ctf for a machine-wide location.

.PARAMETER Uninstall
    Remove the installed files and drop the directory from the user PATH.

.EXAMPLE
    pwsh -NoLogo -NoProfile -NonInteractive -File .\install-ctf.ps1

.EXAMPLE
    pwsh -File .\install-ctf.ps1 -InstallRoot C:\tools\ctf

.EXAMPLE
    pwsh -File .\install-ctf.ps1 -Uninstall

.NOTES
    Author:  Mikhail Deynekin
    License: MIT
    The installer itself requires PowerShell 7.6 or newer. The engine it
    installs (ctf.ps1) also runs on Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ctf'),
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- launcher template -------------------------------------------------------
# Everything inside the single-quoted here-string is literal: neither PowerShell
# nor cmd.exe expands anything here. The text is pure ASCII, and the line
# endings are normalised to CRLF below, because LF breaks labels and `goto` in
# cmd.exe. The `!` character is avoided on purpose so that the launcher stays
# correct even if delayed expansion is inherited from the surrounding shell.
$shimTemplate = @'
@echo off
rem ##########################################################################
rem # ctf.cmd - "Collect To File": launcher for the ctf.ps1 engine (Windows).
rem #
rem # Layout:
rem #   bin\ctf.cmd    this launcher; bin\ is the directory added to PATH
rem #   lib\ctf.ps1    the engine
rem #   lib\ctf.bat    upstream launcher, kept for byte parity with the repo
rem #
rem # Why the engine is NOT on PATH, and why this launcher exists:
rem #   1. PowerShell resolves a bare command name to a .ps1 in preference to a
rem #      .cmd, and it does not bind "--long-option" arguments to script
rem #      parameters. With the engine on PATH, "ctf --version" was taken as a
rem #      positional argument and silently started a collection run, and
rem #      "ctf --ext php --output out.md src" failed with "A positional
rem #      parameter cannot be found".
rem #   2. cmd.exe would pick a .bat, and the upstream ctf.bat runs under
rem #      "setlocal EnableDelayedExpansion", which strips "!" characters from
rem #      every argument: a path such as B:\!1\src became "B:" and the wrong
rem #      directory was scanned without any error.
rem #
rem # Properties of this launcher:
rem #   * delayed expansion is explicitly disabled, so "!" survives verbatim;
rem #   * arguments and exit codes are forwarded unchanged
rem #     (0 ok / 1 runtime / 2 usage / 3 update / 4 nothing collected);
rem #   * only pwsh is started; Windows PowerShell 5.1 is never used, not even
rem #     as a fallback;
rem #   * the previous console code page is restored on exit.
rem #
rem # Usage:  ctf [OPTIONS] [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
rem #         ctf php .\src result.md
rem #         ctf --ext php,js --output bundle.md .\src
rem #         ctf --stats .\src
rem #         ctf --version
rem #         ctf --help
rem ##########################################################################

setlocal EnableExtensions DisableDelayedExpansion

set "CTF_BIN=%~dp0"
set "CTF_PS1=%CTF_BIN%..\lib\ctf.ps1"
set "CTF_RC=90"

if not exist "%CTF_PS1%" (
    echo [ERROR] ctf.ps1 not found at "%CTF_PS1%" - installation is incomplete. >&2
    goto :done
)

set "CTF_PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "CTF_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined CTF_PWSH if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "CTF_PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined CTF_PWSH for /f "delims=" %%P in ('where pwsh 2^>nul') do if not defined CTF_PWSH set "CTF_PWSH=%%P"
if not defined CTF_PWSH (
    echo [ERROR] pwsh.exe, PowerShell 7 or newer, was not found. >&2
    goto :done
)

set "CTF_OLD_CP="
for /f "tokens=2 delims=:" %%C in ('chcp 2^>nul') do set "CTF_OLD_CP=%%C"
set "CTF_OLD_CP=%CTF_OLD_CP: =%"
chcp 65001 >nul 2>&1

"%CTF_PWSH%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CTF_PS1%" %*
set "CTF_RC=%ERRORLEVEL%"

if defined CTF_OLD_CP chcp %CTF_OLD_CP% >nul 2>&1

:done
endlocal & exit /b %CTF_RC%
'@

$bin = Join-Path $InstallRoot 'bin'
$lib = Join-Path $InstallRoot 'lib'
$shimPath = Join-Path $bin 'ctf.cmd'

# --- uninstall ---------------------------------------------------------------
if ($Uninstall) {
    foreach ($f in @($shimPath, (Join-Path $lib 'ctf.ps1'), (Join-Path $lib 'ctf.bat'),
                     (Join-Path $lib 'VERSION'), (Join-Path $InstallRoot 'README.md'),
                     (Join-Path $InstallRoot 'LICENSE'))) {
        if (Test-Path -LiteralPath $f) { Write-Output "removing $f"; Remove-Item -LiteralPath $f -Force }
    }
    foreach ($d in @($bin, $lib)) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) {
            Remove-Item -LiteralPath $d -Force
        }
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $bin.TrimEnd('\') })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Write-Output "uninstalled; $bin removed from the user PATH"
    exit 0
}

# --- source ------------------------------------------------------------------
# The repository root is the directory holding this script, so a fresh clone can
# be installed in place.
$source = $PSScriptRoot
if (-not $source) { $source = (Get-Location).Path }
$engine = Join-Path $source 'ctf.ps1'
if (-not (Test-Path -LiteralPath $engine)) {
    throw "ctf.ps1 not found in $source. Run this script from the repository root."
}

New-Item -ItemType Directory -Path $bin, $lib -Force | Out-Null

# --- engine ------------------------------------------------------------------
# Copied byte for byte; the engine is never edited by the installer.
foreach ($name in 'ctf.ps1', 'ctf.bat', 'VERSION') {
    $p = Join-Path $source $name
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $lib $name) -Force }
}
foreach ($name in 'README.md', 'LICENSE') {
    $p = Join-Path $source $name
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $InstallRoot $name) -Force }
}

# --- launcher ----------------------------------------------------------------
$shim = ($shimTemplate -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllText($shimPath, $shim, [System.Text.Encoding]::ASCII)

# --- PATH --------------------------------------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @($userPath -split ';' | Where-Object { $_ -ne '' })
$stale = @($InstallRoot, $bin)
$parts = @($parts | Where-Object { $stale -notcontains $_.TrimEnd('\') })
$parts += $bin
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')

# Tell already-running processes about the change; otherwise a shell started
# from an existing Explorer may inherit the old PATH. Best effort only.
try {
    if (-not ('Win32.EnvBroadcast' -as [type])) {
        Add-Type -Namespace Win32 -Name EnvBroadcast -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
    }
    $result = [System.IntPtr]::Zero
    [void] [Win32.EnvBroadcast]::SendMessageTimeout([System.IntPtr] 0xffff, 0x1A, [System.IntPtr]::Zero, 'Environment', 2, 5000, [ref] $result)
} catch {
    Write-Verbose "environment-change broadcast skipped: $($_.Exception.Message)"
}

# --- report ------------------------------------------------------------------
Write-Output 'Installed:'
Get-ChildItem -LiteralPath $bin, $lib -File | ForEach-Object {
    $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.Substring(0, 12)
    $rel = $_.FullName.Substring($InstallRoot.Length).TrimStart('\')
    Write-Output ("  {0,-16} {1,7} B  sha256:{2}" -f $rel, $_.Length, $h)
}
$bytes = [System.IO.File]::ReadAllBytes($shimPath)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
Write-Output ''
Write-Output ("Launcher: BOM={0}  CRLF={1}  (expected False / True)" -f $hasBom, [bool] ($text -match "`r`n"))
Write-Output "PATH (User) now contains: $bin"
Write-Output ''
Write-Output 'Verify in a NEW shell:'
Write-Output '  pwsh -NoProfile -Command "ctf --version"'
Write-Output '  cmd  /c "ctf --version"'
