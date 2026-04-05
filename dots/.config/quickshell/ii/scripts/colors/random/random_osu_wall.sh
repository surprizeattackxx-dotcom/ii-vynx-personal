#!/usr/bin/env bash
# random_osu_wall.sh — fetches a unique Konachan wallpaper per monitor

get_pictures_dir() {
    if command -v xdg-user-dir &> /dev/null; then xdg-user-dir PICTURES; return; fi
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

mkdir -p "$WALLPAPER_DIR" "$MONITOR_STATE_DIR" "$(dirname "$HISTORY_FILE")"

current_mode=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")
[[ "$current_mode" == "prefer-dark" ]] && MODE="dark" || MODE="light"

echo "[konachan-wall] Fetching wallpaper list..."

page=$((1 + RANDOM % 1000))
response=$(curl -s "https://konachan.net/post.json?tags=rating%3Asafe&limit=50&page=$page")

total=$(echo "$response" | jq 'length')

if [[ -z "$total" || "$total" == "null" || "$total" -eq 0 ]]; then
    echo "[konachan-wall] Failed to fetch wallpapers." >&2
    exit 1
fi

echo "[konachan-wall] Got $total wallpapers."

read -r _scale screenx screeny _h < <(
    hyprctl monitors -j | jq '.[] | select(.focused) | .scale, .x, .y, .height' | xargs
)

cursorposx=$(hyprctl cursorpos -j 2>/dev/null | jq '.x' || echo 960)
cursorposy=$(hyprctl cursorpos -j 2>/dev/null | jq '.y' || echo 540)

cursorposx=$(bc <<< "scale=0; ($cursorposx - ${screenx:-0}) * ${_scale:-1} / 1")
cursorposy=$(bc <<< "scale=0; ($cursorposy - ${screeny:-0}) * ${_scale:-1} / 1")

mapfile -t MONITORS < <(hyprctl monitors -j | jq -r '.[].name')
[[ ${#MONITORS[@]} -eq 0 ]] && { echo "[konachan-wall] No monitors found." >&2; exit 1; }

declare -A MONITOR_PATHS
used_indices=()

for monitor in "${MONITORS[@]}"; do

    local_index=$((RANDOM % total))
    attempts=0

    while [[ " ${used_indices[*]} " == *" $local_index "* && $attempts -lt 20 ]]; do
        local_index=$((RANDOM % total))
        attempts=$((attempts + 1))
    done

    used_indices+=("$local_index")

    link=$(echo "$response" | jq -r ".[$local_index].file_url")

    if [[ -z "$link" || "$link" == "null" ]]; then
        echo "[konachan-wall] Invalid image link, skipping."
        continue
    fi

    ext="${link##*.}"

    counter=1
    while [[ -f "$WALLPAPER_DIR/${counter}.${ext}" ]]; do
        counter=$((counter + 1))
    done

    dest="$WALLPAPER_DIR/${counter}.${ext}"

    echo "[konachan-wall] Fetching for $monitor (index $local_index)..."

    curl -s "$link" -o "$dest"

    MONITOR_PATHS[$monitor]="$dest"

    awww img "$dest" \
        --outputs "$monitor" \
        --transition-type grow \
        --transition-pos "${cursorposx},${cursorposy}" \
        --transition-duration 0.8 \
        --transition-fps 60 \
        --transition-step 90 &

    echo "[konachan-wall] $monitor → $dest"

done

wait

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for monitor in "${MONITORS[@]}"; do

    imgpath="${MONITOR_PATHS[$monitor]:-}"
    [[ -z "$imgpath" ]] && continue

    entry=$(jq -n \
        --arg monitor "$monitor" \
        --arg path "$imgpath" \
        --arg color "#888888" \
        --arg ts "$timestamp" \
        --arg mode "$MODE" \
        '{monitor:$monitor,path:$path,dominantColor:$color,timestamp:$ts,mode:$mode}')

    echo "$entry" > "$MONITOR_STATE_DIR/${monitor}.json"

    existing="[]"
    [[ -f "$HISTORY_FILE" ]] && existing=$(cat "$HISTORY_FILE")

    echo "$existing" | jq --argjson e "$entry" '[$e] + . | .[0:50]' > "$HISTORY_FILE"

done

primary_monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
primary_path="${MONITOR_PATHS[$primary_monitor]:-${MONITOR_PATHS[${MONITORS[0]}]:-}}"

if [[ -n "$primary_path" ]]; then

    echo "[konachan-wall] Running color generation (primary: $primary_monitor)"

    "$SCRIPT_DIR/../switchwall.sh" --image "$primary_path" --mode "$MODE" --no-save

    sleep 1

    for monitor in "${MONITORS[@]}"; do

        [[ "$monitor" == "$primary_monitor" ]] && continue

        other_path="${MONITOR_PATHS[$monitor]:-}"

        [[ -z "$other_path" || ! -f "$other_path" ]] && continue

        echo "[konachan-wall] Restoring $monitor → $other_path"

        awww img "$other_path" \
            --outputs "$monitor" \
            --transition-type grow \
            --transition-pos "0.5,0.5" \
            --transition-duration 0.8 \
            --transition-fps 60 \
            --transition-step 90 &

    done

    wait

    echo "[konachan-wall] All monitors restored."

fi
