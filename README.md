# ClaudeTerm

Windows Terminal visual feedback plugin for [Claude Code](https://claude.ai/code).  
Ported from [TabChroma](https://github.com/JCPetrelli/TabChroma) by JCPetrelli.

Changes your Windows Terminal **tab color** and **title** based on what Claude is doing — so you can glance at any tab and know its state at a moment's notice.

| State | Default Color | Meaning |
|---|---|---|
| `working` | 🔵 Blue | Claude is processing |
| `done` | 🟢 Green | Ready for your input |
| `attention` | 🟠 Orange | Needs your attention |
| `permission` | 🔴 Red | Awaiting tool approval |
| `session.start` | *(reset)* | New session began |

---

## Requirements

- **Windows 10/11** with [Windows Terminal](https://aka.ms/terminal) **1.18+**
- **PowerShell 5.1+** (built into Windows) or PowerShell 7+
- **[Claude Code](https://claude.ai/code)** CLI installed

> **Note:** Tab color changes require Windows Terminal — they will not work in
> the legacy Windows Console Host (`conhost.exe`) or VS Code's integrated
> terminal.

---

## Installation

### Option 1 — Clone and install locally (recommended)

```powershell
git clone https://github.com/YOUR_ORG/ClaudeTerm.git D:\source\repositories\ClaudeTerm
cd D:\source\repositories\ClaudeTerm
.\install.ps1
```

### Option 2 — Manual copy

Copy the repo to any folder, then from that folder run:

```powershell
.\install.ps1
```

This will:
1. Copy files to `%USERPROFILE%\.claude\hooks\claude-term\`
2. Register Claude Code hook events in `%USERPROFILE%\.claude\settings.json`
3. Add a `claude-term` alias and a `claude` wrapper function to your
   PowerShell profile (so the tab resets when you exit Claude Code)

Reload your shell, then test:

```powershell
claude-term test working
```

---

## Usage

```
claude-term <command> [args]

CONTROLS:
  pause                 Disable color changes
  resume                Re-enable color changes
  toggle                Toggle pause state
  status                Show current config and state

THEMES:
  theme list            List installed themes
  theme use <n>      Switch active theme
  theme next            Cycle to next theme
  theme preview [name]  Preview all states (2s each)

FEATURES:
  title on|off          Toggle tab title updates
  color on|off          Toggle tab color changes

TESTING:
  test <state>          Manually trigger a state
  reset                 Reset tab to default color

INFO:
  help                  Show this help
  version               Show version

SETUP:
  install               Register Claude Code hooks
  uninstall             Remove hooks and data files
```

---

## How It Works

ClaudeTerm registers itself as a Claude Code hook for these events:

| Hook | State |
|---|---|
| `SessionStart` | `session.start` — resets tab color |
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `working` |
| `PostToolUse` | `working` — recovers from permission state |
| `Stop` | `done` |
| `Notification` | `attention` or `permission` (based on message content) |
| `PermissionRequest` | `permission` |

### Tab Color Mechanism

Windows Terminal supports changing the tab color of a running session via
the OSC 9;16 escape sequence:

```
ESC ] 9 ; 16 ; <R> ; <G> ; <B> BEL
```

ClaudeTerm writes this sequence to `[Console]::Out` on every hook event.
This is distinct from the `--tabColor` command-line flag (which only works
at launch time) and from `settings.json` `tabColor` (which affects all tabs
of a profile).

### Debouncing

Identical state transitions within `debounce_seconds` (default: 2s) are
skipped. A typical Claude turn with many file reads fires `PreToolUse`
dozens of times; debouncing means only the first transition triggers a
visual update. `permission` and `attention` always fire immediately.

### Session End / Tab Reset

Claude Code has no `SessionEnd` hook. ClaudeTerm's installer adds a
`claude()` wrapper to your PowerShell profile that calls
`claude-term reset` automatically when the `claude` command exits.

---

## Themes

6 themes are bundled:

| Theme | Working | Done | Attention | Permission | Description |
|---|---|---|---|---|---|
| **default** | `#0078D4` | `#10A050` | `#FF8C00` | `#C42B1C` | Windows-native blue/green |
| **ocean** | `#0F629A` | `#20B2AA` | `#FFA550` | `#B41E2D` | Calm oceanic palette |
| **neon** | `#00FFFF` | `#39FF14` | `#FFD700` | `#FF1493` | Vibrant cyberpunk |
| **pastel** | `#6495ED` | `#90EE90` | `#FFDAB9` | `#FFB6C1` | Gentle, easy on the eyes |
| **solarized** | `#268BD2` | `#859900` | `#CB4B16` | `#DC322F` | Classic Solarized |
| **dracula** | `#6272A4` | `#50FA7B` | `#FFB86C` | `#FF5555` | Dracula editor colors |

```powershell
claude-term theme list
claude-term theme use dracula
claude-term theme preview ocean
```

### Theme Rotation

Automatically cycle themes across sessions. Edit
`%USERPROFILE%\.claude\hooks\claude-term\config.json`:

```json
{
  "theme_rotation": ["default", "ocean", "dracula"],
  "theme_rotation_mode": "round-robin"
}
```

`theme_rotation_mode` can be `"round-robin"`, `"random"`, or `"off"`.

---

## Custom Themes

Create `%USERPROFILE%\.claude\hooks\claude-term\themes\<n>\theme.json`:

```json
{
  "schema_version": "1.0",
  "name": "mytheme",
  "display_name": "My Theme",
  "description": "Custom color scheme",
  "states": {
    "session.start": { "action": "reset", "label": "Session started" },
    "working":    { "r": 0,   "g": 100, "b": 200, "label": "Working"    },
    "done":       { "r": 34,  "g": 180, "b": 80,  "label": "Done"       },
    "attention":  { "r": 255, "g": 160, "b": 40,  "label": "Attention"  },
    "permission": { "r": 220, "g": 60,  "b": 40,  "label": "Permission" }
  }
}
```

---

## Configuration

`%USERPROFILE%\.claude\hooks\claude-term\config.json`:

```json
{
  "active_theme": "default",
  "enabled": true,
  "features": {
    "tab_color": true,
    "title": true
  },
  "debounce_seconds": 2,
  "theme_rotation": [],
  "theme_rotation_mode": "off"
}
```

---

## Uninstalling

```powershell
claude-term uninstall
```

Or run `.\uninstall.ps1` from the repo directory.

---

## Differences from TabChroma

| Feature | TabChroma (macOS) | ClaudeTerm (Windows) |
|---|---|---|
| Terminal | iTerm2 | Windows Terminal 1.18+ |
| Shell | bash / zsh | PowerShell 5.1+ |
| Tab color | iTerm2 OSC `6;1;bg` | WT OSC `9;16;R;G;B` |
| Badge | ✅ (iTerm2 proprietary) | ❌ Not supported by WT |
| Tab title | ✅ | ✅ |
| Install | `bash install.sh` | `.\install.ps1` |
| Hook runner | Python 3 subprocess | PowerShell module |

---

## License

MIT — see [LICENSE](LICENSE)
