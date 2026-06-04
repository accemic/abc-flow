#!/usr/bin/env bash
set -euo pipefail

# Backend came from .abc.config, so verilator must have been invoked.
grep -Eq '^verilator .*--binary .*--top-module top_tb' "$TOOL_LOG"
