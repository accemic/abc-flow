#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/abc/abc-bundle"
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

assert_file_exists() {
	local path="$1"
	[[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_dir_exists() {
	local path="$1"
	[[ -d "$path" ]] || fail "expected directory to exist: $path"
}

assert_not_exists() {
	local path="$1"
	[[ ! -e "$path" ]] || fail "expected path to be absent: $path"
}

compare_exact_file() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	if ! diff -u "$expected" "$actual" >&2; then
		fail "exact comparison failed for $label"
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

list_export_files() {
	local out_dir="$1"
	if [[ ! -d "$out_dir" ]]; then
		return 0
	fi
	(
		cd "$out_dir"
		find . -type f | sed 's#^\./##' | LC_ALL=C sort
	)
}

copy_repo_fixture() {
	local source_dir="$1"
	local dest_dir="$2"

	mkdir -p "$dest_dir"
	cp -R "$source_dir"/. "$dest_dir"
	git -C "$dest_dir" init -q
}

run_case() {
	(
		set -euo pipefail

		local case_dir="$1"
		local case_name
		local expected_dir
		local work_dir
		local repo_dir
		local out_dir
		local stdout_file
		local stderr_file
		local status
		local rel_path

		case_name="$(basename "$case_dir")"
		expected_dir="$case_dir/expected"
		work_dir="$TMP_ROOT/$case_name"
		repo_dir="$work_dir/repo"
		out_dir="$work_dir/export"
		stdout_file="$work_dir/stdout.txt"
		stderr_file="$work_dir/stderr.txt"

		unset ABC_BUNDLE_CALL EXPECT_EXIT_CODE EXPECT_EXPORT_DIR
		ABC_BUNDLE_CALL=()
		EXPECT_EXIT_CODE=0
		EXPECT_EXPORT_DIR="present"
		REPO="$repo_dir"
		OUT_DIR="$out_dir"

		# shellcheck source=/dev/null
		source "$case_dir/case.conf"

		if [[ ${#ABC_BUNDLE_CALL[@]} -eq 0 ]]; then
			fail "missing ABC_BUNDLE_CALL in $case_name/case.conf"
		fi

		copy_repo_fixture "$case_dir/repo" "$repo_dir"

		set +e
		"$SCRIPT" "${ABC_BUNDLE_CALL[@]}" >"$stdout_file" 2>"$stderr_file"
		status=$?
		set -e

		assert_eq "$EXPECT_EXIT_CODE" "$status" "$case_name exit code"

		if [[ -f "$expected_dir/stdout.contains.txt" ]]; then
			check_contains_file "$expected_dir/stdout.contains.txt" "$stdout_file"
		fi
		if [[ -f "$expected_dir/stderr.contains.txt" ]]; then
			check_contains_file "$expected_dir/stderr.contains.txt" "$stderr_file"
		fi

		case "$EXPECT_EXPORT_DIR" in
			present)
				assert_dir_exists "$out_dir"
				;;
			*)
				fail "unknown EXPECT_EXPORT_DIR in $case_name: $EXPECT_EXPORT_DIR"
				;;
		esac

		if [[ -d "$out_dir" && -f "$expected_dir/export.files" ]]; then
			assert_eq "$(cat "$expected_dir/export.files")" "$(list_export_files "$out_dir")" "$case_name export.files"
		fi

		if [[ -d "$out_dir" && -d "$expected_dir/export" ]]; then
			while IFS= read -r rel_path; do
				assert_file_exists "$out_dir/$rel_path"
				compare_exact_file "$expected_dir/export/$rel_path" "$out_dir/$rel_path" "$case_name $rel_path"
			done < <(
				cd "$expected_dir/export"
				find . -type f | sed 's#^\./##' | LC_ALL=C sort
			)
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

	for case_dir in "$TEST_ROOT"/abc-bundle-*; do
		[[ -d "$case_dir" ]] || continue
		run_test "$case_dir"
	done

	echo
	echo "Passed: $PASS_COUNT"
	echo "Failed: $FAIL_COUNT"

	[[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
