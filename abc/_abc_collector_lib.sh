# Shared bash helpers for the abc-export and abc-bundle collectors.
#
# Source from a sibling script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/_abc_collector_lib.sh"
#
# All functions take the calling script's tool name (e.g. "abc-export")
# as an argument so error messages identify the right command.

# Resolve the project root for `input` (the `.abc` task path).
#
# Priority:
#   1. `root_override` if non-empty.
#   2. The git toplevel containing the input.
#   3. The input's directory.
#
# Writes the absolute, normalised root to stdout.
abc_collector_detect_root() {
	local input="$1"
	local root_override="${2:-}"
	local input_hint="$input"
	local input_dir
	local root

	if [[ ! -e "$input_hint" && -e "$input_hint.abc" ]]; then
		input_hint="$input_hint.abc"
	fi
	input_dir="$(cd "$(dirname "$input_hint")" && pwd)"

	if [[ -n "$root_override" ]]; then
		root="$(cd "$root_override" && pwd)"
	elif root=$(git -C "$input_dir" rev-parse --show-toplevel 2>/dev/null); then
		root="$(cd "$root" && pwd)"
	else
		root="$input_dir"
	fi

	printf '%s\n' "$root"
}

# Verify that a tclsh binary is on PATH (or pointed at by the caller's
# $TCLSH variable). Exits the script with code 2 if not. Echoes the
# resolved tclsh path to stdout so the caller can capture it.
abc_collector_require_tclsh() {
	local tool_name="$1"
	local tclsh="${TCLSH:-tclsh}"
	if ! command -v "$tclsh" >/dev/null 2>&1; then
		echo "ERROR: $tool_name: '$tclsh' not found in PATH (set TCLSH=... if needed)" >&2
		exit 2
	fi
	printf '%s\n' "$tclsh"
}

# Create a temp `.tcl` file with a tool-flavoured prefix and register a
# trap that removes it on exit. The path is echoed to stdout.
#
# Caller usage:
#   TMP_TCL="$(abc_collector_mktemp_tcl abc_export)"
abc_collector_mktemp_tcl() {
	local tag="$1"
	local tmp
	tmp="$(mktemp -t "${tag}_XXXXXX.tcl")"
	# shellcheck disable=SC2064  # intentional: capture $tmp now, not at trap time
	trap "rm -f '$tmp'" EXIT
	printf '%s\n' "$tmp"
}
