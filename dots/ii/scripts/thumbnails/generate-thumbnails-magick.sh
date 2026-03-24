#!/usr/bin/env bash

set -e

get_thumbnail_size() {
    case "$1" in
        normal) echo 128 ;;
        large) echo 256 ;;
        x-large) echo 512 ;;
        xx-large) echo 1024 ;;
        *) echo 128 ;;
    esac
}

urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$1"
}

generate_thumbnail() {
    local src="$1"
    local abs_path
    abs_path="$(realpath "$src")"

    # FREEDESKTOP SPEC: Must be file:/// (3 slashes)
    local encoded_path
    encoded_path="$(urlencode "$abs_path")"
    local uri="file://$encoded_path"

    # MD5 the URI string
    local hash
    hash=$(echo -n "$uri" | md5sum | cut -d' ' -f1)

    local out="$CACHE_DIR/$hash.png"
    mkdir -p "$CACHE_DIR"

    # If it exists, just tell the UI we're done
    if [ -f "$out" ]; then
        echo "FILE $abs_path"
        return
    fi

    # Generate with ImageMagick
    magick "$abs_path" -thumbnail "${THUMBNAIL_SIZE}x${THUMBNAIL_SIZE}" "$out"

    # Notify Quickshell
    echo "FILE $abs_path"
}

usage() {
    echo "Usage: $0 [--size normal|large] --file <path> | --directory <path>" >&2
    exit 1
}

SIZE_NAME="normal"
MODE=""
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file|-f) MODE="file"; TARGET="$2"; shift 2 ;;
        --directory|-d) MODE="dir"; TARGET="$2"; shift 2 ;;
        --size|-s) SIZE_NAME="$2"; shift 2 ;;
        *) usage ;;
    esac
    [[ -n "$MODE" ]] && break
done

THUMBNAIL_SIZE="$(get_thumbnail_size "$SIZE_NAME")"
CACHE_DIR="$HOME/.cache/thumbnails/$SIZE_NAME"

case "$MODE" in
    file) generate_thumbnail "$TARGET" ;;
    dir)
        for f in "$TARGET"/*; do
            [[ -f "$f" ]] || continue
            generate_thumbnail "$f" &
        done
        wait
        ;;
esac
