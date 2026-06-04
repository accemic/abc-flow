#!/usr/bin/env bash
set -euo pipefail

if [[ -s "$TOOL_LOG" ]]; then
	echo "expected no xsim tool invocations for build-only task" >&2
	exit 1
fi
