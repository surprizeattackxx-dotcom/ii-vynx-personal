#!/bin/bash
# Regenerate colors toggling dark/light mode without switching the wallpaper.
# Usage: toggle_darkmode.sh [dark|light]
# If no mode given, reads current mode from colors.json and flips it.
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
COLORS_JSON="$XDG_STATE_HOME/quickshell/user/generated/colors.json"

if [[ -n "$1" ]]; then
    MODE="$1"
else
    # Auto-detect current mode from colors.json background lightness
    BG=$(jq -r '.background // empty' "$COLORS_JSON" 2>/dev/null)
    if [[ "$BG" =~ ^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$ ]]; then
        R=$(( 16#${BASH_REMATCH[1]} ))
        G=$(( 16#${BASH_REMATCH[2]} ))
        B=$(( 16#${BASH_REMATCH[3]} ))
        # Perceived lightness: simple average
        L=$(( (R + G + B) / 3 ))
        [[ $L -lt 128 ]] && MODE="light" || MODE="dark"
    else
        MODE="light"
    fi
fi

# Get current wallpaper from swww
WALLPAPER=$(swww query 2>/dev/null | grep -o 'image: .*' | head -1 | sed 's/^image: //')

# Fall back to config
if [[ -z "$WALLPAPER" || ! -f "$WALLPAPER" ]]; then
    WALLPAPER=$(jq -r '.background.wallpaperPath // empty' "$XDG_CONFIG_HOME/illogical-impulse/config.json" 2>/dev/null)
fi

if [[ -z "$WALLPAPER" || ! -f "$WALLPAPER" ]]; then
    echo "[toggle_darkmode] Could not determine current wallpaper path" >&2
    exit 1
fi

# --noswitch before --image so the image arg wins (--noswitch resets imgpath from config)
exec "$SCRIPT_DIR/switchwall.sh" --noswitch --image "$WALLPAPER" --mode "$MODE"
