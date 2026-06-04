#!/usr/bin/env bash
set -euo pipefail

xvlog_line="$(grep '^xvlog ' "$TOOL_LOG")"
case "$xvlog_line" in
	*"helper_pkg.sv"*"consumer.sv"*)
		;;
	*)
		echo "expected helper_pkg.sv to be compiled before consumer.sv" >&2
		exit 1
		;;
esac
