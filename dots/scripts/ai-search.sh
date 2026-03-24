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

echo "[$(date)] QUERY: $QUERY (args: $#, \$1='$1')" >> "$LOG"

# Ensure valkey is running (SearXNG needs it for rate limit tracking)
if ! systemctl is-active --quiet valkey; then
    sudo systemctl start valkey
    sleep 1
fi

# Start SearXNG if not running, then wait for it to be ready
if ! curl -s --max-time 2 "$SEARXNG_URL" > /dev/null 2>&1; then
    sudo systemctl start searxng
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

# Parse results; if main engines (google/brave) are suspended, skip to fallback
OUTPUT=$(echo "$RESULT" | SEARCH_QUERY="$QUERY" python3 -c "
import json, sys, os

query = os.environ.get('SEARCH_QUERY', '').lower()
# Extract meaningful keywords (skip short/common words)
stop_words = {'the','a','an','in','on','at','to','for','of','and','or','is','it','my','me','i','best','top','good','how','what','where','when','why','which','can','do','does','under','over','with','from','by','about','2024','2025','2026'}
query_words = [w for w in query.split() if len(w) > 2 and w.strip('\$') not in stop_words]

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('RETRY')
    sys.exit(0)

unresponsive = data.get('unresponsive_engines', [])
suspended_names = [e[0].lower() for e in unresponsive if 'suspended' in str(e).lower() or 'denied' in str(e).lower()]

# If google and brave are both down, skip SearXNG entirely — other engines give garbage
main_engines_down = 'google' in suspended_names and 'brave' in suspended_names
if main_engines_down:
    print('RETRY')
    sys.exit(0)

results = data.get('results', [])

# Filter out junk results: homepages, dictionary definitions, generic store pages
junk_domains = ['merriam-webster.com', 'dictionary.com', 'wikipedia.org/wiki/Best',
                'bestbuy.com', 'amazon.com', 'walmart.com', 'target.com']
junk_patterns = ['Definition & Meaning', 'Official Online Store', 'Shop Now & Save']
filtered = []
for r in results:
    url = r.get('url', '').lower()
    title = r.get('title', '')
    content = r.get('content', '').strip()
    # Skip results with no real content
    if not content or len(content) < 20:
        continue
    # Skip known junk domains (exact homepage hits)
    if any(d in url for d in junk_domains) and url.count('/') <= 3:
        continue
    # Skip dictionary/definition results
    if any(p in title for p in junk_patterns):
        continue
    # Relevance check: at least one query keyword must appear in title or content
    if query_words:
        combined = (title + ' ' + content).lower()
        if not any(w in combined for w in query_words):
            continue
    filtered.append(r)

results = filtered[:5]
if not results:
    print('EMPTY')
    sys.exit(0)

# Collect URLs for deep fetch
urls_to_fetch = []
for r in results:
    print('### ' + r.get('title', 'No title'))
    print(r.get('content', '').strip())
    url = r.get('url', '')
    print('Source: ' + url)
    print()
    if url and len(urls_to_fetch) < 2:
        urls_to_fetch.append(url)

# Output URLs for deep fetch (picked up by bash below)
import json as _json
print('DEEP_FETCH_URLS:' + _json.dumps(urls_to_fetch))
")

# Deep fetch: extract text content from top 2 result pages
if [[ "$OUTPUT" != "RETRY" && "$OUTPUT" != "EMPTY" ]]; then
    # Extract URLs from the DEEP_FETCH_URLS line
    URLS_JSON=$(echo "$OUTPUT" | grep '^DEEP_FETCH_URLS:' | sed 's/^DEEP_FETCH_URLS://')
    # Remove the DEEP_FETCH_URLS line from output
    OUTPUT=$(echo "$OUTPUT" | grep -v '^DEEP_FETCH_URLS:')

    if [[ -n "$URLS_JSON" ]]; then
        DEEP_CONTENT=$(echo "$URLS_JSON" | python3 -c "
import json, sys, subprocess, re
from html.parser import HTMLParser

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text_parts = []
        self._skip_tags = {'script','style','noscript','svg','head','nav','footer','header'}
        self._skip_depth = 0
        self._content_tags = {'p','h1','h2','h3','h4','h5','h6','li','td','th','blockquote','figcaption'}
        self._in_content = 0
    def handle_starttag(self, tag, attrs):
        if tag in self._skip_tags: self._skip_depth += 1; return
        if self._skip_depth: return
        if tag in self._content_tags: self._in_content += 1
    def handle_endtag(self, tag):
        if tag in self._skip_tags and self._skip_depth: self._skip_depth -= 1
        if tag in self._content_tags and self._in_content:
            self._in_content -= 1
            if tag in ('p','h1','h2','h3','h4','h5','h6','li','blockquote'):
                self.text_parts.append('')
    def handle_data(self, data):
        if self._in_content and not self._skip_depth:
            text = data.strip()
            if text and len(text) > 1: self.text_parts.append(text)

urls = json.load(sys.stdin)
for url in urls[:2]:
    try:
        result = subprocess.run(['curl', '-sL', '--max-time', '8', '-A', 'Mozilla/5.0', url],
                              capture_output=True, text=True, timeout=10)
        html = result.stdout
        if not html or len(html) < 100: continue
        p = TextExtractor()
        p.feed(html)
        text = ' '.join(t for t in p.text_parts if t).strip()
        text = re.sub(r'\s+', ' ', text)
        if text and len(text) > 50:
            print(f'--- Page content from {url} ---')
            print(text[:2000])
            if len(text) > 2000: print(f'... ({len(text)} total chars)')
            print()
    except: pass
" 2>/dev/null)
        if [[ -n "$DEEP_CONTENT" ]]; then
            OUTPUT="$OUTPUT

$DEEP_CONTENT"
        fi
    fi
fi

# If main engines are suspended, restart SearXNG and retry once
if [[ "$OUTPUT" == "RETRY" ]]; then
    echo "[$(date)] Main engines suspended, restarting SearXNG..." >> "$LOG"
    sudo systemctl restart searxng 2>/dev/null
    sleep 3
    RESULT=$(curl -s --max-time 10 "${SEARXNG_URL}/search?q=${ENCODED_QUERY}&format=json&categories=general")
    if [[ -n "$RESULT" ]]; then
        OUTPUT=$(echo "$RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('EMPTY'); sys.exit(0)
unresponsive = data.get('unresponsive_engines', [])
suspended_names = [e[0].lower() for e in unresponsive if 'suspended' in str(e).lower() or 'denied' in str(e).lower()]
if 'google' in suspended_names and 'brave' in suspended_names:
    print('EMPTY'); sys.exit(0)
results = data.get('results', [])
junk_domains = ['merriam-webster.com', 'dictionary.com', 'bestbuy.com', 'amazon.com', 'walmart.com', 'target.com']
junk_patterns = ['Definition & Meaning', 'Official Online Store', 'Shop Now & Save']
filtered = []
for r in results:
    url = r.get('url', '').lower()
    title = r.get('title', '')
    content = r.get('content', '').strip()
    if not content or len(content) < 20:
        continue
    if any(d in url for d in junk_domains) and url.count('/') <= 3:
        continue
    if any(p in title for p in junk_patterns):
        continue
    filtered.append(r)
results = filtered[:5]
if not results:
    print('EMPTY'); sys.exit(0)
for r in results:
    print('### ' + r.get('title', 'No title'))
    print(r.get('content', '').strip())
    print('Source: ' + r.get('url', ''))
    print()
")
    else
        OUTPUT="EMPTY"
    fi
fi

# If SearXNG still has no results, fall back to DuckDuckGo HTML scraping
if [[ "$OUTPUT" == "EMPTY" ]]; then
    echo "[$(date)] SearXNG empty, falling back to DuckDuckGo HTML..." >> "$LOG"
    DDG_QUERY=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")
    DDG_RESULT=$(curl -sL --max-time 10 -A "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" \
        "https://html.duckduckgo.com/html/?q=${DDG_QUERY}" 2>/dev/null)
    if [[ -n "$DDG_RESULT" ]]; then
        OUTPUT=$(echo "$DDG_RESULT" | python3 -c "
import sys, re
from html.parser import HTMLParser

class DDGParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.results = []
        self._in_result = False
        self._in_title = False
        self._in_snippet = False
        self._cur = {}
        self._depth = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get('class', '')
        if 'result__a' in cls and tag == 'a':
            self._in_title = True
            href = a.get('href', '')
            # DDG wraps URLs in a redirect; extract the real URL
            if 'uddg=' in href:
                import urllib.parse
                parsed = urllib.parse.parse_qs(urllib.parse.urlparse(href).query)
                href = parsed.get('uddg', [href])[0]
            self._cur = {'title': '', 'url': href, 'snippet': ''}
        elif 'result__snippet' in cls:
            self._in_snippet = True

    def handle_endtag(self, tag):
        if self._in_title and tag == 'a':
            self._in_title = False
        if self._in_snippet and tag in ('a', 'td', 'div', 'span'):
            self._in_snippet = False
            if self._cur:
                self.results.append(self._cur)
                self._cur = {}

    def handle_data(self, data):
        if self._in_title and self._cur:
            self._cur['title'] += data
        elif self._in_snippet and self._cur:
            self._cur['snippet'] += data

html = sys.stdin.read()
p = DDGParser()
p.feed(html)
# Filter out ad results (duckduckgo.com/y.js redirects)
p.results = [r for r in p.results if 'duckduckgo.com/y.js' not in r.get('url', '')]
if not p.results:
    print('No results found. Search may be temporarily unavailable. Do NOT retry — tell the user search is down.')
    sys.exit(0)
for r in p.results[:5]:
    print('### ' + r['title'].strip())
    print(r['snippet'].strip())
    print('Source: ' + r['url'])
    print()
")
    else
        OUTPUT="No results found. Search may be temporarily unavailable. Do NOT retry — tell the user search is down."
    fi
fi

echo "$OUTPUT"
