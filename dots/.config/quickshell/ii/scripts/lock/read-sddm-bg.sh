#!/bin/bash
THEME=/usr/share/sddm/themes/sddm-astronaut-theme
METADATA="$THEME/metadata.desktop"
# Resolve active conf from metadata.desktop ConfigFile= line
rel_conf=$(grep -oP '(?<=^ConfigFile=).*' "$METADATA" 2>/dev/null | head -1)
[[ -z "$rel_conf" ]] && exit 0
CONF="$THEME/$rel_conf"
rel=$(grep -oP '(?<=^Background=").*(?=")' "$CONF" 2>/dev/null | head -1)
[[ -z "$rel" ]] && exit 0
full="$THEME/$rel"
if [[ "$full" =~ \.(mp4|mkv|webm)$ ]]; then
    png="${full%.*}.png"
    [[ -f "$png" ]] && full="$png"
fi
echo "$full"
