#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/wallpaper/monitors"

# find_regions.py uses -i/--image flag (not positional).
# If neither -i nor --image is present in args, inject the focused monitor's wallpaper.
resolve_wallpaper_path() {
    local prev=""
    for arg in "$@"; do
        if [[ "$prev" == "-i" || "$prev" == "--image" ]]; then
            echo ""  # image already provided
            return
        fi
        prev="$arg"
    done

    # No -i/--image — find focused monitor via hyprctl
    local monitor
    monitor=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused==true) | .name' 2>/dev/null)

    if [[ -z "$monitor" ]]; then
        local first
        first=$(ls "$MONITOR_STATE_DIR"/*.json 2>/dev/null | head -1)
        monitor=$(basename "$first" .json 2>/dev/null)
    fi

    if [[ -n "$monitor" && -f "$MONITOR_STATE_DIR/${monitor}.json" ]]; then
        local path
        path=$(jq -r '.path // empty' "$MONITOR_STATE_DIR/${monitor}.json" 2>/dev/null)
        if [[ -n "$path" && -f "$path" ]]; then
            echo "$path"
            return
        fi
    fi

    # Last resort: most recently modified state file
    local fallback
    fallback=$(ls -t "$MONITOR_STATE_DIR"/*.json 2>/dev/null | head -1)
    if [[ -n "$fallback" ]]; then
        local path
        path=$(jq -r '.path // empty' "$fallback" 2>/dev/null)
        if [[ -n "$path" && -f "$path" ]]; then
            echo "$path"
            return
        fi
    fi

    echo ""
}

source "${ILLOGICAL_IMPULSE_VIRTUAL_ENV/#\~/$HOME}/bin/activate"

injected=$(resolve_wallpaper_path "$@")
if [[ -n "$injected" ]]; then
    "$SCRIPT_DIR/find_regions.py" "$@" --image "$injected"
else
    "$SCRIPT_DIR/find_regions.py" "$@"
fi

deactivate
