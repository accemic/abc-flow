#!/usr/bin/env bash
set -euo pipefail

grep -Fq "$REPO/tb/props_tb.sv" "$TOOL_LOG"
grep -Fq "xvlog -nolog --relax -L uvm -d FLAG=1 -sv" "$TOOL_LOG"
grep -Fq "xelab -nolog --relax -L uvm -L unisims_ver -L unimacro_ver -L secureip --generic_top WIDTH=7 --generic_top DEPTH=3 props_tb glbl -s props_tb" "$TOOL_LOG"
grep -Fq "xsim -nolog props_tb -testplusarg CYCLES=42 -R" "$TOOL_LOG"
