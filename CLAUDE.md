# ClaudeTerm — Claude Code Guidance

## Project Overview

ClaudeTerm is a PowerShell plugin for Windows Terminal that provides visual
feedback while Claude Code is running. It is a Windows port of TabChroma
(bash/iTerm2) and uses the same hook architecture and theme format.

## Architecture

```
ClaudeTerm.psm1      Core module: all logic, CLI commands, hook processing
hook.ps1             Thin entry point called by Claude Code on every hook event
claude-term.ps1      CLI wrapper — delegates to Invoke-ClaudeTerm in the module
install.ps1          Installer
uninstall.ps1        Uninstaller
themes/*/theme.json  Theme definitions (RGB values per state)
VERSION              Plain-text version number
```

## Key Design Decisions

### Tab color mechanism
Windows Terminal supports OSC 9;16;R;G;B to set tab color from inside a
running session. This is written to [Console]::Out (not stderr). The reset
sequence uses R=G=B=-1.

### No badge support
Windows Terminal has no badge equivalent. The badge feature from TabChroma
is intentionally omitted.

### PowerShell-native, no Python dependency
TabChroma used Python 3 for JSON parsing and state management. ClaudeTerm
does everything in PowerShell using ConvertFrom-Json / ConvertTo-Json.

### Hook entry point
Claude Code invokes `hook.ps1` via:
    powershell.exe -NonInteractive -File "<path>\hook.ps1"
stdin carries the JSON event payload. hook.ps1 imports ClaudeTerm.psm1 and
calls Invoke-HookEvent.

### State file
`.state.json` in the install dir tracks last_state, last_state_time,
rotation_index, and per-session theme pins. It is written atomically
(write to .tmp then rename).

## Testing

Test a state manually:
    .\claude-term.ps1 test working
    .\claude-term.ps1 test permission

Preview all states for a theme:
    .\claude-term.ps1 theme preview dracula

Check what hooks are registered:
    .\claude-term.ps1 status

## Theme Format

themes/<name>/theme.json:
```json
{
  "schema_version": "1.0",
  "name": "mytheme",
  "display_name": "My Theme",
  "description": "...",
  "states": {
    "session.start": { "action": "reset", "label": "..." },
    "working":    { "r": 0,   "g": 120, "b": 212, "label": "Working"    },
    "done":       { "r": 16,  "g": 160, "b": 80,  "label": "Done"       },
    "attention":  { "r": 255, "g": 140, "b": 0,   "label": "Attention"  },
    "permission": { "r": 196, "g": 43,  "b": 28,  "label": "Permission" }
  }
}
```
