#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

# The same line classifier serves tracked files, patches and in-memory tests.
scan_file() {
	SCAN_FILE=$1 SCAN_MODE=$2 SCAN_ALLOWLIST=${3-config/privacy-allowlist.txt} awk '
	function glob_regex(glob, result, i, c) {
		result = "^"
		for (i = 1; i <= length(glob); i++) {
			c = substr(glob, i, 1)
			if (c == "*") result = result ".*"
			else if (c == "?") result = result "."
			else if (index(".[](){}+^$|\\", c)) result = result "\\" c
			else result = result c
		}
		return result "$"
	}
	function allowed(text, i) {
		for (i = 1; i <= allow_count; i++)
			if (file ~ allow_path[i] && text ~ allow_pattern[i]) return 1
		return 0
	}
	function hit(rule) {
		# Redact the entire source line, including unrelated adjacent secrets.
		printf "%s:%d: %s: <redacted>\n", file, line_number, rule
		failed = 1
	}
	function private_ipv4(text, rest, address, octets, before, after) {
		rest = text
		while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
			address = substr(rest, RSTART, RLENGTH)
			before = substr(rest, 1, RSTART - 1)
			after = substr(rest, RSTART + RLENGTH)
			rest = after
			if (before ~ /[0-9.]$/ || after ~ /^[0-9.]/) continue
			split(address, octets, ".")
			if (octets[1] > 255 || octets[2] > 255 || octets[3] > 255 || octets[4] > 255) continue
			# Compare numerically so leading zeroes cannot bypass a private range.
			if (octets[1] == 192 && octets[2] == 168 && octets[3] == 1) {
				if (octets[4] == 4 || octets[4] == 1) continue
				if (octets[4] == 0 && after ~ /^\/24([^0-9]|$)/) continue
			}
			if (octets[1] == 10 || (octets[1] == 172 && octets[2] >= 16 && octets[2] <= 31) ||
			    (octets[1] == 192 && octets[2] == 168) ||
			    (octets[1] == 100 && octets[2] >= 64 && octets[2] <= 127)) return 1
		}
		return 0
	}
	function literal_assignment(text, rest, value, first) {
		rest = text
		while (match(tolower(rest), /(^|[^a-z0-9_])(password|passwd|token|secret)[[:space:]]*=[[:space:]]*/)) {
			rest = substr(rest, RSTART + RLENGTH)
			value = rest
			first = substr(value, 1, 1)
			if (first == "\047" || first == "\042") value = substr(value, 2)
			if (value == "" || value ~ /^[[:space:]#;\047\042]/) continue
			# Variable expansion, placeholders and command substitution contain no literal credential.
			if (value ~ /^(\$|`|<|\{\{)/) continue
			return 1
		}
		return 0
	}
	function sensitive_email(text, rest, email) {
		rest = text
		while (match(rest, /[A-Za-z0-9.!#$%&*+\/?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]+/)) {
			email = tolower(substr(rest, RSTART, RLENGTH))
			rest = substr(rest, RSTART + RLENGTH)
			if (email ~ /@users\.noreply\.github\.com$/ || email ~ /^(noreply|no-reply)@/) continue
			return 1
		}
		return 0
	}
	function entropy_token(text, rest, candidate, unique, seen, i, c, name, fields) {
		name = file
		sub(/^.*\//, "", name)
		if (name == "sha256sums" || name ~ /\.sha256$/) {
			split(text, fields, /[[:space:]]+/)
			if (text ~ /^[[:xdigit:]]+[[:space:]]+[* ]?[^[:space:]]/ && length(fields[1]) == 64) return 0
		}
		if (name ~ /(^|[.-])lock([.-]|$)/ || name == "npm-shrinkwrap.json") return 0
		rest = text
		while (match(rest, /[A-Za-z0-9+\/=]+/)) {
			candidate = substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
			if (length(candidate) < 32) continue
			split("", seen)
			unique = 0
			for (i = 1; i <= length(candidate); i++) {
				c = substr(candidate, i, 1)
				if (!(c in seen)) { seen[c] = 1; unique++ }
			}
			if (unique >= 8) return 1
		}
		return 0
	}
	function classify(text, lower) {
		if (allowed(text)) return
		lower = tolower(text)
		if (private_ipv4(text)) hit("private-ipv4")
		if (lower ~ /(^|[^0-9a-f])[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]([^0-9a-f]|$)/ ||
		    lower ~ /(^|[^0-9a-f])[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f]([^0-9a-f]|$)/) hit("mac-address")
		if (literal_assignment(text)) hit("literal-credential")
		if (text ~ /-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----/) hit("private-key")
		if (entropy_token(text)) hit("high-entropy-token")
		if (lower ~ /(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|redis|rediss|mssql|sqlserver):\/\/[^[:space:]\/@:]+:[^[:space:]\/@]+@/) hit("database-credentials")
		if (sensitive_email(text)) hit("email-address")
		if (text ~ /(^|[^A-Za-z0-9_])[A-Za-z]:[\\\/]/ || text ~ /(^|[[:space:]\042\047=:(])\/[a-z]\// ||
		    text ~ /\/(Users|home)\/[^\/[[:space:]\042\047]+\//) hit("local-path")
	}
	BEGIN {
		file = ENVIRON["SCAN_FILE"]
		mode = ENVIRON["SCAN_MODE"]
		while ((getline entry < ENVIRON["SCAN_ALLOWLIST"]) > 0) {
			if (entry ~ /^[[:space:]]*(#|$)/) continue
			sub(/[[:space:]]+#.*$/, "", entry)
			separator = index(entry, ":")
			if (!separator || separator == length(entry)) {
				print "privacy-scan: malformed allowlist entry (redacted)" > "/dev/stderr"
				configuration_error = 1
				continue
			}
			allow_count++
			allow_path[allow_count] = glob_regex(substr(entry, 1, separator - 1))
			allow_pattern[allow_count] = substr(entry, separator + 1)
		}
		close(ENVIRON["SCAN_ALLOWLIST"])
	}
	{
		if (mode == "all") { line_number = FNR; classify($0); next }
		if ($0 ~ /^@@ /) {
			hunk = $0
			sub(/^.* \+/, "", hunk)
			sub(/[, ].*$/, "", hunk)
			line_number = hunk + 0
			in_hunk = 1
			next
		}
		if (!in_hunk) next
		if ($0 ~ /^\+/) { classify(substr($0, 2)); line_number++; next }
		if ($0 ~ /^ /) line_number++
	}
	END { exit (failed || configuration_error) ? 1 : 0 }
	'
}

self_test() {
	local failures=0 checks=0 output result expected category file sample
	local hex base64 available_ref
	hex=0123456789abcdef
	base64=Ab9Cd8Ef7Gh6Ij5K
	# Synthetic samples are assembled in memory; none describe a real environment.
	while IFS='|' read -r expected category file sample; do
		[[ -n $expected ]] || continue
		checks=$((checks + 1))
		output=$(printf '%s\n' "$sample" | scan_file "$file" all /dev/null)
		result=$?
		if [[ $expected == hit ]]; then
			if [[ $result != 1 || $output != *": $category: <redacted>"* || $output == *"$sample"* ]]; then
				printf 'FAIL: %s positive sample\n' "$category" >&2
				failures=$((failures + 1))
			fi
		elif [[ $result != 0 || -n $output ]]; then
			printf 'FAIL: %s negative sample\n' "$category" >&2
			failures=$((failures + 1))
		fi
	done <<EOF
hit|private-ipv4|fixture.txt|$(printf '%s' '10.' '0.0.5')
hit|private-ipv4|fixture.txt|$(printf '%s' '172.' '16.0.2')
hit|private-ipv4|fixture.txt|$(printf '%s' '172.' '31.255.254')
hit|private-ipv4|fixture.txt|$(printf '%s' '192.' '168.2.2')
hit|private-ipv4|fixture.txt|$(printf '%s' '100.' '64.0.2')
hit|private-ipv4|fixture.txt|$(printf '%s' '100.' '127.255.254')
hit|private-ipv4|fixture.txt|$(printf '%s' '192.' '168.1.40')
hit|private-ipv4|fixture.txt|$(printf '%s' '192.' '168.1.0/25')
ok|private-ipv4|fixture.txt|192.168.1.4 192.168.1.1 192.168.1.0/24 127.0.0.1
ok|private-ipv4|fixture.txt|192.0.2.7 198.51.100.7 203.0.113.7
ok|private-ipv4|fixture.txt|$(printf '%s' '172.' '15.0.2 172.' '32.0.2 100.' '63.0.2 100.' '128.0.2')
ok|private-ipv4|fixture.txt|999.168.1.2
hit|mac-address|fixture.txt|$(printf '%s:' 02 00 00 00 00)01
hit|mac-address|fixture.txt|$(printf '%s-' 02 00 00 00 00)01
ok|mac-address|fixture.txt|02:00:00
hit|literal-credential|fixture.txt|pass$(printf word)=fixture
hit|literal-credential|fixture.txt|pass$(printf wd) = 'fixture'
hit|literal-credential|fixture.txt|to$(printf ken)="fixture"
hit|literal-credential|fixture.txt|sec$(printf ret)=fixture
ok|literal-credential|fixture.txt|pass$(printf word)=\$VALUE
ok|literal-credential|fixture.txt|pass$(printf word)=''
ok|literal-credential|fixture.txt|to$(printf ken)=
ok|literal-credential|fixture.txt|sec$(printf ret)=\$(command)
ok|literal-credential|fixture.txt|sec$(printf ret)={{VALUE}}
hit|private-key|fixture.txt|-----$(printf BEGIN) RSA PRIVATE KEY-----
hit|private-key|fixture.txt|-----$(printf BEGIN) PRIVATE KEY-----
ok|private-key|fixture.txt|-----BEGIN PUBLIC KEY-----
hit|high-entropy-token|fixture.txt|$hex$hex
hit|high-entropy-token|fixture.txt|$base64$base64
ok|high-entropy-token|fixture.txt|$hex
ok|high-entropy-token|fixture.txt|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ok|high-entropy-token|sha256sums|$hex$hex$hex$hex  image.img
ok|high-entropy-token|image.sha256|$hex$hex$hex$hex *image.img
hit|high-entropy-token|sha256sums|$hex$hex
ok|high-entropy-token|Cargo.lock|$hex$hex
ok|high-entropy-token|package-lock.json|$base64$base64
hit|literal-credential|Cargo.lock|to$(printf ken)=fixture
hit|database-credentials|fixture.txt|postgres$(printf '://')fixture:fixture@localhost/db
hit|database-credentials|fixture.txt|mongodb+srv$(printf '://')fixture:fixture@localhost/db
ok|database-credentials|fixture.txt|postgres://localhost/db
hit|email-address|fixture.txt|fixture$(printf '@')example.invalid
ok|email-address|fixture.txt|fixture$(printf '@')users.noreply.github.com
ok|email-address|fixture.txt|noreply$(printf '@')example.invalid
ok|email-address|fixture.txt|no-reply$(printf '@')example.invalid
hit|local-path|fixture.txt|$(printf '%s' Z ':' "$(printf '\134')" fixture "$(printf '\134')")
hit|local-path|fixture.txt|$(printf '%s' Z ':' '/' fixture '/')
hit|local-path|fixture.txt|$(printf '/%s/%s/' z fixture)
hit|local-path|fixture.txt|$(printf '/%s/%s/' Users fixture)
hit|local-path|fixture.txt|$(printf '/%s/%s/' home fixture)
ok|local-path|fixture.txt|/usr/share/catwrt /etc/config/network
ok|local-path|fixture.txt|<https://fsf.org/> <https://www.gnu.org/licenses/>
EOF
	# Exercise patch line numbers, deleted lines and additions beginning with ++.
	output=$(printf '%s\n' '--- a/fixture' '+++ b/fixture' '@@ -3 +7,2 @@' '-removed' '+safe' "+++$(printf '%s' '10.' '0.0.5')" | scan_file fixture.txt diff /dev/null)
	result=$?
	checks=$((checks + 1))
	if [[ $result != 1 || $output != 'fixture.txt:8: private-ipv4: <redacted>' ]]; then
		printf 'FAIL: patch parsing and line numbers\n' >&2
		failures=$((failures + 1))
	fi
	# Feed allowlist entries through a descriptor without creating repository files.
	output=$(printf '%s\n' "$(printf '%s' '10.' '0.0.5')" | scan_file fixture.txt all <(printf '%s\n' 'other.*:^10[.]  # deliberate non-match'))
	result=$?
	checks=$((checks + 1))
	if [[ $result != 1 || -z $output ]]; then
		printf 'FAIL: allowlist non-match\n' >&2
		failures=$((failures + 1))
	fi
	output=$(printf '%s\n' "$(printf '%s' '10.' '0.0.5')" | scan_file fixture.txt all <(printf '%s\n' 'fixture.*:^10[.]  # synthetic allowlist test'))
	result=$?
	checks=$((checks + 1))
	if [[ $result != 0 || -n $output ]]; then
		printf 'FAIL: allowlist path glob and reason\n' >&2
		failures=$((failures + 1))
	fi
	# Exercise base selection without changing repository refs or writing fixtures.
	for available_ref in main origin/main missing override; do
		output=$(
			git() {
				# main invokes this scoped Git replacement indirectly.
				# shellcheck disable=SC2317
				case "$1" in
				show-ref)
					[[ $available_ref == main && $4 == refs/heads/main || $available_ref == origin/main && $4 == refs/remotes/origin/main ]]
					;;
				merge-base)
					[[ $3 == "$available_ref" ]] || return 2
					printf 'fixture-base\n'
					;;
				-c) [[ " $* " == *' fixture-base..HEAD '* ]] ;;
				*) return 2 ;;
				esac
			}
			if [[ $available_ref == override ]]; then
				VERIFY_BASE=fixture-base main 2>&1
			else
				VERIFY_BASE='' main 2>&1
			fi
		)
		result=$?
		checks=$((checks + 1))
		if [[ $available_ref == missing ]]; then
			if [[ $result != 1 || $output != *'neither main nor origin/main exists'* ]]; then
				printf 'FAIL: missing base diagnostic\n' >&2
				failures=$((failures + 1))
			fi
		elif [[ $result != 0 || -n $output ]]; then
			printf 'FAIL: base selection (%s)\n' "$available_ref" >&2
			failures=$((failures + 1))
		fi
	done
	printf 'privacy-scan self-test: %d checks, %d failures\n' "$checks" "$failures"
	[[ $failures == 0 ]]
}

main() {
	local mode=${1-} base base_ref file failed=0 result
	local -a diff_args
	case "$mode" in
	--self-test)
		self_test
		return
		;;
	--all | --staged | '') ;;
	*)
		printf 'Usage: bash scripts/privacy-scan.sh [--staged|--all|--self-test]\n' >&2
		return 2
		;;
	esac
	if [[ $# -gt 1 ]]; then
		printf 'privacy-scan: expected at most one mode\n' >&2
		return 2
	fi
	if [[ $mode == --all ]]; then
		git ls-files -z | (
			while IFS= read -r -d '' file; do
				[[ -f $file ]] || continue
				# The path argument is a diagnostic label; scan_file only reads stdin.
				# shellcheck disable=SC2094
				scan_file "$file" all <"$file" || failed=1
			done
			exit "$failed"
		)
		result=$?
		return "$result"
	fi
	if [[ $mode == --staged ]]; then
		diff_args=(--cached)
	else
		base=${VERIFY_BASE:-}
		if [[ -z $base ]]; then
			if git show-ref --verify --quiet refs/heads/main; then
				base_ref=main
			elif git show-ref --verify --quiet refs/remotes/origin/main; then
				base_ref=origin/main
			else
				printf 'privacy-scan: neither main nor origin/main exists; set VERIFY_BASE explicitly.\n' >&2
				return 1
			fi
			if ! base=$(git merge-base HEAD "$base_ref"); then
				printf 'privacy-scan: HEAD and %s have no common ancestor; set VERIFY_BASE explicitly.\n' "$base_ref" >&2
				return 1
			fi
		fi
		diff_args=("$base..HEAD")
	fi
	git -c core.quotePath=false diff --no-ext-diff --no-textconv --name-only -z --diff-filter=ACMRT "${diff_args[@]}" -- | (
		while IFS= read -r -d '' file; do
			git -c core.quotePath=false diff --no-ext-diff --no-textconv --no-renames --unified=0 "${diff_args[@]}" -- "$file" | scan_file "$file" diff || failed=1
		done
		exit "$failed"
	)
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
