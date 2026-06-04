#!/usr/bin/env bash
set -euo pipefail

grep -Fq "vivado -nojournal -nolog -mode tcl" "$TOOL_LOG"
grep -Fq "$REPO/tb/top.abc" "$TOOL_LOG"
if grep -Eq '^xvlog |^xelab |^xsim ' "$TOOL_LOG"; then
	echo "expected no direct xsim tool invocations for IP fallback case" >&2
	exit 1
fi
