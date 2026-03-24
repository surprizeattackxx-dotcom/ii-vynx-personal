#!/usr/bin/env bash
# workspace-layout.sh — Save and restore Hyprland window layouts.
# Usage:
#   workspace-layout.sh save <name>    — save current layout
#   workspace-layout.sh restore <name> — restore a saved layout
#   workspace-layout.sh list           — list saved layouts
#   workspace-layout.sh delete <name>  — delete a saved layout
#   workspace-layout.sh current        — show current window arrangement

LAYOUT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/quickshell/layouts"
mkdir -p "$LAYOUT_DIR"

CMD="${1:-current}"
NAME="$2"

case "$CMD" in
    save)
        if [[ -z "$NAME" ]]; then
            echo "Usage: workspace-layout.sh save <name>"
            exit 1
        fi
        # Capture all client windows with their positions, sizes, workspaces, and classes
        hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
clients = json.load(sys.stdin)
layout = []
for c in clients:
    if not c.get('mapped', False):
        continue
    layout.append({
        'class': c.get('class', ''),
        'title': c.get('title', ''),
        'workspace': c.get('workspace', {}).get('name', ''),
        'monitor': c.get('monitor', 0),
        'at': c.get('at', [0, 0]),
        'size': c.get('size', [0, 0]),
        'floating': c.get('floating', False),
        'fullscreen': c.get('fullscreen', 0),
        'pinned': c.get('pinned', False),
    })
json.dump(layout, sys.stdout, indent=2)
" > "$LAYOUT_DIR/$NAME.json" 2>&1
        COUNT=$(python3 -c "import json; print(len(json.load(open('$LAYOUT_DIR/$NAME.json'))))" 2>/dev/null)
        echo "Saved layout '$NAME' ($COUNT windows)"
        ;;
    restore)
        if [[ -z "$NAME" ]]; then
            echo "Usage: workspace-layout.sh restore <name>"
            exit 1
        fi
        LAYOUT_FILE="$LAYOUT_DIR/$NAME.json"
        if [[ ! -f "$LAYOUT_FILE" ]]; then
            echo "Layout '$NAME' not found. Available: $(ls "$LAYOUT_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json | tr '\n' ', ')"
            exit 1
        fi
        # Restore: move windows to their saved workspaces and positions
        python3 -c "
import json, subprocess, sys

with open('$LAYOUT_FILE') as f:
    layout = json.load(f)

# Get current clients
result = subprocess.run(['hyprctl', 'clients', '-j'], capture_output=True, text=True)
current = json.loads(result.stdout or '[]')

# Build a map of current windows by class
by_class = {}
for c in current:
    cls = c.get('class', '')
    if cls not in by_class:
        by_class[cls] = []
    by_class[cls].append(c)

restored = 0
launched = []
for item in layout:
    cls = item['class']
    if cls in by_class and by_class[cls]:
        # Match existing window
        win = by_class[cls].pop(0)
        addr = win.get('address', '')
        if not addr:
            continue
        ws = item['workspace']
        # Move to workspace
        subprocess.run(['hyprctl', 'dispatch', f'movetoworkspacesilent {ws},address:{addr}'], capture_output=True)
        # If floating, set position and size
        if item.get('floating'):
            x, y = item['at']
            w, h = item['size']
            subprocess.run(['hyprctl', 'dispatch', f'setfloating address:{addr}'], capture_output=True)
            subprocess.run(['hyprctl', 'dispatch', f'movewindowpixel exact {x} {y},address:{addr}'], capture_output=True)
            subprocess.run(['hyprctl', 'dispatch', f'resizewindowpixel exact {w} {h},address:{addr}'], capture_output=True)
        restored += 1
    else:
        launched.append(cls)

print(f'Restored {restored} window(s)')
if launched:
    print(f'Not found (need to launch): {\", \".join(set(launched))}')
" 2>&1
        ;;
    list)
        FILES=$(ls "$LAYOUT_DIR"/*.json 2>/dev/null)
        if [[ -z "$FILES" ]]; then
            echo "No saved layouts."
            exit 0
        fi
        echo "Saved layouts:"
        for f in $FILES; do
            LNAME=$(basename "$f" .json)
            COUNT=$(python3 -c "import json; print(len(json.load(open('$f'))))" 2>/dev/null)
            echo "  $LNAME ($COUNT windows)"
        done
        ;;
    delete)
        if [[ -z "$NAME" ]]; then
            echo "Usage: workspace-layout.sh delete <name>"
            exit 1
        fi
        if [[ -f "$LAYOUT_DIR/$NAME.json" ]]; then
            rm "$LAYOUT_DIR/$NAME.json"
            echo "Deleted layout '$NAME'"
        else
            echo "Layout '$NAME' not found."
        fi
        ;;
    current)
        hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
clients = json.load(sys.stdin)
by_ws = {}
for c in clients:
    if not c.get('mapped', False):
        continue
    ws = c.get('workspace', {}).get('name', '?')
    mon = c.get('monitor', 0)
    key = f'ws:{ws} (mon:{mon})'
    if key not in by_ws:
        by_ws[key] = []
    cls = c.get('class', 'unknown')
    pos = c.get('at', [0,0])
    size = c.get('size', [0,0])
    fl = ' [float]' if c.get('floating') else ''
    by_ws[key].append(f'  {cls} {size[0]}x{size[1]} at ({pos[0]},{pos[1]}){fl}')

for ws in sorted(by_ws):
    print(ws)
    for w in by_ws[ws]:
        print(w)
" 2>&1
        ;;
    *)
        echo "Unknown command: $CMD"
        echo "Commands: save, restore, list, delete, current"
        exit 1
        ;;
esac
