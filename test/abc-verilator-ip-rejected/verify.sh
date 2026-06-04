#!/usr/bin/env bash
set -euo pipefail

# Strict: no verilator invocation, no Vivado fallback.
if grep -Eq '^verilator ' "$TOOL_LOG"; then
	echo "verilator must not be invoked when create_ip is rejected" >&2
	exit 1
fi
if grep -Eq '^vivado ' "$TOOL_LOG"; then
	echo "verilator backend must not silently fall back to vivado" >&2
	exit 1
fi
