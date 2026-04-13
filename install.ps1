#Requires -Version 5.1
<#
.SYNOPSIS
    ClaudeTerm installer - registers hooks and sets up the shell wrapper.

.DESCRIPTION
    Works both as a local install (from cloned repo) and as a remote install:

        irm https://raw.githubusercontent.com/YOUR_ORG/ClaudeTerm/main/install.ps1 | iex

    What this script does:
      1. Copies ClaudeTerm files to $env:USERPROFILE\.claude\hooks\claude-term\
      2. Registers Claude Code hook events in settings.json
      3. Adds a 'claude' function wrapper to your PowerShell profile so the
         tab color resets when you exit Claude Code (Claude Code has no
         SessionEnd hook, so a shell wrapper is the only way to do this).
      4. Adds claude-term as a function alias in your profile.
#>

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\claude-term')
)

$ErrorActionPreference = 'Stop'

# ─── Detect local vs remote install ──────────────────────────────────────────

$scriptDir = $PSScriptRoot

# When piped via iex, $PSScriptRoot is empty
$isLocal = $scriptDir -and (Test-Path (Join-Path $scriptDir 'ClaudeTerm.psm1'))

if ($isLocal) {
    Write-Host "ClaudeTerm installer (local)"
    $sourceDir = $scriptDir
} else {
    Write-Host "ClaudeTerm installer (remote)"
    Write-Host ""

    $repo    = 'YOUR_ORG/ClaudeTerm'   # Update this when you publish the repo
    $tarball = "https://github.com/$repo/archive/refs/heads/main.zip"

    $tmpDir = Join-Path $env:TEMP "claude-term-install-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    Write-Host "Downloading from GitHub..."
    $zipPath = Join-Path $tmpDir 'claudeterm.zip'
    Invoke-WebRequest -Uri $tarball -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force

    # Find extracted subfolder (e.g. ClaudeTerm-main)
    $sourceDir = Get-ChildItem $tmpDir -Directory | Select-Object -First 1 -ExpandProperty FullName
}

$version = if (Test-Path (Join-Path $sourceDir 'VERSION')) {
    (Get-Content (Join-Path $sourceDir 'VERSION') -Raw).Trim()
} else { 'unknown' }

Write-Host ""
Write-Host "Installing ClaudeTerm v$version to: $InstallDir"
Write-Host ""

# ─── Copy files to install dir ───────────────────────────────────────────────

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

foreach ($item in @('ClaudeTerm.psm1', 'hook.ps1', 'claude-term.ps1', 'themes', 'VERSION')) {
    $src = Join-Path $sourceDir $item
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $InstallDir $item) -Recurse -Force
    }
}

# Copy slash commands if present
$commandsSrc = Join-Path $sourceDir 'commands'
if (Test-Path $commandsSrc) {
    $commandsDst = Join-Path $env:USERPROFILE '.claude\commands'
    if (-not (Test-Path $commandsDst)) {
        New-Item -ItemType Directory -Path $commandsDst -Force | Out-Null
    }
    Copy-Item (Join-Path $commandsSrc '*') $commandsDst -Force
    Write-Host "Installed Claude slash commands to: $commandsDst"
}

# ─── Delegate to the module's Install-ClaudeTerm ─────────────────────────────

$moduleFile = Join-Path $InstallDir 'ClaudeTerm.psm1'
Import-Module $moduleFile -Force -DisableNameChecking

# Override SCRIPT_DIR so Install-ClaudeTerm writes the correct hook path
# (The module sets $script:SCRIPT_DIR at import time from $PSScriptRoot,
#  which will be the install dir since we imported from there.)
Install-ClaudeTerm

Write-Host ""
Write-Host "Done! Reload your shell, then test with:"
Write-Host ""
Write-Host "    claude-term test working"
Write-Host ""
