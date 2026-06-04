#!/usr/bin/env bash
set -euo pipefail

verilator_line="$(grep '^verilator ' "$TOOL_LOG")"
case "$verilator_line" in
	*"base_pkg.sv"*"dep_pkg.sv"*"consumer.sv"*)
		;;
	*)
		echo "expected base_pkg.sv to precede dep_pkg.sv and consumer.sv on the verilator command line" >&2
		echo "got: $verilator_line" >&2
		exit 1
		;;
esac
