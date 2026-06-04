#!/usr/bin/env bash
set -euo pipefail

# Top, defines and generics make it to the verilator command line.
grep -Eq '^verilator .*--binary .*--top-module props_tb' "$TOOL_LOG"
grep -Fq " -D FLAG=1 " "$TOOL_LOG"
grep -Fq " -G WIDTH=7 " "$TOOL_LOG"
grep -Fq " -G DEPTH=3 " "$TOOL_LOG"

# xsim-only knob must NOT leak through.
if grep -Fq "testplusarg" "$TOOL_LOG"; then
	echo "xsim.simulate.xsim.more_options must not be forwarded under verilator" >&2
	exit 1
fi
# No runtime argv was provided, so the simulator binary must have been
# invoked with no arguments.
grep -Fq "verilator_sim " "$TOOL_LOG"
