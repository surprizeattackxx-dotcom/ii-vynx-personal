#!/usr/bin/env bash
# random_konachan_wall.sh — fetch a random Konachan wallpaper per monitor.
# Restored to the original working approach (konachan.net, random page),
# extended to handle multiple monitors and write state for QuickConfig previews.

get_pictures_dir() {
    if command -v xdg-user-dir &> /dev/null; then
        xdg-user-dir PICTURES; return
    fi
    local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
    if [ -f "$config_file" ]; then
        local pictures_path
        pictures_path=$(source "$config_file" >/dev/null 2>&1; echo "$XDG_PICTURES_DIR")
        echo "${pictures_path/#\$HOME/$HOME}"; return
    fi
    echo "$HOME/Pictures"
}

QUICKSHELL_CONFIG_NAME="ii"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
PICTURES_DIR=$(get_pictures_dir)
STATE_DIR="$XDG_STATE_HOME/quickshell"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WALLPAPER_DIR="$PICTURES_DIR/Wallpapers"
MONITOR_STATE_DIR="$STATE_DIR/user/generated/wallpaper/monitors"
HISTORY_FILE="$STATE_DIR/user/generated/wallpaper/history.json"
ILLOGICAL_CONFIG="$XDG_CONFIG_HOME/illogical-impulse/config.json"

mkdir -p "$WALLPAPER_DIR" "$MONITOR_STATE_DIR" "$(dirname "$HISTORY_FILE")"

# Detect dark/light mode
current_mode=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")
[[ "$current_mode" == "prefer-dark" ]] && MODE="dark" || MODE="light"

# Get cursor position for awww grow transition (awk, no bc dependency)
read -r _scale screenx screeny _h < <(
    hyprctl monitors -j | jq '.[] | select(.focused) | .scale, .x, .y, .height' | xargs
)
cursorposx=$(hyprctl cursorpos -j 2>/dev/null | jq '.x' 2>/dev/null || echo 960)
cursorposy=$(hyprctl cursorpos -j 2>/dev/null | jq '.y' 2>/dev/null || echo 540)
cursorposx=$(awk "BEGIN{printf \"%d\", ($cursorposx - ${screenx:-0}) * ${_scale:-1}}")
cursorposy=$(awk "BEGIN{printf \"%d\", ($cursorposy - ${screeny:-0}) * ${_scale:-1}}")

# Get all monitors
mapfile -t MONITORS < <(hyprctl monitors -j | jq -r '.[].name')
if [[ ${#MONITORS[@]} -eq 0 ]]; then
    echo "[konachan] No monitors found." >&2
    exit 1
fi

echo "[konachan] Found ${#MONITORS[@]} monitor(s): ${MONITORS[*]}"

declare -A MONITOR_PATHS
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# Fetch and apply one wallpaper per monitor
# Uses konachan.net (the original working endpoint) with a random page
# ---------------------------------------------------------------------------
for monitor in "${MONITORS[@]}"; do
    echo "[konachan] Fetching for $monitor..."

    page=$((1 + RANDOM % 1000))
    response=$(curl -sf "https://konachan.net/post.json?tags=rating%3Asafe&limit=1&page=$page")

    if [[ -z "$response" ]]; then
        echo "[konachan] curl failed for $monitor — konachan.net may be unreachable." >&2
        notify-send -a "Wallpaper" -u critical "Konachan fetch failed" \
            "Could not reach konachan.net for $monitor. Check your network." 2>/dev/null || true
        continue
    fi

    link=$(echo "$response" | jq -r '.[0].file_url // empty')
    if [[ -z "$link" ]]; then
        echo "[konachan] No file_url in response for $monitor." >&2
        continue
    fi

    ext="${link##*.}"

    # Avoid overwriting the currently-set wallpaper
    downloadPath="$WALLPAPER_DIR/random_wallpaper_${monitor}.${ext}"
    currentWallpaperPath=$(jq -r '.background.wallpaperPath' "$ILLOGICAL_CONFIG" 2>/dev/null || echo "")
    if [[ "$downloadPath" == "$currentWallpaperPath" ]]; then
        downloadPath="$WALLPAPER_DIR/random_wallpaper_${monitor}-1.${ext}"
    fi

    echo "[konachan] Downloading $link → $downloadPath"
    if ! curl -sf "$link" -o "$downloadPath"; then
        echo "[konachan] Download failed for $monitor." >&2
        continue
    fi

    MONITOR_PATHS[$monitor]="$downloadPath"

    # Apply wallpaper via awww
    if command -v awww &>/dev/null; then
        awww img "$downloadPath" \
            --outputs "$monitor" \
            --transition-type grow \
            --transition-pos "${cursorposx},${cursorposy}" \
            --transition-duration 0.8 \
            --transition-fps 60 \
            --transition-step 90 &
    fi

    echo "[konachan] $monitor → $downloadPath"
done

wait  # Let awww transitions settle

# ---------------------------------------------------------------------------
# Write monitor state files (used by QuickConfig wallpaper previews)
# ---------------------------------------------------------------------------
for monitor in "${MONITORS[@]}"; do
    imgpath="${MONITOR_PATHS[$monitor]:-}"
    [[ -z "$imgpath" ]] && continue

    entry=$(jq -n \
        --arg monitor "$monitor" \
        --arg path    "$imgpath" \
        --arg color   "#888888" \
        --arg ts      "$timestamp" \
        --arg mode    "$MODE" \
        '{monitor:$monitor, path:$path, dominantColor:$color, timestamp:$ts, mode:$mode}')

    echo "$entry" > "$MONITOR_STATE_DIR/${monitor}.json"

    existing="[]"
    [[ -f "$HISTORY_FILE" ]] && existing=$(cat "$HISTORY_FILE")
    echo "$existing" | jq --argjson e "$entry" '[$e] + . | .[0:50]' > "$HISTORY_FILE"
done

# ---------------------------------------------------------------------------
# Hand the focused/primary monitor's wallpaper to switchwall.sh for
# full Material You color generation + shell theming.
# ---------------------------------------------------------------------------
primary_monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
primary_path="${MONITOR_PATHS[$primary_monitor]:-${MONITOR_PATHS[${MONITORS[0]}]:-}}"

if [[ -n "$primary_path" ]]; then
    echo "[konachan] Running color generation (primary: $primary_monitor → $primary_path)"
    "$SCRIPT_DIR/../switchwall.sh" --image "$primary_path" --mode "$MODE" --no-save

    # switchwall's awww call resets all monitors to primary_path.
    # Wait for its transition then restore the other monitors.
    sleep 1
    for monitor in "${MONITORS[@]}"; do
        [[ "$monitor" == "$primary_monitor" ]] && continue
        other_path="${MONITOR_PATHS[$monitor]:-}"
        [[ -z "$other_path" || ! -f "$other_path" ]] && continue
        echo "[konachan] Restoring $monitor → $other_path"
        awww img "$other_path" \
            --outputs "$monitor" \
            --transition-type grow \
            --transition-pos "0.5,0.5" \
            --transition-duration 0.8 \
            --transition-fps 60 \
            --transition-step 90 &
    done
    wait
    echo "[konachan] All monitors restored."
else
    echo "[konachan] No wallpaper was downloaded successfully." >&2
    notify-send -a "Wallpaper" -u critical "Konachan: nothing downloaded" \
        "All monitor fetches failed. Is konachan.net reachable?" 2>/dev/null || true
fi
