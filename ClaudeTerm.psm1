#Requires -Version 5.1
<#
.SYNOPSIS
    ClaudeTerm - Windows Terminal visual feedback plugin for Claude Code.
    Ported from TabChroma (https://github.com/JCPetrelli/TabChroma).

.DESCRIPTION
    Changes the active Windows Terminal tab color and title based on
    Claude Code hook events, so you can glance at any tab and know its
    state at a moment's notice.

    Tab color is set via the Windows Terminal escape sequence:
        ESC ] 9 ; 16 ; <r> ; <g> ; <b> ST

    This requires Windows Terminal 1.18+ and is the only programmatic way
    to change a tab color from inside a running session (the --tabColor
    command-line flag only works at launch time).

.NOTES
    Author  : Ported to PowerShell/Windows by Claude
    License : MIT
    Requires: Windows Terminal 1.18+, PowerShell 5.1+, Claude Code CLI
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Module paths ─────────────────────────────────────────────────────────────

$script:SCRIPT_DIR   = $PSScriptRoot
$script:CONFIG_FILE  = Join-Path $script:SCRIPT_DIR 'config.json'
$script:STATE_FILE   = Join-Path $script:SCRIPT_DIR '.state.json'
$script:PAUSED_FILE  = Join-Path $script:SCRIPT_DIR '.paused'
$script:THEMES_DIR   = Join-Path $script:SCRIPT_DIR 'themes'
$script:VERSION_FILE = Join-Path $script:SCRIPT_DIR 'VERSION'

$script:VERSION = if (Test-Path $script:VERSION_FILE) {
    (Get-Content $script:VERSION_FILE -Raw).Trim()
} else { 'unknown' }

# ─── Terminal Detection ────────────────────────────────────────────────────────

function Get-TerminalType {
    <#
    .SYNOPSIS
        Detects whether we are running inside Windows Terminal.
    #>
    if ($env:WT_SESSION) {
        return 'windows-terminal'
    }
    return 'unsupported'
}

# ─── Tab Color / Title via OSC Escape Sequences ───────────────────────────────

function Set-WTTabColor {
    <#
    .SYNOPSIS
        Sets the Windows Terminal tab color using OSC 9;16 escape sequence.

    .DESCRIPTION
        Windows Terminal supports setting the tab background color from within
        a running session using the private sequence:
            ESC ] 9 ; 16 ; R ; G ; B ST
        where R, G, B are integers 0-255.

        Reference: https://github.com/microsoft/terminal/blob/main/doc/specs/%23654%20-%20Improved%20VT%20Tab%20and%20Window%20Title%20support.md
        and Windows Terminal source: TerminalControl/TermControl.cpp
    #>
    param(
        [Parameter(Mandatory)][int]$R,
        [Parameter(Mandatory)][int]$G,
        [Parameter(Mandatory)][int]$B
    )
    # ESC ] 9 ; 16 ; R ; G ; B BEL
    $esc = [char]27
    $bel = [char]7
    [Console]::Write("${esc}]9;16;${R};${G};${B}${bel}")
}

function Reset-WTTabColor {
    <#
    .SYNOPSIS
        Resets the Windows Terminal tab color to the profile default.

    .DESCRIPTION
        Sends OSC 9;16 with value -1 to signal a reset, which Windows Terminal
        interprets as "use the profile-default tabColor".
    #>
    $esc = [char]27
    $bel = [char]7
    # Reset: send empty/reset sequence. WT interprets ESC]9;16;-1;-1;-1 as reset.
    [Console]::Write("${esc}]9;16;-1;-1;-1${bel}")
}

function Set-WTTabTitle {
    <#
    .SYNOPSIS
        Sets the Windows Terminal tab title via OSC 0 (xterm title sequence).
    #>
    param([string]$Title)
    $esc = [char]27
    $bel = [char]7
    [Console]::Write("${esc}]0;${Title}${bel}")
}

# ─── Config Helpers ───────────────────────────────────────────────────────────

function Get-DefaultConfig {
    return @{
        active_theme       = 'default'
        enabled            = $true
        features           = @{
            tab_color = $true
            title     = $true
        }
        states             = @{
            'session.start' = $true
            working         = $true
            done            = $true
            attention       = $true
            permission      = $true
        }
        debounce_seconds   = 2
        theme_rotation     = @()
        theme_rotation_mode = 'off'
    }
}

function Ensure-Config {
    if (-not (Test-Path $script:CONFIG_FILE)) {
        $default = Get-DefaultConfig
        $default | ConvertTo-Json -Depth 5 | Set-Content $script:CONFIG_FILE -Encoding UTF8
    }
}

function Read-Config {
    Ensure-Config
    try {
        $raw = Get-Content $script:CONFIG_FILE -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        return Get-DefaultConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    }
}

function Write-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $script:CONFIG_FILE -Encoding UTF8
}

function Get-ActiveTheme {
    $cfg = Read-Config
    if ($cfg.active_theme) { return $cfg.active_theme }
    return 'default'
}

function Read-State {
    if (Test-Path $script:STATE_FILE) {
        try {
            return (Get-Content $script:STATE_FILE -Raw -Encoding UTF8) | ConvertFrom-Json
        } catch {}
    }
    return [PSCustomObject]@{
        last_state      = ''
        last_state_time = 0
        session_themes  = @{}
        rotation_index  = 0
    }
}

function Write-State($state) {
    $tmp = $script:STATE_FILE + '.tmp'
    $state | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $script:STATE_FILE -Force
}

function Read-Theme($themeName) {
    $themeFile = Join-Path $script:THEMES_DIR "$themeName\theme.json"
    if (-not (Test-Path $themeFile)) {
        $themeFile = Join-Path $script:THEMES_DIR "default\theme.json"
    }
    if (-not (Test-Path $themeFile)) { return $null }
    try {
        return (Get-Content $themeFile -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch { return $null }
}

# ─── Apply Theme State ────────────────────────────────────────────────────────

function Invoke-ThemeState {
    <#
    .SYNOPSIS
        Applies a named state from a theme (sets color and/or title).
    #>
    param(
        [object]$Theme,
        [string]$StateName,
        [string]$ProjectName = '',
        [bool]$DoColor = $true,
        [bool]$DoTitle = $true
    )

    if (-not $Theme) { return }

    $stateConfig = $null
    if ($Theme.states.PSObject.Properties[$StateName]) {
        $stateConfig = $Theme.states.$StateName
    }
    if (-not $stateConfig) { return }

    $action = if ($stateConfig.PSObject.Properties['action']) { $stateConfig.action } else { 'color' }
    $label  = if ($stateConfig.PSObject.Properties['label'])  { $stateConfig.label  } else { $StateName }

    if ($action -eq 'reset') {
        Reset-WTTabColor
    } elseif ($DoColor -and $action -eq 'color') {
        Set-WTTabColor -R $stateConfig.r -G $stateConfig.g -B $stateConfig.b
    }

    if ($DoTitle -and $ProjectName) {
        Set-WTTabTitle -Title "◉ ${ProjectName}: ${StateName}"
    }
}

# ─── CLI Commands ─────────────────────────────────────────────────────────────

function Show-Help {
    Write-Host ""
    Write-Host "ClaudeTerm v$script:VERSION — Windows Terminal visual feedback for Claude Code"
    Write-Host "(Ported from TabChroma by JCPetrelli)"
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  claude-term <command> [args]"
    Write-Host ""
    Write-Host "CONTROLS:"
    Write-Host "  pause                 Disable color changes"
    Write-Host "  resume                Re-enable color changes"
    Write-Host "  toggle                Toggle pause state"
    Write-Host "  status                Show current config and state"
    Write-Host ""
    Write-Host "THEMES:"
    Write-Host "  theme list            List installed themes"
    Write-Host "  theme use <name>      Switch active theme"
    Write-Host "  theme next            Cycle to next theme"
    Write-Host "  theme preview [name]  Preview all states (2s each)"
    Write-Host ""
    Write-Host "FEATURES:"
    Write-Host "  title on|off          Toggle tab title updates"
    Write-Host "  color on|off          Toggle tab color changes"
    Write-Host ""
    Write-Host "TESTING:"
    Write-Host "  test <state>          Manually trigger a state"
    Write-Host "    States: working  done  attention  permission  session.start"
    Write-Host "  reset                 Reset tab to default color"
    Write-Host ""
    Write-Host "INFO:"
    Write-Host "  help                  Show this help"
    Write-Host "  version               Show version"
    Write-Host ""
    Write-Host "SETUP:"
    Write-Host "  install               Register Claude Code hooks"
    Write-Host "  uninstall             Remove hooks and data files"
    Write-Host ""
}

function Show-Status {
    Ensure-Config
    $cfg   = Read-Config
    $state = Read-State
    $paused = Test-Path $script:PAUSED_FILE

    Write-Host ""
    Write-Host "ClaudeTerm v$script:VERSION"
    Write-Host ""
    Write-Host "  paused       : $paused"
    Write-Host "  enabled      : $($cfg.enabled)"
    Write-Host "  active theme : $($cfg.active_theme)"
    Write-Host "  last state   : $(if ($state.last_state) { $state.last_state } else { 'none' })"
    Write-Host ""
    Write-Host "  features:"
    Write-Host "    tab_color : $($cfg.features.tab_color)"
    Write-Host "    title     : $($cfg.features.title)"
    Write-Host ""
    $mode = if ($cfg.PSObject.Properties['theme_rotation_mode']) { $cfg.theme_rotation_mode } else { 'off' }
    Write-Host "  theme rotation: $mode"
    if ($cfg.PSObject.Properties['theme_rotation'] -and $cfg.theme_rotation.Count -gt 0) {
        Write-Host "    themes: $($cfg.theme_rotation -join ', ')"
    }
    Write-Host ""
}

function Set-Paused {
    New-Item -ItemType File -Path $script:PAUSED_FILE -Force | Out-Null
    Write-Host "claude-term paused"
}

function Set-Resumed {
    Remove-Item $script:PAUSED_FILE -Force -ErrorAction SilentlyContinue
    Write-Host "claude-term resumed"
}

function Invoke-Toggle {
    if (Test-Path $script:PAUSED_FILE) { Set-Resumed } else { Set-Paused }
}

function Get-ThemeList {
    Ensure-Config
    $active = Get-ActiveTheme
    Write-Host ""
    Write-Host "Installed themes:"
    Write-Host ""
    Get-ChildItem $script:THEMES_DIR -Directory | Sort-Object Name | ForEach-Object {
        $themeFile = Join-Path $_.FullName 'theme.json'
        if (Test-Path $themeFile) {
            try {
                $t = (Get-Content $themeFile -Raw -Encoding UTF8) | ConvertFrom-Json
                $display = if ($t.PSObject.Properties['display_name']) { $t.display_name } else { $_.Name }
                $desc    = if ($t.PSObject.Properties['description'])  { $t.description  } else { '' }
                $marker  = if ($_.Name -eq $active) { '*' } else { ' ' }
                Write-Host ("  {0} {1,-12} {2,-16} {3}" -f $marker, $_.Name, $display, $desc)
            } catch {}
        }
    }
    Write-Host ""
    Write-Host "  (* = active)"
    Write-Host ""
}

function Set-ActiveTheme([string]$Name) {
    if (-not $Name) {
        Write-Error "Usage: claude-term theme use <name>"
        return
    }
    $themeDir = Join-Path $script:THEMES_DIR $Name
    if (-not (Test-Path $themeDir)) {
        Write-Error "Theme not found: $Name"
        Write-Host "Run 'claude-term theme list' to see available themes"
        return
    }
    Ensure-Config
    $cfg = Read-Config
    $cfg | Add-Member -MemberType NoteProperty -Name 'active_theme' -Value $Name -Force
    Write-Config $cfg
    Write-Host "Active theme set to: $Name"
}

function Invoke-NextTheme {
    Ensure-Config
    $themes = Get-ChildItem $script:THEMES_DIR -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'theme.json') } |
        Sort-Object Name | Select-Object -ExpandProperty Name

    $cfg     = Read-Config
    $current = if ($cfg.PSObject.Properties['active_theme']) { $cfg.active_theme } else { 'default' }
    $idx     = [array]::IndexOf($themes, $current)
    $nextIdx = if ($idx -ge 0) { ($idx + 1) % $themes.Count } else { 0 }
    $next    = $themes[$nextIdx]

    $cfg | Add-Member -MemberType NoteProperty -Name 'active_theme' -Value $next -Force
    Write-Config $cfg
    Write-Host "Active theme set to: $next"
}

function Invoke-ThemePreview([string]$Name = '') {
    if (-not $Name) {
        Ensure-Config
        $Name = Get-ActiveTheme
    }
    $themeFile = Join-Path $script:THEMES_DIR "$Name\theme.json"
    if (-not (Test-Path $themeFile)) {
        Write-Error "Theme not found: $Name"
        return
    }
    $theme = (Get-Content $themeFile -Raw -Encoding UTF8) | ConvertFrom-Json
    Write-Host "Previewing theme: $Name (2s per state)"
    foreach ($s in @('working','done','attention','permission','session.start')) {
        Write-Host "  -> $s"
        Invoke-ThemeState -Theme $theme -StateName $s -DoColor $true -DoTitle $false
        Start-Sleep -Seconds 2
    }
    Reset-WTTabColor
    Write-Host "Preview complete"
}

function Invoke-Test([string]$StateName) {
    $valid = @('working','done','attention','permission','session.start')
    if (-not $StateName -or $StateName -notin $valid) {
        Write-Error "Usage: claude-term test <state>"
        Write-Host "States: $($valid -join '  ')"
        return
    }
    Ensure-Config
    $cfg       = Read-Config
    $themeName = if ($cfg.PSObject.Properties['active_theme']) { $cfg.active_theme } else { 'default' }
    $theme     = Read-Theme $themeName
    if (-not $theme) {
        Write-Error "Could not load theme: $themeName"
        return
    }
    $doColor = if ($cfg.PSObject.Properties['features'] -and $cfg.features.PSObject.Properties['tab_color']) { $cfg.features.tab_color } else { $true }
    $doTitle = if ($cfg.PSObject.Properties['features'] -and $cfg.features.PSObject.Properties['title'])     { $cfg.features.title     } else { $true }
    $project = Split-Path -Leaf (Get-Location)

    Write-Host "Testing state: $StateName  (theme: $themeName)"
    Invoke-ThemeState -Theme $theme -StateName $StateName -ProjectName $project -DoColor $doColor -DoTitle $doTitle
}

function Invoke-Reset {
    Reset-WTTabColor
    Write-Host "Tab color reset"
}

function Set-Feature([string]$Feature, [string]$Value) {
    $validFeatures = @('color','title')
    $validValues   = @('on','off')
    if ($Feature -notin $validFeatures) { Write-Error "Unknown feature: $Feature"; return }
    if ($Value   -notin $validValues)   { Write-Error "Usage: claude-term $Feature on|off"; return }

    $key = switch ($Feature) {
        'color' { 'tab_color' }
        'title' { 'title' }
    }
    $boolVal = ($Value -eq 'on')

    Ensure-Config
    $cfg = Read-Config
    if (-not $cfg.PSObject.Properties['features']) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'features' -Value ([PSCustomObject]@{}) -Force
    }
    $cfg.features | Add-Member -MemberType NoteProperty -Name $key -Value $boolVal -Force
    Write-Config $cfg
    Write-Host "${Feature}: $Value"

    if ($Value -eq 'off' -and $Feature -eq 'color') {
        Reset-WTTabColor
    }
}

# ─── Install / Uninstall ──────────────────────────────────────────────────────

function Install-ClaudeTerm {
    <#
    .SYNOPSIS
        Registers ClaudeTerm as Claude Code hooks in %USERPROFILE%\.claude\settings.json.

    .DESCRIPTION
        Hooks registered:
            SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop,
            Notification, PermissionRequest

        Each hook calls:
            powershell.exe -NonInteractive -File "<SCRIPT_DIR>\hook.ps1"

        Also adds a PowerShell profile function 'claude' that resets the tab
        color when Claude Code exits (since there is no SessionEnd hook).
    #>

    $settingsDir  = Join-Path $env:USERPROFILE '.claude'
    $settingsFile = Join-Path $settingsDir 'settings.json'
    $hookScript   = Join-Path $script:SCRIPT_DIR 'hook.ps1'

    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    # Load or create settings
    $settings = if (Test-Path $settingsFile) {
        try { (Get-Content $settingsFile -Raw -Encoding UTF8) | ConvertFrom-Json }
        catch { [PSCustomObject]@{} }
    } else { [PSCustomObject]@{} }

    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([PSCustomObject]@{}) -Force
    }

    $hookCmd    = "powershell.exe -NonInteractive -File `"$hookScript`""
    $hookEntry  = [PSCustomObject]@{ type = 'command'; command = $hookCmd }
    $catchAll   = [PSCustomObject]@{ matcher = ''; hooks = @($hookEntry) }

    $events = @('SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','Stop','Notification','PermissionRequest')
    $changed = $false

    foreach ($event in $events) {
        if (-not $settings.hooks.PSObject.Properties[$event]) {
            $settings.hooks | Add-Member -MemberType NoteProperty -Name $event -Value @($catchAll) -Force
            $changed = $true
        } else {
            $matchers = $settings.hooks.$event
            $existing = $matchers | Where-Object { $_.matcher -eq '' } | Select-Object -First 1
            if ($existing) {
                $alreadyRegistered = $existing.hooks | Where-Object { $_.command -like "*hook.ps1*" }
                if (-not $alreadyRegistered) {
                    $existing.hooks += $hookEntry
                    $changed = $true
                }
            } else {
                $settings.hooks.$event += $catchAll
                $changed = $true
            }
        }
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    if ($changed) {
        Write-Host "ClaudeTerm hooks registered in: $settingsFile"
    } else {
        Write-Host "ClaudeTerm hooks already registered."
    }

    # Add profile function that wraps 'claude' to reset tab on exit
    $profileFile  = $PROFILE.CurrentUserAllHosts
    $profileDir   = Split-Path $profileFile
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    $markerLine   = '# claude-term: reset tab on claude exit'
    $profileText  = if (Test-Path $profileFile) { Get-Content $profileFile -Raw -Encoding UTF8 } else { '' }

    if ($profileText -notlike "*$markerLine*") {
        $snippet = @"


$markerLine
function Invoke-Claude {
    & claude @args
    & "$hookScript" reset
}
Set-Alias claude Invoke-Claude -Force -Scope Global
"@
        Add-Content $profileFile -Value $snippet -Encoding UTF8
        Write-Host "claude wrapper added to: $profileFile"
        Write-Host "(Restart your shell or run: . `$PROFILE)"
    } else {
        Write-Host "claude wrapper already in profile."
    }

    Write-Host ""
    Write-Host "Installation complete. Test with: claude-term test working"
    Write-Host ""
}

function Uninstall-ClaudeTerm {
    $confirm = Read-Host "Remove ClaudeTerm completely? This will remove all hooks and data. [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Aborted."
        return
    }

    $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $settingsFile) {
        try {
            $settings = (Get-Content $settingsFile -Raw -Encoding UTF8) | ConvertFrom-Json
            $hookDir  = $script:SCRIPT_DIR
            $changed  = $false
            foreach ($event in $settings.hooks.PSObject.Properties.Name) {
                $matchers = $settings.hooks.$event
                foreach ($m in $matchers) {
                    if ($m.PSObject.Properties['hooks']) {
                        $orig = $m.hooks
                        $m.hooks = @($m.hooks | Where-Object { $_.command -notlike "*$hookDir*" })
                        if ($m.hooks.Count -ne $orig.Count) { $changed = $true }
                    }
                }
            }
            if ($changed) {
                $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
                Write-Host "Removed ClaudeTerm hooks from settings.json"
            }
        } catch {
            Write-Warning "Could not update settings.json: $_"
        }
    }

    # Remove profile entries
    $profileFile = $PROFILE.CurrentUserAllHosts
    if (Test-Path $profileFile) {
        $content = Get-Content $profileFile -Raw -Encoding UTF8
        $content = $content -replace '(?s)\r?\n# claude-term: reset tab on claude exit\r?\nfunction Invoke-Claude \{.*?\}\r?\nSet-Alias claude Invoke-Claude.*?(\r?\n)', ''
        Set-Content $profileFile -Value $content -Encoding UTF8
        Write-Host "Removed ClaudeTerm entries from profile"
    }

    Reset-WTTabColor
    Write-Host "Done. ClaudeTerm has been uninstalled."
}

# ─── Hook Event Processing ─────────────────────────────────────────────────────

function Invoke-HookEvent {
    <#
    .SYNOPSIS
        Processes a Claude Code hook event (called from hook.ps1).

    .DESCRIPTION
        Reads JSON from stdin (piped by Claude Code), determines the new
        visual state, debounces, resolves the theme, and updates the tab
        color and/or title.

        This mirrors the process_hook() function in the original tab-chroma.sh
        but uses Windows Terminal escape sequences instead of iTerm2 ones.
    #>
    param([string]$InputJson = '')

    $terminal = Get-TerminalType
    if ($terminal -eq 'unsupported') { return }
    if (Test-Path $script:PAUSED_FILE) { return }

    Ensure-Config

    if (-not $InputJson) {
        # Read from stdin if no direct input provided
        $InputJson = $input | Out-String
    }
    if (-not $InputJson.Trim()) { return }

    try { $eventData = $InputJson | ConvertFrom-Json }
    catch { return }

    $event           = if ($eventData.PSObject.Properties['hook_event_name']) { $eventData.hook_event_name } else { '' }
    $cwd             = if ($eventData.PSObject.Properties['cwd'])             { $eventData.cwd             } else { '' }
    $sessionId       = if ($eventData.PSObject.Properties['session_id'])      { $eventData.session_id      } else { '' }
    $notifMessage    = if ($event -eq 'Notification' -and $eventData.PSObject.Properties['message']) { $eventData.message.ToLower() } else { '' }

    # Map event -> state name
    $stateMap = @{
        SessionStart      = 'session.start'
        UserPromptSubmit  = 'working'
        PreToolUse        = 'working'
        PostToolUse       = 'working'
        Stop              = 'done'
    }

    $stateName = if ($stateMap.ContainsKey($event)) { $stateMap[$event] } else { '' }

    if ($event -eq 'Notification') {
        if ($notifMessage -match 'permission|approval') { $stateName = 'permission' }
        # generic completion notifications ignored (Stop already handles 'done')
    } elseif ($event -eq 'PermissionRequest') {
        $stateName = 'permission'
    }

    if (-not $stateName) { return }

    $cfg = Read-Config
    if (-not $cfg.enabled) { return }

    # Check per-state enable
    if ($cfg.PSObject.Properties['states'] -and $cfg.states.PSObject.Properties[$stateName]) {
        if (-not $cfg.states.$stateName) { return }
    }

    $state = Read-State
    $now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Debounce
    $debounce  = if ($cfg.PSObject.Properties['debounce_seconds']) { $cfg.debounce_seconds } else { 2 }
    $urgent    = $stateName -in @('attention','permission')
    $lastTime  = if ($state.PSObject.Properties['last_state_time']) { $state.last_state_time } else { 0 }
    $lastState = if ($state.PSObject.Properties['last_state'])      { $state.last_state      } else { '' }

    if ($stateName -eq $lastState -and ($now - $lastTime) -lt $debounce -and -not $urgent) { return }

    # Resolve theme (with rotation support)
    $rotationMode  = if ($cfg.PSObject.Properties['theme_rotation_mode']) { $cfg.theme_rotation_mode } else { 'off' }
    $rotation      = if ($cfg.PSObject.Properties['theme_rotation'])      { @($cfg.theme_rotation) }  else { @() }
    $rotationIdx   = if ($state.PSObject.Properties['rotation_index'])    { $state.rotation_index  }  else { 0 }

    # Per-session theme pinning
    $sessionThemes = if ($state.PSObject.Properties['session_themes'] -and $state.session_themes) {
        $state.session_themes
    } else { [PSCustomObject]@{} }

    $themeName = if ($rotationMode -ne 'off' -and $rotation.Count -gt 0) {
        if ($rotationMode -eq 'random') {
            $rotation | Get-Random
        } elseif ($rotationMode -eq 'round-robin') {
            $rotation[$rotationIdx % $rotation.Count]
        } else {
            if ($cfg.PSObject.Properties['active_theme']) { $cfg.active_theme } else { 'default' }
        }
    } else {
        if ($cfg.PSObject.Properties['active_theme']) { $cfg.active_theme } else { 'default' }
    }

    # Update rotation index on session start
    if ($stateName -eq 'session.start' -and $rotationMode -eq 'round-robin' -and $rotation.Count -gt 0) {
        $rotationIdx = ($rotationIdx + 1) % $rotation.Count
    }

    # Pin theme to session
    if ($sessionId -and $stateName -eq 'session.start') {
        $sessionThemes | Add-Member -MemberType NoteProperty -Name $sessionId -Value $themeName -Force
    } elseif ($sessionId -and $sessionThemes.PSObject.Properties[$sessionId]) {
        $themeName = $sessionThemes.$sessionId
    }

    $theme = Read-Theme $themeName
    if (-not $theme) { return }

    $doColor = if ($cfg.PSObject.Properties['features'] -and $cfg.features.PSObject.Properties['tab_color']) { $cfg.features.tab_color } else { $true }
    $doTitle = if ($cfg.PSObject.Properties['features'] -and $cfg.features.PSObject.Properties['title'])     { $cfg.features.title     } else { $true }
    $project = if ($cwd) { Split-Path -Leaf $cwd } else { '' }

    Invoke-ThemeState -Theme $theme -StateName $stateName -ProjectName $project -DoColor $doColor -DoTitle $doTitle

    # Save state atomically
    $state | Add-Member -MemberType NoteProperty -Name 'last_state'       -Value $stateName    -Force
    $state | Add-Member -MemberType NoteProperty -Name 'last_state_time'  -Value $now          -Force
    $state | Add-Member -MemberType NoteProperty -Name 'session_themes'   -Value $sessionThemes -Force
    $state | Add-Member -MemberType NoteProperty -Name 'rotation_index'   -Value $rotationIdx  -Force
    Write-State $state
}

# ─── CLI Routing ───────────────────────────────────────────────────────────────

function Invoke-ClaudeTerm {
    <#
    .SYNOPSIS
        Main entry point for the claude-term CLI.
    #>
    param([string[]]$Args)

    if (-not $Args -or $Args.Count -eq 0) {
        Show-Help
        return
    }

    $cmd  = $Args[0]
    $rest = if ($Args.Count -gt 1) { $Args[1..($Args.Count-1)] } else { @() }

    switch ($cmd) {
        'pause'   { Set-Paused }
        'resume'  { Set-Resumed }
        'toggle'  { Invoke-Toggle }
        'status'  { Show-Status }
        'reset'   { Invoke-Reset }
        'version' { Write-Host "ClaudeTerm v$script:VERSION" }
        'help'    { Show-Help }
        '--help'  { Show-Help }
        '-h'      { Show-Help }
        'theme' {
            $sub = if ($rest.Count -gt 0) { $rest[0] } else { 'list' }
            $subRest = if ($rest.Count -gt 1) { $rest[1..($rest.Count-1)] } else { @() }
            switch ($sub) {
                'list'    { Get-ThemeList }
                'use'     { Set-ActiveTheme ($subRest | Select-Object -First 1) }
                'next'    { Invoke-NextTheme }
                'preview' { Invoke-ThemePreview ($subRest | Select-Object -First 1) }
                default   { Write-Error "Unknown theme subcommand: $sub" }
            }
        }
        'title'   { Set-Feature 'title' ($rest | Select-Object -First 1) }
        'color'   { Set-Feature 'color' ($rest | Select-Object -First 1) }
        'test'    { Invoke-Test ($rest | Select-Object -First 1) }
        'install' { Install-ClaudeTerm }
        'uninstall' { Uninstall-ClaudeTerm }
        default   {
            Write-Error "Unknown command: $cmd"
            Write-Host "Run 'claude-term help' for usage"
        }
    }
}

Export-ModuleMember -Function @(
    # ── Main entry points (called by claude-term.ps1, hook.ps1, install.ps1) ──
    'Invoke-ClaudeTerm',
    'Invoke-HookEvent',
    'Install-ClaudeTerm',
    'Uninstall-ClaudeTerm',

    # ── Terminal primitives (useful for scripting / custom hooks) ──
    'Get-TerminalType',
    'Set-WTTabColor',
    'Reset-WTTabColor',
    'Set-WTTabTitle',

    # ── CLI commands (each reachable via Invoke-ClaudeTerm, but also
    #    directly importable for scripting or testing) ──
    'Show-Help',
    'Show-Status',
    'Set-Paused',
    'Set-Resumed',
    'Invoke-Toggle',
    'Invoke-Reset',
    'Invoke-Test',
    'Invoke-ThemeState',
    'Invoke-ThemePreview',
    'Invoke-NextTheme',
    'Get-ThemeList',
    'Set-ActiveTheme',
    'Set-Feature',

    # ── Config / state accessors (useful for scripting) ──
    'Read-Config',
    'Write-Config',
    'Read-State',
    'Read-Theme',
    'Get-ActiveTheme',
    'Ensure-Config'
)
