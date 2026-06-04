#!/usr/bin/env bash
set -euo pipefail

grep -Fq "core.sv" "$TOOL_LOG"
grep -Fq "synth_wrapper.sv" "$TOOL_LOG"
grep -Fq "wrapper_tb.sv" "$TOOL_LOG"
grep -Fq "$REPO/rtl/core.sv" "$TOOL_LOG"
grep -Fq "$REPO/rtl/synth_wrapper.sv" "$TOOL_LOG"
grep -Fq "$REPO/tb/wrapper_tb.sv" "$TOOL_LOG"
grep -Fq "xvlog -nolog --relax -L uvm -sv" "$TOOL_LOG"
grep -Fq "glbl.v" "$TOOL_LOG"
grep -Fq "xelab -nolog --relax -L uvm -L unisims_ver -L unimacro_ver -L secureip wrapper_tb glbl -s wrapper_tb" "$TOOL_LOG"
grep -Fq "xsim -nolog wrapper_tb -R" "$TOOL_LOG"
if grep -Fq "xelab -nolog synth_wrapper -s synth_wrapper" "$TOOL_LOG"; then
	echo "unexpected synthesis top elaboration in xsim backend" >&2
	exit 1
fi
if grep -Fq "xsim -nolog synth_wrapper -R" "$TOOL_LOG"; then
	echo "unexpected synthesis top simulation in xsim backend" >&2
	exit 1
fi
if grep -Fq "/export/" "$TOOL_LOG"; then
	echo "unexpected exported temp path in tool log" >&2
	exit 1
fi
