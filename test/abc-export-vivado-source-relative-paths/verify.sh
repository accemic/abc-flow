#!/usr/bin/env bash
set -euo pipefail

run_dir="$WORK_DIR/vivado-check/run"
tmp_dir="$WORK_DIR/vivado-check/tmp"

mkdir -p "$run_dir" "$tmp_dir"

cat >"$run_dir/check.tcl" <<'TCL'
set ::temp_dir [file normalize [file join [pwd] .. tmp]]
set ::calls {}

proc current_fileset {args} {
    return sim_1
}

proc read_verilog {args} {
    set path [lindex $args end]
    if {![file exists $path]} {
        error "read_verilog missing file: $path"
    }
    lappend ::calls [list read_verilog {*}$args]
    cd $::temp_dir
    return ""
}

proc add_files {args} {
    set path [lindex $args end]
    if {![file exists $path]} {
        error "add_files missing file: $path"
    }
    lappend ::calls [list add_files {*}$args]
    return ""
}

proc read_xdc {args} {
    error "unexpected read_xdc call"
}

proc set_property {args} {
    return ""
}

proc get_files {args} {
    return ""
}

source ../../export/add_to_vivado.tcl

if {[llength $::calls] != 2} {
    error "expected 2 tool calls, got [llength $::calls]"
}
if {[lindex [lindex $::calls 0] 0] ne "read_verilog"} {
    error "first call was not read_verilog"
}
if {[lindex [lindex $::calls 1] 0] ne "add_files"} {
    error "second call was not add_files"
}
TCL

(
	cd "$run_dir"
	tclsh check.tcl >/dev/null
)
