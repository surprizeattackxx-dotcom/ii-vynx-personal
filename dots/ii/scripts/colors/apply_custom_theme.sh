#!/bin/bash
# Apply a custom or built-in theme JSON, theming GTK4, Kitty, Rofi, Hyprland, and terminal.
# Usage: apply_custom_theme.sh <theme.json>
THEME_FILE="$1"
[[ -z "$THEME_FILE" || ! -f "$THEME_FILE" ]] && { echo "Usage: apply_custom_theme.sh <theme.json>" >&2; exit 1; }

XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
STATE_DIR="$XDG_STATE_HOME/quickshell"
VENV_PYTHON="${ILLOGICAL_IMPULSE_VIRTUAL_ENV:-$HOME/.local/state/quickshell/.venv}/bin/python3"
COLORS_JSON="$STATE_DIR/user/generated/colors.json"
SCSS_FILE="$STATE_DIR/user/generated/material_colors.scss"
TERMSCHEME="$SCRIPT_DIR/terminal/scheme-base.json"

mkdir -p "$(dirname "$COLORS_JSON")"

# Copy theme JSON → colors.json (MaterialThemeLoader watches this for QML colors)
cp "$THEME_FILE" "$COLORS_JSON"

# Detect dark/light mode from background color lightness
BG=$(jq -r '.background // "#1e1e2e"' "$THEME_FILE")
R=$(( 16#${BG:1:2} )); G=$(( 16#${BG:3:2} )); B=$(( 16#${BG:5:2} ))
L=$(( (R + G + B) / 3 ))
[[ $L -lt 128 ]] && MODE="dark" || MODE="light"

# Set GNOME color-scheme so system-wide dark/light is consistent
if [[ "$MODE" == "dark" ]]; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null
    gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' 2>/dev/null
else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null
    gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3' 2>/dev/null
fi

# Convert theme JSON colors → camelCase SCSS variables (preserving actual theme colors)
python3 - "$THEME_FILE" > "$SCSS_FILE" << 'PYEOF'
import json, re, sys

def snake_to_camel(name):
    return re.sub(r'_([a-z])', lambda m: m.group(1).upper(), name)

with open(sys.argv[1]) as f:
    d = json.load(f)

for k, v in d.items():
    if isinstance(v, str) and v.startswith('#'):
        print(f"${snake_to_camel(k)}: {v};")
PYEOF

# Append terminal colors (term0-term15) derived from the theme's primary color
PRIMARY=$(jq -r '.primary // "#ffffff"' "$THEME_FILE")
if [[ -f "$TERMSCHEME" && -x "$VENV_PYTHON" ]]; then
    "$VENV_PYTHON" "$SCRIPT_DIR/generate_colors_material.py" \
        --color "$PRIMARY" --mode "$MODE" \
        --termscheme "$TERMSCHEME" --blend_bg_fg 2>/dev/null \
        | grep -E '^\$term[0-9]+:' >> "$SCSS_FILE"
fi

# Apply all colors: GTK4, Kitty, Rofi, Hyprland borders, terminal sequences
"$SCRIPT_DIR/applycolor.sh"

# Theme Qt/KDE apps (Dolphin, etc.) via kde-material-you-colors
COLOR_TXT="$STATE_DIR/user/generated/color.txt"
printf '%s' "${PRIMARY#\#}" > "$COLOR_TXT"

VENV_DIR="${ILLOGICAL_IMPULSE_VIRTUAL_ENV:-$HOME/.local/state/quickshell/.venv}"
KDE_BIN="$VENV_DIR/bin/kde-material-you-colors"
if [[ -x "$KDE_BIN" ]]; then
    [[ "$MODE" == "dark" ]] && KDE_MODE_FLAG="-d" || KDE_MODE_FLAG="-l"
    source "$VENV_DIR/bin/activate" 2>/dev/null
    "$KDE_BIN" "$KDE_MODE_FLAG" --color "${PRIMARY#\#}" -sv 5 &
    deactivate 2>/dev/null
fi
