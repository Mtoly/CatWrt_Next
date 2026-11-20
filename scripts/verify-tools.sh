#!/usr/bin/env bash
set -uo pipefail

if [[ $# != 2 || $1 != --files-from || $2 != - ]]; then
	printf 'Usage: bash scripts/verify-tools.sh --files-from - < NUL-delimited-file-list\n' >&2
	exit 2
fi

declare -a shell_files=() prettier_files=() workflows=()
declare -a step_names=() step_results=()
failed=0

run_step() {
	local name=$1 result
	shift
	printf '\n== %s ==\n' "$name"
	"$@"
	result=$?
	step_names+=("$name")
	if [[ $result == 0 ]]; then
		step_results+=(PASS)
	else
		step_results+=("FAIL ($result)")
		failed=1
	fi
}

skip_step() {
	step_names+=("$1")
	step_results+=("SKIP ($2)")
}

rust_step() {
	# Invoked indirectly through run_step rather than as a direct function call.
	# shellcheck disable=SC2317
	(cd package/cattools && cargo "$@")
}

# Read the host-selected list; worktree metadata is unavailable in local containers.
shebang_pattern='^#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$)'
while IFS= read -r -d '' file; do
	file=${file#./}
	[[ -f $file ]] || continue
	case "$file" in
	*.sh) shell_files+=("$file") ;;
	scripts/* | package/*/files/*)
		first_line=''
		IFS= read -r first_line <"$file" || true
		if [[ $first_line =~ $shebang_pattern ]]; then
			shell_files+=("$file")
		fi
		;;
	esac
	case "$file" in
	package/cattools/*.md) ;;
	*.json | *.yml | *.yaml | *.js | *.md) prettier_files+=("$file") ;;
	esac
	case "$file" in
	.github/workflows/*.yml | .github/workflows/*.yaml) workflows+=("$file") ;;
	esac
done

if ((${#shell_files[@]})); then
	run_step shellcheck shellcheck "${shell_files[@]}"
	run_step shfmt shfmt -d -i 0 "${shell_files[@]}"
else
	skip_step shellcheck 'no shell files'
	skip_step shfmt 'no shell files'
fi
if ((${#prettier_files[@]})); then
	run_step prettier prettier --check "${prettier_files[@]}"
else
	skip_step prettier 'no matching files'
fi
if ((${#workflows[@]})); then
	run_step actionlint actionlint "${workflows[@]}"
else
	skip_step actionlint 'no workflows'
fi
if [[ -f scripts/gen-meta.sh ]]; then
	run_step 'gen-meta self-test' bash scripts/gen-meta.sh --self-test
fi
if [[ -f package/cattools/Cargo.toml ]]; then
	run_step 'cargo fmt' rust_step fmt --all -- --check
	run_step 'cargo clippy' rust_step clippy --all-targets -- -D warnings
	run_step 'cargo test' rust_step test
else
	skip_step Rust 'cattools not imported'
fi

printf '\n%-20s %s\n' CHECK RESULT
for ((i = 0; i < ${#step_names[@]}; i++)); do
	printf '%-20s %s\n' "${step_names[i]}" "${step_results[i]}"
done
exit "$failed"
