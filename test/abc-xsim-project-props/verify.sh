#!/usr/bin/env bash
set -euo pipefail

grep -Fq "$REPO/tb/synth_top.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/top_tb.sv" "$TOOL_LOG"
grep -Fq "xelab -nolog --relax -L uvm -L unisims_ver -L unimacro_ver -L secureip top_tb glbl -s top_tb" "$TOOL_LOG"
grep -Fq "xsim -nolog top_tb -R" "$TOOL_LOG"
if grep -Fq "vivado -nojournal -nolog -mode tcl" "$TOOL_LOG"; then
	echo "unexpected vivado fallback for benign project-level properties" >&2
	exit 1
fi
