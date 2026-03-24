#!/bin/bash
# Start recording audio for STT. Saves PID so stop_stt.sh can terminate it.
TMPDIR="/tmp/quickshell/ai"
mkdir -p "$TMPDIR"
rm -f "$TMPDIR/stt.wav" "$TMPDIR/stt.pid"
pw-record --format=s16le --rate=16000 --channels=1 "$TMPDIR/stt.wav" &
echo $! > "$TMPDIR/stt.pid"
