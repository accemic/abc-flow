# Shared Tcl preamble for the abc-export and abc-bundle collectors.
#
# Both scripts build a sandboxed Tcl interpreter that sources `.abc`
# files and observes what they reference. The pieces below are the ones
# that are byte-identical between the two collectors (a few procs on the
# `::abc` namespace, the `::abc_py` stub namespace, and the stdout-clean
# `::puts` override).
#
# Tool-specific bits (state vars, the per-recording procs, the
# `::source` / `::exec` overrides, CLI parsing) live in the calling
# script's own heredoc that gets concatenated after this file.
#
# Convention: the caller MUST set `::abc::tool_name` (e.g. "abc-export")
# before anything that could call `die` or surface user-visible errors.

namespace eval abc {
	variable tool_name "abc"
	variable anchor ""
	variable errors {}

	proc die {msg} {
		variable tool_name
		puts stderr "ERROR: $tool_name: $msg"
		exit 2
	}
	proc add_error {msg} { variable errors; lappend errors $msg }
	proc has_errors {} { variable errors; expr {[llength $errors] > 0} }
	proc dump_errors {} {
		variable errors
		foreach e $errors { puts stderr "  - $e" }
	}

	proc git_root {} {
		if {[catch {exec git rev-parse --show-toplevel} root]} {
			die "Not in git; pass --root"
		}
		return [file normalize $root]
	}

	# `resolve` implements the `.abc`-side path-list syntax: a `:` token
	# uses the preceding element as a path prefix for the rest, and an
	# `@`-anchored path is rebased onto the project root (`anchor`).
	proc resolve {args} {
		variable anchor
		set deps {}
		set prefix ""
		foreach dep $args {
			if { $dep == ":" } {
				set prefix [lindex $deps end]
				set deps [lrange $deps 0 end-1]
			} else {
				set pre $prefix
				if { [string first @ $dep] == 0 } {
					set pre $anchor
					set dep [string range $dep 1 end]
				}
				lappend deps [file normalize [file join $pre $dep]]
			}
		}
		return $deps
	}

	# Return `abs` relative to the project root when it lives inside it,
	# else the absolute path verbatim. Used when emitting record lines so
	# downstream consumers see repo-relative paths whenever possible.
	proc relpath_or_abs {abs} {
		variable anchor
		set root [file normalize $anchor]
		set p [file normalize $abs]
		set rootp $root
		if {![string match "*/" $rootp]} { append rootp "/" }
		if {[string first $rootp $p] == 0} {
			return [string range $p [string length $rootp] end]
		}
		return $p
	}
}

# Some `.abc` files probe for a Python helper namespace; stub it out so
# they execute under the collectors without side effects.
namespace eval abc_py {
	proc require_module {module_name} { return {python3} }
	proc find_python_cmd_for_module {module_name} { return {python3} }
	proc find_python_cmd {} { return {python3} }
	proc python_module_cmd {module_name} { return [list python3 -m $module_name] }
	proc has_module {module_name} { return 0 }
}

# Keep stdout clean for the records the script emits via ::tcl_puts:
# absorb every `puts` from a sourced `.abc` and only pass through
# explicit `puts stderr ...` calls.
if {[llength [info commands ::tcl_puts]] == 0} { rename ::puts ::tcl_puts }
proc ::puts {args} {
	if {[llength $args] >= 2 && [lindex $args 0] eq "stderr"} {
		return [::tcl_puts stderr [lindex $args 1]]
	}
	return ""
}
