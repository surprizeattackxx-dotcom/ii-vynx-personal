#!/bin/bash
# Sets the SDDM login screen background image.
# Requires root — run via: pkexec set-sddm-bg.sh /path/to/image.jpg

IMG="$1"
THEME=/usr/share/sddm/themes/sddm-astronaut-theme
METADATA="$THEME/metadata.desktop"
# Resolve active conf from metadata.desktop ConfigFile= line
rel_conf=$(grep -oP '(?<=^ConfigFile=).*' "$METADATA" 2>/dev/null | head -1)
CONF="${THEME}/${rel_conf:-Themes/astronaut.conf}"
BG_DIR="$THEME/Backgrounds"
DEST_NAME="quickshell_custom_bg.${IMG##*.}"
DEST="$BG_DIR/$DEST_NAME"

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Usage: $0 <image-path>" >&2
    exit 1
fi

cp "$IMG" "$DEST" || { echo "Failed to copy image" >&2; exit 1; }
sed -i "s|^Background=.*|Background=\"Backgrounds/$DEST_NAME\"|" "$CONF"
sed -i "s|^BackgroundPlaceholder=.*|BackgroundPlaceholder=\"Backgrounds/$DEST_NAME\"|" "$CONF"

echo "SDDM background set to: $DEST_NAME"
