#Requires -Version 5.1
<#
.SYNOPSIS
    claude-term uninstaller: removes the hooks from settings.json files, the
    shims, and the installed directory. Pass -Settings for extra profiles.
#>

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\claude-term'),
    [string[]]$Settings = @((Join-Path $env:USERPROFILE '.claude\settings.json'))
)

$ErrorActionPreference = 'Continue'
$script = Join-Path $InstallDir 'claude_term.py'

if (Test-Path $script) {
    foreach ($settingsFile in $Settings) {
        if (Test-Path $settingsFile) { & python -S -E $script uninstall $settingsFile }
    }
}

$binDir = Join-Path $env:USERPROFILE '.local\bin'
Remove-Item (Join-Path $binDir 'claude-term.cmd'), (Join-Path $binDir 'claude-term') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:USERPROFILE '.claude\commands\tab-status.md'), (Join-Path $env:USERPROFILE '.claude\commands\theme.md') -Force -ErrorAction SilentlyContinue
Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "claude-term removed. Open sessions keep their current tab color until they end."
