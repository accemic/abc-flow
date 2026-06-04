#!/usr/bin/env bash
set -euo pipefail

# abc was invoked from the repo root, so the work dir is <task>.vsim there.
work_dir="$REPO/top.vsim"

# The work dir, the built sim binary, and the testbench's output dump must
# all survive the run (no auto-cleanup of the temp dir anymore).
test -d "$work_dir" || { echo "work dir $work_dir missing after run" >&2; exit 1; }
test -x "$work_dir/obj_top_tb/top_tb" || { echo "sim binary missing" >&2; exit 1; }
test -f "$work_dir/sim_dump.out" || { echo "sim output dump did not persist" >&2; exit 1; }
