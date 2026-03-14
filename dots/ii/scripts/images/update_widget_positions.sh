#!/usr/bin/env bash
# update_widget_positions.sh
# Called by switchwall.sh post_process after every wallpaper change.
# Reads each background widget's placementStrategy from config.json.
# For "leastBusy" and "mostBusy" widgets, runs positioning scripts
# per monitor using each monitor's own wallpaper, then writes results
# to per-monitor state files and updates config.json with the focused
# monitor's values for backward compatibility.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
SHELL_CONFIG_FILE="$XDG_CONFIG_HOME/illogical-impulse/config.json"
LBR_SCRIPT="$SCRIPT_DIR/least-busy-region-venv.sh"
FIND_REGIONS_SCRIPT="$SCRIPT_DIR/find-regions-venv.sh"

MONITOR_WALL_DIR="$XDG_STATE_HOME/quickshell/user/generated/wallpaper/monitors"
WIDGET_STATE_DIR="$XDG_STATE_HOME/quickshell/user/generated/widgets/monitors"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -f "$LBR_SCRIPT" ]]; then
    echo "[widget-pos] least-busy-region-venv.sh not found at $LBR_SCRIPT" >&2
    exit 1
fi

if [[ ! -f "$FIND_REGIONS_SCRIPT" ]]; then
    echo "[widget-pos] find-regions-venv.sh not found at $FIND_REGIONS_SCRIPT" >&2
    exit 1
fi

if [[ ! -f "$SHELL_CONFIG_FILE" ]]; then
    echo "[widget-pos] Config file not found: $SHELL_CONFIG_FILE" >&2
    exit 1
fi

mkdir -p "$WIDGET_STATE_DIR"

# ---------------------------------------------------------------------------
# Widget approximate half-sizes (used to convert center→top-left x,y).
# These match the visual size of each widget on screen.
# ---------------------------------------------------------------------------
declare -A WIDGET_HALF_W=( [clock]=200  [weather]=150 [media]=200 )
declare -A WIDGET_HALF_H=( [clock]=100  [weather]=100 [media]=150 )

# ---------------------------------------------------------------------------
# run_lbr <wallpaper_path> <screen_w> <screen_h> <region_w> <region_h>
# Used for leastBusy — finds the quietest area via variance scanning
# ---------------------------------------------------------------------------
run_lbr() {
    local wp="$1" sw="$2" sh="$3" rw="$4" rh="$5"

    bash "$LBR_SCRIPT" "$wp" \
        --screen-width  "$sw" \
        --screen-height "$sh" \
        --width  "$rw" \
        --height "$rh" \
        --stride 10 \
        2>/dev/null
}

# ---------------------------------------------------------------------------
# run_find_regions <wallpaper_path> <region_w> <region_h>
# Used for mostBusy — uses selective search to find visually busy areas
# Picks the largest found region and returns a center_x/center_y JSON object
# ---------------------------------------------------------------------------
run_find_regions() {
    local wp="$1" rw="$2" rh="$3"

    local raw
    raw=$(bash "$FIND_REGIONS_SCRIPT" \
        --image "$wp" \
        --min-width  "$rw" \
        --min-height "$rh" \
        2>/dev/null)

    if [[ -z "$raw" || "$raw" == "[]" ]]; then
        echo ""
        return
    fi

    # Pick the largest region by area and convert to center_x/center_y format
    echo "$raw" | jq -c '
        max_by(.width * .height)
        | { center_x: (.x + (.width  / 2) | floor),
            center_y: (.y + (.height / 2) | floor),
            width:  .width,
            height: .height }
    ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# process_monitor <monitor> <wallpaper_path> <screen_w> <screen_h>
# Runs positioning for all enabled auto-placed widgets for one monitor.
# Outputs a JSON object of { widget: {x, y}, ... } to stdout.
# ---------------------------------------------------------------------------
process_monitor() {
    local monitor="$1"
    local wp="$2"
    local sw="$3"
    local sh="$4"
    local out="{}"

    # Track placed regions as "x y w h" strings to avoid overlap
    local placed_regions=()

    # Check if a candidate position overlaps any already-placed region (with margin)
    overlaps_placed() {
        local cx="$1" cy="$2" rw="$3" rh="$4"
        local margin=40
        local ax1=$(( cx - rw/2 - margin ))
        local ay1=$(( cy - rh/2 - margin ))
        local ax2=$(( cx + rw/2 + margin ))
        local ay2=$(( cy + rh/2 + margin ))

        for placed in "${placed_regions[@]}"; do
            read -r px py pw ph <<< "$placed"
            local bx1=$(( px - pw/2 ))
            local by1=$(( py - ph/2 ))
            local bx2=$(( px + pw/2 ))
            local by2=$(( py + ph/2 ))
            # AABB overlap check
            if (( ax1 < bx2 && ax2 > bx1 && ay1 < by2 && ay2 > by1 )); then
                return 0  # overlaps
            fi
        done
        return 1  # no overlap
    }

    # Find a non-overlapping position by scanning quadrants as fallback
    find_non_overlapping() {
        local cx="$1" cy="$2" rw="$3" rh="$4"
        # Try each screen quadrant center as fallback candidates
        local candidates=(
            "$(( sw/4 ))        $(( sh/4 ))"
            "$(( sw*3/4 ))      $(( sh/4 ))"
            "$(( sw/4 ))        $(( sh*3/4 ))"
            "$(( sw*3/4 ))      $(( sh*3/4 ))"
            "$(( sw/2 ))        $(( sh/4 ))"
            "$(( sw/2 ))        $(( sh*3/4 ))"
            "$(( sw/4 ))        $(( sh/2 ))"
            "$(( sw*3/4 ))      $(( sh/2 ))"
        )
        # First try original result
        if ! overlaps_placed "$cx" "$cy" "$rw" "$rh"; then
            echo "$cx $cy"
            return
        fi
        # Try each quadrant candidate
        for cand in "${candidates[@]}"; do
            read -r qx qy <<< "$cand"
            if ! overlaps_placed "$qx" "$qy" "$rw" "$rh"; then
                echo "$qx $qy"
                return
            fi
        done
        # Last resort: return original even if overlapping
        echo "$cx $cy"
    }

    for widget in clock weather media; do
        local enabled strategy rw rh result cx cy hw hh x y
        enabled=$(jq -r ".background.widgets.${widget}.enable // false" "$SHELL_CONFIG_FILE")
        [[ "$enabled" != "true" ]] && { echo "[widget-pos] [$monitor] $widget: disabled." >&2; continue; }

        strategy=$(jq -r ".background.widgets.${widget}.placementStrategy // \"free\"" "$SHELL_CONFIG_FILE")
        [[ "$strategy" != "leastBusy" && "$strategy" != "mostBusy" ]] && { echo "[widget-pos] [$monitor] $widget: strategy='$strategy', skipping." >&2; continue; }

        rw=$(( WIDGET_HALF_W[$widget] * 2 ))
        rh=$(( WIDGET_HALF_H[$widget] * 2 ))

        if [[ "$strategy" == "leastBusy" ]]; then
            echo "[widget-pos] [$monitor] $widget: least-busy-region (${rw}x${rh})..." >&2
            result=$(run_lbr "$wp" "$sw" "$sh" "$rw" "$rh")
        else
            echo "[widget-pos] [$monitor] $widget: find-regions (${rw}x${rh})..." >&2
            result=$(run_find_regions "$wp" "$rw" "$rh")
        fi

        [[ -z "$result" ]] && { echo "[widget-pos] [$monitor] $widget: no result, skipping." >&2; continue; }

        cx=$(echo "$result" | jq -r '.center_x // empty')
        cy=$(echo "$result" | jq -r '.center_y // empty')
        [[ -z "$cx" || -z "$cy" ]] && { echo "[widget-pos] [$monitor] $widget: bad JSON output." >&2; continue; }

        # Resolve overlap with previously placed widgets
        read -r cx cy <<< "$(find_non_overlapping "$cx" "$cy" "$rw" "$rh")"

        hw=${WIDGET_HALF_W[$widget]}
        hh=${WIDGET_HALF_H[$widget]}
        x=$(awk "BEGIN{ x=$cx-$hw; if(x<0)x=0; if(x>$sw-$rw)x=$sw-$rw; printf \"%d\",x }")
        y=$(awk "BEGIN{ y=$cy-$hh; if(y<0)y=0; if(y>$sh-$rh)y=$sh-$rh; printf \"%d\",y }")

        echo "[widget-pos] [$monitor] $widget: $strategy → center=(${cx},${cy}) → pos=(${x},${y})" >&2

        # Record this region as placed
        placed_regions+=("$cx $cy $rw $rh")

        out=$(echo "$out" | jq --arg w "$widget" --argjson x "$x" --argjson y "$y" '.[$w] = {x:$x, y:$y}')
    done

    echo "$out"
}

# ---------------------------------------------------------------------------
# Resolve all monitors and focused monitor
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Resolve focused monitor (used to match wallpaper arg passed from switchwall.sh)
# ---------------------------------------------------------------------------
focused_monitor=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused==true) | .name' 2>/dev/null)
mapfile -t all_monitors < <(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null)

if [[ ${#all_monitors[@]} -eq 0 ]]; then
    echo "[widget-pos] No monitors found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Loop over every monitor
# ---------------------------------------------------------------------------
for monitor in "${all_monitors[@]}"; do
    echo "[widget-pos] ── Monitor: $monitor ──"

    local_wp=""
    local_sw=1920
    local_sh=1080

    # If a wallpaper was passed as arg and this is the focused/only monitor, use it
    if [[ -n "$1" && -f "$1" && "$monitor" == "$focused_monitor" ]]; then
        local_wp="$1"
        local_sw="${2:-1920}"
        local_sh="${3:-1080}"
    fi

    # Fall back to per-monitor wallpaper state file
    if [[ -z "$local_wp" || ! -f "$local_wp" ]]; then
        local_state="$MONITOR_WALL_DIR/${monitor}.json"
        if [[ -f "$local_state" ]]; then
            local_wp=$(jq -r '.path // empty' "$local_state" 2>/dev/null)
        fi
    fi

    # Get screen dimensions from hyprctl
    dims=$(hyprctl monitors -j 2>/dev/null | \
        jq -r --arg m "$monitor" '.[] | select(.name==$m) | "\(.width) \(.height)"' 2>/dev/null)
    local_sw=$(echo "$dims" | awk '{print $1}')
    local_sh=$(echo "$dims" | awk '{print $2}')
    local_sw="${local_sw:-1920}"
    local_sh="${local_sh:-1080}"

    if [[ -z "$local_wp" || ! -f "$local_wp" ]]; then
        echo "[widget-pos] [$monitor] No wallpaper found, skipping." >&2
        continue
    fi

    echo "[widget-pos] [$monitor] Wallpaper: $local_wp (${local_sw}x${local_sh})"

    positions=$(process_monitor "$monitor" "$local_wp" "$local_sw" "$local_sh")

    [[ -z "$positions" || "$positions" == "{}" ]] && { echo "[widget-pos] [$monitor] No positions computed." >&2; continue; }

    # Write per-monitor widget state file
    state_file="$WIDGET_STATE_DIR/${monitor}.json"
    echo "$positions" | jq --arg m "$monitor" '. + {monitor: $m}' \
        > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
    echo "[widget-pos] [$monitor] → $state_file"
done

echo "[widget-pos] Done."
