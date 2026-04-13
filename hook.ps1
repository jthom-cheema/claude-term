#Requires -Version 5.1
<#
.SYNOPSIS
    ClaudeTerm hook entry point - called by Claude Code on hook events.

.DESCRIPTION
    Claude Code invokes this script for each registered hook event.
    The event JSON is passed via stdin.

    This script also doubles as a thin CLI wrapper: if a command argument
    is passed (e.g. "reset") it routes to the module's CLI handler instead
    of processing stdin as a hook event.

    Registered for: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
                    Stop, Notification, PermissionRequest

.EXAMPLE
    # Called automatically by Claude Code (stdin = JSON):
    echo '{"hook_event_name":"Stop","cwd":"C:\\myproject"}' | powershell -File hook.ps1

    # Direct CLI usage (via claude-term.ps1):
    powershell -File hook.ps1 reset
#>

param([string[]]$Args)

$ErrorActionPreference = 'SilentlyContinue'

# Load the module from the same directory as this script
$moduleFile = Join-Path $PSScriptRoot 'ClaudeTerm.psm1'
if (-not (Test-Path $moduleFile)) {
    exit 0
}

Import-Module $moduleFile -Force -DisableNameChecking

# If arguments were passed, this is a direct CLI call (e.g. "reset")
# Treat as: Invoke-ClaudeTerm $Args
if ($Args -and $Args.Count -gt 0) {
    Invoke-ClaudeTerm -Args $Args
    exit 0
}

# Hook mode: read JSON from stdin
$inputJson = ''
if (-not [Console]::IsInputRedirected) {
    exit 0
}

try {
    $inputJson = [Console]::In.ReadToEnd()
} catch {
    exit 0
}

if ($inputJson.Trim()) {
    Invoke-HookEvent -InputJson $inputJson
}

exit 0
