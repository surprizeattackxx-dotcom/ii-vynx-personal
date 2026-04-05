#!/usr/bin/env python3
"""
Local MCP bridge for Quickshell sidebar AI (OpenAI-style tools only).
Reads the same JSON shape as Jan's mcp_config.json and exposes:
  GET  /health
  GET  /catalog
  POST /call   {"server": "<key>", "tool": "<name>", "arguments": {...}}
  POST /reload
"""
from __future__ import annotations

import asyncio
import json
import os
import traceback
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
except ImportError as e:  # pragma: no cover
    raise SystemExit(
        "Missing deps. Run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
    ) from e

DEFAULT_CONFIG = Path.home() / ".local/share/Jan/data/mcp_config.json"
HOST = os.environ.get("MCP_SIDEBAR_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_SIDEBAR_PORT", "3847"))
MAX_PARALLEL = int(os.environ.get("MCP_SIDEBAR_MAX_PARALLEL", "4"))
# Compact catalog: omit inputSchema (huge); cap description length per tool
CATALOG_DESC_MAX = int(os.environ.get("MCP_CATALOG_DESC_MAX", "120"))
CATALOG_MAX_JSON_CHARS = int(os.environ.get("MCP_CATALOG_MAX_JSON_CHARS", "14000"))

_catalog_cache: dict[str, Any] | None = None


def _config_path() -> Path:
    p = os.environ.get("MCP_CONFIG_PATH", "")
    return Path(p) if p else DEFAULT_CONFIG


def _load_raw_config() -> dict[str, Any]:
    path = _config_path()
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def _merge_env(extra: dict[str, str] | None) -> dict[str, str]:
    base = {**os.environ}
    if extra:
        base.update(extra)
    return base


def _stdio_params_for_server(name: str, entry: dict[str, Any]) -> dict[str, Any] | None:
    if entry.get("active") is False:
        return None
    if entry.get("type") == "http":
        return None
    cmd = (entry.get("command") or "").strip()
    if not cmd:
        return None
    args = list(entry.get("args") or [])
    env = _merge_env(entry.get("env"))
    return {"name": name, "command": cmd, "args": args, "env": env}


async def _with_stdio_session(
    command: str,
    args: list[str],
    env: dict[str, str],
    work: Any,
):
    params = StdioServerParameters(command=command, args=args, env=env)
    async with stdio_client(params) as streams:
        read, write = streams
        async with ClientSession(read, write) as session:
            await session.initialize()
            return await work(session)


async def _list_tools_for_server(spec: dict[str, Any]) -> dict[str, Any]:
    async def work(session: ClientSession):
        out = await session.list_tools()
        tools = []
        for t in out.tools:
            schema = t.inputSchema
            if schema is not None and hasattr(schema, "model_dump"):
                schema = schema.model_dump()
            tools.append(
                {
                    "name": t.name,
                    "description": (t.description or "")[:2000],
                    "inputSchema": schema,
                }
            )
        return {"tools": tools}

    return await _with_stdio_session(
        spec["command"], spec["args"], spec["env"], work
    )


async def _call_tool(
    spec: dict[str, Any], tool: str, arguments: dict[str, Any]
) -> str:
    async def work(session: ClientSession):
        result = await session.call_tool(tool, arguments or {})
        if result.isError:
            return "Error: " + json.dumps(
                [c.model_dump() if hasattr(c, "model_dump") else str(c) for c in result.content]
            )
        parts: list[str] = []
        for c in result.content:
            if hasattr(c, "text"):
                parts.append(c.text)
            else:
                parts.append(str(c))
        return "\n".join(parts) if parts else "(empty result)"

    return await _with_stdio_session(
        spec["command"], spec["args"], spec["env"], work
    )


async def build_catalog() -> dict[str, Any]:
    raw = _load_raw_config()
    servers = raw.get("mcpServers") or {}
    out: dict[str, Any] = {"servers": {}, "skipped": []}
    specs: list[tuple[str, dict[str, Any]]] = []
    for key, entry in servers.items():
        if entry.get("type") == "http":
            out["skipped"].append(f"{key}: http transport (use Jan or a proxy)")
            continue
        sp = _stdio_params_for_server(key, entry)
        if sp is None:
            if entry.get("active") is False:
                out["skipped"].append(f"{key}: inactive")
            elif not (entry.get("command") or "").strip():
                out["skipped"].append(f"{key}: no command")
            continue
        specs.append((key, sp))

    sem = asyncio.Semaphore(MAX_PARALLEL)

    async def one(key: str, spec: dict[str, Any]):
        async with sem:
            try:
                data = await _list_tools_for_server(spec)
                out["servers"][key] = {
                    "command": spec["command"],
                    "tools": data["tools"],
                }
            except Exception as e:  # noqa: BLE001
                out["servers"][key] = {
                    "error": str(e),
                    "traceback": traceback.format_exc()[-4000:],
                }

    await asyncio.gather(*(one(k, s) for k, s in specs))
    return out


def _compact_catalog(full: dict[str, Any]) -> dict[str, Any]:
    """Strip inputSchema and long text so LLM context stays small."""
    out: dict[str, Any] = {
        "format": "compact",
        "note": "No per-tool JSON schemas here (saves context). Call mcp_call with server+tool; guess arguments from names or ask the user. For full schemas use GET /catalog?full=1 (large).",
        "servers": {},
        "skipped": full.get("skipped", []),
    }
    for key, val in full.get("servers", {}).items():
        if "error" in val:
            out["servers"][key] = {"error": val["error"]}
            continue
        tools_in = val.get("tools") or []
        compact_tools: list[dict[str, Any]] = []
        for t in tools_in:
            if not isinstance(t, dict):
                continue
            compact_tools.append(
                {
                    "name": t.get("name"),
                    "description": (t.get("description") or "")[:CATALOG_DESC_MAX],
                }
            )
        out["servers"][key] = {"tools": compact_tools}

    text = json.dumps(out, ensure_ascii=False)
    if len(text) > CATALOG_MAX_JSON_CHARS:
        minimal: dict[str, Any] = {
            "format": "minimal",
            "note": "Catalog too large even compact; listing tool names only.",
            "servers": {},
            "skipped": out.get("skipped", []),
        }
        for k, v in full.get("servers", {}).items():
            if not isinstance(v, dict):
                continue
            if "error" in v:
                minimal["servers"][k] = {"error": v["error"]}
            else:
                tools_in = v.get("tools") or []
                minimal["servers"][k] = {
                    "tools": [
                        t.get("name")
                        for t in tools_in
                        if isinstance(t, dict) and t.get("name")
                    ]
                }
        out = minimal

    return out


class CallBody(BaseModel):
    server: str = Field(..., description="Server key from mcp_config.json")
    tool: str = Field(..., description="Tool name from that server")
    arguments: dict[str, Any] = Field(default_factory=dict)


app = FastAPI(title="MCP Sidebar Bridge", version="1.0.0")


@app.get("/health")
async def health():
    return {"ok": True, "config": str(_config_path()), "catalog_cached": _catalog_cache is not None}


@app.get("/catalog")
async def catalog(full: bool = False):
    """Default: compact (no inputSchema) for small LLM context. Use ?full=1 for complete schemas."""
    global _catalog_cache
    if _catalog_cache is None:
        _catalog_cache = await build_catalog()
    if full:
        return _catalog_cache
    return _compact_catalog(_catalog_cache)


@app.post("/reload")
async def reload():
    global _catalog_cache
    _catalog_cache = None
    return await catalog()


@app.post("/call")
async def call(body: CallBody):
    raw = _load_raw_config()
    servers = raw.get("mcpServers") or {}
    entry = servers.get(body.server)
    if not entry:
        raise HTTPException(404, f"Unknown server {body.server!r}")
    spec = _stdio_params_for_server(body.server, entry)
    if spec is None:
        raise HTTPException(400, f"Server {body.server!r} is not available via stdio bridge")
    try:
        text = await _call_tool(spec, body.tool, body.arguments)
        return PlainTextResponse(text)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, str(e) + "\n" + traceback.format_exc()[-8000:]) from e


def main():
    import uvicorn

    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        log_level="info",
        factory=False,
    )


if __name__ == "__main__":
    main()
