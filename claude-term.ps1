#Requires -Version 5.1
<#
.SYNOPSIS
    claude-term - Windows Terminal visual feedback for Claude Code.

.DESCRIPTION
    Command-line interface for ClaudeTerm.
    Add this script's directory to your PATH, or call it directly.

.EXAMPLE
    claude-term status
    claude-term theme list
    claude-term test working
    claude-term install
#>

param([Parameter(ValueFromRemainingArguments)][string[]]$Args)

$ErrorActionPreference = 'Continue'

$moduleFile = Join-Path $PSScriptRoot 'ClaudeTerm.psm1'
if (-not (Test-Path $moduleFile)) {
    Write-Error "ClaudeTerm module not found at: $moduleFile"
    exit 1
}

Import-Module $moduleFile -Force -DisableNameChecking

Invoke-ClaudeTerm -Args $Args
