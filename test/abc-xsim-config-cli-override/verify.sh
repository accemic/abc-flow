#!/usr/bin/env bash
set -euo pipefail

# Explicit --sim-backend vivado wins over the config default: the Vivado
# project flow must run, and no direct xsim tools.
grep -Fq "vivado -nojournal -nolog -mode tcl" "$TOOL_LOG"
grep -Fq "$REPO/tb/top.abc" "$TOOL_LOG"
if grep -Eq '^xvlog |^xelab |^xsim ' "$TOOL_LOG"; then
	echo "expected no direct xsim tool invocations when overriding to vivado" >&2
	exit 1
fi
