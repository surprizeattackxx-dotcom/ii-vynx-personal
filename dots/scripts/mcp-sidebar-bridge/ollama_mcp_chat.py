#!/usr/bin/env python3
"""
Terminal chat: Ollama (OpenAI-compatible /v1/chat/completions) + same MCP bridge
as Quickshell sidebar (http://127.0.0.1:3847 by default).

Requires: bridge running (~/.config/quickshell/scripts/mcp-sidebar-bridge/run.sh),
Ollama running, and a model that supports tool calling.

Examples:
  ./ollama_mcp_chat.py -m qwen2.5:latest "What MCP servers do I have? Use mcp_list_catalog."
  ./ollama_mcp_chat.py -m llama3.1 "Call the time tool on the time server" 
  echo "List git tools" | ./ollama_mcp_chat.py -m qwen2.5:latest

  # One session — type many questions (bridge + ollama stay running; run this once)
  ./ollama_mcp_chat.py -i -m qwen2.5:latest

Env:
  OLLAMA_HOST     default http://127.0.0.1:11434
  MCP_SIDEBAR_URL default http://127.0.0.1:3847
  OLLAMA_MODEL    default model if -m omitted
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

# Match services/Ai.qml _mcpListCatalogOai / _mcpCallOai (OpenAI tools format)
MCP_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "mcp_list_catalog",
            "description": (
                "Compact MCP index: server keys and tool names with short blurbs only. "
                "Prefer skipping if the user already named a server/tool; call mcp_call directly when possible."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mcp_call",
            "description": (
                "Invoke one tool on a configured MCP server (stdio). "
                "Use mcp_list_catalog only when you do not know server or tool names. "
                "Server keys match Jan's mcp_config.json (e.g. filesystem, git, time)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "server": {"type": "string", "description": "Server key from catalog"},
                    "tool": {"type": "string", "description": "Tool name from that server"},
                    "arguments": {"type": "object", "description": "Tool arguments (optional)"},
                },
                "required": ["server", "tool"],
            },
        },
    },
]


def _http_json(method: str, url: str, body: dict[str, Any] | None = None) -> Any:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} {url}\n{err_body}") from e


def _http_text(method: str, url: str, body: dict[str, Any] | None = None) -> str:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} {url}\n{err_body}") from e


def check_bridge(base: str) -> None:
    _http_json("GET", base.rstrip("/") + "/health")


def run_tool(bridge: str, name: str, arguments: dict[str, Any]) -> str:
    if name == "mcp_list_catalog":
        return _http_text("GET", bridge.rstrip("/") + "/catalog")
    if name == "mcp_call":
        server = arguments.get("server") or ""
        tool = arguments.get("tool") or ""
        args_obj = arguments.get("arguments")
        if isinstance(args_obj, str):
            try:
                args_obj = json.loads(args_obj) if args_obj.strip() else {}
            except json.JSONDecodeError:
                args_obj = {}
        if not isinstance(args_obj, dict):
            args_obj = {}
        payload = {"server": server, "tool": tool, "arguments": args_obj}
        return _http_text("POST", bridge.rstrip("/") + "/call", payload)
    raise ValueError(f"Unknown tool: {name}")


def complete_conversation_turn(
    ollama: str,
    model: str,
    bridge: str,
    messages: list[dict[str, Any]],
    max_rounds: int,
) -> None:
    """Append user message(s) to `messages` before calling. Prints assistant reply; mutates `messages`."""
    url = ollama.rstrip("/") + "/v1/chat/completions"

    for _round_i in range(max_rounds):
        body = {
            "model": model,
            "messages": messages,
            "tools": MCP_TOOLS,
            "tool_choice": "auto",
            "stream": False,
        }
        data = _http_json("POST", url, body)
        choice = (data.get("choices") or [{}])[0]
        msg = choice.get("message") or {}
        content = msg.get("content")
        tool_calls = msg.get("tool_calls")

        asst_msg: dict[str, Any] = {"role": "assistant", "content": content}
        if tool_calls:
            asst_msg["tool_calls"] = tool_calls
        messages.append(asst_msg)

        if not tool_calls:
            if content:
                print(content.strip() if isinstance(content, str) else str(content))
            else:
                print("(no content)", file=sys.stderr)
            return

        for tc in tool_calls:
            tid = tc.get("id") or ""
            fn = tc.get("function") or {}
            fname = fn.get("name") or ""
            raw_args = fn.get("arguments") or "{}"
            try:
                args = json.loads(raw_args) if isinstance(raw_args, str) else (raw_args or {})
            except json.JSONDecodeError:
                args = {}
            if not isinstance(args, dict):
                args = {}
            try:
                out = run_tool(bridge, fname, args)
            except Exception as e:  # noqa: BLE001
                out = f"[error] {e}"
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tid,
                    "content": out,
                }
            )

    print(f"[stopped after {max_rounds} tool rounds]", file=sys.stderr)


def chat_loop(ollama: str, model: str, bridge: str, user_text: str, max_rounds: int) -> None:
    messages: list[dict[str, Any]] = [{"role": "user", "content": user_text}]
    complete_conversation_turn(ollama, model, bridge, messages, max_rounds)


def main() -> None:
    ap = argparse.ArgumentParser(description="Ollama + Jan MCP bridge in the terminal")
    ap.add_argument(
        "-m",
        "--model",
        default=os.environ.get("OLLAMA_MODEL", "qwen2.5:latest"),
        help="Ollama model name (tool-capable)",
    )
    ap.add_argument(
        "--ollama",
        default=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"),
        help="Ollama base URL",
    )
    ap.add_argument(
        "--bridge",
        default=os.environ.get("MCP_SIDEBAR_URL", "http://127.0.0.1:3847"),
        help="MCP sidebar bridge URL",
    )
    ap.add_argument(
        "--max-rounds",
        type=int,
        default=24,
        help="Max assistant/tool cycles per reply (safety)",
    )
    ap.add_argument(
        "-i",
        "--repl",
        action="store_true",
        help="Interactive: one process, many questions (keeps chat context)",
    )
    ap.add_argument(
        "prompt",
        nargs="*",
        help="User message; if empty (non-REPL), read stdin",
    )
    args = ap.parse_args()

    if args.repl:
        initial = " ".join(args.prompt).strip() if args.prompt else ""
    else:
        if args.prompt:
            user_text = " ".join(args.prompt)
        else:
            user_text = sys.stdin.read()
        user_text = user_text.strip()
        if not user_text:
            print("No prompt: pass text as args or stdin (or use -i for interactive)", file=sys.stderr)
            sys.exit(1)

    try:
        check_bridge(args.bridge)
    except Exception as e:  # noqa: BLE001
        print(
            f"MCP bridge not reachable at {args.bridge}\n{e}\n\n"
            "Start: ~/.config/quickshell/scripts/mcp-sidebar-bridge/run.sh",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        if args.repl:
            messages: list[dict[str, Any]] = []
            if initial:
                messages.append({"role": "user", "content": initial})
                complete_conversation_turn(
                    args.ollama, args.model, args.bridge, messages, args.max_rounds
                )
            print("mcp+ollama> (exit / quit / Ctrl-D to leave)", file=sys.stderr)
            while True:
                try:
                    line = input("mcp> ").strip()
                except (EOFError, KeyboardInterrupt):
                    print(file=sys.stderr)
                    break
                if line.lower() in ("exit", "quit", "q"):
                    break
                if not line:
                    continue
                messages.append({"role": "user", "content": line})
                complete_conversation_turn(
                    args.ollama, args.model, args.bridge, messages, args.max_rounds
                )
        else:
            chat_loop(args.ollama, args.model, args.bridge, user_text, args.max_rounds)
    except Exception as e:  # noqa: BLE001
        print(str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
