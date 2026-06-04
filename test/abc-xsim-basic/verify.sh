#!/usr/bin/env bash
set -euo pipefail

grep -Fq "core.sv" "$TOOL_LOG"
grep -Fq "generated.sv" "$TOOL_LOG"
grep -Fq "helper_pkg.sv" "$TOOL_LOG"
grep -Fq "top_tb.sv" "$TOOL_LOG"
grep -Fq "$REPO/rtl/core.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/generated.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/helper_pkg.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/top_tb.sv" "$TOOL_LOG"
grep -Fq "xvlog -nolog --relax -L uvm -sv" "$TOOL_LOG"
grep -Fq "glbl.v" "$TOOL_LOG"
grep -Fq "xelab -nolog --relax -L uvm -L unisims_ver -L unimacro_ver -L secureip top_tb glbl -s top_tb" "$TOOL_LOG"
grep -Fq "xsim -nolog top_tb -R" "$TOOL_LOG"
grep -Fq "xsim_file payload.bin" "$TOOL_LOG"
grep -Fq "xsim_file tb/payload.bin" "$TOOL_LOG"
if grep -Fq "/export/" "$TOOL_LOG"; then
	echo "unexpected exported temp path in tool log" >&2
	exit 1
fi
