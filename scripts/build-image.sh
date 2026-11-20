#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C

fail() {
	printf 'build-image: %s\n' "$*" >&2
	exit 1
}

select_imagebuilder() {
	local manifest=$1 version=$2 target=$3 subtarget=$4
	awk -v expected="immortalwrt-imagebuilder-${version}-${target}-${subtarget}.Linux-x86_64.tar.zst" '
		{
			name = $2
			sub(/^\*/, "", name)
			if (name == expected && $1 ~ /^[[:xdigit:]]+$/ && length($1) == 64) {
				count++
				selected = tolower($1) " " name
			}
		}
		END {
			if (count != 1) {
				printf "Expected one ImageBuilder named %s; found %d\n", expected, count > "/dev/stderr"
				exit 1
			}
			print selected
		}' "$manifest"
}

verify_sha256() {
	local path=$1 expected=$2 actual
	actual=$(sha256sum "$path")
	actual=${actual%% *}
	[[ $actual == "$expected" ]] || fail "SHA256 mismatch: $path; expected $expected; actual $actual"
}

download() {
	local url=$1 destination=$2 metadata result=0 status content_type final_url
	metadata=$(curl --silent --show-error --location --connect-timeout 30 \
		--output "$destination.part" --write-out '%{http_code}|%{content_type}|%{url_effective}' \
		"$url") || result=$?
	IFS='|' read -r status content_type final_url <<<"$metadata"
	if [[ $result != 0 || $status != 2[0-9][0-9] ]]; then
		rm -f -- "$destination.part"
		fail "Download failed: URL=$url; curl=$result; HTTP=$status; type=$content_type; final=$final_url"
	fi
	mv -- "$destination.part" "$destination"
}

parse_packages() {
	local path line number
	for path in "$@"; do
		[[ -f $path ]] || fail "Missing package list: $path"
		number=0
		while IFS= read -r line || [[ -n $line ]]; do
			number=$((number + 1))
			line=${line%%#*}
			line=${line#"${line%%[![:space:]]*}"}
			line=${line%"${line##*[![:space:]]}"}
			[[ -n $line ]] || continue
			[[ $line =~ ^-?[a-z0-9][a-z0-9._+-]*$ ]] || fail "Invalid package name in $path:$number: $line"
			printf '%s\n' "$line"
		done <"$path"
	done
}

require_packages() {
	local directory=$1 path
	local -a apks
	[[ -d $directory ]] || fail "Missing package directory: $directory; run bash scripts/build-packages.sh first"
	shopt -s nullglob
	apks=("$directory"/*.apk)
	shopt -u nullglob
	[[ ${#apks[@]} -gt 0 ]] || fail "Missing *.apk in $directory; run bash scripts/build-packages.sh first"
	for path in "${apks[@]}" "$directory/packages.adb" "$directory/signing-public-key.pem"; do
		[[ -f $path && -s $path ]] || fail "Missing or empty $path; run bash scripts/build-packages.sh first"
	done
}

check_manifest() {
	local path=$1
	[[ -s $path ]] || fail "Missing or empty image manifest: $path"
	awk '
		{ installed[$1] = 1 }
		END {
			split("catwrt-base cattools luci-theme-argon luci-app-openclash tailscale luci-app-appfilter luci-app-mosdns", required, " ")
			split("luci-app-attendedsysupgrade luci-i18n-attendedsysupgrade-zh-cn attendedsysupgrade-common owut luci-app-passwall", forbidden, " ")
			for (i in required) {
				if (!(required[i] in installed)) {
					printf "build-image: Manifest missing required package: %s\n", required[i] > "/dev/stderr"
					failed = 1
				}
			}
			for (i in forbidden) {
				if (forbidden[i] in installed) {
					printf "build-image: Manifest contains forbidden package: %s\n", forbidden[i] > "/dev/stderr"
					failed = 1
				}
			}
			exit failed
		}' "$path"
}

list_outputs() {
	printf 'ImageBuilder produced (%s):\n' "$1" >&2
	if [[ -d $1 ]]; then
		find "$1" -maxdepth 1 -type f -printf '  %f\n' | sort >&2
	else
		printf '  (directory missing)\n' >&2
	fi
}

collect_images() {
	local source=$1 destination=$2 version=$3 fs boot suffix format name
	local -a matches names=()
	mkdir -p -- "$destination"
	for fs in squashfs ext4; do
		for boot in bios efi; do
			suffix=''
			[[ $boot != efi ]] || suffix=-efi
			for format in img.gz qcow2; do
				shopt -s nullglob
				matches=("$source"/*-"$fs"-combined"$suffix"."$format")
				if [[ $format == qcow2 ]]; then
					matches+=("$source"/*-"$fs"-combined"$suffix".qcow2.gz)
				fi
				shopt -u nullglob
				if [[ ${#matches[@]} != 1 ]]; then
					list_outputs "$source"
					fail "Expected one $fs/$boot/$format image; found ${#matches[@]}"
				fi
				name="catwrt-next-${version}-x86-64-${fs}-${boot}.${format}"
				if [[ $format == qcow2 && ${matches[0]} == *.gz ]]; then
					gzip -dc -- "${matches[0]}" >"$destination/$name" || fail "Cannot decompress qcow2: ${matches[0]}; see gzip diagnostics above"
				else
					cp -- "${matches[0]}" "$destination/$name" || fail "Cannot copy image: ${matches[0]}; see cp diagnostics above"
				fi
				[[ -s $destination/$name ]] || fail "Empty image: ${matches[0]}"
				names+=("$name")
			done
		done
	done
	(cd "$destination" && sha256sum "${names[@]}" >sha256sums)
}

self_test() {
	local fixture output selected fs boot suffix format package checks=0
	fixture=$(mktemp -d)
	trap 'rm -rf -- "$fixture"' EXIT
	printf '# Packages\r\n\n catwrt-base  # defaults\r\n-luci-app-attendedsysupgrade\nlibtest+variant\n' >"$fixture/packages"
	printf '\tkmod-test_1.2-3\t# driver\ncattools' >"$fixture/drivers"
	output=$(parse_packages "$fixture/packages" "$fixture/drivers")
	[[ $output == $'catwrt-base\n-luci-app-attendedsysupgrade\nlibtest+variant\nkmod-test_1.2-3\ncattools' ]]
	checks=$((checks + 1))
	for package in '-' '--bad' 'Bad' 'one two' 'pkg;cmd' '../pkg' '+pkg' 'pkg/path' 'pkg=1'; do
		printf '%s\n' "$package" >"$fixture/invalid"
		if output=$(parse_packages "$fixture/invalid" 2>&1); then
			fail "self-test: invalid package accepted: $package"
		fi
		[[ $output == *'Invalid package name in '*':1:'* ]]
		checks=$((checks + 1))
	done
	if output=$(parse_packages "$fixture/missing" 2>&1); then
		fail 'self-test: missing package list accepted'
	fi
	[[ $output == *'Missing package list:'* ]]
	checks=$((checks + 1))
	printf '%064d *immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64.tar.zst\n' 0 >"$fixture/sums"
	selected=$(select_imagebuilder "$fixture/sums" 25.12.2 x86 64)
	[[ ${selected#* } == immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64.tar.zst ]]
	checks=$((checks + 1))
	if select_imagebuilder "$fixture/sums" 25.12.3 x86 64 2>/dev/null; then
		fail 'self-test: missing ImageBuilder accepted'
	fi
	checks=$((checks + 1))
	cat "$fixture/sums" "$fixture/sums" >"$fixture/duplicates"
	if select_imagebuilder "$fixture/duplicates" 25.12.2 x86 64 2>/dev/null; then
		fail 'self-test: duplicate ImageBuilder accepted'
	fi
	checks=$((checks + 1))
	mkdir -p "$fixture/input"
	for fs in squashfs ext4; do
		for boot in bios efi; do
			suffix=''
			[[ $boot != efi ]] || suffix=-efi
			printf '%s %s img\n' "$fs" "$boot" | gzip -c >"$fixture/input/upstream-$fs-combined$suffix.img.gz"
			printf '%s %s qcow2\n' "$fs" "$boot" >"$fixture/disk"
			if [[ $fs == ext4 ]]; then
				gzip -c "$fixture/disk" >"$fixture/input/upstream-$fs-combined$suffix.qcow2.gz"
			else
				cp "$fixture/disk" "$fixture/input/upstream-$fs-combined$suffix.qcow2"
			fi
		done
	done
	printf 'unshipped\n' >"$fixture/input/upstream-ext4-combined.vmdk"
	collect_images "$fixture/input" "$fixture/output" v-test
	[[ $(find "$fixture/output" -maxdepth 1 -type f | wc -l) == 9 ]]
	[[ $(wc -l <"$fixture/output/sha256sums") == 8 ]]
	(cd "$fixture/output" && sha256sum --check --status sha256sums)
	checks=$((checks + 1))
	for fs in squashfs ext4; do
		for boot in bios efi; do
			for format in img.gz qcow2; do
				selected="$fixture/output/catwrt-next-v-test-x86-64-$fs-$boot.$format"
				if [[ $format == img.gz ]]; then
					output=$(gzip -dc "$selected")
					[[ $output == "$fs $boot img" ]]
				else
					[[ $(cat "$selected") == "$fs $boot qcow2" ]]
				fi
				checks=$((checks + 1))
			done
		done
	done
	cp "$fixture/input/upstream-squashfs-combined.qcow2" "$fixture/input/duplicate-squashfs-combined.qcow2"
	if output=$(collect_images "$fixture/input" "$fixture/duplicate-output" v-test 2>&1); then
		fail 'self-test: ambiguous output accepted'
	fi
	[[ $output == *'found 2'* && $output == *'ImageBuilder produced'* ]]
	checks=$((checks + 1))
	rm -- "$fixture/input/duplicate-squashfs-combined.qcow2" "$fixture/input/upstream-ext4-combined-efi.img.gz"
	if output=$(collect_images "$fixture/input" "$fixture/missing-output" v-test 2>&1); then
		fail 'self-test: missing output accepted'
	fi
	[[ $output == *'ext4/efi/img.gz'* && $output == *'ImageBuilder produced'* ]]
	checks=$((checks + 1))
	printf '%s - 1.0-r1\n' catwrt-base cattools luci-theme-argon luci-app-openclash tailscale luci-app-appfilter luci-app-mosdns >"$fixture/valid.manifest"
	check_manifest "$fixture/valid.manifest"
	checks=$((checks + 1))
	for package in catwrt-base cattools luci-theme-argon luci-app-openclash tailscale luci-app-appfilter luci-app-mosdns; do
		awk -v name="$package" '$1 != name' "$fixture/valid.manifest" >"$fixture/invalid.manifest"
		if output=$(check_manifest "$fixture/invalid.manifest" 2>&1); then
			fail "self-test: missing required package accepted: $package"
		fi
		[[ $output == *"Manifest missing required package: $package"* ]]
		checks=$((checks + 1))
	done
	for package in luci-app-attendedsysupgrade luci-i18n-attendedsysupgrade-zh-cn attendedsysupgrade-common owut luci-app-passwall; do
		cp "$fixture/valid.manifest" "$fixture/invalid.manifest"
		printf '%s - 1.0-r1\n' "$package" >>"$fixture/invalid.manifest"
		if output=$(check_manifest "$fixture/invalid.manifest" 2>&1); then
			fail "self-test: forbidden package accepted: $package"
		fi
		[[ $output == *"Manifest contains forbidden package: $package"* ]]
		checks=$((checks + 1))
	done
	if output=$(require_packages "$fixture/no-packages" 2>&1); then
		fail 'self-test: missing package artifacts accepted'
	fi
	[[ $output == *'run bash scripts/build-packages.sh first'* ]]
	checks=$((checks + 1))
	mkdir -p "$fixture/local-packages"
	if output=$(require_packages "$fixture/local-packages" 2>&1); then
		fail 'self-test: absent APKs accepted'
	fi
	[[ $output == *'Missing *.apk'* ]]
	checks=$((checks + 1))
	printf 'fixture\n' >"$fixture/local-packages/test.apk"
	for selected in packages.adb signing-public-key.pem; do
		if output=$(require_packages "$fixture/local-packages" 2>&1); then
			fail "self-test: missing $selected accepted"
		fi
		[[ $output == *"Missing or empty $fixture/local-packages/$selected"* ]]
		printf 'fixture\n' >"$fixture/local-packages/$selected"
		checks=$((checks + 1))
	done
	require_packages "$fixture/local-packages"
	checks=$((checks + 1))
	rm -rf -- "$fixture"
	trap - EXIT
	printf 'build-image self-test: %d checks passed\n' "$checks"
}

if [[ ${1:-} == --self-test && $# == 1 ]]; then
	self_test
	exit 0
fi
[[ $# == 0 ]] || fail 'Usage: bash scripts/build-image.sh [--self-test]'

started=$SECONDS
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
packages_dir=${PACKAGES_DIR:-out/packages}
require_packages "$packages_dir"

if [[ ${CATWRT_IN_CONTAINER:-0} != 1 && ${CI:-false} != true ]]; then
	out_dir=${OUT_DIR:-out/images}
	mkdir -p -- "$out_dir"
	packages_mount=$(
		cd "$packages_dir"
		pwd -W 2>/dev/null || pwd
	)
	docker build --platform linux/amd64 -t catwrt-build -f docker/build.Dockerfile .
	docker_args=(--platform linux/amd64
		-v "$(pwd -W 2>/dev/null || pwd):/src:ro"
		-v "$packages_mount:/input-packages:ro"
		-v catwrt-work:/work -e PACKAGES_DIR=/input-packages -e OUT_DIR=/tmp/catwrt-images)
	container=$(MSYS_NO_PATHCONV=1 docker create "${docker_args[@]}" catwrt-build bash scripts/build-image.sh)
	trap 'MSYS_NO_PATHCONV=1 docker rm "$container" >/dev/null' EXIT
	MSYS_NO_PATHCONV=1 docker start --attach "$container"
	container_status=$(MSYS_NO_PATHCONV=1 docker inspect --format '{{.State.ExitCode}}' "$container")
	[[ $container_status == 0 ]] || fail "Build container exited with status $container_status; see diagnostics above"
	MSYS_NO_PATHCONV=1 docker cp "$container:/tmp/catwrt-images/." "$out_dir"
	printf '\n镜像已导出至：%s\n总用时：%s 秒\n' "$out_dir" "$((SECONDS - started))"
	exit 0
fi

for tool in curl qemu-img sha256sum tar zstd make gcc g++ file gawk gettext git python3 \
	rsync unzip wget xz openssl which xsltproc gzip find stat; do
	command -v "$tool" >/dev/null 2>&1 || fail "Missing build dependency: $tool (use docker/build.Dockerfile)"
done
[[ $(id -u) != 0 ]] || fail 'The ImageBuilder requires a non-root user; run as builder'

# release.env is trusted repository configuration.
# shellcheck disable=SC1091
source config/release.env
[[ $IMMORTALWRT_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid IMMORTALWRT_VERSION'
# TARGET and SUBTARGET come from release.env, which ShellCheck cannot follow.
# shellcheck disable=SC2153
[[ $TARGET == x86 && $SUBTARGET == 64 && $ARCH == x86_64 ]] || fail 'This builder supports only TARGET=x86 SUBTARGET=64 ARCH=x86_64'
[[ $CATWRT_VERSION =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail 'Invalid CATWRT_VERSION'
[[ $ROOTFS_SIZE =~ ^[1-9][0-9]*$ ]] || fail 'ROOTFS_SIZE must be a positive integer in MiB'
package_list=$(parse_packages config/packages.txt config/drivers.txt)
package_list=${package_list//$'\n'/ }
packages_dir=$(cd "$packages_dir" && pwd -P)
openssl pkey -pubin -in "$packages_dir/signing-public-key.pem" -noout || fail "Invalid signing public key: $packages_dir/signing-public-key.pem; run bash scripts/build-packages.sh first"

work=${WORK_DIR:-/work}
if [[ ${CI:-false} == true && ${CATWRT_IN_CONTAINER:-0} != 1 && -z ${WORK_DIR:-} ]]; then
	work=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/catwrt-work
fi
mkdir -p -- "$work"
work=$(cd "$work" && pwd -P)
repo_real=$(pwd -P)
case "$work/" in
"$repo_real/"*) fail 'WORK_DIR must be outside the repository (ImageBuilder keeps its local index signing key there)' ;;
esac
ib="$work/imagebuilder-$IMMORTALWRT_VERSION"
output_path=${OUT_DIR:-"$repo/out/images"}
[[ $output_path == /* ]] || output_path="$repo/$output_path"
dl="$work/dl"
mkdir -p -- "$dl"
base_url="https://downloads.immortalwrt.org/releases/$IMMORTALWRT_VERSION/targets/$TARGET/$SUBTARGET"
manifest="$dl/sha256sums-$IMMORTALWRT_VERSION-$TARGET-$SUBTARGET"
download "$base_url/sha256sums" "$manifest"
selected=$(select_imagebuilder "$manifest" "$IMMORTALWRT_VERSION" "$TARGET" "$SUBTARGET")
ib_hash=${selected%% *}
ib_file=${selected#* }
archive="$dl/$ib_file"
if [[ ! -f $archive ]]; then
	download "$base_url/$ib_file" "$archive"
fi
verify_sha256 "$archive" "$ib_hash"

extract_dir=''
staging=''
cleanup() {
	if [[ -n $extract_dir ]]; then
		rm -rf -- "$extract_dir"
	fi
	if [[ -n $staging ]]; then
		rm -rf -- "$staging"
	fi
}
trap cleanup EXIT
if [[ -d $ib ]]; then
	[[ -f $ib/.catwrt-imagebuilder-sha256 && $(cat "$ib/.catwrt-imagebuilder-sha256") == "$ib_hash" ]] || fail "ImageBuilder cache checksum changed or extraction incomplete: $ib; remove this cache and retry"
	printf '复用 ImageBuilder 缓存：imagebuilder-%s\n' "$IMMORTALWRT_VERSION"
else
	extract_dir=$(mktemp -d "$work/.imagebuilder-extract.XXXXXX")
	tar --zstd -xf "$archive" -C "$extract_dir" --strip-components=1
	[[ -f $extract_dir/Makefile && -d $extract_dir/include ]] || fail "Invalid ImageBuilder archive layout: $archive"
	printf '%s\n' "$ib_hash" >"$extract_dir/.catwrt-imagebuilder-sha256"
	mv -- "$extract_dir" "$ib"
	extract_dir=''
fi

mkdir -p -- "$ib/packages" "$ib/keys"
# ImageBuilder regenerates its own local index; trust the key that signed the APKs.
find "$ib/packages" -maxdepth 1 -type f \( -name '*.apk' -o -name packages.adb \) -delete
cp -- "$packages_dir/"*.apk "$ib/packages/"
cp -- "$packages_dir/signing-public-key.pem" "$ib/keys/catwrt-next.pem"
# Vendored MosDNS: fetch the pinned sbwml release, verify it, and add its APKs to
# the ImageBuilder's local feed so luci-app-mosdns and its runtime install from
# there. The cache file name carries the checksum so a version bump never reuses a
# stale tarball.
# shellcheck disable=SC1091
source "$repo/config/mosdns.env"
mosdns_tarball="$dl/mosdns-$MOSDNS_TARBALL_SHA256.tar.gz"
if [[ ! -f $mosdns_tarball ]]; then
	download "$MOSDNS_TARBALL_URL" "$mosdns_tarball"
fi
verify_sha256 "$mosdns_tarball" "$MOSDNS_TARBALL_SHA256"
mosdns_extract=$(mktemp -d "$work/.mosdns.XXXXXX")
tar -xzf "$mosdns_tarball" -C "$mosdns_extract"
shopt -s nullglob
mosdns_apks=("$mosdns_extract"/packages_ci/*.apk)
shopt -u nullglob
[[ ${#mosdns_apks[@]} -gt 0 ]] || fail "No MosDNS APKs in $mosdns_tarball"
cp -- "${mosdns_apks[@]}" "$ib/packages/"
rm -rf -- "$mosdns_extract"
produced="$ib/bin/targets/$TARGET/$SUBTARGET"
# A cached build must not satisfy collection with images from an earlier run.
if [[ -d $produced ]]; then
	find "$produced" -maxdepth 1 -type f -delete
fi
# The stock config also enables ISO/VDI/VMDK/VHDX; we ship only img.gz and qcow2,
# so disable the rest (ISO needs mkisofs) and keep qcow2, both filesystems and GRUB.
sed -i -E 's/^CONFIG_(ISO|VDI|VMDK|VHDX)_IMAGES=y$/# CONFIG_\1_IMAGES is not set/' "$ib/.config"
for option in QCOW2_IMAGES TARGET_ROOTFS_EXT4FS TARGET_ROOTFS_SQUASHFS GRUB_IMAGES GRUB_EFI_IMAGES TARGET_IMAGES_GZIP; do
	grep -qx "CONFIG_$option=y" "$ib/.config" || fail "ImageBuilder .config lacks CONFIG_$option=y"
done
(
	cd "$ib"
	make image PROFILE=generic "ROOTFS_PARTSIZE=$ROOTFS_SIZE" "PACKAGES=$package_list" EXTRA_IMAGE_NAME=
)

staging=$(mktemp -d "$work/.images.XXXXXX")
collect_images "$produced" "$staging" "$CATWRT_VERSION"
shopt -s nullglob
manifests=("$produced"/*.manifest)
shopt -u nullglob
if [[ ${#manifests[@]} != 1 ]]; then
	list_outputs "$produced"
	fail "Expected one ImageBuilder manifest; found ${#manifests[@]}"
fi
check_manifest "${manifests[0]}"
cp -- "${manifests[0]}" "$staging/catwrt-next-${CATWRT_VERSION}-x86-64.manifest"
mkdir -p -- "$output_path"
cp -- "$staging/"* "$output_path/"
printf '\n镜像构建完成：\n'
for artifact in "$staging/"*; do
	printf '  %s  %s 字节\n' "$(basename -- "$artifact")" "$(stat -c %s "$artifact")"
done
printf '输出目录：%s\n总用时：%s 秒\n' "${OUT_DIR:-out/images}" "$((SECONDS - started))"
