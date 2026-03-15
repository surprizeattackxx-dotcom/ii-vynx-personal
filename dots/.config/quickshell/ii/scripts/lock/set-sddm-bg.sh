#!/bin/bash
# Sets the SDDM login screen background image.
# Requires root — run via: pkexec set-sddm-bg.sh /path/to/image.jpg
# Usage: set-sddm-bg.sh <image-path> <theme-conf-path>

IMG="$1"
CONF="${2:-/usr/share/sddm/themes/sddm-astronaut-theme/Themes/hyprland_kath.conf}"
THEME_DIR="$(dirname "$(dirname "$CONF")")"
BG_DIR="$THEME_DIR/Backgrounds"
DEST_NAME="quickshell_custom_bg.${IMG##*.}"
DEST="$BG_DIR/$DEST_NAME"

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Usage: $0 <image-path> [theme-conf]" >&2
    exit 1
fi

cp "$IMG" "$DEST" || { echo "Failed to copy image" >&2; exit 1; }
sed -i "s|^Background=.*|Background=\"Backgrounds/$DEST_NAME\"|" "$CONF"
sed -i "s|^BackgroundPlaceholder=.*|BackgroundPlaceholder=\"Backgrounds/$DEST_NAME\"|" "$CONF"

echo "SDDM background set to: $DEST_NAME"
