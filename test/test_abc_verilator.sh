#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/abc/abc"
TEST_ROOT="$REPO_ROOT/test"
TMP_ROOT="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
	echo "    $*" >&2
	return 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local label="${3:-values}"
	if [[ "$expected" != "$actual" ]]; then
		printf '    mismatch for %s\n' "$label" >&2
		printf '    expected:\n%s\n' "$expected" >&2
		printf '    actual:\n%s\n' "$actual" >&2
		return 1
	fi
}

check_contains_file() {
	local needles_file="$1"
	local target="$2"
	local needle

	while IFS= read -r needle || [[ -n "$needle" ]]; do
		[[ -z "$needle" || "$needle" == \#* ]] && continue
		grep -Fq -- "$needle" "$target" || fail "expected '$needle' in $target"
	done < "$needles_file"
}

copy_repo_fixture() {
	local source_dir="$1"
	local dest_dir="$2"

	mkdir -p "$dest_dir"
	cp -R "$source_dir"/. "$dest_dir"
	git -C "$dest_dir" init -q
}

# Build a stub Verilator that records its argv and synthesizes a fake
# binary in -Mdir/<-o name> so the launcher can invoke it as a "simulation".
setup_stub_verilator() {
	local tool_root="$1"

	mkdir -p "$tool_root/bin"
	cat >"$tool_root/bin/verilator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verilator %s\n' "$*" >>"$ABC_TOOL_LOG"
obj_dir=""
out_name=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-Mdir)
			obj_dir="$2"; shift 2;;
		-o)
			out_name="$2"; shift 2;;
		*)
			shift;;
	esac
done
if [[ -n "$obj_dir" && -n "$out_name" ]]; then
	mkdir -p "$obj_dir"
	cat >"$obj_dir/$out_name" <<'BIN'
#!/usr/bin/env bash
set -euo pipefail
printf 'verilator_sim %s\n' "$*" >>"$ABC_TOOL_LOG"
printf 'verilator_sim_cwd %s\n' "$PWD" >>"$ABC_TOOL_LOG"
# Emulate a testbench writing an output dump into its run cwd, so tests
# can assert the file persists after the run.
echo "stub-dump" > "$PWD/sim_dump.out"
find . -maxdepth 3 \( -type f -o -type l \) | LC_ALL=C sort \
	| sed 's#^\./#verilator_sim_file #' >>"$ABC_TOOL_LOG"
echo "stub verilator sim ok"
BIN
	chmod +x "$obj_dir/$out_name"
fi
EOF
	chmod +x "$tool_root/bin/verilator"
}

run_case() {
	(
		set -euo pipefail

		local case_dir="$1"
		local case_name
		local expected_dir
		local work_dir
		local repo_dir
		local tool_root
		local stdout_file
		local stderr_file
		local tool_log
		local status

		case_name="$(basename "$case_dir")"
		expected_dir="$case_dir/expected"
		work_dir="$TMP_ROOT/$case_name"
		repo_dir="$work_dir/repo"
		tool_root="$work_dir/tools"
		stdout_file="$work_dir/stdout.txt"
		stderr_file="$work_dir/stderr.txt"
		tool_log="$work_dir/tool.log"

		unset ABC_CALL EXPECT_EXIT_CODE WITH_VERILATOR
		ABC_CALL=()
		EXPECT_EXIT_CODE=0
		WITH_VERILATOR=1
		REPO="$repo_dir"
		TOOL_ROOT="$tool_root"
		STDOUT_FILE="$stdout_file"
		STDERR_FILE="$stderr_file"
		TOOL_LOG="$tool_log"

		# shellcheck source=/dev/null
		source "$case_dir/case.conf"

		if [[ ${#ABC_CALL[@]} -eq 0 ]]; then
			fail "missing ABC_CALL in $case_name/case.conf"
		fi

		copy_repo_fixture "$case_dir/repo" "$repo_dir"
		setup_stub_verilator "$tool_root"
		: >"$tool_log"

		# A minimal PATH that contains the stub verilator (when enabled) and
		# the essentials needed by abc-export's Tcl interpreter; deliberately
		# *no* Vivado so we exercise the no-Vivado guarantee.
		local case_path
		if [[ "$WITH_VERILATOR" == "1" ]]; then
			case_path="$tool_root/bin:/usr/bin:/bin"
		else
			case_path="/usr/bin:/bin"
		fi

		# Run from inside the fixture repo so a project .abc.config at the
		# repo root is discovered (matches how users invoke abc from a repo
		# subdir). Absolute paths above are unaffected.
		cd "$repo_dir"

		set +e
		env -i HOME="$HOME" PATH="$case_path" \
			ABC_TOOL_LOG="$tool_log" \
			"$SCRIPT" "${ABC_CALL[@]}" >"$stdout_file" 2>"$stderr_file"
		status=$?
		set -e

		assert_eq "$EXPECT_EXIT_CODE" "$status" "$case_name exit code"

		if [[ -f "$expected_dir/stdout.contains.txt" ]]; then
			check_contains_file "$expected_dir/stdout.contains.txt" "$stdout_file"
		fi
		if [[ -f "$expected_dir/stderr.contains.txt" ]]; then
			check_contains_file "$expected_dir/stderr.contains.txt" "$stderr_file"
		fi

		if [[ -f "$case_dir/verify.sh" ]]; then
			CASE_DIR="$case_dir" REPO="$repo_dir" WORK_DIR="$work_dir" \
			STDOUT_FILE="$stdout_file" STDERR_FILE="$stderr_file" TOOL_LOG="$tool_log" \
				bash "$case_dir/verify.sh"
		fi
	)
}

run_test() {
	local case_dir="$1"
	local case_name
	local status
	case_name="$(basename "$case_dir")"

	set +e
	run_case "$case_dir"
	status=$?
	set -e

	if [[ $status -eq 0 ]]; then
		echo "ok - $case_name"
		PASS_COUNT=$((PASS_COUNT + 1))
	else
		echo "not ok - $case_name"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
}

main() {
	local case_dir

	for case_dir in "$TEST_ROOT"/abc-verilator-*; do
		[[ -d "$case_dir" ]] || continue
		run_test "$case_dir"
	done

	echo
	echo "Passed: $PASS_COUNT"
	echo "Failed: $FAIL_COUNT"

	[[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
