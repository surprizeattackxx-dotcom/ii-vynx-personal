#!/bin/bash
# Switches the active SDDM theme variant.
# Requires root — run via: pkexec set-sddm-theme.sh <theme-name>
THEME="$1"
METADATA=/usr/share/sddm/themes/sddm-astronaut-theme/metadata.desktop

if [[ -z "$THEME" ]]; then
    echo "Usage: $0 <theme-name>" >&2
    exit 1
fi

if [[ ! -f "/usr/share/sddm/themes/sddm-astronaut-theme/Themes/${THEME}.conf" ]]; then
    echo "Theme not found: $THEME" >&2
    exit 1
fi

sed -i "s|^ConfigFile=.*|ConfigFile=Themes/${THEME}.conf|" "$METADATA"
echo "SDDM theme set to: $THEME"
