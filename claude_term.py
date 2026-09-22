#!/usr/bin/env python3
"""claude-term: Windows Terminal tab color and title driven by Claude Code hook events.

Python port of the PowerShell ClaudeTerm module (itself a port of TabChroma).
One process per hook event; startup is the whole cost, so this file imports only
the standard library and runs fine under ``python -S -E``.

State per Claude session (keyed by session_id), never global, so tabs do not
debounce or pin each other:

    session.start  SessionStart (startup/resume/clear)   tab color reset
    working        UserPromptSubmit, PostToolUse recovery, Stop with live subagents
    attention      PreToolUse AskUserQuestion / ExitPlanMode, elicitation notifications
    permission     PermissionRequest, permission notifications
    delegated      Stop while a Codex companion job for this session is still running
    done           Stop / SubagentStop with nothing left running
    SessionEnd     tab color and title reset, session record dropped

Tab color: OSC 4 index 264 (Windows Terminal frame background, WT 1.15+),
reset with OSC 104;264 (WT 1.22+). Content background: OSC 11 / OSC 111.
Title: OSC 0.
"""

import ctypes
import ctypes.wintypes as w
import json
import os
import re
import sys
import time

VERSION = "2.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(HERE, "config.json")
STATE_FILE = os.path.join(HERE, ".state.json")
PAUSED_FILE = os.path.join(HERE, ".paused")
THEMES_DIR = os.path.join(HERE, "themes")
DEBUG_LOG = os.path.join(HERE, ".debug.log")

SUBAGENT_ACTIVE_WINDOW_S = 300      # transcript written within this window counts as live
SESSION_TTL_S = 48 * 3600           # drop session records after this
CODEX_JOB_LOOKBACK_S = 48 * 3600    # only inspect recent companion job files
STATE_NAMES = ("session.start", "working", "done", "attention", "permission", "delegated")
URGENT = {"attention", "permission"}

ESC = "\x1b"
BEL = "\x07"

# --------------------------------------------------------------------------- config / state


def default_config():
    return {
        "enabled": True,
        "active_theme": "default",
        "features": {"tab_color": True, "title": True},
        "states": {s: True for s in STATE_NAMES},
        "debounce_seconds": 2,
        "theme_rotation": [],
        "theme_rotation_mode": "off",
        "debug": False,
    }


def read_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else fallback
    except Exception:
        return fallback


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)


def read_config():
    cfg = default_config()
    on_disk = read_json(CONFIG_FILE, None)
    if on_disk is None:
        write_json(CONFIG_FILE, cfg)
        return cfg
    for key, value in on_disk.items():
        if isinstance(value, dict) and isinstance(cfg.get(key), dict):
            cfg[key].update(value)
        else:
            cfg[key] = value
    return cfg


def read_state():
    st = read_json(STATE_FILE, {})
    if not isinstance(st.get("sessions"), dict):
        st["sessions"] = {}
    st.setdefault("rotation_index", 0)
    return st


def new_session_record(now):
    return {"main_busy": False, "finished_agents": [], "last_state": "", "last_state_time": 0,
            "theme": None, "updated": now}


def prune_sessions(state, now):
    keep = {}
    for sid, rec in state["sessions"].items():
        if isinstance(rec, dict) and now - int(rec.get("updated", 0) or 0) < SESSION_TTL_S:
            keep[sid] = rec
    state["sessions"] = keep


def read_theme(name):
    for candidate in (name, "default"):
        if not candidate:
            continue
        theme = read_json(os.path.join(THEMES_DIR, candidate, "theme.json"), None)
        if theme and isinstance(theme.get("states"), dict):
            return theme
    return None


def list_themes():
    names = []
    try:
        for entry in sorted(os.listdir(THEMES_DIR)):
            if os.path.isfile(os.path.join(THEMES_DIR, entry, "theme.json")):
                names.append(entry)
    except FileNotFoundError:
        pass
    return names


def debug(cfg, msg):
    if not (cfg.get("debug") or os.environ.get("CLAUDE_TERM_DEBUG")):
        return
    try:
        if os.path.exists(DEBUG_LOG) and os.path.getsize(DEBUG_LOG) > 262144:
            os.replace(DEBUG_LOG, DEBUG_LOG + ".1")
        with open(DEBUG_LOG, "a", encoding="utf-8") as fh:
            fh.write("%s pid=%d %s\n" % (time.strftime("%H:%M:%S"), os.getpid(), msg))
    except Exception:
        pass


# --------------------------------------------------------------------------- terminal output

_k32 = None
_ntdll = None
_attached = False


class _PBI(ctypes.Structure):
    _fields_ = [("ExitStatus", ctypes.c_void_p), ("PebBaseAddress", ctypes.c_void_p),
                ("AffinityMask", ctypes.c_void_p), ("BasePriority", ctypes.c_void_p),
                ("UniqueProcessId", ctypes.c_void_p), ("InheritedFromUniqueProcessId", ctypes.c_void_p)]


def _native():
    global _k32, _ntdll
    if _k32 is None:
        _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        _ntdll = ctypes.WinDLL("ntdll")
    return _k32, _ntdll


def _parent_pid(pid):
    k32, ntdll = _native()
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return 0
    try:
        info = _PBI()
        ln = w.ULONG(0)
        st = ntdll.NtQueryInformationProcess(w.HANDLE(h), 0, ctypes.byref(info), ctypes.sizeof(info), ctypes.byref(ln))
        return int(info.InheritedFromUniqueProcessId or 0) if st == 0 else 0
    finally:
        k32.CloseHandle(h)


def _proc_name(pid):
    k32, _ = _native()
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = w.DWORD(1024)
        if k32.QueryFullProcessImageNameW(w.HANDLE(h), 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value).lower()
        return ""
    finally:
        k32.CloseHandle(h)


def pid_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    k32, _ = _native()
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return False
    try:
        code = w.DWORD(0)
        if not k32.GetExitCodeProcess(w.HANDLE(h), ctypes.byref(code)):
            return False
        return code.value == 259  # STILL_ACTIVE
    finally:
        k32.CloseHandle(h)


def _attach_terminal_console():
    """Re-home this process onto the console of the ancestor that Windows Terminal owns.

    Claude Code spawns hooks with their own hidden console, so CONOUT$ would
    otherwise point at nothing visible. Walking up to the process whose parent
    is WindowsTerminal/OpenConsole finds the ConPTY for *this* tab, which is
    why the sequences land on the right tab even with many sessions open.
    """
    global _attached
    if _attached:
        return
    _attached = True
    k32, _ = _native()
    target = None
    cur = os.getpid()
    for _ in range(16):
        parent = _parent_pid(cur)
        if parent <= 4:
            break
        name = _proc_name(parent)
        if "windowsterminal" in name or "openconsole" in name:
            target = cur
            break
        cur = parent
    k32.FreeConsole()
    k32.AttachConsole(w.DWORD(target if target else 0xFFFFFFFF))


def write_tty(sequence):
    """Write raw bytes to the tab's console. Never falls back to stdout: in hook
    mode stdout is read by Claude Code and must stay clean."""
    if not os.environ.get("WT_SESSION"):
        return False
    try:
        _attach_terminal_console()
        k32, _ = _native()
        h = k32.CreateFileW("CONOUT$", 0x40000000, 3, None, 3, 0, None)
        if h in (0, -1, 0xFFFFFFFFFFFFFFFF):
            return False
        try:
            data = sequence.encode("utf-8")
            written = w.DWORD(0)
            return bool(k32.WriteFile(w.HANDLE(h), data, len(data), ctypes.byref(written), None))
        finally:
            k32.CloseHandle(h)
    except Exception:
        return False


def set_tab_color(r, g, b):
    return write_tty("%s]4;264;rgb:%02x/%02x/%02x%s" % (ESC, r, g, b, BEL))


def reset_tab_color():
    return write_tty("%s]104;264%s\\" % (ESC, ESC))


def set_background(r, g, b):
    return write_tty("%s]11;rgb:%02x/%02x/%02x%s" % (ESC, r, g, b, BEL))


def reset_background():
    return write_tty("%s]111%s" % (ESC, BEL))


def set_title(title):
    return write_tty("%s]0;%s%s" % (ESC, title, BEL))


def apply_state(theme, state_name, project, do_color=True, do_title=True, direct=False):
    states = theme.get("states", {})
    cfg = states.get(state_name)
    if cfg is None and state_name == "delegated":
        cfg = states.get("working")
    if not cfg:
        return
    action = cfg.get("action", "color")
    label = cfg.get("label", state_name)
    if action == "reset":
        reset_tab_color()
        if do_color:
            reset_background()
    elif do_color and action == "color":
        set_tab_color(int(cfg["r"]), int(cfg["g"]), int(cfg["b"]))
        bg = cfg.get("bg")
        if isinstance(bg, dict):
            set_background(int(bg["r"]), int(bg["g"]), int(bg["b"]))
        else:
            reset_background()
    if do_title and project:
        if direct:
            set_title("○ %s (direct): %s" % (project, label))
        else:
            set_title("◉ %s: %s" % (project, label))


# --------------------------------------------------------------------------- liveness probes


def active_subagents(session_id, transcript_path, finished):
    if not session_id or not transcript_path:
        return 0
    base = os.path.dirname(transcript_path)
    sub_dir = os.path.join(base, session_id, "subagents")
    if not os.path.isdir(sub_dir):
        return 0
    cutoff = time.time() - SUBAGENT_ACTIVE_WINDOW_S
    finished = set(finished or ())
    count = 0
    for root, dirs, files in os.walk(sub_dir):
        if root != sub_dir and "workflows" not in os.path.relpath(root, sub_dir).split(os.sep):
            dirs[:] = []
            continue
        for name in files:
            if not (name.startswith("agent-") and name.endswith(".jsonl")):
                continue
            agent_id = name[len("agent-"):-len(".jsonl")]
            if agent_id in finished:
                continue
            try:
                if os.path.getmtime(os.path.join(root, name)) >= cutoff:
                    count += 1
            except OSError:
                pass
    return count


def running_codex_jobs(session_id):
    """Codex companion jobs launched from this Claude session that are still alive.

    A stored ``running`` status is bookkeeping; the worker pid must also be
    alive (harness lesson 2026-08-14). Job files live under the plugin data
    home, one directory per workspace.
    """
    if not session_id:
        return 0
    data_root = os.path.join(os.path.expanduser("~"), ".claude", "plugins", "data")
    cutoff = time.time() - CODEX_JOB_LOOKBACK_S
    count = 0
    try:
        plugin_dirs = [d for d in os.listdir(data_root) if d.startswith("codex-")]
    except OSError:
        return 0
    for plugin in plugin_dirs:
        state_root = os.path.join(data_root, plugin, "state")
        try:
            workspaces = os.listdir(state_root)
        except OSError:
            continue
        for ws in workspaces:
            jobs_dir = os.path.join(state_root, ws, "jobs")
            try:
                entries = list(os.scandir(jobs_dir))
            except OSError:
                continue
            for entry in entries:
                if not entry.name.endswith(".json"):
                    continue
                try:
                    if entry.stat().st_mtime < cutoff:
                        continue
                    job = read_json(entry.path, {})
                except OSError:
                    continue
                if job.get("status") != "running" or job.get("sessionId") != session_id:
                    continue
                if pid_alive(job.get("pid")):
                    count += 1
    return count


# --------------------------------------------------------------------------- hook handling


def notification_state(event):
    kind = str(event.get("notification_type") or "").lower()
    if kind:
        if kind == "permission_prompt":
            return "permission"
        if kind in ("elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"):
            return "attention"
        return ""  # idle_prompt, auth_success, agent_completed, quota_*: no visual change
    message = str(event.get("message") or "").lower()
    if re.search(r"permission|approval", message):
        return "permission"
    return ""


def handle_hook(raw):
    cfg = read_config()
    if not cfg.get("enabled", True) or os.path.exists(PAUSED_FILE):
        return
    try:
        event = json.loads(raw)
    except Exception:
        return
    if not isinstance(event, dict):
        return

    name = event.get("hook_event_name", "")
    session_id = event.get("session_id", "") or ""
    cwd = event.get("cwd", "") or ""
    transcript = event.get("transcript_path", "") or ""
    tool = event.get("tool_name", "") or ""
    now = int(time.time())
    started = time.perf_counter()

    state = read_state()
    sessions = state["sessions"]
    rec = sessions.get(session_id)
    if not isinstance(rec, dict):
        rec = new_session_record(now)
    rec.setdefault("finished_agents", [])
    rec.setdefault("last_state", "")
    rec.setdefault("last_state_time", 0)

    target = ""
    end_session = False

    if name == "SessionStart":
        source = str(event.get("source") or "startup").lower()  # startup|resume|clear|compact|fork
        if source == "compact":
            # Mid-turn compaction: nothing about the tab changed. Do not wipe
            # the record or flash the reset color while Claude is still working.
            debug(cfg, "SessionStart compact ignored sid=%s" % session_id)
            return
        rec = new_session_record(now)
        # theme selection (rotation) is decided once per session, here
        mode = cfg.get("theme_rotation_mode", "off")
        rotation = [t for t in (cfg.get("theme_rotation") or []) if t]
        theme_name = cfg.get("active_theme", "default")
        if mode != "off" and rotation:
            if mode == "random":
                import random
                theme_name = random.choice(rotation)
            elif mode == "round-robin":
                idx = int(state.get("rotation_index", 0) or 0)
                theme_name = rotation[idx % len(rotation)]
                state["rotation_index"] = (idx + 1) % len(rotation)
        rec["theme"] = theme_name
        target = "session.start"
    elif name == "UserPromptSubmit":
        rec["main_busy"] = True
        target = "working"
    elif name == "PreToolUse":
        if tool in ("AskUserQuestion", "ExitPlanMode"):
            target = "attention"
    elif name == "PostToolUse":
        # Cheap recovery path: after a permission prompt, a question, or a
        # blocked Stop that let the turn continue, the tab must read working again.
        if rec.get("last_state") != "working" or not rec.get("main_busy"):
            rec["main_busy"] = True
            target = "working"
    elif name == "PermissionRequest":
        target = "permission"
    elif name == "Notification":
        target = notification_state(event)
    elif name == "Stop":
        rec["main_busy"] = False
        if active_subagents(session_id, transcript, rec["finished_agents"]) > 0:
            target = "working"
        elif running_codex_jobs(session_id) > 0:
            target = "delegated"
        else:
            target = "done"
    elif name == "SubagentStop":
        agent_id = event.get("agent_id") or ""
        if agent_id and agent_id not in rec["finished_agents"]:
            rec["finished_agents"].append(agent_id)
        if rec.get("main_busy"):
            target = "working"
        elif active_subagents(session_id, transcript, rec["finished_agents"]) > 0:
            target = "working"
        elif running_codex_jobs(session_id) > 0:
            target = "delegated"
        else:
            target = "done"
    elif name == "SessionEnd":
        end_session = True

    rec["updated"] = now

    if end_session:
        reset_tab_color()
        reset_background()
        if cfg.get("features", {}).get("title", True) and cwd:
            set_title(os.path.basename(cwd.rstrip("\\/")) or cwd)
        sessions.pop(session_id, None)
        prune_sessions(state, now)
        write_json(STATE_FILE, state)
        debug(cfg, "SessionEnd sid=%s reset" % session_id)
        return

    painted = False
    if target and cfg.get("states", {}).get(target, True):
        debounce = int(cfg.get("debounce_seconds", 2) or 0)
        same = rec.get("last_state") == target
        recent = now - int(rec.get("last_state_time", 0) or 0) < debounce
        if not (same and recent and target not in URGENT):
            theme = read_theme(rec.get("theme") or cfg.get("active_theme", "default"))
            if theme:
                features = cfg.get("features", {})
                project = os.path.basename(cwd.rstrip("\\/")) if cwd else ""
                direct = os.path.basename(os.environ.get("CLAUDE_CONFIG_DIR", "").rstrip("\\/")) == ".claude-direct"
                apply_state(theme, target, project,
                            do_color=bool(features.get("tab_color", True)),
                            do_title=bool(features.get("title", True)),
                            direct=direct)
                painted = True
            rec["last_state"] = target
            rec["last_state_time"] = now

    if session_id:
        sessions[session_id] = rec
    prune_sessions(state, now)
    write_json(STATE_FILE, state)
    debug(cfg, "%s tool=%s sid=%s -> %s painted=%s %.0fms" % (
        name, tool, session_id[:8], target or "-", painted, (time.perf_counter() - started) * 1000))


# --------------------------------------------------------------------------- hook installation

HOOK_COMMAND = [sys.executable if sys.executable else "python", "-S", "-E", os.path.join(HERE, "claude_term.py"), "hook"]

HOOK_EVENTS = {
    "SessionStart": "",
    "UserPromptSubmit": "",
    "PreToolUse": "AskUserQuestion|ExitPlanMode",
    "PostToolUse": "",
    "PermissionRequest": "",
    "Notification": "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
    "Stop": "",
    "SubagentStop": "",
    "SessionEnd": "",
}


def _is_ours(hook):
    cmd = hook.get("command", "")
    args = " ".join(hook.get("args", []) or [])
    return "claude-term" in cmd or "claude-term" in args or "claude_term" in cmd or "claude_term" in args


def install(settings_path):
    settings = read_json(settings_path, {})
    hooks = settings.setdefault("hooks", {})
    entry = {"type": "command", "command": "python",
             "args": HOOK_COMMAND[1:], "timeout": 10, "statusMessage": "claude-term"}
    # strip every previous claude-term registration (PowerShell or Python) first
    for event, groups in list(hooks.items()):
        kept_groups = []
        for group in groups or []:
            group_hooks = [h for h in (group.get("hooks") or []) if not _is_ours(h)]
            if group_hooks:
                group["hooks"] = group_hooks
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            hooks.pop(event, None)
    for event, matcher in HOOK_EVENTS.items():
        groups = hooks.setdefault(event, [])
        home = None
        for group in groups:
            if (group.get("matcher") or "") == matcher:
                home = group
                break
        if home is None:
            home = {"matcher": matcher, "hooks": []}
            groups.append(home)
        hook = dict(entry)
        if event == "SessionEnd":
            hook["timeout"] = 5  # SessionEnd hooks share a short budget
        home.setdefault("hooks", []).append(hook)
    # one owner for the tab title: stop Claude Code's own title updates
    settings.setdefault("env", {})["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
    write_json(settings_path, settings)
    print("claude-term hooks registered in %s" % settings_path)


def uninstall(settings_path):
    settings = read_json(settings_path, {})
    hooks = settings.get("hooks", {})
    removed = 0
    for event, groups in list(hooks.items()):
        kept_groups = []
        for group in groups or []:
            before = len(group.get("hooks") or [])
            group_hooks = [h for h in (group.get("hooks") or []) if not _is_ours(h)]
            removed += before - len(group_hooks)
            if group_hooks:
                group["hooks"] = group_hooks
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            hooks.pop(event, None)
    env = settings.get("env")
    if isinstance(env, dict) and env.get("CLAUDE_CODE_DISABLE_TERMINAL_TITLE") == "1":
        env.pop("CLAUDE_CODE_DISABLE_TERMINAL_TITLE")
        if not env:
            settings.pop("env")
    write_json(settings_path, settings)
    reset_tab_color()
    reset_background()
    print("removed %d claude-term hook entries from %s" % (removed, settings_path))


# --------------------------------------------------------------------------- CLI


def cmd_status():
    cfg = read_config()
    state = read_state()
    print("claude-term v%s" % VERSION)
    print("  paused        : %s" % os.path.exists(PAUSED_FILE))
    print("  enabled       : %s" % cfg.get("enabled"))
    print("  active theme  : %s" % cfg.get("active_theme"))
    print("  tab_color     : %s" % cfg.get("features", {}).get("tab_color"))
    print("  title         : %s" % cfg.get("features", {}).get("title"))
    print("  debounce (s)  : %s" % cfg.get("debounce_seconds"))
    print("  debug log     : %s" % bool(cfg.get("debug")))
    print("  terminal      : %s" % ("windows-terminal" if os.environ.get("WT_SESSION") else "unsupported"))
    now = int(time.time())
    live = [(sid, rec) for sid, rec in state["sessions"].items() if isinstance(rec, dict)]
    print("  sessions      : %d" % len(live))
    for sid, rec in sorted(live, key=lambda kv: -int(kv[1].get("updated", 0) or 0))[:12]:
        age = now - int(rec.get("updated", 0) or 0)
        print("    %s  %-11s busy=%-5s agents_done=%-2d theme=%-9s %ds ago" % (
            sid[:8], rec.get("last_state") or "-", rec.get("main_busy"),
            len(rec.get("finished_agents") or []), rec.get("theme") or "-", age))


def cmd_test(state_name):
    if state_name not in STATE_NAMES:
        print("usage: claude-term test <%s>" % "|".join(STATE_NAMES))
        return 2
    cfg = read_config()
    theme = read_theme(cfg.get("active_theme", "default"))
    if not theme:
        print("theme not found")
        return 1
    features = cfg.get("features", {})
    apply_state(theme, state_name, os.path.basename(os.getcwd()),
                do_color=bool(features.get("tab_color", True)), do_title=bool(features.get("title", True)))
    print("applied %s (theme %s)" % (state_name, cfg.get("active_theme")))
    return 0


def cmd_theme(args):
    sub = args[0] if args else "list"
    cfg = read_config()
    if sub == "list":
        for name in list_themes():
            theme = read_theme(name) or {}
            marker = "*" if name == cfg.get("active_theme") else " "
            print(" %s %-10s %-12s %s" % (marker, name, theme.get("display_name", name), theme.get("description", "")))
        return 0
    if sub == "use" and len(args) > 1:
        if args[1] not in list_themes():
            print("theme not found: %s" % args[1])
            return 1
        cfg["active_theme"] = args[1]
        write_json(CONFIG_FILE, cfg)
        print("active theme: %s" % args[1])
        return 0
    if sub == "next":
        names = list_themes()
        idx = names.index(cfg.get("active_theme")) if cfg.get("active_theme") in names else -1
        cfg["active_theme"] = names[(idx + 1) % len(names)]
        write_json(CONFIG_FILE, cfg)
        print("active theme: %s" % cfg["active_theme"])
        return 0
    if sub == "preview":
        theme = read_theme(args[1] if len(args) > 1 else cfg.get("active_theme", "default"))
        for s in ("working", "attention", "permission", "delegated", "done", "session.start"):
            print("  -> %s" % s)
            apply_state(theme, s, "", do_title=False)
            time.sleep(2)
        reset_tab_color()
        return 0
    print("usage: claude-term theme list|use <name>|next|preview [name]")
    return 2


def cmd_feature(feature, value):
    key = {"color": "tab_color", "title": "title"}.get(feature)
    if key is None or value not in ("on", "off"):
        print("usage: claude-term %s on|off" % feature)
        return 2
    cfg = read_config()
    cfg.setdefault("features", {})[key] = value == "on"
    write_json(CONFIG_FILE, cfg)
    if feature == "color" and value == "off":
        reset_tab_color()
        reset_background()
    print("%s: %s" % (feature, value))
    return 0


def cmd_help():
    print(__doc__.strip())
    print("""
usage: claude-term <command>
  hook                  process one Claude Code hook event from stdin (used by settings.json)
  status                config plus per-session state
  test <state>          paint a state on this tab (%s)
  reset                 reset tab color and background
  pause | resume | toggle
  theme list | use <name> | next | preview [name]
  color on|off          tab color feature
  title on|off          tab title feature
  debug on|off          write .debug.log with every event decision
  install [settings.json]    register hooks (default: ~/.claude/settings.json)
  uninstall [settings.json]  remove them again
  version | help""" % ", ".join(STATE_NAMES))


def main(argv):
    if not argv:
        cmd_help()
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "hook":
        try:
            raw = sys.stdin.read()
        except Exception:
            return 0
        if raw and raw.strip():
            try:
                handle_hook(raw)
            except Exception as exc:  # never break the Claude turn over a color
                debug(read_config(), "error %r" % (exc,))
        return 0
    if cmd == "status":
        cmd_status()
        return 0
    if cmd == "test":
        return cmd_test(rest[0] if rest else "")
    if cmd == "reset":
        reset_tab_color()
        reset_background()
        print("tab reset")
        return 0
    if cmd == "pause":
        open(PAUSED_FILE, "w").close()
        print("paused")
        return 0
    if cmd == "resume":
        try:
            os.remove(PAUSED_FILE)
        except FileNotFoundError:
            pass
        print("resumed")
        return 0
    if cmd == "toggle":
        return main(["resume" if os.path.exists(PAUSED_FILE) else "pause"])
    if cmd == "theme":
        return cmd_theme(rest)
    if cmd in ("color", "title"):
        return cmd_feature(cmd, rest[0] if rest else "")
    if cmd == "debug":
        cfg = read_config()
        cfg["debug"] = (rest[0] if rest else "on") == "on"
        write_json(CONFIG_FILE, cfg)
        print("debug: %s" % ("on" if cfg["debug"] else "off"))
        return 0
    if cmd == "install":
        install(rest[0] if rest else os.path.join(os.path.expanduser("~"), ".claude", "settings.json"))
        return 0
    if cmd == "uninstall":
        uninstall(rest[0] if rest else os.path.join(os.path.expanduser("~"), ".claude", "settings.json"))
        return 0
    if cmd == "version":
        print("claude-term v%s" % VERSION)
        return 0
    cmd_help()
    return 0 if cmd in ("help", "--help", "-h") else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
