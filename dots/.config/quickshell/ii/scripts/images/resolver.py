#!/usr/bin/env bash
MONITOR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/wallpaper/monitors"

echo "---- Monitor JSON Status ----"
for f in "$MONITOR_STATE_DIR"/*.json; do
    monitor=$(basename "$f" .json)
    path=$(jq -r '.path // empty' "$f" 2>/dev/null)
    exists="[MISSING]"
    [[ -f "${path#file://}" ]] && exists="[OK]"
    echo "$monitor: $path $exists"
done

echo
focused=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused==true) | .name')
echo "Focused monitor: ${focused:-<none>}"
