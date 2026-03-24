#!/usr/bin/env bash
COLOR_FILE_PATH="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/color.txt"

# Define an array of possible VSCode settings file paths for various forks
settings_paths=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/VSCodium/User/settings.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/Code - OSS/User/settings.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/Code - Insiders/User/settings.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User/settings.json"
    # Add more paths as needed for other forks
)

new_color=$(cat "$COLOR_FILE_PATH" 2>/dev/null)

if [[ -z "$new_color" || ! "$new_color" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    exit 1
fi

escaped_color=$(printf '%s\n' "$new_color" | sed 's/[&/\]/\\&/g')

for CODE_SETTINGS_PATH in "${settings_paths[@]}"; do
    if [[ -f "$CODE_SETTINGS_PATH" ]]; then
        if grep -q '"material-code.primaryColor"' "$CODE_SETTINGS_PATH"; then
            sed -i -E \
                "s/(\"material-code.primaryColor\"\s*:\s*\")[^\"]*(\")/\1${escaped_color}\2/" \
                "$CODE_SETTINGS_PATH"
        else
            sed -i "\$ s/}/,\n  \"material-code.primaryColor\": \"${escaped_color}\"\n}/" "$CODE_SETTINGS_PATH"
        fi
    fi
done

