#!/usr/bin/env bash
set -uo pipefail

failed=0
base=${VERIFY_BASE:-}
if [[ -z $base ]]; then
	if git show-ref --verify --quiet refs/heads/main; then
		base_ref=main
	elif git show-ref --verify --quiet refs/remotes/origin/main; then
		base_ref=origin/main
	else
		printf 'verify: neither main nor origin/main exists; set VERIFY_BASE explicitly.\n' >&2
		exit 1
	fi
	if ! base=$(git merge-base HEAD "$base_ref"); then
		printf 'verify: HEAD and %s have no common ancestor; set VERIFY_BASE explicitly.\n' "$base_ref" >&2
		exit 1
	fi
fi
export VERIFY_BASE=$base

printf '== Host checks ==\n'
git diff --check "$base..HEAD" || failed=1
bash scripts/privacy-scan.sh || failed=1
bash scripts/privacy-scan.sh --self-test || failed=1
if [[ -f package/catwrt-base/tests/defaults.sh ]]; then
	sh package/catwrt-base/tests/defaults.sh || failed=1
fi

tools=(shellcheck shfmt prettier actionlint gitleaks)
if [[ -f package/cattools/Cargo.toml ]]; then
	tools+=(cargo rustfmt cargo-clippy)
fi
have_tools=true
for tool in "${tools[@]}"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		have_tools=false
	fi
done

if [[ ${CI:-false} == true || $have_tools == true ]]; then
	git ls-files -z --cached --others --exclude-standard | bash scripts/verify-tools.sh --files-from - || failed=1
else
	if docker build -q -t catwrt-verify -f docker/verify.Dockerfile .; then
		git ls-files -z --cached --others --exclude-standard | MSYS_NO_PATHCONV=1 docker run --rm -i \
			-v "$(pwd -W 2>/dev/null || pwd):/src" \
			-v catwrt-cargo-registry:/usr/local/cargo/registry \
			-w /src catwrt-verify bash scripts/verify-tools.sh --files-from - || failed=1
	else
		printf 'verify: Docker image build failed; see the build diagnostics above.\n' >&2
		failed=1
	fi
fi

printf '\nVerification result: '
if [[ $failed == 0 ]]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$failed"
