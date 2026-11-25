#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C

fail() {
	printf 'build-packages: %s\n' "$*" >&2
	exit 1
}

# Select exactly one SDK for this release; the compiler version is upstream-owned.
select_sdk() {
	local manifest=$1 version=$2 target=$3 subtarget=$4
	awk -v prefix="immortalwrt-sdk-${version}-${target}-${subtarget}_" '
		{
			name = $2
			sub(/^\*/, "", name)
			if (index(name, prefix) == 1 && name ~ /\.Linux-x86_64\.tar\.zst$/ &&
			    name !~ /\// && $1 ~ /^[[:xdigit:]]+$/ && length($1) == 64) {
				count++
				selected = tolower($1) " " name
			}
		}
		END {
			if (count != 1) {
				printf "Expected one SDK matching %s*.Linux-x86_64.tar.zst; found %d\n", prefix, count > "/dev/stderr"
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

own_package_name() {
	local filename=${1##*/} name
	# APK versions start with a digit; split off the optional package release too.
	[[ $filename =~ ^(.+)-([0-9][A-Za-z0-9._+~]*(-r[0-9]+)?)\.apk$ ]] || return 1
	name=${BASH_REMATCH[1]}
	case "$name" in
	cattools | catwrt-base | UAmask | luci-app-poweroff | luci-i18n-poweroff-?*) printf '%s\n' "$name" ;;
	*) return 1 ;;
	esac
}

select_export_packages() {
	local directory=$1 with_poweroff=$2 listing artifact name
	local -a expected=(cattools catwrt-base UAmask) selected=()
	local -A counts=()
	if [[ $with_poweroff == 1 ]]; then
		expected+=(luci-app-poweroff luci-i18n-poweroff-zh-cn)
	fi
	[[ -d $directory ]] || fail "find: missing APK directory: $directory"
	listing=$(find "$directory" -type f -name '*.apk' | sort) || fail "find/sort: failed to list APKs under $directory"
	while IFS= read -r artifact; do
		if ! name=$(own_package_name "$artifact"); then
			continue
		fi
		if [[ $with_poweroff != 1 && $name == luci-* ]]; then
			continue
		fi
		counts[$name]=$((${counts[$name]:-0} + 1))
		[[ ${counts[$name]} == 1 ]] || fail "select_export_packages: duplicate APK for $name under $directory"
		selected+=("$artifact")
	done <<<"$listing"
	for name in "${expected[@]}"; do
		[[ ${counts[$name]:-0} == 1 ]] || fail "select_export_packages: missing APK for $name under $directory"
	done
	printf '%s\n' "${selected[@]}"
}

# luci-app-campus-auth is proprietary and built outside this repository. Only a
# checksum-pinned copy is fetched here; reuse the cache so reruns stay offline.
fetch_external_apk() {
	local name=$1 url=$2 sha256=$3 cache=$4 staged
	[[ $name =~ ^luci-app-campus-auth-[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+\.apk$ ]] ||
		fail "fetch_external_apk: unexpected APK name: $name"
	staged="$cache/$name"
	if [[ ! -f $staged ]]; then
		download "$url" "$staged"
	fi
	verify_sha256 "$staged" "$sha256"
	printf '%s\n' "$staged"
}

self_test() {
	local fixture selected output artifact name checks=0 transport_status=0 response external_sha
	local -a own_apks=(cattools-1.0.1-r1.apk catwrt-base-1-r1.apk UAmask-0.4.3-r1.apk
		luci-app-poweroff-1-r1.apk luci-i18n-poweroff-zh-cn-0.261116.52078.apk)
	fixture=$(mktemp -d)
	trap 'rm -rf -- "$fixture"' EXIT
	printf '%064d *immortalwrt-sdk-25.12.2-x86-64_gcc-test_musl.Linux-x86_64.tar.zst\n' 0 >"$fixture/sums"
	printf '%064d *immortalwrt-sdk-25.12.1-x86-64_gcc-other.Linux-x86_64.tar.zst\n' 0 >>"$fixture/sums"
	selected=$(select_sdk "$fixture/sums" 25.12.2 x86 64)
	[[ ${selected#* } == immortalwrt-sdk-25.12.2-x86-64_gcc-test_musl.Linux-x86_64.tar.zst ]]
	checks=$((checks + 1))
	if select_sdk "$fixture/sums" 25.12.3 x86 64 2>/dev/null; then
		fail 'self-test: missing SDK accepted'
	fi
	checks=$((checks + 1))
	cat "$fixture/sums" "$fixture/sums" >"$fixture/duplicates"
	if select_sdk "$fixture/duplicates" 25.12.2 x86 64 2>/dev/null; then
		fail 'self-test: duplicate SDK accepted'
	fi
	checks=$((checks + 1))
	printf 'fixture\n' >"$fixture/archive"
	selected=$(sha256sum "$fixture/archive")
	verify_sha256 "$fixture/archive" "${selected%% *}"
	checks=$((checks + 1))
	if output=$(verify_sha256 "$fixture/archive" invalid 2>&1); then
		fail 'self-test: invalid checksum accepted'
	fi
	[[ $output == *'expected invalid; actual '* ]]
	checks=$((checks + 1))
	# Replace curl locally: exercise HTTP and transport failures without a network.
	response='503|text/html|https://example.invalid/sdk'
	# Called indirectly by download.
	# shellcheck disable=SC2317
	curl() {
		printf '%s' "$response"
		return "$transport_status"
	}
	if output=$(download https://example.invalid/sdk "$fixture/download" 2>&1); then
		fail 'self-test: HTTP failure accepted'
	fi
	[[ $output == *'HTTP=503; type=text/html; final=https://example.invalid/sdk'* ]]
	checks=$((checks + 1))
	transport_status=28
	response='000||https://example.invalid/sdk'
	if output=$(download https://example.invalid/sdk "$fixture/download" 2>&1); then
		fail 'self-test: transport failure accepted'
	fi
	[[ $output == *'curl=28; HTTP=000; type=; final=https://example.invalid/sdk'* ]]
	checks=$((checks + 1))
	unset -f curl
	printf 'external\n' >"$fixture/luci-app-campus-auth-0.7.0-r1.apk"
	external_sha=$(sha256sum "$fixture/luci-app-campus-auth-0.7.0-r1.apk")
	external_sha=${external_sha%% *}
	selected=$(fetch_external_apk luci-app-campus-auth-0.7.0-r1.apk https://example.invalid/pkg.apk \
		"$external_sha" "$fixture")
	[[ $selected == "$fixture/luci-app-campus-auth-0.7.0-r1.apk" ]] ||
		fail 'self-test: cached external APK not reused'
	checks=$((checks + 1))
	if output=$(fetch_external_apk luci-app-campus-auth-0.7.0-r1.apk https://example.invalid/pkg.apk \
		invalid "$fixture" 2>&1); then
		fail 'self-test: external APK checksum mismatch accepted'
	fi
	[[ $output == *'expected invalid; actual '* ]]
	checks=$((checks + 1))
	if output=$(fetch_external_apk luci-app-campus-auth-0.7.0.apk https://example.invalid/pkg.apk \
		"$external_sha" "$fixture" 2>&1); then
		fail 'self-test: unexpected external APK name accepted'
	fi
	[[ $output == *'unexpected APK name'* ]]
	checks=$((checks + 1))
	mkdir "$fixture/packages"
	for artifact in "${own_apks[@]}" cattools-extra-1.apk cattools-foo.apk \
		luci-base-1.apk ucode-1.apk luci-app-poweroff-ng-1.apk uamask-0.4.3-r1.apk \
		UAmask-extra-1.apk; do
		: >"$fixture/packages/$artifact"
	done
	selected=$(select_export_packages "$fixture/packages" 1)
	output=$(printf '%s\n' "${own_apks[@]/#/$fixture/packages/}" | sort)
	[[ $selected == "$output" ]] || fail 'self-test: APK export filter selected the wrong files'
	checks=$((checks + 1))
	for artifact in "${own_apks[@]}"; do
		mv -- "$fixture/packages/$artifact" "$fixture/missing.apk"
		if output=$(select_export_packages "$fixture/packages" 1 2>&1); then
			fail "self-test: missing $artifact accepted"
		fi
		name=$(own_package_name "$artifact")
		[[ $output == *"missing APK for $name under $fixture/packages"* ]]
		mv -- "$fixture/missing.apk" "$fixture/packages/$artifact"
		checks=$((checks + 1))
	done
	selected=$(select_export_packages "$fixture/packages" 0)
	output=$(printf '%s\n' "$fixture/packages/UAmask-0.4.3-r1.apk" \
		"$fixture/packages/cattools-1.0.1-r1.apk" "$fixture/packages/catwrt-base-1-r1.apk" | sort)
	[[ $selected == "$output" ]]
	checks=$((checks + 1))
	: >"$fixture/packages/cattools-2-r1.apk"
	if output=$(select_export_packages "$fixture/packages" 1 2>&1); then
		fail 'self-test: duplicate own APK accepted'
	fi
	[[ $output == *"duplicate APK for cattools under $fixture/packages"* ]]
	checks=$((checks + 1))
	rm -rf -- "$fixture"
	trap - EXIT
	printf 'build-packages self-test: %d checks passed\n' "$checks"
}

if [[ ${1:-} == --self-test && $# == 1 ]]; then
	self_test
	exit 0
fi
[[ $# == 0 ]] || fail 'Usage: bash scripts/build-packages.sh [--self-test]'

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

if [[ ${CATWRT_IN_CONTAINER:-0} != 1 && ${CI:-false} != true ]]; then
	out_dir=${OUT_DIR:-out/packages}
	mkdir -p -- "$out_dir"
	docker build --platform linux/amd64 -t catwrt-build -f docker/build.Dockerfile .
	docker_args=(--platform linux/amd64
		-v "$(pwd -W 2>/dev/null || pwd):/src:ro"
		-v catwrt-work:/work -e OUT_DIR=/work/output)
	if [[ -n ${APK_SIGN_KEY:-} ]]; then
		docker_args+=(-e APK_SIGN_KEY)
	fi
	container=$(MSYS_NO_PATHCONV=1 docker create "${docker_args[@]}" catwrt-build bash scripts/build-packages.sh)
	trap 'MSYS_NO_PATHCONV=1 docker rm "$container" >/dev/null' EXIT
	MSYS_NO_PATHCONV=1 docker start --attach "$container"
	container_status=$(MSYS_NO_PATHCONV=1 docker inspect --format '{{.State.ExitCode}}' "$container")
	[[ $container_status == 0 ]] || fail "Build container exited with status $container_status; see diagnostics above"
	MSYS_NO_PATHCONV=1 docker cp "$container:/work/output/." "$out_dir"
	printf '\n软件包已导出至：%s\n' "$out_dir"
	exit 0
fi

for tool in curl sha256sum tar zstd make gcc g++ file readelf gawk gettext \
	git python3 rsync unzip wget xz openssl which xsltproc cargo rustup cc; do
	command -v "$tool" >/dev/null 2>&1 || fail "Missing build dependency: $tool (use docker/build.Dockerfile)"
done
[[ $(id -u) != 0 ]] || fail 'The SDK requires a non-root user; run as builder'

# release.env is trusted repository configuration.
# shellcheck disable=SC1091
source config/release.env
# Pinned UAmask source; see config/uamask.env.
# shellcheck disable=SC1091
source config/uamask.env
# UAMASK_* come from config/uamask.env, which ShellCheck cannot follow.
# shellcheck disable=SC2153
[[ $UAMASK_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid UAMASK_VERSION'
[[ $UAMASK_TARBALL_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid UAMASK_TARBALL_SHA256'
# Pinned proprietary APK; see config/campus-auth.env.
# shellcheck disable=SC1091
source config/campus-auth.env
# CAMPUS_AUTH_* come from config/campus-auth.env, which ShellCheck cannot follow.
# shellcheck disable=SC2153
[[ $CAMPUS_AUTH_APK_FILE =~ ^luci-app-campus-auth-[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+\.apk$ ]] || fail 'Invalid CAMPUS_AUTH_APK_FILE'
# shellcheck disable=SC2153
[[ $CAMPUS_AUTH_APK_URL =~ ^https://[^[:space:]]+$ ]] || fail 'Invalid CAMPUS_AUTH_APK_URL'
# shellcheck disable=SC2153
[[ $CAMPUS_AUTH_APK_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid CAMPUS_AUTH_APK_SHA256'
[[ $IMMORTALWRT_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid IMMORTALWRT_VERSION'
# TARGET and SUBTARGET come from release.env, which ShellCheck cannot follow.
# shellcheck disable=SC2153
[[ $TARGET == x86 && $SUBTARGET == 64 && $ARCH == x86_64 ]] || fail 'This builder supports only TARGET=x86 SUBTARGET=64 ARCH=x86_64'

work=${WORK_DIR:-/work}
# Hosted CI runners cannot create /work; use their writable temporary storage.
if [[ ${CI:-false} == true && ${CATWRT_IN_CONTAINER:-0} != 1 && -z ${WORK_DIR:-} ]]; then
	work=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/catwrt-work
fi
mkdir -p -- "$work"
work=$(cd "$work" && pwd -P)
repo_real=$(pwd -P)
case "$work/" in
"$repo_real/"*) fail 'WORK_DIR must be outside the repository (SDK signing keys stay there)' ;;
esac
sdk="$work/sdk-$IMMORTALWRT_VERSION"
output_path=${OUT_DIR:-"$repo/out/packages"}
[[ $output_path == /* ]] || output_path="$repo/$output_path"
dl="$work/dl"
mkdir -p -- "$dl"

base_url="https://downloads.immortalwrt.org/releases/$IMMORTALWRT_VERSION/targets/$TARGET/$SUBTARGET"
manifest="$dl/sha256sums-$IMMORTALWRT_VERSION-$TARGET-$SUBTARGET"
download "$base_url/sha256sums" "$manifest"
selected=$(select_sdk "$manifest" "$IMMORTALWRT_VERSION" "$TARGET" "$SUBTARGET")
sdk_hash=${selected%% *}
sdk_file=${selected#* }
archive="$dl/$sdk_file"
if [[ ! -f $archive ]]; then
	download "$base_url/$sdk_file" "$archive"
fi
verify_sha256 "$archive" "$sdk_hash"

extract_dir=''
cleanup() {
	rm -f -- "$sdk/private-key.pem" "$sdk/public-key.pem"
	if [[ -n $extract_dir ]]; then
		rm -rf -- "$extract_dir"
	fi
}
trap cleanup EXIT
if [[ -d $sdk ]]; then
	[[ -f $sdk/.catwrt-sdk-sha256 && $(cat "$sdk/.catwrt-sdk-sha256") == "$sdk_hash" ]] || fail "SDK cache checksum changed or extraction incomplete: $sdk; remove this cache and retry"
	printf '复用 SDK 缓存：sdk-%s\n' "$IMMORTALWRT_VERSION"
else
	extract_dir=$(mktemp -d "$work/.sdk-extract.XXXXXX")
	tar --zstd -xf "$archive" -C "$extract_dir" --strip-components=1
	[[ -f $extract_dir/rules.mk && -f $extract_dir/Makefile ]] || fail "Invalid SDK archive layout: $archive"
	printf '%s\n' "$sdk_hash" >"$extract_dir/.catwrt-sdk-sha256"
	mv -- "$extract_dir" "$sdk"
	extract_dir=''
fi

# Restrict key file permissions and remove both SDK key files on every exit.
umask 077
if [[ -n ${APK_SIGN_KEY:-} ]]; then
	printf '%s\n' "$APK_SIGN_KEY" >"$sdk/private-key.pem"
	unset APK_SIGN_KEY
	openssl pkey -in "$sdk/private-key.pem" -passin pass: -pubout -out "$sdk/public-key.pem"
	project_key="$repo/package/catwrt-base/files/etc/apk/keys/catwrt-next.pem"
	[[ -f $project_key ]] || fail "Missing project public key: $project_key"
	project_public=$(openssl pkey -pubin -in "$project_key" -pubout)
	[[ $(cat "$sdk/public-key.pem") == "$project_public" ]] || fail "APK_SIGN_KEY public key does not match $project_key"
else
	printf 'WARNING: unsigned-by-project build (temporary key)\n' >&2
	openssl ecparam -name prime256v1 -genkey -noout -out "$sdk/private-key.pem"
	openssl pkey -in "$sdk/private-key.pem" -pubout -out "$sdk/public-key.pem"
fi
openssl pkey -pubin -in "$sdk/public-key.pem" -text -noout | grep -q 'ASN1 OID: prime256v1' || fail 'APK signing requires an ECDSA prime256v1 key'
fingerprint=$(sha256sum "$sdk/public-key.pem")
fingerprint=${fingerprint%% *}
umask 022

# Cargo needs a writable source tree even when the host checkout is read-only.
rsync -a --delete --exclude /target/ "$repo/package/cattools/" "$work/cattools/"
export CARGO_TARGET_DIR="$work/cargo-target"
# Override cattools' .cargo/config.toml (x86_64-linux-musl-gcc): Rust's musl target
# links self-contained with the host cc and yields a static-pie; Debian's musl-gcc
# wrapper would produce a dynamically linked binary instead.
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=cc
(
	cd "$work/cattools"
	cargo build --release --locked --target x86_64-unknown-linux-musl
)
cattools_bin="$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/cattools"
[[ -f $cattools_bin ]] || fail "Missing cargo output: $cattools_bin"
binary_info=$(file -b "$cattools_bin")
[[ $binary_info == *'ELF 64-bit'* && $binary_info == *'x86-64'* && $binary_info == *'static'* ]] || fail "Expected a static x86_64 ELF: $cattools_bin; file=$binary_info"
if readelf -l "$cattools_bin" | grep -q INTERP || readelf -d "$cattools_bin" | grep -q NEEDED; then
	fail "Binary has a dynamic interpreter or shared-library dependency: $cattools_bin"
fi

# UAmask is GPL-3.0-only: keep its sources out of this GPL-2.0-only repository and
# fetch the pinned upstream release at build time. Only the packaging Makefile is ours.
uamask_version=$UAMASK_VERSION
uamask_archive="$dl/UAmask-$uamask_version.tar.gz"
if [[ ! -f $uamask_archive ]]; then
	download "$UAMASK_TARBALL_URL" "$uamask_archive"
fi
verify_sha256 "$uamask_archive" "$UAMASK_TARBALL_SHA256"
uamask_src="$work/uamask-src"
rm -rf -- "$uamask_src"
mkdir -p -- "$uamask_src"
tar -xzf "$uamask_archive" -C "$uamask_src" --strip-components=1
for required in go.mod go.sum src files/UAmask.init files/UAmask.uci; do
	[[ -e $uamask_src/$required ]] || fail "Invalid UAmask source layout: missing $required in $uamask_archive"
done
(
	export GOTOOLCHAIN=local GO111MODULE=on CGO_ENABLED=0 GOOS=linux GOARCH=amd64
	export GOFLAGS=-mod=mod GOPATH="$work/go" GOMODCACHE="$work/go-mod" GOCACHE="$work/go-cache"
	cd "$uamask_src"
	go build -trimpath -ldflags "-s -w -X main.version=$uamask_version" -o "$work/UAmask" ./src
)
uamask_bin="$work/UAmask"
[[ -f $uamask_bin ]] || fail "Missing Go build output: $uamask_bin"
binary_info=$(file -b "$uamask_bin")
[[ $binary_info == *'ELF 64-bit'* && $binary_info == *'x86-64'* && $binary_info == *'statically linked'* ]] || fail "Expected a static x86_64 ELF: $uamask_bin; file=$binary_info"
if readelf -l "$uamask_bin" | grep -q INTERP || readelf -d "$uamask_bin" | grep -q NEEDED; then
	fail "Binary has a dynamic interpreter or shared-library dependency: $uamask_bin"
fi

rm -rf -- "$sdk/package/catwrt"
wrapper_dir="$sdk/package/catwrt/cattools"
mkdir -p "$wrapper_dir"
cp -a "$repo/package/catwrt-base" "$sdk/package/catwrt/"
cp "$repo/package/cattools/Makefile" "$wrapper_dir/Makefile"
cp "$cattools_bin" "$wrapper_dir/cattools"
[[ -f $repo/package/uamask/Makefile ]] || fail 'Missing package/uamask/Makefile'
cp -a "$repo/package/uamask" "$sdk/package/catwrt/"
packages=(catwrt-base cattools UAmask)
with_poweroff=0
if [[ -d $repo/package/luci-app-poweroff ]]; then
	[[ -f $repo/package/luci-app-poweroff/Makefile ]] || fail 'Missing package/luci-app-poweroff/Makefile'
	cp -a "$repo/package/luci-app-poweroff" "$sdk/package/catwrt/"
	packages+=(luci-app-poweroff)
	with_poweroff=1
fi
# UAmask declares DEPENDS on luci-compat, so its package definition must be known
# to the SDK even though UAmask is not preinstalled in the image.
(
	cd "$sdk"
	./scripts/feeds update base luci || fail "./scripts/feeds update base luci failed in $sdk"
	./scripts/feeds install -p base ucode libnl-tiny libubox ubus rpcd lua || fail "./scripts/feeds install -p base ucode libnl-tiny libubox ubus rpcd lua failed in $sdk"
	./scripts/feeds install luci-base luci-compat || fail "./scripts/feeds install luci-base luci-compat failed in $sdk"
)

cd "$sdk"
make_args=("CATWRT_VERSION=$CATWRT_VERSION" "IMMORTALWRT_VERSION=$IMMORTALWRT_VERSION"
	"CATWRT_ARCH=$ARCH" "CATWRT_BUILD_DATE=$(date -u +%Y-%m-%d)"
	"CATTOOLS_BIN=$wrapper_dir/cattools" "UAMASK_BIN=$uamask_bin"
	"UAMASK_SRC=$uamask_src" "UAMASK_FILES=$uamask_src/files")
cat >.config <<'EOF'
CONFIG_ALL=n
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_SIGNED_PACKAGES=y
EOF
for package in "${packages[@]}"; do
	printf 'CONFIG_PACKAGE_%s=m\n' "$package" >>.config
done
make "${make_args[@]}" defconfig
grep -qx 'CONFIG_SIGNED_PACKAGES=y' .config || fail 'SDK defconfig disabled signed packages'
# Drop earlier APKs (including the poweroff translation subpackage) so cached SDK runs
# leave exactly one APK per exported name.
if [[ -d $sdk/bin/packages ]]; then
	for package in "${packages[@]}" luci-i18n-poweroff-zh-cn; do
		find "$sdk/bin/packages" -type f -name "$package-*.apk" -delete
	done
fi
for package in "${packages[@]}"; do
	# make targets address the SDK package directory, which is lowercase for UAmask
	# (the APK/package name is UAmask). Reinstall payloads cleanly on cached SDK runs too.
	dir=$package
	[[ $package == UAmask ]] && dir=uamask
	make "${make_args[@]}" "package/$dir/clean" V=s
	make "${make_args[@]}" "package/$dir/compile" V=s
done
out_dir=$output_path
mkdir -p -- "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)
selected=$(select_export_packages "$sdk/bin/packages" "$with_poweroff")
mapfile -t artifacts <<<"$selected"
host_apk="$sdk/staging_dir/host/bin/apk"
[[ -x $host_apk ]] || fail "apk mkndx: missing executable: $host_apk"
[[ -f $sdk/private-key.pem ]] || fail "apk mkndx --sign: missing SDK signing key: $sdk/private-key.pem"
find "$out_dir" -maxdepth 1 -type f \( -name '*.apk' -o -name packages.adb \) -delete
for artifact in "${artifacts[@]}"; do
	cp -- "$artifact" "$out_dir/" || fail "cp: failed to export $artifact to $out_dir"
done
external_apk=$(fetch_external_apk "$CAMPUS_AUTH_APK_FILE" "$CAMPUS_AUTH_APK_URL" "$CAMPUS_AUTH_APK_SHA256" "$dl")
cp -- "$external_apk" "$out_dir/" || fail "cp: failed to export $external_apk to $out_dir"
cp -- "$sdk/public-key.pem" "$out_dir/signing-public-key.pem"
chmod 644 "$out_dir/signing-public-key.pem"
# Like the SDK package/index target: individual APKs built by apk mkpkg do not carry
# embedded signatures, so skip input trust checks and sign packages.adb with the SDK key.
(
	cd "$out_dir"
	"$host_apk" mkndx --allow-untrusted --sign "$sdk/private-key.pem" \
		--output packages.adb ./*.apk || fail "$host_apk mkndx failed for $out_dir/packages.adb"
)
[[ -s $out_dir/packages.adb ]] || fail "apk mkndx: missing or empty index: $out_dir/packages.adb"
printf '\n已导出的软件包名称：\n'
for artifact in "${artifacts[@]}"; do
	printf '  %s\n' "$(own_package_name "$artifact")"
done
printf '  %s（外部已构建，经 SHA256 校验）\n' "$CAMPUS_AUTH_APK_FILE"
printf '\n构建完成（软件包文件名包含版本）：\n'
for artifact in "$out_dir"/*.apk "$out_dir/packages.adb" "$out_dir/signing-public-key.pem"; do
	printf '  %s  %s 字节\n' "$(basename -- "$artifact")" "$(stat -c %s "$artifact")"
done
printf '签名公钥 SHA256：%s\n输出目录：%s\n' "$fingerprint" "${OUT_DIR:-out/packages}"
