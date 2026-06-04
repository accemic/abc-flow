#!/usr/bin/env bash
set -euo pipefail

grep -Fq "xsim -nolog a_basic_tb -R" "$TOOL_LOG"
grep -Fq "vivado -nojournal -nolog -mode tcl" "$TOOL_LOG"
grep -Fq "$REPO/test/b_ip.abc" "$TOOL_LOG"

xsim_line="$(grep -n 'xsim -nolog a_basic_tb -R' "$TOOL_LOG" | head -n1 | cut -d: -f1)"
vivado_line="$(grep -n 'vivado -nojournal -nolog -mode tcl' "$TOOL_LOG" | head -n1 | cut -d: -f1)"
if [[ -z "$xsim_line" || -z "$vivado_line" || "$xsim_line" -ge "$vivado_line" ]]; then
	echo "expected plain xsim task to run before vivado fallback task" >&2
	exit 1
fi
