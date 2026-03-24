#!/bin/bash
# Stop recording and transcribe with the best available Whisper implementation.
TMPDIR="/tmp/quickshell/ai"
PID=$(cat "$TMPDIR/stt.pid" 2>/dev/null)
[ -n "$PID" ] && kill "$PID" 2>/dev/null
rm -f "$TMPDIR/stt.pid"
sleep 0.3  # Let the WAV file be finalised by pw-record

WAVFILE="$TMPDIR/stt.wav"
[ ! -f "$WAVFILE" ] && exit 1

strip_timestamps() {
    # Remove [HH:MM:SS.mmm --> HH:MM:SS.mmm] style timestamps from whisper output
    sed 's/\[[0-9:.,]* --> [0-9:.,]*\]//g' | sed 's/^[[:space:]]*//' | grep -v '^$'
}

if command -v whisper-faster &>/dev/null; then
    whisper-faster "$WAVFILE" --model tiny --language auto --output-format txt \
        --output-dir "$TMPDIR" 2>/dev/null
    cat "$TMPDIR/stt.txt" 2>/dev/null | strip_timestamps
elif command -v whisper &>/dev/null; then
    whisper "$WAVFILE" --model tiny --language auto --output-format txt \
        --output-dir "$TMPDIR" 2>/dev/null
    cat "$TMPDIR/stt.txt" 2>/dev/null | strip_timestamps
elif [ -f "$HOME/.local/bin/whisper-cpp" ]; then
    MODEL="$HOME/.local/share/whisper/ggml-tiny.en.bin"
    [ ! -f "$MODEL" ] && MODEL=$(find "$HOME/.local/share/whisper" -name "ggml-*.bin" 2>/dev/null | head -1)
    "$HOME/.local/bin/whisper-cpp" -m "$MODEL" -f "$WAVFILE" -otxt 2>/dev/null
    cat "$WAVFILE.txt" 2>/dev/null | strip_timestamps
else
    echo "[No Whisper found. Install whisper, faster-whisper, or whisper.cpp]"
    exit 1
fi
