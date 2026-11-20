#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() {
	printf 'upstream-check: %s\n' "$*" >&2
	exit 1
}

self_test() (
	local fixture script output checks=0
	fixture=$(mktemp -d)
	trap 'rm -f -- "$fixture"/*.html "$fixture/diagnostic"; rmdir -- "$fixture"' EXIT
	script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/upstream-check.sh
	# These entries are cut from the upstream release directory index.
	cat >"$fixture/current.html" <<'EOF'
<a href="25.12-SNAPSHOT/">25.12-SNAPSHOT/</a>
<a href="25.12.0/">25.12.0/</a>
<a href="25.12.1/">25.12.1/</a>
<a href="25.12.2/">25.12.2/</a>
<a href="faillogs-25.12/">faillogs-25.12/</a>
<a href="packages-25.12/">packages-25.12/</a>
EOF
	output=$(bash "$script" --current 25.12.2 --index "$fixture/current.html")
	[[ -z $output ]] || fail 'self-test: expected no newer release'
	checks=$((checks + 1))
	output=$(bash "$script" --current 25.12.1 --index "$fixture/current.html")
	[[ $output == 25.12.2 ]] || fail 'self-test: expected one newer release'
	checks=$((checks + 1))
	output=$(bash "$script" --current 25.12.0 --index "$fixture/current.html")
	[[ $output == 25.12.2 ]] || fail 'self-test: expected newest of two newer releases'
	checks=$((checks + 1))
	cp "$fixture/current.html" "$fixture/newer.html"
	printf '%s\n' '<a href="25.12.10/">25.12.10/</a><a href="25.12.9/">25.12.9/</a>' >>"$fixture/newer.html"
	output=$(bash "$script" --current 25.12.2 --index "$fixture/newer.html")
	[[ $output == 25.12.10 ]] || fail 'self-test: 25.12.10 must beat 25.12.9'
	checks=$((checks + 1))
	output=$(bash "$script" --current 25.12.11 --index "$fixture/newer.html")
	[[ -z $output ]] || fail 'self-test: must not suggest a downgrade'
	checks=$((checks + 1))
	cp "$fixture/current.html" "$fixture/ignored.html"
	cat >>"$fixture/ignored.html" <<'EOF'
<a href="25.12.3-rc1/">25.12.3-rc1/</a>
<a href="24.10.9/">24.10.9/</a><a href="26.12.9/">26.12.9/</a>
<a href="25.12.99/extra/">nested</a><a href="prefix25.12.99/">prefixed</a>
<a data-href="25.12.99/">not an href</a><a href="25.12.99">no slash</a>
EOF
	output=$(bash "$script" --current 25.12.2 --index "$fixture/ignored.html")
	[[ -z $output ]] || fail 'self-test: accepted an unrelated or non-release href'
	checks=$((checks + 1))
	printf '%s\n' "<a href='25.12.3/'>25.12.3/</a>" >"$fixture/quoted.html"
	output=$(bash "$script" --current 25.12.2 --index "$fixture/quoted.html")
	[[ $output == 25.12.3 ]] || fail 'self-test: expected a single-quoted href'
	checks=$((checks + 1))

	expect_failure() {
		local expected=$1 diagnostic
		shift
		if output=$(bash "$script" "$@" 2>"$fixture/diagnostic"); then
			fail "self-test: accepted invalid input ($expected)"
		fi
		diagnostic=$(cat "$fixture/diagnostic")
		[[ -z $output && $diagnostic == *"$expected"* ]] || fail "self-test: unexpected diagnostic: $diagnostic"
		checks=$((checks + 1))
	}
	printf '%s\n' '<a href="24.10.9/">24.10.9/</a><a href="25.12-SNAPSHOT/">snapshot</a>' >"$fixture/empty.html"
	expect_failure 'No release found for series 25.12' --current 25.12.2 --index "$fixture/empty.html"
	for output in 25.12 25.12.2-rc1 v25.12.2 '25x12.2'; do
		expect_failure 'Invalid --current' --current "$output" --index "$fixture/current.html"
	done
	expect_failure 'Missing or unreadable index file' --current 25.12.2 --index "$fixture/missing.html"
	expect_failure 'Missing or unreadable index file' --current 25.12.2 --index "$fixture"
	expect_failure 'Missing required argument' --current 25.12.2
	expect_failure 'Missing value' --current
	expect_failure 'Duplicate argument' --current 25.12.2 --current 25.12.1 --index "$fixture/current.html"
	expect_failure 'Unknown argument' --unknown
	printf 'upstream-check self-test: %d checks passed\n' "$checks"
)

if [[ ${1:-} == --self-test && $# == 1 ]]; then
	self_test
	exit 0
fi

current='' index=''
declare -A seen=()
while (($#)); do
	option=$1
	case "$option" in
	--current | --index) ;;
	*) fail "Unknown argument: $option" ;;
	esac
	[[ -z ${seen[$option]:-} ]] || fail "Duplicate argument: $option"
	[[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $option"
	seen[$option]=1
	case "$option" in
	--current) current=$2 ;;
	--index) index=$2 ;;
	esac
	shift 2
done
[[ -n $current && -n $index ]] || fail 'Missing required argument; usage: upstream-check.sh --current <x.y.z> --index <file>'
[[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid --current: $current; expected x.y.z"
[[ -f $index && -r $index ]] || fail 'Missing or unreadable index file'
series=${current%.*}
releases=$(awk -v series="$series" '
	BEGIN {
		gsub(/\./, "\\.", series)
		pattern = "^" series "\\.[0-9]+/$"
	}
	{
		rest = $0
		while (match(rest, /(^|[[:space:]<])href[[:space:]]*=[[:space:]]*("[^"]*"|\047[^\047]*\047)/)) {
			href = substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
			sub(/^[^=]*=[[:space:]]*/, "", href)
			href = substr(href, 2, length(href) - 2)
			if (href ~ pattern) print substr(href, 1, length(href) - 1)
		}
	}' "$index")
[[ -n $releases ]] || fail "No release found for series $series; upstream index format may have changed"
newest=$(printf '%s\n' "$releases" | sort -V | tail -n 1)
if [[ $newest != "$current" && $(printf '%s\n' "$current" "$newest" | sort -V | tail -n 1) == "$newest" ]]; then
	printf '%s\n' "$newest"
fi
