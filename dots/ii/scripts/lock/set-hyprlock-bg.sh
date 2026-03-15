#!/bin/bash
# Sets the hyprlock lockscreen background image.
# Usage: set-hyprlock-bg.sh /path/to/image.jpg

IMG="$1"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprlock.conf"

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Usage: $0 <image-path>" >&2
    exit 1
fi

# Replace or insert path= inside the first background { } block
if grep -q "^\s*path\s*=" "$CONF"; then
    sed -i "s|^\(\s*\)path\s*=.*|\1path = $IMG|" "$CONF"
else
    sed -i "s|^\(\s*\)color\s*=.*|\1path = $IMG|" "$CONF"
fi

echo "Hyprlock background set to: $IMG"
