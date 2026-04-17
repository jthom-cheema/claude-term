# ClaudeTerm

Windows Terminal visual feedback plugin for [Claude Code](https://claude.ai/code).  
Ported from [TabChroma](https://github.com/JCPetrelli/TabChroma) by JCPetrelli.

Changes your Windows Terminal **tab color**, **content background tint**, and **title** based on what Claude is doing — so you can glance at any tab and know its state at a moment's notice.

| State | Tab frame | Content bg | Meaning |
|---|---|---|---|
| `working` | 🔵 Blue | Dark blue tint | Claude is processing |
| `done` | 🟢 Green | *(reset)* | Ready for your input |
| `permission` | 🔴 Red | *(reset)* | Awaiting tool approval |
| `session.start` | *(reset)* | *(reset)* | New session began |

`attention` (orange) is also defined in themes but is not currently wired to any Claude hook event — available for custom use.

---

## Requirements

- **Windows 10/11** with [Windows Terminal](https://aka.ms/terminal) **1.15+** (1.22+ required for clean color reset)
- **PowerShell 5.1+** (built into Windows) or PowerShell 7+
- **[Claude Code](https://claude.ai/code)** CLI installed

> **Note:** Tab color changes require Windows Terminal — they will not work in
> the legacy Windows Console Host (`conhost.exe`) or VS Code's integrated
> terminal. If a profile has `tabColor` set in `settings.json`, it overrides
> runtime color changes.

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

### Escape Sequences

ClaudeTerm emits three xterm/Windows-Terminal OSC sequences:

| Purpose | Sequence | WT support |
|---|---|---|
| Tab frame color | `ESC ] 4 ; 264 ; rgb:RR/GG/BB BEL` | 1.15+ (PR #13058) |
| Tab frame reset | `ESC ] 104 ; 264 ESC \` | 1.22+ (PR #18767) |
| Content background | `ESC ] 11 ; rgb:RR/GG/BB BEL` | xterm standard |
| Background reset | `ESC ] 111 BEL` | xterm standard |
| Tab title | `ESC ] 0 ; <title> BEL` | xterm standard |

Note: `OSC 9;16;R;G;B` is iTerm2's proprietary sequence and is **not**
supported by Windows Terminal (even though it's widely quoted). Use OSC 4
with color-table index 264 (FRAME_BACKGROUND).

### Delivering Sequences Through Claude Code's Subprocess

Claude Code spawns hooks as `powershell.exe -NonInteractive -File hook.ps1`
with stdout/stderr redirected for capture. Two consequences:

1. Writing to `[Console]::Out` lands in Claude's capture buffer, never the
   terminal. Fix: `CreateFile("CONOUT$")` via kernel32 P/Invoke to write
   directly to the console device.
2. The subprocess is spawned with a new console (isolated from WT's
   ConPTY), so `CONOUT$` opens a hidden buffer by default. Fix:
   `FreeConsole()` then `AttachConsole()` walking up the parent process
   tree until we hit an ancestor whose parent is `WindowsTerminal.exe` or
   `OpenConsole.exe` — that's the process directly owning the ConPTY
   that forwards to WT.

Parent-process lookup uses native `NtQueryInformationProcess`
(~1ms/level) rather than WMI (~300ms/level) to keep hooks responsive.

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
    "working":    { "r": 0,   "g": 100, "b": 200, "bg": { "r": 10, "g": 30, "b": 80 }, "label": "Working"    },
    "done":       { "r": 34,  "g": 180, "b": 80,  "label": "Done"       },
    "attention":  { "r": 255, "g": 160, "b": 40,  "label": "Attention"  },
    "permission": { "r": 220, "g": 60,  "b": 40,  "label": "Permission" }
  }
}
```

**Fields per state:**
- `r`, `g`, `b` — tab frame color (0–255 each)
- `bg` — optional object `{ r, g, b }` to tint the terminal content background while the state is active. States without `bg` reset the background to the profile default.
- `action: "reset"` — use instead of RGB for `session.start` to reset both tab and background.
- `label` — displayed in status/preview output.

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
| Terminal | iTerm2 | Windows Terminal 1.15+ |
| Shell | bash / zsh | PowerShell 5.1+ |
| Tab color | iTerm2 OSC `6;1;bg` | WT OSC `4;264;rgb:RR/GG/BB` |
| Content bg tint | N/A | OSC `11;rgb:RR/GG/BB` |
| Badge | ✅ (iTerm2 proprietary) | ❌ Not supported by WT |
| Tab title | ✅ | ✅ |
| Install | `bash install.sh` | `.\install.ps1` |
| Hook runner | Python 3 subprocess | PowerShell module |

---

## License

MIT — see [LICENSE](LICENSE)
