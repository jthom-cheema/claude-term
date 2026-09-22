# claude-term: guidance for Claude Code

## Layout

```
claude_term.py        everything: hook handler, terminal output, CLI, install/uninstall
themes/*/theme.json   colors per state (six states, see README)
install.ps1           copies to ~/.claude/hooks/claude-term, registers hooks, adds shims
uninstall.ps1         reverse of install
commands/*.md         optional slash commands
VERSION               plain-text version, keep in sync with VERSION in claude_term.py
```

Standard library only. The hook runs as `python -S -E claude_term.py hook`, so do not add imports that need `site`, and keep startup cheap; a run should stay near 100 ms.

## Rules that keep it working

- Never write to stdout in hook mode. Claude Code reads it. Terminal sequences go through `write_tty`, which attaches to the tab's console and writes `CONOUT$`.
- Tab color is OSC 4 index 264. OSC 9;16 is iTerm2-only and silently does nothing in Windows Terminal.
- All bookkeeping is per `session_id`. Nothing global may gate a paint, or tabs start suppressing each other.
- `SessionStart` with `source: compact` must be a no-op.
- A stored companion job `status: running` is not proof of a live job; check the pid.
- `SessionEnd` hooks share a short budget in Claude Code; keep that path fast.

## Testing

`claude-term test <state>` paints the current tab. For logic, pipe synthetic events:

```
echo {"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"C:\\x"} | python -S -E claude_term.py hook
claude-term status
```

Turn on `claude-term debug on` to get a per-event decision log in `.debug.log`.
