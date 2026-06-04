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

setup_stub_toolchain() {
	local tool_root="$1"

	mkdir -p "$tool_root/2024.1/bin"
	mkdir -p "$tool_root/2024.1/data/verilog/src"

	cat >"$tool_root/2024.1/bin/vivado" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == "-version" ]]; then
	echo "Vivado v2024.1 (64-bit)"
	exit 0
fi
printf 'vivado %s\n' "$*" >>"$ABC_TOOL_LOG"
EOF

	cat >"$tool_root/2024.1/bin/xvlog" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xvlog %s\n' "$*" >>"$ABC_TOOL_LOG"
EOF

	cat >"$tool_root/2024.1/bin/xelab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xelab %s\n' "$*" >>"$ABC_TOOL_LOG"
EOF

	cat >"$tool_root/2024.1/bin/xsim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xsim %s\n' "$*" >>"$ABC_TOOL_LOG"
printf 'xsim_cwd %s\n' "$PWD" >>"$ABC_TOOL_LOG"
find . -maxdepth 3 \( -type f -o -type l \) | LC_ALL=C sort | sed 's#^\./#xsim_file #' >>"$ABC_TOOL_LOG"
echo "stub xsim ok"
EOF

	cat >"$tool_root/2024.1/data/verilog/src/glbl.v" <<'EOF'
module glbl;
endmodule
EOF

	chmod +x "$tool_root/2024.1/bin"/vivado \
		"$tool_root/2024.1/bin"/xvlog \
		"$tool_root/2024.1/bin"/xelab \
		"$tool_root/2024.1/bin"/xsim
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

		unset ABC_XSIM_CALL EXPECT_EXIT_CODE
		ABC_XSIM_CALL=()
		EXPECT_EXIT_CODE=0
		REPO="$repo_dir"
		TOOL_ROOT="$tool_root"
		STDOUT_FILE="$stdout_file"
		STDERR_FILE="$stderr_file"
		TOOL_LOG="$tool_log"

		# shellcheck source=/dev/null
		source "$case_dir/case.conf"

		if [[ ${#ABC_XSIM_CALL[@]} -eq 0 ]]; then
			fail "missing ABC_XSIM_CALL in $case_name/case.conf"
		fi

		copy_repo_fixture "$case_dir/repo" "$repo_dir"
		setup_stub_toolchain "$tool_root"
		: >"$tool_log"

		# Run from inside the fixture repo so a project .abc.config at the
		# repo root is discovered. Absolute paths above are unaffected.
		cd "$repo_dir"

		set +e
		ABC_VIVADO_ROOTS="$tool_root" \
		ABC_TOOL_LOG="$tool_log" \
		"$SCRIPT" "${ABC_XSIM_CALL[@]}" >"$stdout_file" 2>"$stderr_file"
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

	for case_dir in "$TEST_ROOT"/abc-xsim-*; do
		[[ -d "$case_dir" ]] || continue
		run_test "$case_dir"
	done

	echo
	echo "Passed: $PASS_COUNT"
	echo "Failed: $FAIL_COUNT"

	[[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
