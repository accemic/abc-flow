#!/usr/bin/env bash
set -euo pipefail

grep -Eq '^verilator .*--binary .*--top-module top_tb' "$TOOL_LOG"
grep -Fq "$REPO/rtl/core.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/top_tb.sv" "$TOOL_LOG"
grep -Fq "verilator_sim_file payload.bin" "$TOOL_LOG"

# No glbl.v: Verilator path must not pull Vivado support files.
if grep -Fq "glbl" "$TOOL_LOG"; then
	echo "unexpected glbl reference for verilator case" >&2
	exit 1
fi
# No fallback to vivado.
if grep -Eq '^vivado ' "$TOOL_LOG"; then
	echo "unexpected vivado invocation for verilator case" >&2
	exit 1
fi
