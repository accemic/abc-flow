#!/usr/bin/env bash
set -euo pipefail

if grep -Eq '^verilator ' "$TOOL_LOG"; then
	echo "verilator must not be invoked when no simulate action exists" >&2
	exit 1
fi
