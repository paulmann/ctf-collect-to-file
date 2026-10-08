@echo off
rem ###########################################################################
rem # ctf.bat - Collect To File: launcher for ctf.ps1 (Windows 10/11)
rem #
rem #   ctf.bat [OPTIONS] [EXTENSION] [SOURCE_DIR] [OUTPUT_FILE]
rem #
rem # This file is intentionally thin. All logic lives in ctf.ps1 so that there
rem # is exactly one Windows implementation to test, lint and update. The
rem # previous BAT+PowerShell polyglot extracted its own payload with
rem # `more +N`, which corrupts long lines and non-ASCII text; that is gone.
rem #
rem # The option names are the same as in ctf.sh: PowerShell matches `--name`
rem # case-insensitively, and hyphenated aliases are declared in ctf.ps1.
rem #   ctf.bat php .\src result.md
rem #   ctf.bat --ext php,js --output bundle.md .\src
rem #   ctf.bat --stats .\src
rem #   ctf.bat --check-update
rem #
rem # Exit codes are forwarded from ctf.ps1:
rem #   0 success | 1 runtime | 2 usage | 3 update/network | 4 nothing collected
rem #   90 launcher error (ctf.ps1 or PowerShell not found)
rem #
rem # Version: 4.0.0   Author: Mikhail Deynekin <Mikhail@Deynekin.com>
rem # License: MIT
rem ###########################################################################

setlocal EnableExtensions EnableDelayedExpansion

set "CTF_SELF_DIR=%~dp0"
set "CTF_PS1=%CTF_SELF_DIR%ctf.ps1"
set "CTF_RC=90"

rem --- locate ctf.ps1: next to this file, or anywhere in PATH ---------------
if not exist "%CTF_PS1%" (
    for %%F in ("%~dpn0.ps1") do if exist "%%~fF" set "CTF_PS1=%%~fF"
)
if not exist "%CTF_PS1%" (
    where ctf.ps1 >nul 2>&1
    if not errorlevel 1 for /f "delims=" %%P in ('where ctf.ps1') do set "CTF_PS1=%%P"
)
if not exist "%CTF_PS1%" (
    echo [ERROR] ctf.ps1 not found next to %~nx0 and not in PATH. >&2
    echo         Install both files into the same directory. >&2
    goto :done
)

rem --- prefer PowerShell 7 (pwsh), fall back to Windows PowerShell 5.1 ------
set "CTF_PWSH="
where pwsh >nul 2>&1 && for /f "delims=" %%P in ('where pwsh') do if not defined CTF_PWSH set "CTF_PWSH=%%P"
if not defined CTF_PWSH where powershell >nul 2>&1 && for /f "delims=" %%P in ('where powershell') do if not defined CTF_PWSH set "CTF_PWSH=%%P"
if not defined CTF_PWSH (
    echo [ERROR] Neither pwsh.exe nor powershell.exe was found in PATH. >&2
    goto :done
)

rem --- UTF-8 console output; restore the previous code page on exit ---------
set "CTF_OLD_CP="
for /f "tokens=2 delims=:" %%C in ('chcp 2^>nul') do set "CTF_OLD_CP=%%C"
set "CTF_OLD_CP=!CTF_OLD_CP: =!"
chcp 65001 >nul 2>&1

"%CTF_PWSH%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CTF_PS1%" %*
set "CTF_RC=%ERRORLEVEL%"

if defined CTF_OLD_CP chcp !CTF_OLD_CP! >nul 2>&1

:done
endlocal & exit /b %CTF_RC%
