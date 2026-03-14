#!/usr/bin/env bash
# ai-search.sh - Web search via local SearXNG for Ollama AI models
# Usage: ai-search.sh "your search query"

QUERY="$*"
SEARXNG_URL="http://localhost:8888"
LOG="/tmp/ai-search.log"

if [[ -z "$QUERY" ]]; then
    echo "Usage: ai-search.sh <query>"
    exit 1
fi

echo "[$(date)] QUERY: $QUERY" >> "$LOG"

# Ensure valkey is running (SearXNG needs it for rate limit tracking)
if ! systemctl is-active --quiet valkey; then
    systemctl start valkey
    sleep 1
fi

# Start SearXNG if not running, then wait for it to be ready
if ! curl -s --max-time 2 "$SEARXNG_URL" > /dev/null 2>&1; then
    systemctl start searxng
    for i in {1..10}; do
        sleep 1
        curl -s --max-time 2 "$SEARXNG_URL" > /dev/null 2>&1 && break
        if [[ $i -eq 10 ]]; then
            echo "ERROR: SearXNG failed to start after 10 seconds."
            exit 1
        fi
    done
fi

ENCODED_QUERY=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")

RESULT=$(curl -s --max-time 10 "${SEARXNG_URL}/search?q=${ENCODED_QUERY}&format=json&categories=general")

if [[ -z "$RESULT" ]]; then
    echo "ERROR: No response from SearXNG. The search service may be down."
    exit 1
fi

echo "$RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('ERROR: SearXNG returned invalid JSON. Cannot parse results.')
    sys.exit(1)

results = data.get('results', [])[:5]
if not results:
    print('No results found for this query. Try different search terms.')
    sys.exit(0)

for r in results:
    print('### ' + r.get('title', 'No title'))
    print(r.get('content', '').strip())
    print('Source: ' + r.get('url', ''))
    print()
"
