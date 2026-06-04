#!/usr/bin/env bash
set -euo pipefail

# Backend came from .abc.config: direct xsim tools must have run.
grep -Fq "xvlog -nolog --relax -L uvm -sv" "$TOOL_LOG"
grep -Fq "xsim -nolog top_tb -R" "$TOOL_LOG"
