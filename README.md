# claude-term

Windows Terminal tab color and title that follow what Claude Code is doing, so you can glance across ten tabs and see which one needs you.

Started as a Windows port of [TabChroma](https://github.com/JCPetrelli/TabChroma). Version 2 is a small Python script driven by Claude Code hook events.

| Tab color (default theme) | State | When |
| --- | --- | --- |
| profile default | `session.start` | a session starts, resumes, or is cleared |
| blue, tinted background | `working` | Claude is thinking or running tools, or a background subagent is still running |
| orange | `attention` | Claude asked you a question or is waiting for plan approval |
| red | `permission` | a tool call is waiting for your approval |
| violet | `delegated` | Claude's turn ended but a Codex companion job it launched is still running |
| green | `done` | the turn ended and nothing is running |
| profile default | | the session ended |

The tab title reads `◉ project: state`. Claude Code's own title updates are turned off during install so the two do not fight.

## Requirements

- Windows 10/11 with [Windows Terminal](https://aka.ms/terminal) 1.15 or newer (1.22 or newer for a clean color reset).
- Python 3.8 or newer on `PATH`.
- Claude Code.

Tab colors need Windows Terminal. They will not show in the legacy console host or the VS Code terminal. A profile with `tabColor` set in Windows Terminal's settings overrides everything here.

## Install

```powershell
git clone https://github.com/jthom-cheema/claude-term.git
cd claude-term
.\install.ps1
```

This copies the tool to `%USERPROFILE%\.claude\hooks\claude-term`, registers the hooks in `%USERPROFILE%\.claude\settings.json`, sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` in that file's `env` block, adds a `claude-term` command to `~\.local\bin` (cmd and Git Bash shims) and puts that folder on your user `PATH`.

Hooks apply to sessions started after the install. Already-open sessions keep running the old hook set until they end.

If you also run a second Claude Code profile through `CLAUDE_CONFIG_DIR`, register it too:

```powershell
.\install.ps1 -Settings "$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.claude-direct\settings.json"
```

A profile whose config directory is named `.claude-direct` gets the title `○ project (direct): state` so its tabs are easy to tell apart.

Remove everything with `.\uninstall.ps1`.

## Commands

```
claude-term status            config plus every live session record
claude-term test <state>      paint a state on this tab
claude-term reset             clear color and background
claude-term pause | resume | toggle
claude-term theme list | use <name> | next | preview [name]
claude-term color on|off      title on|off
claude-term debug on|off      log every event decision to .debug.log
claude-term install [settings.json]    (re)register hooks; idempotent
claude-term uninstall [settings.json]
```

Slash commands `/tab-status` and `/theme <name>` are installed too.

## How it works

Claude Code runs `python -S -E claude_term.py hook` for these events, with the event JSON on stdin:

| Event | Effect |
| --- | --- |
| `SessionStart` (startup, resume, clear, fork) | new session record, tab reset. `compact` is ignored so a mid-turn compaction does not flash the tab |
| `UserPromptSubmit` | `working` |
| `PreToolUse` for `AskUserQuestion`, `ExitPlanMode` | `attention` |
| `PostToolUse` | back to `working` if the tab was showing anything else |
| `PermissionRequest`, `Notification` of type `permission_prompt` | `permission` |
| `Notification` of type `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` | `attention` |
| `Stop`, `SubagentStop` | `working` if a subagent transcript is still being written, `delegated` if a Codex companion job from this session is alive, otherwise `done` |
| `SessionEnd` | reset color and title, drop the session record |

State is kept per session in `.state.json`, so many tabs never debounce or pin each other. A run costs 60 to 110 ms on an ordinary laptop.

Sequences go straight to the tab's console. Claude Code starts hooks with their own hidden console and captured stdout, so the script frees its console, walks up the process tree to the ancestor whose parent is `WindowsTerminal.exe` or `OpenConsole.exe`, attaches to that console, and writes to `CONOUT$`. Nothing is ever written to stdout in hook mode.

| Purpose | Sequence | Windows Terminal |
| --- | --- | --- |
| tab frame color | `ESC ] 4 ; 264 ; rgb:RR/GG/BB BEL` | 1.15+ |
| tab frame reset | `ESC ] 104 ; 264 ESC \` | 1.22+ |
| content background | `ESC ] 11 ; rgb:RR/GG/BB BEL`, reset `ESC ] 111 BEL` | any |
| title | `ESC ] 0 ; text BEL` | any |

The `delegated` state reads job records under `~\.claude\plugins\data\codex-*\state\*\jobs`. A job counts only if its status is `running`, its `sessionId` matches, and its worker pid is alive. Without the Codex companion plugin the state never fires.

## Themes

Six bundled themes, each defining all six states: `default`, `ocean`, `neon`, `pastel`, `solarized`, `dracula`. Custom themes go in `themes\<name>\theme.json`:

```json
{
  "schema_version": "1.0",
  "name": "mytheme",
  "display_name": "My Theme",
  "states": {
    "session.start": { "action": "reset", "label": "Session started" },
    "working":    { "r": 0,   "g": 120, "b": 212, "bg": { "r": 10, "g": 30, "b": 80 }, "label": "Working" },
    "attention":  { "r": 255, "g": 140, "b": 0,   "label": "Attention" },
    "permission": { "r": 196, "g": 43,  "b": 28,  "label": "Permission" },
    "delegated":  { "r": 128, "g": 80,  "b": 220, "label": "Codex running" },
    "done":       { "r": 16,  "g": 160, "b": 80,  "label": "Done" }
  }
}
```

`bg` is optional and tints the content area. Theme rotation across sessions is in `config.json`: set `theme_rotation` to a list and `theme_rotation_mode` to `round-robin` or `random`.

## Troubleshooting

- `claude-term status` shows what the tool believes about every session: last state, whether the main thread is busy, finished subagents.
- `claude-term debug on` appends one line per event with the decision and timing to `.debug.log`.
- Colors never change: check `WT_SESSION` is set in the shell that launched Claude Code, and that the profile has no `tabColor`.
- Color stuck after a permission prompt: make sure the `PostToolUse` registration is present (`claude-term install` restores it).

## License

MIT. See `LICENSE`.
