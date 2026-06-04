#!/usr/bin/env bash
set -euo pipefail

xvlog_line="$(grep '^xvlog ' "$TOOL_LOG")"
case "$xvlog_line" in
	*"base_pkg.sv"*"dep_pkg.sv"*"consumer.sv"*)
		;;
	*)
		echo "expected base_pkg.sv to compile before dep_pkg.sv and consumer.sv" >&2
		exit 1
		;;
esac
