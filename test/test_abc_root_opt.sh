#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fixture_repo="$TMP_ROOT/repo"
fixture_out="$TMP_ROOT/out"

mkdir -p "$fixture_repo/tb"
git -C "$fixture_repo" init -q

cat >"$fixture_repo/tb/root_check.abc" <<'EOF'
read_sim root_check_tb.sv
simulate root_check_tb
EOF

cat >"$fixture_repo/tb/root_check_tb.sv" <<'EOF'
module root_check_tb;
endmodule
EOF

"$REPO_ROOT/abc/abc-bundle" "$fixture_repo/tb/root_check" "$fixture_out" >/dev/null

if ! grep -Fq 'exec abc "$@" "-root=$ROOT"' "$fixture_out/run_abc.sh"; then
	echo "expected run_abc.sh to pass -root=\$ROOT" >&2
	exit 1
fi

ABC_DIR="$REPO_ROOT/abc" python3 - <<'PY'
import os
import pathlib
import subprocess
import sys

abc_dir = pathlib.Path(os.environ["ABC_DIR"])
abc_path = abc_dir / "abc"

# The implementation moved into the _abcflow package; load it the same way
# the abc launcher does.
sys.path.insert(0, str(abc_dir))
from _abcflow.core import validate_abc_tcl_args as validate

assert validate(["-new", "-sim", "foo", "-root=."]) == ["-new", "-sim", "foo", "-root=."]
try:
    validate(["-new", "-sim", "foo", "-root", "."])
except ValueError as exc:
    assert "-root must be passed as -root=<value>" in str(exc)
else:
    raise AssertionError("expected bare -root to be rejected")

# Help text must document -root= so users can discover the override.
help_text = subprocess.check_output([str(abc_path), "-h"], text=True)
assert "-root=<DIR>" in help_text, "expected -root=<DIR> in `abc -h` output"
print("ok - abc root option validation")
PY

# Verify the abc.tcl import diagnostic without requiring Vivado: source the
# namespace-eval body in tclsh and exercise import / import_resolution_error.
if command -v tclsh >/dev/null 2>&1; then
	ABC_TCL="$REPO_ROOT/abc/abc.tcl" tclsh - <<'TCL'
set abc_tcl $::env(ABC_TCL)
set fd [open $abc_tcl r]
set src [read $fd]
close $fd

# Extract just the namespace eval abc { ... } block; the trailing driver code
# depends on Vivado-only commands (create_project, quit, ...) and is not what
# we're testing here.
set start [string first "namespace eval abc \{" $src]
if { $start < 0 } { error "could not locate namespace eval abc block" }
# Find the matching closing brace by counting depth from $start.
set depth 0
set i $start
set len [string length $src]
set end -1
while { $i < $len } {
	set ch [string index $src $i]
	if { $ch eq "\{" } { incr depth }
	if { $ch eq "\}" } {
		incr depth -1
		if { $depth == 0 } { set end $i; break }
	}
	incr i
}
if { $end < 0 } { error "could not find end of namespace eval abc block" }
set body [string range $src $start $end]
eval $body

abc::reset /tmp/no/such/root /tmp/proj "reason: -root= override"
set caught [catch { abc::import @missing/leaf } err]
if { !$caught } { error "expected import to fail for missing @-target" }
foreach needle {
	"abc: cannot resolve import '@missing/leaf'"
	"@ anchored at: /tmp/no/such/root"
	"reason: -root= override"
	"Hint: pass -root=<DIR>"
} {
	if { [string first $needle $err] < 0 } {
		puts stderr "missing in error: $needle"
		puts stderr "got: $err"
		exit 1
	}
}
puts "ok - abc.tcl import diagnostic"
TCL
else
	echo "skipping abc.tcl import diagnostic check: tclsh not on PATH" >&2
fi
