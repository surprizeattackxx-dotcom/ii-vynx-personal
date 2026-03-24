#!/usr/bin/env bash
# activity-context.sh — Gather rich activity context for AI sidebar injection.
# Outputs a compact multi-line summary of what the user is actively doing.

# Active window details
ACTIVE_JSON=$(hyprctl activewindow -j 2>/dev/null || echo '{}')
WIN_CLASS=$(echo "$ACTIVE_JSON" | jq -r '.class // "unknown"' 2>/dev/null)
WIN_TITLE=$(echo "$ACTIVE_JSON" | jq -r '.title // "unknown"' 2>/dev/null)
WIN_PID=$(echo "$ACTIVE_JSON" | jq -r '.pid // 0' 2>/dev/null)
WORKSPACE=$(echo "$ACTIVE_JSON" | jq -r '.workspace.name // "?"' 2>/dev/null)
MONITOR=$(echo "$ACTIVE_JSON" | jq -r '.monitor // 0' 2>/dev/null)

# Monitor layout
MONITOR_INFO=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | "\(.name) [\(.width)x\(.height)] ws:\(.activeWorkspace.name)"' 2>/dev/null | tr '\n' '; ')

# Terminal CWD detection — walk the process tree to find a shell child
CWD=""
GIT_INFO=""
PROJECT=""
if [[ "$WIN_CLASS" =~ ^(kitty|foot|alacritty|wezterm|ghostty|org\.wezfurlong|com\.mitchellh|terminal|konsole|gnome-terminal|xterm)$ ]] || \
   [[ "$WIN_CLASS" == *"terminal"* ]] || [[ "$WIN_CLASS" == *"Terminal"* ]]; then
    # Find the deepest child shell process
    SHELL_PID=""
    # Get direct children of the terminal
    CHILDREN=$(pgrep -P "$WIN_PID" 2>/dev/null)
    for CPID in $CHILDREN; do
        CNAME=$(cat "/proc/$CPID/comm" 2>/dev/null)
        if [[ "$CNAME" =~ ^(bash|zsh|fish|sh|nu)$ ]]; then
            SHELL_PID="$CPID"
            # Check if shell has a foreground child (editor, build tool, etc.)
            GRANDCHILDREN=$(pgrep -P "$CPID" 2>/dev/null)
            for GCPID in $GRANDCHILDREN; do
                GCNAME=$(cat "/proc/$GCPID/comm" 2>/dev/null)
                # If running an interactive command, note it
                if [[ "$GCNAME" =~ ^(nvim|vim|nano|helix|code|cursor|make|cargo|npm|pnpm|yarn|python|node|go|rustc|gcc|docker|kubectl|git)$ ]]; then
                    PROJECT="running: $GCNAME"
                fi
            done
            break
        fi
    done
    if [[ -n "$SHELL_PID" ]]; then
        CWD=$(readlink -f "/proc/$SHELL_PID/cwd" 2>/dev/null)
    elif [[ -n "$WIN_PID" && "$WIN_PID" != "0" ]]; then
        CWD=$(readlink -f "/proc/$WIN_PID/cwd" 2>/dev/null)
    fi
    # Git info if in a repo
    if [[ -n "$CWD" ]] && git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
        GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
        GIT_DIRTY=$(git -C "$CWD" status --porcelain 2>/dev/null | wc -l)
        GIT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
        GIT_NAME=$(basename "$GIT_ROOT" 2>/dev/null)
        GIT_INFO="repo: $GIT_NAME ($GIT_BRANCH, $GIT_DIRTY uncommitted)"
        PROJECT="${PROJECT:+$PROJECT, }$GIT_INFO"
    fi
fi

# IDE/editor detection from window title
if [[ "$WIN_CLASS" =~ ^(code|Code|cursor|Cursor|codium)$ ]]; then
    # VS Code / Cursor title format: "filename - project — Editor"
    PROJECT_FROM_TITLE=$(echo "$WIN_TITLE" | sed -n 's/.*— \(.*\) — .*/\1/p; s/.* - \(.*\)$/\1/p' | head -1)
    if [[ -n "$PROJECT_FROM_TITLE" ]]; then
        PROJECT="editor: $PROJECT_FROM_TITLE"
    fi
fi

# Browser tab context
BROWSER_CONTEXT=""
if [[ "$WIN_CLASS" =~ ^(firefox|librewolf|chromium|google-chrome|brave|zen|thorium|vivaldi|floorp)$ ]]; then
    # Extract meaningful context from browser title
    BROWSER_CONTEXT="tab: $WIN_TITLE"
fi

# Workspace overview — what's on each workspace
WORKSPACE_SUMMARY=$(hyprctl clients -j 2>/dev/null | jq -r '
    group_by(.workspace.name) |
    map(
        (.[0].workspace.name) as $ws |
        ($ws + ": " + (map(.class) | unique | join(", ")))
    ) | join("; ")
' 2>/dev/null)

# Build output
echo "Active: $WIN_CLASS ($WORKSPACE, monitor $MONITOR)"
[[ -n "$CWD" ]] && echo "CWD: $CWD"
[[ -n "$PROJECT" ]] && echo "Project: $PROJECT"
[[ -n "$BROWSER_CONTEXT" ]] && echo "Browser: $BROWSER_CONTEXT"
echo "Workspaces: $WORKSPACE_SUMMARY"
echo "Monitors: $MONITOR_INFO"
