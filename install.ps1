#Requires -Version 5.1
<#
.SYNOPSIS
    claude-term installer: copies the tool into ~/.claude/hooks/claude-term,
    registers the Claude Code hooks, and adds a `claude-term` command.

.DESCRIPTION
    Requires Python 3.8+ on PATH (the hook runs `python -S -E claude_term.py hook`).

    Run from a clone of the repo:
        .\install.ps1
    Register for an extra Claude Code profile too (for example a stock
    profile started with CLAUDE_CONFIG_DIR):
        .\install.ps1 -Settings "$env:USERPROFILE\.claude-direct\settings.json"
#>

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\claude-term'),
    [string[]]$Settings = @((Join-Path $env:USERPROFILE '.claude\settings.json'))
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Error "python was not found on PATH. Install Python 3 and re-run."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($item in @('claude_term.py', 'themes', 'VERSION', 'README.md')) {
    Copy-Item (Join-Path $source $item) (Join-Path $InstallDir $item) -Recurse -Force
}

# Optional slash commands (/tab-status, /theme)
$commandsDst = Join-Path $env:USERPROFILE '.claude\commands'
New-Item -ItemType Directory -Path $commandsDst -Force | Out-Null
Copy-Item (Join-Path $source 'commands\*') $commandsDst -Force

# Register hooks in every requested settings file
$script = Join-Path $InstallDir 'claude_term.py'
foreach ($settingsFile in $Settings) {
    & python -S -E $script install $settingsFile
}

# `claude-term` command: a .cmd shim on PATH via ~/.local/bin, plus a bash shim for Git Bash
$binDir = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
$cmdShim = "@echo off`r`npython -S -E `"%USERPROFILE%\.claude\hooks\claude-term\claude_term.py`" %*`r`n"
[IO.File]::WriteAllText((Join-Path $binDir 'claude-term.cmd'), $cmdShim)
$bashShim = "#!/usr/bin/env bash`nexec python -S -E `"`$HOME/.claude/hooks/claude-term/claude_term.py`" `"`$@`"`n"
[IO.File]::WriteAllText((Join-Path $binDir 'claude-term'), $bashShim)

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
    Write-Host "Added $binDir to your user PATH (open a new terminal to pick it up)."
}

Write-Host ""
Write-Host "Installed claude-term $((Get-Content (Join-Path $InstallDir 'VERSION')).Trim()) to $InstallDir"
Write-Host "Hooks apply to new Claude Code sessions. Try:  claude-term test working"
