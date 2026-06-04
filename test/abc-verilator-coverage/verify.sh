#!/usr/bin/env bash
set -euo pipefail

# Build was instrumented for line coverage.
grep -Eq '^verilator .*--coverage-line' "$TOOL_LOG" \
	|| { echo "expected --coverage-line in verilator compile" >&2; exit 1; }

# Sim was told where to write its per-top coverage data.
grep -Fq 'verilator_sim +verilator+coverage+file+coverage_top_tb.dat' "$TOOL_LOG" \
	|| { echo "expected coverage-file plusarg passed to sim" >&2; exit 1; }

# verilator_coverage post-processing ran: lcov info + annotated source tree.
grep -Eq '^verilator_coverage .*--write-info .*coverage\.info' "$TOOL_LOG" \
	|| { echo "expected verilator_coverage --write-info" >&2; exit 1; }
grep -Eq '^verilator_coverage .*--annotate ' "$TOOL_LOG" \
	|| { echo "expected verilator_coverage --annotate" >&2; exit 1; }

# genhtml is on PATH (stubbed), so an HTML report is rendered.
grep -Eq '^genhtml .*-o .*coverage_html' "$TOOL_LOG" \
	|| { echo "expected genhtml HTML render" >&2; exit 1; }

# Report artifacts landed in the persistent <task>.vsim work dir.
vsim="$REPO/top.vsim"
[[ -f "$vsim/coverage.info" ]]            || { echo "missing coverage.info" >&2; exit 1; }
[[ -f "$vsim/coverage_html/index.html" ]] || { echo "missing coverage_html/index.html" >&2; exit 1; }
