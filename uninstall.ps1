#Requires -Version 5.1
<#
.SYNOPSIS
    ClaudeTerm uninstaller.
#>

$ErrorActionPreference = 'Continue'

$moduleFile = Join-Path $PSScriptRoot 'ClaudeTerm.psm1'
if (-not (Test-Path $moduleFile)) {
    Write-Error "ClaudeTerm module not found at: $moduleFile"
    exit 1
}

Import-Module $moduleFile -Force -DisableNameChecking
Invoke-ClaudeTerm -Args @('uninstall')
