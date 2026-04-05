#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
export MCP_CONFIG_PATH="${MCP_CONFIG_PATH:-$HOME/.local/share/Jan/data/mcp_config.json}"
export MCP_SIDEBAR_HOST="${MCP_SIDEBAR_HOST:-127.0.0.1}"
export MCP_SIDEBAR_PORT="${MCP_SIDEBAR_PORT:-3847}"
exec "$DIR/.venv/bin/python" -m uvicorn main:app --host "$MCP_SIDEBAR_HOST" --port "$MCP_SIDEBAR_PORT"
