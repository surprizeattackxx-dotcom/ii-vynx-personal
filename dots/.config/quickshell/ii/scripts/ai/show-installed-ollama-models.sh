#!/usr/bin/env bash
ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | jq -Rn '[inputs | select(length > 0)]'
