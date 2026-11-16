#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temp_dir=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd)
test_root=$(mktemp -d "$temp_dir/catwrt-base-tests.XXXXXX")
case "$test_root" in
"$temp_dir"/catwrt-base-tests.*) ;;
*) exit 1 ;;
esac
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

export TEST_ROOT="$test_root"
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/init.d"
cp "$test_dir/fixtures/uci" "$TEST_ROOT/bin/uci"
chmod +x "$TEST_ROOT/bin/uci"

# Redirect filesystem probes and init calls into the isolated fixture tree.
sed -e "s|/etc/init.d/|$TEST_ROOT/init.d/|g" \
	-e "s|/www/luci-static/argon|$TEST_ROOT/argon|g" \
	-e "s|/usr/share/catwrt/|$TEST_ROOT/share/|g" \
	-e "s|/etc/banner|$TEST_ROOT/banner|g" \
	"$test_dir/../files/etc/uci-defaults/zz-catwrt-defaults" >"$TEST_ROOT/defaults"

assert_line() {
	if ! grep -Fqx -- "$1" "$2"; then
		printf 'Missing expected line: %s\n' "$1" >&2
		exit 1
	fi
}

assert_absent() {
	if grep -Fq -- "$1" "$2"; then
		printf 'Unexpected value: %s\n' "$1" >&2
		exit 1
	fi
}

# Missing optional packages, theme and imm_init section must be safe.
cat >"$TEST_ROOT/state" <<'EOF'
system.@system[0].hostname=stock
system.@system[0].timezone=CST-8
system.@system[0].zonename=Asia/Shanghai
network.lan.ipaddr=192.0.2.1
network.lan.netmask=255.255.255.0
luci.main.mediaurlbase=/luci-static/bootstrap
luci.main.lang=zh_cn
catwrt.repo=catwrt
catwrt.repo.mirror=vsean
catwrt.repo.custom=0
EOF
: >"$TEST_ROOT/uci.log"
sh "$TEST_ROOT/defaults"
assert_line 'system.@system[0].hostname=CatWrt' "$TEST_ROOT/state"
assert_line 'network.lan.ipaddr=192.168.1.4' "$TEST_ROOT/state"
assert_line 'network.lan.netmask=255.255.255.0' "$TEST_ROOT/state"
assert_line 'system.@system[0].timezone=CST-8' "$TEST_ROOT/state"
assert_line 'system.@system[0].zonename=Asia/Shanghai' "$TEST_ROOT/state"
assert_line 'luci.main.lang=zh_cn' "$TEST_ROOT/state"
assert_line 'luci.main.mediaurlbase=/luci-static/bootstrap' "$TEST_ROOT/state"
assert_line 'system.@imm_init[0]=imm_init' "$TEST_ROOT/state"
assert_line 'system.@imm_init[0].catwrt_init=1' "$TEST_ROOT/state"
assert_line 'commit' "$TEST_ROOT/uci.log"
assert_absent 'enabled=' "$TEST_ROOT/state"
assert_absent 'enable=' "$TEST_ROOT/state"
printf 'PASS: absent optional packages and theme\n'

# With every optional package present, disable each service and its known flags.
cat >>"$TEST_ROOT/state" <<'EOF'
system.@imm_init[0].catwrt_init=0
openclash.config=openclash
openclash.config.enable=1
zerotier.@zerotier[0]=zerotier
zerotier.@zerotier[0].enabled=1
ddns.global=ddns
ddns.global.enabled=1
ddns.example=service
ddns.example.enabled=1
ddns.@service[0]=service
ddns.@service[0].enabled=1
ddns-go.config=ddns-go
ddns-go.config.enabled=1
frpc.common=frpc
frpc.common.server_port=7000
EOF
# Remove the previous done flag before applying the second fixture.
sed '/^system\.@imm_init\[0\]\.catwrt_init=1$/d' "$TEST_ROOT/state" >"$TEST_ROOT/state.next"
mv "$TEST_ROOT/state.next" "$TEST_ROOT/state"
mkdir "$TEST_ROOT/argon"
for service in openclash tailscale zerotier frpc ddns ddns-go; do
	cat >"$TEST_ROOT/init.d/$service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$TEST_ROOT/services.log"
EOF
	chmod +x "$TEST_ROOT/init.d/$service"
done
sh "$TEST_ROOT/defaults"
assert_line 'luci.main.mediaurlbase=/luci-static/argon' "$TEST_ROOT/state"
assert_line 'openclash.config.enable=0' "$TEST_ROOT/state"
assert_line 'zerotier.@zerotier[0].enabled=0' "$TEST_ROOT/state"
assert_line 'ddns.example.enabled=0' "$TEST_ROOT/state"
assert_line 'ddns.@service[0].enabled=0' "$TEST_ROOT/state"
assert_line 'ddns.global.enabled=1' "$TEST_ROOT/state"
assert_line 'ddns-go.config.enabled=0' "$TEST_ROOT/state"
assert_line 'frpc.common.server_port=7000' "$TEST_ROOT/state"
assert_line 'catwrt.repo.mirror=vsean' "$TEST_ROOT/state"
assert_line 'catwrt.repo.custom=0' "$TEST_ROOT/state"
for service in openclash tailscale zerotier frpc ddns ddns-go; do
	assert_line "$service disable" "$TEST_ROOT/services.log"
done
[ "$(wc -l <"$TEST_ROOT/services.log")" -eq 6 ]
printf 'PASS: optional service flags and init scripts\n'

# A later run must preserve user changes and never repeat service actions.
uci set 'network.lan.ipaddr=192.0.2.2'
uci set 'system.@system[0].hostname=custom'
uci set 'catwrt.repo.mirror=official'
cp "$TEST_ROOT/state" "$TEST_ROOT/expected.state"
cp "$TEST_ROOT/services.log" "$TEST_ROOT/expected.services"
: >"$TEST_ROOT/uci.log"
sh "$TEST_ROOT/defaults"
cmp "$TEST_ROOT/state" "$TEST_ROOT/expected.state"
cmp "$TEST_ROOT/services.log" "$TEST_ROOT/expected.services"
assert_line '-q get system.@imm_init[0].catwrt_init' "$TEST_ROOT/uci.log"
[ "$(wc -l <"$TEST_ROOT/uci.log")" -eq 1 ]
printf 'PASS: second run preserves user settings and has no writes\n'
