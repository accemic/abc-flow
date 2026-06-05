#############################################################################
# abc.tcl - run simulation/synthesis through .abc file(s)
#
# Copyright (c) 2018-2026 Accemic Technologies GmbH
#
# Usage:
#   vivado -mode tcl -source abc.tcl -tclargs [OPTIONS] -tclargs [FILES ...]
#
# Options:
#   -new                  Create a new vivado project, instead of reusing the existing one.
#   -sim                  Run simulation.
#   -synth                Run synthesis.
#   -netlist              Run synthesis and export netlist.
#   -impl                 Run implementation.
#   -bitgen               Generate bitfile.
#   -root=<CUSTOM-ROOT>   Custom root dir for @DIR resolution. Defaults to git root. Required if no git is used.
#
# By default, FPGA 'xczu19eg-ffvb1517' is chosen as project part.
#   -11eg        Use xczu11eg-ffvb1517 instead.
#   -7ev         Use xczu7ev-ffvc1156-2-i
#   -7ev1517     Use xczu7ev-ffvf1517-1-e
#   -xc7         Use xc7v585tffg1761 instead.
#############################################################################

variable version 0.0.1

namespace eval abc {
	namespace export resolve import constraints read_sv read_sim simulate synthesize dump_errors

	variable anchor ""
	variable anchor_reason ""
	variable at_origin {}
	variable proj_dir ""
	variable seen_srcs {}

	variable do_sim			0
	variable the_build		{}
	variable do_netlist		0
	variable do_bitgen		0
	variable custom_root	""
	variable all_errors		{}

	proc extract_flag {lst flag action} {
		upvar $lst l
		while { [set idx [lsearch $l $flag]] >= 0 } {
			set l [lreplace $l $idx $idx]
			uplevel $action
		}
	}

	proc extract_opt {lst option_prefix varname} {
		upvar $lst l
		upvar $varname var
		set pattern "${option_prefix}="
		foreach item $l {
			if {[string match "${pattern}*" $item]} {
				# Ensure there is a value after the '='
				if {[string length $item] == [string length $pattern]} {
					error "Option $option_prefix requires a value after '='."
				}
				set var [string range $item [string length $pattern] end]
				set l [lreplace $l [lsearch $l $item] [lsearch $l $item]]
				return
			} elseif {[string match "${option_prefix}" $item]} {
				error "Option $option_prefix requires an '=' followed by a value."
			}
		}
	}

	proc parse_args {argv} {
		upvar $argv args
		extract_flag args -sim		{ set abc::do_sim 1 }
		extract_flag args -synth	{ set abc::the_build synthesis }
		extract_flag args -netlist	{ set abc::the_build synthesis; set abc::do_netlist 1 }
		extract_flag args -impl		{ set abc::the_build implementation }
		extract_flag args -bitgen	{ set abc::the_build implementation; set abc::do_bitgen 1 }
	}

	proc reset {_anchor _proj_dir {_anchor_reason ""}} {
		variable anchor
		variable anchor_reason
		variable at_origin
		variable seen_srcs
		variable proj_dir
		set anchor $_anchor
		set anchor_reason $_anchor_reason
		set at_origin {}
		set proj_dir $_proj_dir
		set seen_srcs {}
	}

	#------------------------------------------------------------------------
	# Tries to determine the number of processors
	proc get_number_of_processors {} {
		global tcl_platform
		set cores {}
		switch $tcl_platform(os) {
			Linux {
				if {![catch {open /proc/cpuinfo} fd]} {
					set cores [regexp -all -line {^processor\s:} [read $fd]]
					close $fd
				}
			}
			Windows {
				global env
				set cores $env(NUMBER_OF_PROCESSORS)
			}
		}
		return [expr {$cores > 0? $cores : 1}]
	}
	variable jobs [expr {max(1,int(.8*[get_number_of_processors]))}]

	#------------------------------------------------------------------------
	# Appends all `args` to the list `lst` that have not been in the list
	# before and returns a list of the actually added elements.
	proc lappend_unique {lst args} {
		upvar $lst l
		set beg [llength $l]
		foreach arg $args {
			if {[lsearch $l $arg] < 0} { lappend l $arg }
		}
		return [lrange $l $beg end]
	}

	#------------------------------------------------------------------------
	# Resolves the passed list of paths to absolute representations relative
	# to the current working directory. Also:
	#	- A path starting with '@' is anchored at path in `anchor`.
	#	- A path of ':' removes the preceding path from the list and uses it
	#	  as a prefix for all subsequent ones.
	proc resolve {args} {
		variable anchor
		variable at_origin

		set deps {}
		set prefix ""
		foreach dep $args {
			if { $dep == ":" } {
				set prefix [lindex $deps end]
				set deps [lrange $deps 0 end-1]
			} else {
				set orig $dep
				set pre $prefix
				if { [string first @ $dep] == 0 } {
					set pre $anchor
					set dep [string range $dep 1 end]
				}
				set resolved [file normalize [file join $pre $dep]]
				# Remember the user-written form for diagnostics (first writer wins).
				if { ![dict exists $at_origin $resolved] } {
					dict set at_origin $resolved $orig
				}
				lappend deps $resolved
			}
		}
		return $deps
	}

	#------------------------------------------------------------------------
	# `import` Command for Dependency Traversal
	proc import {args} {
		variable seen_srcs
		variable anchor
		variable anchor_reason
		variable at_origin

		# Process only new unique build constraints
		foreach dep [resolve {*}$args] {
			if {[llength [lappend_unique seen_srcs $dep]]} {
				set save_dir [pwd]
				set ref [file tail [file rootname $dep]]
				set dir [file dirname $dep]
				set abc_file [file join $dir "$ref.abc"]
				set orig [expr {[dict exists $at_origin $dep] ? [dict get $at_origin $dep] : $dep}]

				if { ![file isdirectory $dir] } {
					error [import_resolution_error $orig $dep "directory does not exist: $dir"]
				}
				if { ![file isfile $abc_file] } {
					error [import_resolution_error $orig $dep "no such file: $abc_file"]
				}

				cd $dir
				source $ref.abc
				cd $save_dir
			}
		}
	}

	# Build a focused error for failed @-imports. The user typically just sees
	# a Tcl stack trace; this surfaces the active root, where it came from, and
	# how to override it.
	proc import_resolution_error {orig resolved detail} {
		variable anchor
		variable anchor_reason

		set lines {}
		lappend lines "abc: cannot resolve import '$orig': $detail"
		lappend lines "  resolved to: $resolved"
		if { [string first @ $orig] == 0 } {
			set reason_str [expr {$anchor_reason ne "" ? " ($anchor_reason)" : ""}]
			lappend lines "  @ anchored at: $anchor$reason_str"
			lappend lines "  Hint: pass -root=<DIR> to anchor @-prefixed imports at a different directory"
			lappend lines "        (e.g. when @modules/... lives under a sub-tree of the repo)."
		}
		return [join $lines "\n"]
	}

	#----------------------------------------------------------------------------
	# Adding Constraints
	#	- Constraints are bound to the currently loading module unless the '-top'
	#	  switch is provided.
	#	- The flags 'impl' or 'synth' may be used to restrict the applicability
	#	  of the added constraints to synthesis or implementation, respectively.
	proc constraints {args} {
		upvar ref ref
		set used "synthesis implementation"
		set reff "-ref $ref"
		while {[llength $args] > 0} {
			switch "[lindex $args 0]" {
				-top	{ set args [lreplace $args 0 0]; set reff {} }
				impl	{ set args [lreplace $args 0 0]; set used "implementation" }
				synth	{ set args [lreplace $args 0 0]; set used "synthesis" }
				default {
					set_property USED_IN "$used" [get_files [read_xdc {*}[concat -unmanaged $reff $args]]]
					return
				}
			}
		}
	}

	#----------------------------------------------------------------------------
	# Convenience Shorthands for File Inclusion
	proc read_sv {args} {
		return [read_verilog -sv {*}$args]
	}

	proc read_sim {args} {
		return [add_files -fileset [current_fileset -simset] {*}$args]
	}

	#----------------------------------------------------------------------------
	# Convenience Shorthands for Runs
	proc simulate {tb} {
		set_property top $tb [current_fileset -simset]

		variable do_sim
		if { $do_sim } {
			set_property -name {xsim.simulate.runtime} -value {all} -objects [current_fileset -simset]
			launch_simulation
			close_sim -force

			variable proj_dir
			set log [glob -nocomplain [file join $proj_dir {*.sim} {*} behav xsim simulate.log]]
			if { [llength $log] } {
				set log [open $log]
				set errors [regexp -inline -all -line -nocase {^(?:error:|fatal:).*$} [read $log]]
				close $log
				if { [llength $errors] } {
					variable all_errors
					lappend all_errors $tb:
					foreach error $errors { lappend all_errors "\t$error" }
				}
			} else {
				variable all_errors
				lappend all_errors $tb: "Error: Found no simulation log."
			}
		}
	}

	proc build {top} {
		set_property top $top [current_fileset]

		set_msg_config -quiet -id {[Synth 8-2244]} -suppress
		set_msg_config -quiet -id {[Synth 8-2898]} -suppress

		variable the_build
		if { [llength $the_build] } {
			variable jobs
			variable do_netlist
			variable do_bitgen

			set run [current_run "-$the_build"]

			if { $do_netlist } {
				set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects $run
			}

			launch_run $run -jobs $jobs
			wait_on_run $run

			variable proj_dir
			if { ($the_build eq "synthesis") && $do_netlist } {
				open_run $run
				write_verilog -mode design -cell $top -force [file join $proj_dir ${top}_netlist.v]
			}

			if { ($the_build eq "implementation") } {
				open_run $run
				report_utilization -file [file join $proj_dir $top.rpt] -hierarchical

				if { $do_bitgen } {
					set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
					write_bitstream    -force -bin_file [file join $proj_dir $top.bit]
					write_debug_probes -force           [file join $proj_dir $top.ltx]
					write_hw_platform  -fixed -force -file [file join $proj_dir $top.xsa]
				}
			}

			set log [glob -nocomplain [file join $proj_dir {*.runs} $run runme.log]]
			if { [llength $log] } {
				set log [open $log]
				set errors [regexp -inline -all -line -nocase {^(?:error:|fatal:).*$} [read $log]]
				close $log
				if { [llength $errors] } {
					variable all_errors
					lappend all_errors $top:
					foreach error $errors { lappend all_errors "\t$error" }
				}
			} else {
				variable all_errors
				lappend all_errors $tb: "Error: Found no run log."
			}
		}
	}

	#----------------------------------------------------------------------------
	# Dumping Errors
	proc dump_errors {} {
		variable all_errors
		if { [llength $all_errors] } {
			puts [join $all_errors "\n"]
		} else {
			puts "No errors encountered."
		}
	}
}
namespace import abc::*

puts "abc Version: $version"
puts "#####################"

# Disable WebTalk by default for this user when running through abc-flow.
# This is best-effort because some license/device combinations can override it.
catch {config_webtalk -user off -quiet}

set argv_user {}
set idx [lsearch $argv --]
if { $idx >= 0 } {
	set argv_user [lrange $argv [expr {$idx+1}] end]
	set argv [lrange $argv 0 [expr {$idx-1}]]
}

abc::parse_args argv

set new 0; abc::extract_flag argv -new { set new 1 }
set gui 0; abc::extract_flag argv -gui { set gui 1 }
set do_11eg	0; abc::extract_flag argv -11eg { set do_11eg 1 }
set do_7ev	0; abc::extract_flag argv -7ev { set do_7ev 1 }
set do_7ev1517	0; abc::extract_flag argv -7ev1517 { set do_7ev1517 1 }
set do_xc7	0; abc::extract_flag argv -xc7 { set do_xc7 1 }
set custom_root	""; abc::extract_opt argv -root custom_root

set tasks {}
foreach arg $argv {
	if { [file isfile "$arg"] } {
		lappend tasks $arg
	} elseif { [file isfile "$arg.abc"] } {
		lappend tasks $arg
	} elseif { [file isdirectory $arg] } {
		set dirs "$arg"
		while {[llength $dirs]} {
			set dir [lindex $dirs 0]
			set dirs [lreplace $dirs 0 0 {*}[glob -nocomplain -directory $dir -types d *]]
			if { [lsearch -exact [file split $dir] test] >= 0 } {
				foreach proj [glob -nocomplain -directory $dir -types f *.abc] {
					lappend tasks [file rootname $proj]
				}
			}
		}
	} else {
		puts "Error: File or directory not found '$arg'"
		exit 1
	}
}
puts "\n[string repeat = 78]\nTask List:\n [join $tasks "\n "]\n"


if {[info exists custom_root] && $custom_root ne ""} {
	set root [file normalize $custom_root]
	set root_reason "reason: -root= override"
} else {
	if {[catch {set root [exec git rev-parse --show-toplevel]}]} {
		puts "Error: Not in a Git repository. Please use the -root=<DIR> flag to specify the root directory."
		exit 1
	}
	set root_reason "reason: git rev-parse --show-toplevel"
}
puts "abc: using root $root ($root_reason)"

foreach task $tasks {
	puts -nonewline "\n[string repeat {#} 78]\n# Running $task"
	if { $abc::do_sim } { puts -nonewline " -sim" }
	if { $new         } { puts -nonewline " -new" }
	if { $do_11eg     } { puts -nonewline " -11eg" }
	if { $do_7ev      } { puts -nonewline " -7ev" }
	if { $do_7ev1517  } { puts -nonewline " -7ev1517" }
	if { $do_xc7      } { puts -nonewline " -xc7" }
	puts ""

	set top [file tail $task]
	set dir [file normalize $top.vivado]
	set xpr [file join $dir $top.xpr]

	# Rebuild exisiting project or create a new one
	if { !$new && [file isfile "$xpr"] } {
		# Strip existing project of all sources BUT:
		#	- *managed* constraints, and
		#	- waveforms.
		open_project "$xpr"
		remove_files -quiet [get_files -filter {FILE_TYPE != {XDC} && FILE_TYPE != {Waveform Configuration File}}]
	} else {
		if { $do_11eg } {
			create_project -force -part xczu11eg-ffvb1517-1-e $top $dir
		} elseif { $do_7ev } {
			create_project -force -part xczu7ev-ffvc1156-2-i $top $dir
		} elseif { $do_7ev1517 } {
			create_project -force -part xczu7ev-ffvf1517-1-e $top $dir
		} elseif { $do_xc7 } {
			create_project -force -part xc7v585tffg1761-1 $top $dir
		} else {
			create_project -force -part xczu19eg-ffvb1517-1-e $top $dir
		}
		set target_xdc [file join $dir target.xdc]
		close [open $target_xdc w]
		add_files -fileset [current_fileset -constrset] $target_xdc
		set_property target_constrs_file $target_xdc [current_fileset -constrset]
	}

	abc::reset $root $dir $root_reason

	set TIME_start [clock seconds]
	import $task
	set TIME_taken [expr [clock seconds] - $TIME_start]
	puts "\n[string repeat {#} 78]\n# Finished $task in $TIME_taken seconds"
	puts "\n[string repeat {#} 78]\n"

	if { $gui } {
		set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [current_fileset -simset]
		start_gui
		return
	}

	close_project
}

dump_errors

quit
