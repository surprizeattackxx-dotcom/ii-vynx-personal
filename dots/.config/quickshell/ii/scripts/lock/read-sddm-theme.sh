#!/bin/bash
METADATA=/usr/share/sddm/themes/sddm-astronaut-theme/metadata.desktop
grep -oP '(?<=^ConfigFile=Themes/).*(?=\.conf)' "$METADATA" 2>/dev/null | head -1
