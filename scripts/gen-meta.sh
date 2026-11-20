#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() {
	printf 'gen-meta: %s\n' "$*" >&2
	exit 1
}

self_test() (
	local fixture script fs boot name output checks=0
	fixture=$(mktemp -d)
	trap 'rm -rf -- "$fixture"' EXIT
	script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/gen-meta.sh
	mkdir "$fixture/images"
	for fs in squashfs ext4; do
		for boot in efi bios; do
			printf '%s %s fixture\n' "$fs" "$boot" >"$fixture/images/catwrt-next-v26.12-x86-64-$fs-$boot.img.gz"
		done
	done
	(cd "$fixture/images" && sha256sum --text catwrt-next-*.img.gz) >"$fixture/sums"
	cp "$fixture/sums" "$fixture/images/sha256sums"
	local -a args=(--version v26.12 --base immortalwrt-25.12.2 --released 2026-12-01
		--repo Mtoly/CatWrt_Next --images "$fixture/images" --output "$fixture/meta.json")
	bash "$script" "${args[@]}"
	grep -qx '  "schema": 1,' "$fixture/meta.json"
	grep -qx '  "latest": "v26.12",' "$fixture/meta.json"
	grep -qx '  "base": "immortalwrt-25.12.2",' "$fixture/meta.json"
	grep -qx '  "released": "2026-12-01",' "$fixture/meta.json"
	grep -qx '  "notes_url": "https://github.com/Mtoly/CatWrt_Next/releases/tag/v26.12",' "$fixture/meta.json"
	awk '
		NR == 1 && $0 != "{" { exit 1 }
		NR == 7 && $0 != "  \"images\": {" { exit 1 }
		NR == 8 && $0 != "    \"x86_64\": {" { exit 1 }
		NR == 29 && $0 != "    }" { exit 1 }
		NR == 30 && $0 != "  }" { exit 1 }
		NR == 31 && $0 != "}" { exit 1 }
		END { if (NR != 31) exit 1 }
	' "$fixture/meta.json"
	for fs in squashfs ext4; do
		for boot in efi bios; do
			name="catwrt-next-v26.12-x86-64-$fs-$boot.img.gz"
			grep -qx "      \"$fs-$boot\": {" "$fixture/meta.json"
			grep -Fxq "        \"url\": \"https://github.com/Mtoly/CatWrt_Next/releases/download/v26.12/$name\"," "$fixture/meta.json"
			output=$(sha256sum "$fixture/images/$name")
			grep -Fxq "        \"sha256\": \"${output%% *}\"," "$fixture/meta.json"
			grep -Fxq "        \"size\": $(stat -c %s "$fixture/images/$name")" "$fixture/meta.json"
		done
	done
	if grep -q qcow2 "$fixture/meta.json"; then
		fail 'self-test: qcow2 image listed in meta.json'
	fi
	checks=$((checks + 1))
	cp "$fixture/meta.json" "$fixture/original"

	# Each rejected invocation must preserve the previous metadata byte for byte.
	expect_failure() {
		local expected=$1 diagnostic
		shift
		if diagnostic=$(bash "$script" "$@" 2>&1); then
			fail "self-test: accepted invalid input ($expected)"
		fi
		[[ $diagnostic == *"$expected"* ]] || fail "self-test: unexpected diagnostic: $diagnostic"
		cmp -s "$fixture/original" "$fixture/meta.json" || fail 'self-test: output changed on failure'
		checks=$((checks + 1))
	}

	name=catwrt-next-v26.12-x86-64-squashfs-efi.img.gz
	mv "$fixture/images/$name" "$fixture/saved"
	expect_failure 'found 0' "${args[@]}"
	mv "$fixture/saved" "$fixture/images/$name"
	# A second export with the same basename must not silently select an image.
	mkdir "$fixture/images/duplicate"
	cp "$fixture/images/$name" "$fixture/images/duplicate/$name"
	expect_failure 'found 2' "${args[@]}"
	rm -r "$fixture/images/duplicate"
	awk -v name="$name" '$2 != name' "$fixture/sums" >"$fixture/images/sha256sums"
	expect_failure 'found 0 checksum lines' "${args[@]}"
	cat "$fixture/sums" "$fixture/sums" >"$fixture/images/sha256sums"
	expect_failure 'found 2 checksum lines' "${args[@]}"
	awk -v name="$name" '{ if ($2 == name) $1 = sprintf("%064d", 0); print }' "$fixture/sums" >"$fixture/images/sha256sums"
	expect_failure 'SHA256 mismatch' "${args[@]}"
	cp "$fixture/sums" "$fixture/images/sha256sums"
	rm "$fixture/images/sha256sums"
	expect_failure 'Missing sha256sums' "${args[@]}"
	cp "$fixture/sums" "$fixture/images/sha256sums"
	for output in v26.13 v26.00 v26.12.0 invalid; do
		expect_failure 'Invalid stable tag' --version "$output" "${args[@]:2}"
	done
	expect_failure 'Pre-release tags never go into meta.json' --version v26.12-rc1 "${args[@]:2}"
	for output in 2026-02-29 2026-13-01 2026-2-01; do
		expect_failure 'Invalid release date' "${args[@]:0:4}" --released "$output" "${args[@]:6}"
	done
	for output in ../repo owner/repo/extra 'owner/repo"'; do
		expect_failure 'Invalid repository' "${args[@]:0:6}" --repo "$output" "${args[@]:8}"
	done
	expect_failure 'Invalid base' "${args[@]:0:2}" --base 'immortalwrt-25.12.2"' "${args[@]:4}"
	expect_failure 'Duplicate argument' "${args[@]}" --version v26.12
	expect_failure 'Missing value' --version
	expect_failure 'Missing required argument' "${args[@]:0:10}"
	expect_failure 'Unknown argument' --unknown
	[[ $(find "$fixture" -maxdepth 1 -name 'meta.json.tmp.*' | wc -l) == 0 ]]
	rm -rf -- "$fixture"
	trap - EXIT
	printf 'gen-meta self-test: %d checks passed\n' "$checks"
)

if [[ ${1:-} == --self-test && $# == 1 ]]; then
	self_test
	exit 0
fi

version='' base='' released='' repo='' images='' output=''
declare -A seen=()
while (($#)); do
	option=$1
	case "$option" in
	--version | --base | --released | --repo | --images | --output) ;;
	*) fail "Unknown argument: $option" ;;
	esac
	[[ -z ${seen[$option]:-} ]] || fail "Duplicate argument: $option"
	[[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $option"
	seen[$option]=1
	case "$option" in
	--version)
		[[ $2 != *-rc* ]] || fail 'Pre-release tags never go into meta.json; use a stable tag'
		[[ $2 =~ ^v[0-9]{2}\.(0?[1-9]|1[0-2])(\.[1-9][0-9]*)?$ ]] || fail "Invalid stable tag: $2"
		version=$2
		;;
	--base)
		[[ $2 =~ ^immortalwrt-[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid base: $2"
		base=$2
		;;
	--released)
		if [[ ! $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || $(date -u -d "$2" +%F 2>/dev/null) != "$2" ]]; then
			fail "Invalid release date: $2"
		fi
		released=$2
		;;
	--repo)
		[[ $2 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9._-]*$ && ${2%%/*} != *--* ]] || fail "Invalid repository: $2"
		repo=$2
		;;
	--images)
		[[ $2 != *[[:cntrl:]]* && -d $2 && -r $2 ]] || fail 'Invalid images directory'
		images=$(cd -- "$2" && pwd)
		;;
	--output)
		[[ $2 != *[[:cntrl:]]* && $2 != */ && ! -d $2 && -d $(dirname -- "$2") && -w $(dirname -- "$2") ]] || fail 'Invalid output file or parent directory'
		output=$2
		;;
	esac
	shift 2
done
for option in --version --base --released --repo --images --output; do
	[[ -n ${seen[$option]:-} ]] || fail "Missing required argument: $option; usage: gen-meta.sh --version <tag> --base <immortalwrt-x.y.z> --released <YYYY-MM-DD> --repo <owner/name> --images <dir> --output <file>"
done

[[ -f $images/sha256sums ]] || fail 'Missing sha256sums in images directory'
variants=(squashfs-efi squashfs-bios ext4-efi ext4-bios)
names=() hashes=() sizes=()
for variant in "${variants[@]}"; do
	name="catwrt-next-${version}-x86-64-${variant}.img.gz"
	# Count exact basenames, including accidentally nested duplicate exports.
	listing=$(find "$images" -name "$name" -type f -print) || fail 'Cannot list image files; see find diagnostics above'
	count=$(printf '%s\n' "$listing" | awk 'NF { count++ } END { print count+0 }')
	[[ $count == 1 && -f $images/$name ]] || fail "Expected one top-level image $name; found $count"
	actual=$(sha256sum -- "$images/$name")
	actual=${actual%% *}
	size=$(stat -c %s -- "$images/$name")
	[[ $size =~ ^[1-9][0-9]*$ ]] || fail "Empty or invalid image size: $name"
	expected=$(awk -v expected="$name" '
		{
			name = $2
			sub(/^\*/, "", name)
			if (name == expected) {
				count++
				hash = tolower($1)
				if (NF != 2 || hash !~ /^[[:xdigit:]]+$/ || length(hash) != 64) invalid = 1
			}
		}
		END {
			if (count != 1 || invalid) {
				printf "gen-meta: %s: found %d checksum lines; expected one valid SHA256 line\n", expected, count > "/dev/stderr"
				exit 1
			}
			print hash
		}' "$images/sha256sums")
	[[ $actual == "$expected" ]] || fail "SHA256 mismatch for $name; expected $expected; actual $actual"
	names+=("$name")
	hashes+=("$actual")
	sizes+=("$size")
done

temporary=$(mktemp -- "${output}.tmp.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
{
	printf '{\n  "schema": 1,\n  "latest": "%s",\n  "base": "%s",\n' "$version" "$base"
	printf '  "released": "%s",\n  "notes_url": "https://github.com/%s/releases/tag/%s",\n' "$released" "$repo" "$version"
	printf '  "images": {\n    "x86_64": {\n'
	for i in "${!variants[@]}"; do
		printf '      "%s": {\n' "${variants[i]}"
		printf '        "url": "https://github.com/%s/releases/download/%s/%s",\n' "$repo" "$version" "${names[i]}"
		printf '        "sha256": "%s",\n        "size": %s\n' "${hashes[i]}" "${sizes[i]}"
		comma=,
		[[ $i != 3 ]] || comma=''
		printf '      }%s\n' "$comma"
	done
	printf '    }\n  }\n}\n'
} >"$temporary"
mv -f -- "$temporary" "$output"
trap - EXIT
