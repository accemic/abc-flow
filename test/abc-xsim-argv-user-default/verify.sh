#!/usr/bin/env bash
set -euo pipefail

grep -Fq "xelab -nolog --relax -L uvm -L unisims_ver -L unimacro_ver -L secureip --generic_top TRACE_SOURCE=fallback.bin top_tb glbl -s top_tb" "$TOOL_LOG"
grep -Fq "xsim_file fallback.bin" "$TOOL_LOG"
grep -Fq "xsim_file tb/fallback.bin" "$TOOL_LOG"
