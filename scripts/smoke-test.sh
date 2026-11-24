#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C

fail() {
	printf 'smoke-test: %s\n' "$*" >&2
	exit 1
}

if [[ $# != 0 ]]; then
	[[ $# == 1 && $1 == --self-test ]] || fail '用法：bash scripts/smoke-test.sh [--self-test]'
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

if [[ $# == 0 && ${CATWRT_IN_CONTAINER:-0} != 1 && ${CI:-false} != true ]]; then
	log_dir=${SMOKE_LOG_DIR:-out/smoke}
	[[ -d out/images ]] || fail '缺少 out/images；请先运行 scripts/build-image.sh'
	mkdir -p -- "$log_dir"
	images_mount=$(
		cd out/images
		pwd -W 2>/dev/null || pwd
	)
	docker build --platform linux/amd64 -t catwrt-build -f docker/build.Dockerfile .
	docker_args=(--platform linux/amd64 --init --user builder
		-v "$(pwd -W 2>/dev/null || pwd):/src:ro"
		-v "$images_mount:/input-images:ro"
		-e CATWRT_IN_CONTAINER=1 -e SMOKE_IMAGE_DIR=/input-images
		-e SMOKE_LOG_DIR=/tmp/catwrt-smoke
		-e "SMOKE_VARIANTS=${SMOKE_VARIANTS:-squashfs-efi squashfs-bios}"
		-e "SMOKE_EXPECT_LAN_IP=${SMOKE_EXPECT_LAN_IP:-192.168.1.4}")
	if [[ -n ${SMOKE_BOOT_TIMEOUT:-} ]]; then
		docker_args+=(-e "SMOKE_BOOT_TIMEOUT=$SMOKE_BOOT_TIMEOUT")
	fi
	if [[ -n ${SMOKE_HTTP_TIMEOUT+x} ]]; then
		docker_args+=(-e "SMOKE_HTTP_TIMEOUT=$SMOKE_HTTP_TIMEOUT")
	fi
	if [[ -r /dev/kvm && -w /dev/kvm ]]; then
		docker_args+=(--device /dev/kvm --group-add "$(stat -c %g /dev/kvm)")
	fi
	container=$(MSYS_NO_PATHCONV=1 docker create "${docker_args[@]}" catwrt-build bash scripts/smoke-test.sh)
	# Invoked by trap.
	# shellcheck disable=SC2317
	cleanup_container() {
		local result=$?
		trap '' INT TERM
		# Stop before exporting so interrupted runs retain their final serial bytes.
		MSYS_NO_PATHCONV=1 docker stop --time 10 "$container" >/dev/null || true
		if MSYS_NO_PATHCONV=1 docker cp "$container:/tmp/catwrt-smoke/." "$log_dir"; then
			printf '\n日志已导出至 SMOKE_LOG_DIR（默认 out/smoke）。\n'
		else
			printf 'smoke-test: 无法导出冒烟日志；请检查容器诊断。\n' >&2
			result=1
		fi
		MSYS_NO_PATHCONV=1 docker rm --force "$container" >/dev/null || result=1
		trap - EXIT
		exit "$result"
	}
	trap cleanup_container EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	container_status=0
	MSYS_NO_PATHCONV=1 docker start --attach "$container" || container_status=$?
	if [[ $container_status == 0 ]]; then
		container_status=$(MSYS_NO_PATHCONV=1 docker inspect --format '{{.State.ExitCode}}' "$container")
	fi
	exit "$container_status"
fi

command -v python3 >/dev/null 2>&1 || fail '缺少 python3；请使用 docker/build.Dockerfile'
exec python3 -I - "$@" <<'PY'
import contextlib
import hashlib
import io
import ipaddress
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


class SmokeError(Exception):
    pass


class SmokeTimeout(SmokeError):
    pass


def release_value(text, key):
    values = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        name, value = line.split('=', 1)
        if name.strip() == key:
            values.append(value.strip().strip('\'"'))
    if len(values) != 1:
        raise SmokeError(f'发布配置 {key}：预期 1 项，实际 {len(values)} 项')
    return values[0]


def variants_from(text):
    variants = text.split()
    if not variants or any(not re.fullmatch(r'(squashfs|ext4)-(bios|efi)', v) for v in variants):
        raise SmokeError('SMOKE_VARIANTS：预期 squashfs/ext4 与 bios/efi 的组合')
    if len(set(variants)) != len(variants):
        raise SmokeError('SMOKE_VARIANTS：存在重复变体（日志会被覆盖）')
    return variants


def verified_image(directory, version, variant):
    name = f'catwrt-next-{version}-x86-64-{variant}.qcow2'
    image = directory / name
    manifest = directory / 'sha256sums'
    if not image.is_file() or image.is_symlink():
        raise SmokeError(f'镜像：预期普通文件 {name}，实际缺失或为符号链接')
    if not manifest.is_file():
        raise SmokeError('镜像校验：缺少 out/images/sha256sums')
    matches = []
    for line in manifest.read_text(encoding='utf-8').splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2 and fields[1].lstrip('*') == name:
            matches.append(fields[0])
    if len(matches) != 1 or not re.fullmatch(r'[a-fA-F0-9]{64}', matches[0]):
        raise SmokeError(f'{name}：预期唯一有效 SHA256，实际 {len(matches)} 项（可能格式无效）')
    digest = hashlib.sha256()
    with image.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != matches[0].lower():
        raise SmokeError(f'{name}：SHA256 预期={matches[0].lower()}；实际={actual}')
    return image


def probe_ovmf(directory):
    for suffix in ('_4M', ''):
        code = directory / f'OVMF_CODE{suffix}.fd'
        variables = directory / f'OVMF_VARS{suffix}.fd'
        if code.is_file() and variables.is_file():
            return code, variables
    raise SmokeError('UEFI：缺少匹配的 OVMF_CODE_4M.fd + OVMF_VARS_4M.fd 或 OVMF_CODE.fd + OVMF_VARS.fd（安装 ovmf）')


def console_text(raw):
    text = raw.decode('utf-8', errors='replace').replace('\r', '')
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    # Kernel records can arrive between lines or in the middle of a value/marker.
    return re.sub(r'(?:<\d+>)?\[\s*\d+(?:\.\d+)?\][^\n]*(?:\n|$)', '', text)


def marker_result(raw, number):
    text = console_text(raw)
    start = re.search(rf'(?:^|\n)__S_{number}__\n', text)
    if start is None:
        return None
    end = re.search(rf'(?:^|\n)__E_{number}__ ([0-9]+)\n', text[start.end():])
    if end is None:
        return None
    return text[start.end():start.end() + end.start()].strip(), int(end[1])


def shell_prompt(raw):
    return re.search(r'(?:^|\n)root@[^:\s]+:[^\n]*# (?:\n|$)', console_text(raw))


def diagnostic(text):
    # Summaries must not expose host paths or addresses from external diagnostics.
    text = str(text).replace(str(Path.cwd()), '<工作目录>')
    text = re.sub(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s<>\'";,；]+', '<路径>', text)
    text = re.sub(r'/(?:Users|home)/[^\s<>\'";,]+', '<路径>', text)
    text = re.sub(r'/tmp/catwrt-[^\s<>\'";,]+', '<临时路径>', text)
    text = re.sub(r'\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b', '<地址>', text)
    text = re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
                  lambda m: m[0] if m[0] in ('192.168.1.4', '192.168.1.1', '127.0.0.1') else '<地址>', text)
    return re.sub(r'[\x00-\x1f\x7f]', ' ', text)[:400]


class SerialConsole:
    def __init__(self, args, log):
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, bufsize=0)
        self.log = log
        self.buffer = bytearray()
        self.number = 0
        self.eof = False
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def pump(self, timeout):
        if self.eof:
            return
        for key, _ in self.selector.select(max(0, timeout)):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                self.eof = True
                self.selector.unregister(key.fileobj)
                return
            self.log.write(chunk)
            self.buffer.extend(chunk)

    def send(self, text):
        try:
            self.process.stdin.write(text.encode('utf-8'))
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise SmokeError(f'串口写入失败：{exc.__class__.__name__}；QEMU 状态={self.process.poll()}') from None

    def wait_for(self, predicate, deadline, context):
        while True:
            result = predicate(self.buffer)
            if result is not None:
                return result
            if self.eof:
                raise SmokeError(f'{context}：QEMU 提前退出，状态={self.process.poll()}；片段={diagnostic(console_text(self.buffer[-800:]))}')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SmokeTimeout(f'{context}：等待超时；片段={diagnostic(console_text(self.buffer[-400:]))}')
            self.pump(min(remaining, 0.5))

    def command(self, command, deadline):
        self.number += 1
        number = self.number
        self.buffer.clear()
        # Markers occupy complete lines, so terminal command echo cannot match.
        self.send(f"printf '\\n%s\\n' __S_{number}__; {{ {command}; }}; "
                  f"smoke_rc=$?; printf '\\n%s %s\\n' __E_{number}__ \"$smoke_rc\"\n")
        return self.wait_for(lambda raw: marker_result(raw, number), deadline, f'串口命令 {command}')

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None and time.monotonic() < deadline:
            self.pump(min(0.5, max(0, deadline - time.monotonic())))
        if self.process.poll() is None:
            raise SmokeError(f'poweroff：预期 QEMU 在 {timeout} 秒内自行退出，实际仍在运行')
        while not self.eof:
            self.pump(0.1)
        return self.process.returncode

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        while not self.eof:
            self.pump(0.1)
        self.selector.close()
        self.process.stdin.close()
        self.process.stdout.close()


def wait_ready(console, command, deadline):
    actual = '未就绪'
    while time.monotonic() < deadline:
        try:
            output, status = console.command(command, min(deadline, time.monotonic() + 10))
        except SmokeTimeout as exc:
            actual = str(exc)
        else:
            if status == 0:
                return
            actual = f'{output}（退出码 {status}）'
        console.pump(min(1, max(0, deadline - time.monotonic())))
    raise SmokeError(f'首次启动：预期 ubus 可用且 uci-defaults 为空；实际={actual}；启动期限已到')


class VariantRun:
    def __init__(self, variant, accelerator, log_label):
        self.variant = variant
        self.accelerator = accelerator
        self.log_label = log_label
        self.passed = 0
        self.failed = 0
        self.boot_seconds = '-'

    def check(self, name, expected, actual, success, command=''):
        if success:
            self.passed += 1
        else:
            self.failed += 1
        print(f'[{self.variant}] {"PASS" if success else "FAIL"} {name}：'
              f'预期={diagnostic(expected)}；实际={diagnostic(actual)}'
              + (f'；命令={command}' if command else '')
              + (f'；日志={self.log_label}' if not success else ''), flush=True)


def luci_response(url, timeout):
    with tempfile.TemporaryDirectory(prefix='catwrt-http-') as work:
        body = Path(work) / 'body'
        result = subprocess.run(['curl', '--silent', '--show-error', '--location', '--max-redirs', '5',
                                 '--noproxy', '*',
                                 '--connect-timeout', str(min(3, timeout)), '--max-time', str(timeout),
                                 '--output', str(body), '--write-out',
                                 '%{http_code}|%{content_type}|%{url_effective}', url],
                                capture_output=True, timeout=timeout + 2, check=False)
        metadata = result.stdout.decode('utf-8', errors='replace').split('|', 2)
        status, content_type, final_url = (metadata + [''] * 3)[:3]
        data = body.read_bytes() if body.exists() else b''
        success = result.returncode == 0 and status in ('200', '403') and b'luci' in data.lower()
        detail = (f'curl={result.returncode}；HTTP={status}；类型={content_type}；'
                  f'最终 URL={final_url}；正文片段={diagnostic(data[:200].decode("utf-8", errors="replace"))}；'
                  f'诊断={diagnostic(result.stderr.decode("utf-8", errors="replace"))}')
        return success, detail


def check_luci_http(run, console, url, expected_ip, http_timeout, command_timeout):
    deadline = time.monotonic() + http_timeout
    network_ready = False
    success = False
    detail = f'br-lan 尚未就绪；预期 LAN 地址={expected_ip}/24；URL={url}'
    last_network_detail = detail
    while time.monotonic() < deadline:
        try:
            output, status = console.command('ip -4 addr show br-lan',
                                             min(deadline, time.monotonic() + command_timeout))
            network_ready = status == 0 and re.search(r'\binet\s+' + re.escape(expected_ip) + r'/24(?:\s|$)', output) is not None
            detail = f'br-lan 预期 LAN 地址={expected_ip}/24；实际={output}（退出码 {status}）；URL={url}'
            last_network_detail = detail
        except SmokeError as exc:
            detail = f'{last_network_detail}；br-lan 等待失败：{exc}'
        if network_ready:
            break
        console.pump(min(1, max(0, deadline - time.monotonic())))
    if network_ready:
        while time.monotonic() < deadline:
            try:
                success, detail = luci_response(url, min(5, max(0.1, deadline - time.monotonic())))
            except (OSError, subprocess.SubprocessError) as exc:
                detail = f'HTTP 请求失败：{exc}；URL={url}'
            if success:
                break
            console.pump(min(1, max(0, deadline - time.monotonic())))
    run.check('LuCI HTTP', 'HTTP 200/403 且正文包含 luci', detail, success, f'curl {url}')
    if not success:
        for command in (
            'ip -4 addr show br-lan',
            'ip link show eth0',
            'netstat -ltn',
            'pgrep uhttpd || echo NO_UHTTPD',
            'ping -c1 -W2 192.168.1.1',
            'wget -q -O- -T5 http://127.0.0.1/cgi-bin/luci/ | head -c 200',
            'ip neigh',
            'nft list ruleset | grep -c .',
        ):
            try:
                output, status = console.command(command, time.monotonic() + command_timeout)
                detail = f'{output}（退出码 {status}）'
            except (SmokeError, OSError, subprocess.SubprocessError) as exc:
                detail = f'诊断命令失败：{exc}'
            print(f'[{run.variant}] INFO {command}：{diagnostic(detail)}', flush=True)


def wan_response(port, timeout):
    url = f'http://127.0.0.1:{port}/cgi-bin/luci/'
    with tempfile.TemporaryDirectory(prefix='catwrt-wan-') as work:
        body = Path(work) / 'body'
        result = subprocess.run(
            ['curl', '--silent', '--show-error', '--noproxy', '*',
             '--connect-timeout', str(min(3, timeout)), '--max-time', str(timeout),
             '--output', str(body), '--write-out', '%{http_code}|%{content_type}', url],
            capture_output=True, timeout=timeout + 2, check=False)
        metadata = result.stdout.decode('utf-8', errors='replace').split('|', 1)
        status, content_type = (metadata + [''] * 2)[:2]
        data = body.read_bytes() if body.exists() else b''
        success = result.returncode != 0 and status == '000'
        detail = (f'curl={result.returncode}；HTTP={status}；类型={content_type}；'
                  f'正文片段={diagnostic(data[:200].decode("utf-8", errors="replace"))}；'
                  f'诊断={diagnostic(result.stderr.decode("utf-8", errors="replace"))}')
        return success, detail


def wait_wan_ipv4(console, deadline, command_timeout):
    detail = 'eth1 尚未就绪'
    while time.monotonic() < deadline:
        try:
            output, status = console.command('ip -4 addr show eth1',
                                             min(deadline, time.monotonic() + command_timeout))
        except SmokeError as exc:
            detail = f'eth1 地址查询失败：{exc}'
        else:
            if status == 0 and re.search(r'\binet\s+', output):
                return
            detail = f'eth1 无 IPv4 地址：{output}（退出码 {status}）'
        console.pump(min(1, max(0, deadline - time.monotonic())))
    raise SmokeTimeout(f'WAN 地址：预期 eth1 获得 IPv4 地址；实际={detail}')


def check_wan_management_unreachable(run, console, port, timeout, command_timeout):
    url = f'http://127.0.0.1:{port}/cgi-bin/luci/'
    expected = 'curl 退出码非 0 且 HTTP=000'
    try:
        wait_wan_ipv4(console, time.monotonic() + timeout, command_timeout)
    except SmokeError as exc:
        run.check('WAN 管理面不可达', expected, f'{exc}；URL={url}', False,
                  f'ip -4 addr show eth1；curl {url}')
        return
    try:
        success, detail = wan_response(port, min(5, timeout))
    except (OSError, subprocess.SubprocessError) as exc:
        success, detail = False, f'HTTP 请求失败：{exc}；URL={url}'
    run.check('WAN 管理面不可达', expected, detail, success, f'curl {url}')


def wan_zone_policy(output):
    sections = {}
    for line in output.splitlines():
        match = re.fullmatch(r"firewall\.(@[^.]+|[^.]+)\.(name|input|forward)='(.*)'", line)
        if match:
            sections.setdefault(match[1], {})[match[2]] = match[3]
    for section in sections.values():
        if section.get('name') == 'wan' and 'input' in section and 'forward' in section:
            return (section.get('input') in ('REJECT', 'DROP') and
                    section.get('forward') in ('REJECT', 'DROP'))
    return False


def vlmcsd_not_listening(output):
    return re.search(r':1688(?=\s|$)', output) is None


def run_variant(run, images, version, log_dir, boot_timeout, expected_ip, http_timeout):
    console = None
    shell_open = False
    shutdown_attempted = False
    started = time.monotonic()
    with (log_dir / f'{run.variant}.log').open('wb', buffering=0) as log, \
            tempfile.TemporaryDirectory(prefix='catwrt-smoke-') as work:
        try:
            image = verified_image(images, version, run.variant)
            run.check('镜像 SHA256', '匹配 sha256sums', image.name, True)
            # Free loopback ports avoid collisions with other local services.
            with socket.socket() as lan_listener, socket.socket() as wan_listener:
                lan_listener.bind(('127.0.0.1', 0))
                wan_listener.bind(('127.0.0.1', 0))
                port = lan_listener.getsockname()[1]
                wan_port = wan_listener.getsockname()[1]
            args = ['qemu-system-x86_64', '-accel', run.accelerator, '-m', '512', '-smp', '1',
                    '-snapshot', '-nographic', '-monitor', 'none', '-serial', 'stdio',
                    '-drive', f'file={image},format=qcow2,if=virtio',
                    '-netdev', 'user,id=lan,net=192.168.1.0/24,host=192.168.1.1,restrict=on,'
                               f'hostfwd=tcp:127.0.0.1:{port}-192.168.1.4:80',
                    '-device', 'virtio-net-pci,netdev=lan',
                    '-netdev', f'user,id=wan,hostfwd=tcp:127.0.0.1:{wan_port}-:80',
                    '-device', 'virtio-net-pci,netdev=wan']
            if run.variant.endswith('-efi'):
                code, variables = probe_ovmf(Path('/usr/share/OVMF'))
                writable_vars = Path(work) / 'vars.fd'
                shutil.copyfile(variables, writable_vars)
                args += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}',
                         '-drive', f'if=pflash,format=raw,file={writable_vars}']
            started = time.monotonic()
            deadline = started + boot_timeout
            console = SerialConsole(args, log)
            console.wait_for(lambda raw: True if 'Please press Enter to activate this console.'
                             in console_text(raw) else None, deadline, '启动控制台')
            console.send('\n')
            console.wait_for(shell_prompt, deadline, 'root shell 提示符')
            shell_open = True
            ready_command = ('ubus call system board >/dev/null && '
                             'test -d /etc/uci-defaults && '
                             '{ ls -A /etc/uci-defaults; '
                             'test -z "$(ls -A /etc/uci-defaults)"; }')
            wait_ready(console, ready_command, deadline)
            run.boot_seconds = str(round(time.monotonic() - started, 1))
            run.check('启动与首次默认设置', 'ubus 可用且 uci-defaults 为空', '已就绪', True, ready_command)
            command_timeout = 20 if run.accelerator == 'kvm' else 60

            def guest_check(name, command, expected, predicate=None):
                try:
                    output, status = console.command(command, time.monotonic() + command_timeout)
                    success = status == 0 and (predicate(output) if predicate else output == expected)
                    run.check(name, expected, f'{output}（退出码 {status}）', success, command)
                except SmokeError as exc:
                    run.check(name, expected, str(exc), False, command)

            def release_matches(output):
                try:
                    return release_value(output, 'version') == version
                except SmokeError:
                    return False

            guest_check('固件版本', 'cat /etc/catwrt_release', version, release_matches)
            for name, command, expected in (
                ('LAN 地址', 'uci get network.lan.ipaddr', f'{expected_ip}/24'),
                ('主机名', "uci get 'system.@system[0].hostname'", 'CatWrt'),
                ('LuCI 语言', 'uci get luci.main.lang', 'zh_cn'),
                ('软件源镜像', "uci get 'system.@imm_init[0].apk_mirror'", 'https://mirrors.vsean.net/openwrt'),
            ):
                guest_check(name, command, expected)
            mirror = 'https://mirrors.vsean.net/openwrt'
            guest_check('distfeeds 镜像', 'cat /etc/apk/repositories.d/distfeeds.list',
                        '包含 mirrors.vsean.net/openwrt 且无 downloads.immortalwrt.org',
                        lambda output: mirror in output and 'downloads.immortalwrt.org' not in output)
            for package in ('catwrt-base', 'cattools', 'luci-app-poweroff', 'luci-i18n-poweroff-zh-cn',
                            'luci-theme-argon', 'luci-app-openclash', 'tailscale', 'adguardhome',
                            'nfs-kernel-server', 'qemu-ga', 'luci-app-nfs',
                            'luci-app-adguardhome',
                            'intel-microcode', 'amd64-microcode', 'kmod-tcp-bbr',
                            'kmod-atlantic', 'kmod-bnx2x', 'kmod-iavf', 'kmod-macsec', 'kmod-sfp',
                            'kmod-usb-net-cdc-ncm', 'kmod-usb-net-rndis',
                            'kmod-usb-net-ipheth', 'kmod-usb-net-aqc111',
                            'jq', 'pciutils', 'pciids', 'usbutils', 'htop', 'nano', 'openssl-util',
                            'irqbalance'):
                guest_check(f'已安装 {package}', f'apk info -e {package}', '已安装', lambda output: True)
            for package in ('luci-app-attendedsysupgrade', 'attendedsysupgrade-common', 'owut', 'luci-app-passwall'):
                guest_check(f'未安装 {package}', f'apk info -e {package}; smoke_status=$?; '
                            'printf "apk_exit=%s\\n" "$smoke_status"; '
                            'test "$smoke_status" -eq 1', '未安装（apk 退出码 1）', lambda output: True)
            for service in ('openclash', 'tailscale', 'zerotier', 'appfilter', 'mosdns',
                            'adguardhome', 'nfsd', 'qemu-ga', 'vmtoolsd'):
                command = (f'if test ! -e /etc/init.d/{service}; then echo SKIP; '
                           f'elif /etc/init.d/{service} enabled; then echo ENABLED; '
                           'else echo DISABLED; fi')
                guest_check(f'默认停用 {service}', command, 'DISABLED 或 SKIP（无初始化脚本）',
                            lambda output: output in ('DISABLED', 'SKIP'))
            for path in ('/usr/share/luci/menu.d/luci-app-poweroff.json',
                         '/www/luci-static/resources/view/poweroff.js', '/etc/apk/keys/catwrt-next.pem'):
                guest_check(f'文件 {path}', f'test -f {shlex.quote(path)}', '存在', lambda output: True)
            guest_check('cattools 命令', 'command -v cattools', '可执行命令', bool)
            guest_check('cattools 非交互退出', 'cattools </dev/null 2>&1; echo "exit=$?"',
                        'exit=1 且输出含“交互式终端”、不含 IoError',
                        lambda output: 'exit=1' in output and '交互式终端' in output and 'IoError' not in output)
            guest_check('默认拥塞控制', 'sysctl -n net.ipv4.tcp_congestion_control', 'bbr')
            guest_check('irqbalance 已启用', "uci get 'irqbalance.irqbalance.enabled'", '1')
            guest_check('RPS 流表大小', "uci get 'network.@globals[0].steering_flows'", '16384')
            guest_check('连接跟踪上限', 'sysctl -n net.netfilter.nf_conntrack_max', '65536')
            guest_check('Dropbear 仅绑定 LAN', "uci get 'dropbear.@dropbear[0].Interface'", 'lan')
            guest_check('ttyd 仅绑定 LAN', "uci get 'ttyd.@ttyd[0].interface'", '@lan')
            guest_check('vlmcsd 默认停用', 'uci get vlmcsd.config.enabled', '0')
            guest_check('UPnP 默认停用', 'uci get upnpd.config.enabled', '0')
            guest_check('vlmcsd 未监听 1688', 'netstat -ltn', '不含 :1688 监听',
                        vlmcsd_not_listening)
            guest_check('WAN 防火墙策略', 'uci show firewall',
                        'wan 区域 input 与 forward 均为 REJECT/DROP', wan_zone_policy)

            url = f'http://127.0.0.1:{port}/cgi-bin/luci/'
            check_luci_http(run, console, url, expected_ip, http_timeout, command_timeout)
            check_wan_management_unreachable(run, console, wan_port, http_timeout, command_timeout)
        except (SmokeError, OSError, subprocess.SubprocessError) as exc:
            run.check('变体执行', '全部检查完成', str(exc), False)
        finally:
            if console is not None:
                cancelling = sys.exc_info()[0] is KeyboardInterrupt
                try:
                    if not cancelling and shell_open and console.process.poll() is None:
                        shutdown_attempted = True
                        console.send('poweroff\n')
                        timeout = 60 if run.accelerator == 'kvm' else 120
                        status = console.wait_exit(timeout)
                        run.check('关机', f'QEMU 在 {timeout} 秒内自行退出且状态为 0', status, status == 0, 'poweroff')
                    elif not cancelling and shell_open:
                        run.check('关机', 'poweroff 后自行退出', 'QEMU 已提前退出', False, 'poweroff')
                except (SmokeError, OSError) as exc:
                    run.check('关机', 'poweroff 后自行退出', str(exc), False, 'poweroff')
                finally:
                    # A second interrupt must not interrupt termination/reaping.
                    old_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
                    old_term = signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    try:
                        console.close()
                    finally:
                        signal.signal(signal.SIGINT, old_int)
                        signal.signal(signal.SIGTERM, old_term)
            if not shutdown_attempted and not shell_open:
                print(f'[{run.variant}] SKIP 关机：控制台尚未就绪；日志={run.log_label}', flush=True)


class SelfTest(unittest.TestCase):
    def test_shell_prompt_after_activation(self):
        activation = b'Please press Enter to activate this console.\r\n'
        self.assertIsNone(shell_prompt(activation))
        self.assertIsNone(shell_prompt(activation + b'root@(none):~#'))
        for prompt in (b'root@(none):~# ', b'root@CatWrt:~# '):
            self.assertIsNotNone(shell_prompt(activation + prompt))
        self.assertIsNotNone(shell_prompt(activation + b'root@Cat[ 12.001] kernel: fixture\nWrt:~# '))

    def test_readiness_retries_lost_and_failed_markers(self):
        for statuses, budget, succeeds in (([None, 1, 0], 300, True), ([None, None, None], 25, False)):
            with self.subTest(succeeds=succeeds):
                console = object.__new__(SerialConsole)
                console.buffer = bytearray()
                console.number = 0
                console.eof = False
                clock = [100.0]
                chunks = []
                sent = []

                def send(text):
                    sent.append(text)
                    number = console.number
                    status = statuses[number - 1]
                    if status is not None:
                        chunks.append(f'__S_{number - 1}__\nstale\n__E_{number - 1}__ 0\n'.encode())
                        chunks.append(f'__S_{number}__\n[ 12.001] kernel: fixture\n'
                                      f'probe {number}\n__E_{number}__ {status}\n'.encode())

                def pump(timeout):
                    clock[0] += timeout
                    if chunks:
                        console.buffer.extend(chunks.pop(0))

                console.send = send
                console.pump = pump
                with mock.patch.object(time, 'monotonic', side_effect=lambda: clock[0]):
                    if succeeds:
                        wait_ready(console, 'fixture probe', 100 + budget)
                    else:
                        with self.assertRaisesRegex(SmokeError, '首次启动'):
                            wait_ready(console, 'fixture probe', 100 + budget)
                self.assertEqual(console.number, 3)
                for number, text in enumerate(sent, 1):
                    self.assertIn(f'__S_{number}__', text)
                    self.assertIn(f'__E_{number}__', text)
                if succeeds:
                    self.assertEqual(marker_result(console.buffer, 3), ('probe 3', 0))
                    self.assertGreaterEqual(clock[0] - 100, 10)
                else:
                    self.assertEqual(clock[0], 100 + budget)

    def test_marker_interleaved_kernel(self):
        raw = (b"root@CatWrt:/# printf '__S_7__'; echo '__E_7__'\r\n"
               b'__S_6__\r\nold\r\n__E_6__ 0\r\n'
               b'__S_7__\r\n[   12.001] kernel: fixture\r\nCat'
               b'[   12.002] kernel: fixture\r\nWrt\r\n'
               b'__E_[   12.003] kernel: fixture\r\n7__ 3\r\n')
        self.assertEqual(marker_result(raw, 7), ('CatWrt', 3))
        self.assertIsNone(marker_result(raw, 8))
        for length in range(len(raw)):
            self.assertIsNone(marker_result(raw[:length], 7))

    def test_marker_echo_empty_and_ansi(self):
        self.assertIsNone(marker_result(b"root# echo __S_1__; echo __E_1__ 0\n", 1))
        self.assertEqual(marker_result(b'\x1b[0m__S_1__\r\n\r\n__E_1__ 0\r\n', 1), ('', 0))
        self.assertIsNone(marker_result(b'__S_1__\nvalue\n__E_1__ 0', 1))

    def test_release(self):
        for text in ('version=v-test\nbase=fixture\n', '# fixture\r\nversion = "v-test"\r\n',
                     "version='v-test'\n", 'other=x\nversion=v-test'):
            self.assertEqual(release_value(text, 'version'), 'v-test')
        for text in ('base=fixture', 'version=x\nversion=y'):
            with self.assertRaises(SmokeError):
                release_value(text, 'version')

    def test_variants(self):
        valid = ['squashfs-efi', 'squashfs-bios', 'ext4-efi', 'ext4-bios']
        self.assertEqual(variants_from(' '.join(valid)), valid)
        for value in ('', '../squashfs-efi', 'squashfs-efi/extra', 'SQUASHFS-efi', 'ext4-uefi',
                      'squashfs-efi;true', 'squashfs-efi squashfs-efi'):
            with self.subTest(value=value), self.assertRaises(SmokeError):
                variants_from(value)

    def test_image_selection_and_checksum(self):
        with tempfile.TemporaryDirectory(prefix='catwrt-fixture-') as work:
            root = Path(work)
            manifest = root / 'sha256sums'
            for variant in variants_from('squashfs-efi squashfs-bios ext4-efi ext4-bios'):
                image = root / f'catwrt-next-v-test-x86-64-{variant}.qcow2'
                image.write_bytes(b'redacted fixture')
                digest = hashlib.sha256(image.read_bytes()).hexdigest()
                for prefix in (' ', '*'):
                    manifest.write_text(f'{digest} {prefix}{image.name}\n', encoding='utf-8')
                    self.assertEqual(verified_image(root, 'v-test', variant), image)
                good = manifest.read_text(encoding='utf-8')
                for invalid in ('', good + good, f'bad  {image.name}\n',
                                f'{digest}  ../{image.name}\n', f'{digest}  {image.name}.gz\n'):
                    manifest.write_text(invalid, encoding='utf-8')
                    with self.assertRaises(SmokeError):
                        verified_image(root, 'v-test', variant)
                manifest.write_text(good, encoding='utf-8')
                image.write_bytes(b'changed fixture')
                with self.assertRaisesRegex(SmokeError, 'SHA256 预期='):
                    verified_image(root, 'v-test', variant)
                image.unlink()
                with self.assertRaises(SmokeError):
                    verified_image(root, 'v-test', variant)
            image.write_bytes(b'fixture')
            manifest.unlink()
            with self.assertRaises(SmokeError):
                verified_image(root, 'v-test', 'ext4-bios')

    def test_ovmf(self):
        with tempfile.TemporaryDirectory(prefix='catwrt-fixture-') as work:
            root = Path(work)
            with self.assertRaisesRegex(SmokeError, 'OVMF_CODE_4M'):
                probe_ovmf(root)
            (root / 'OVMF_CODE_4M.fd').touch()
            (root / 'OVMF_VARS.fd').touch()
            with self.assertRaises(SmokeError):
                probe_ovmf(root)
            (root / 'OVMF_CODE.fd').touch()
            self.assertEqual(probe_ovmf(root)[0].name, 'OVMF_CODE.fd')
            (root / 'OVMF_VARS_4M.fd').touch()
            self.assertEqual(probe_ovmf(root)[1].name, 'OVMF_VARS_4M.fd')

    def test_luci_status_body_and_diagnostics(self):
        url = 'http://127.0.0.1:8080/cgi-bin/luci/'
        for status, body, curl_status, expected in (
            ('200', b'<html>LuCI login</html>', 0, True),
            ('403', b'<html>luci login</html>', 0, True),
            ('200', b'<html>unrelated page</html>', 0, False),
            ('500', b'luci failure', 0, False),
            ('302', b'luci redirect', 0, False),
            ('000', b'', 7, False),
        ):
            def curl(args, **kwargs):
                Path(args[args.index('--output') + 1]).write_bytes(body)
                return subprocess.CompletedProcess(args, curl_status,
                                                   f'{status}|text/html|{url}'.encode(), b'fixture diagnostic')

            with self.subTest(status=status, curl=curl_status), mock.patch.object(subprocess, 'run', side_effect=curl):
                success, detail = luci_response(url, 1)
                self.assertEqual(success, expected)
                self.assertIn(f'HTTP={status}', detail)
                self.assertIn(url, diagnostic(detail))
                self.assertIn('text/html', detail)
                self.assertIn('fixture diagnostic', detail)

    def test_wan_management_requires_no_http_response(self):
        url = 'http://127.0.0.1:8080/cgi-bin/luci/'

        def curl(args, **kwargs):
            self.assertEqual(args[-1], url)
            Path(args[args.index('--output') + 1]).write_bytes(b'luci fixture')
            return subprocess.CompletedProcess(args, curl_status,
                                               f'{status}|text/html'.encode(), b'fixture diagnostic')

        for status, curl_status, expected in (
            ('000', 7, True),
            ('000', 28, True),
            ('200', 0, False),
            ('403', 0, False),
            ('200', 7, False),
        ):
            with self.subTest(status=status, curl=curl_status), mock.patch.object(subprocess, 'run', side_effect=curl):
                success, detail = wan_response(8080, 1)
                self.assertEqual(success, expected)
                self.assertIn(f'HTTP={status}', detail)
                self.assertIn('fixture diagnostic', detail)

    def test_wan_zone_policy(self):
        for output, expected in (
            ("firewall.@zone[1].name='wan'\n"
             "firewall.@zone[1].input='REJECT'\n"
             "firewall.@zone[1].forward='DROP'", True),
            ("firewall.wan.name='wan'\n"
             "firewall.wan.input='DROP'\n"
             "firewall.wan.forward='REJECT'", True),
            ("firewall.@zone[1].name='wan'\n"
             "firewall.@zone[1].input='ACCEPT'\n"
             "firewall.@zone[1].forward='REJECT'", False),
            ("firewall.@zone[1].name='wan'\n"
             "firewall.@zone[1].input='REJECT'", False),
            ("firewall.@zone[0].name='lan'\n"
             "firewall.@zone[0].input='ACCEPT'", False),
            ("firewall.rule0.name='wan'\n"
             "firewall.@zone[1].name='wan'\n"
             "firewall.@zone[1].input='REJECT'\n"
             "firewall.@zone[1].forward='REJECT'", True),
        ):
            with self.subTest(output=output):
                self.assertEqual(wan_zone_policy(output), expected)

    def test_vlmcsd_port_boundary(self):
        for output, expected in (
            ('tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN', True),
            ('tcp 0 0 0.0.0.0:1688 0.0.0.0:* LISTEN', False),
            ('tcp 0 0 0.0.0.0:16880 0.0.0.0:* LISTEN', True),
            ('tcp6 0 0 :::1688 :::* LISTEN', False),
            ('tcp 0 0 0.0.0.0:1688', False),
        ):
            with self.subTest(output=output):
                self.assertEqual(vlmcsd_not_listening(output), expected)

    def test_check_failures_shutdown_and_interrupt(self):
        for scenario in ('success', 'success-kvm', 'wrong-lan', 'bare-lan', 'wrong-prefix', 'wrong-bbr',
                         'wrong-irqbalance', 'wan-reachable',
                         'command-timeout', 'boot-failure', 'shutdown-timeout', 'interrupt'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix='catwrt-fixture-') as work:
                root = Path(work)
                accelerator = 'kvm' if scenario == 'success-kvm' else 'tcg'
                run = VariantRun('squashfs-bios', accelerator, 'fixture.log')
                serial = mock.Mock()
                serial.process.poll.return_value = None
                serial.wait_exit.return_value = 0
                if scenario == 'boot-failure':
                    serial.wait_for.side_effect = SmokeError('fixture boot failure')
                if scenario == 'shutdown-timeout':
                    serial.wait_exit.side_effect = SmokeError('fixture shutdown timeout')

                def command(text, deadline):
                    self.assertEqual(serial.wait_for.call_count, 2)
                    self.assertIs(serial.wait_for.call_args.args[0], shell_prompt)
                    if not text.startswith('ubus call '):
                        self.assertAlmostEqual(deadline - time.monotonic(),
                                               20 if accelerator == 'kvm' else 60, delta=1)
                    if text == 'uci get network.lan.ipaddr':
                        if scenario == 'command-timeout':
                            raise SmokeError('fixture command timeout')
                        if scenario == 'interrupt':
                            raise KeyboardInterrupt
                        if scenario == 'bare-lan':
                            return '192.168.1.4', 0
                        return ('192.168.1.4/32' if scenario == 'wrong-prefix' else '192.168.1.4/24'), 0
                    values = {
                        'cat /etc/catwrt_release': 'version=v-test',
                        "uci get 'system.@system[0].hostname'": 'CatWrt',
                        'uci get luci.main.lang': 'zh_cn',
                        "uci get 'system.@imm_init[0].apk_mirror'": 'https://mirrors.vsean.net/openwrt',
                        'cat /etc/apk/repositories.d/distfeeds.list': 'https://mirrors.vsean.net/openwrt',
                        'command -v cattools': '/usr/bin/cattools',
                        'cattools </dev/null 2>&1; echo "exit=$?"': '错误: cattools 需要交互式终端运行，请通过 SSH 或串口终端使用\nexit=1',
                        'sysctl -n net.ipv4.tcp_congestion_control': 'cubic' if scenario == 'wrong-bbr' else 'bbr',
                        'ip -4 addr show br-lan': 'inet 192.168.1.1/24' if scenario == 'wrong-lan' else 'inet 192.168.1.4/24',
                        "uci get 'irqbalance.irqbalance.enabled'": '0' if scenario == 'wrong-irqbalance' else '1',
                        "uci get 'network.@globals[0].steering_flows'": '16384',
                        'sysctl -n net.netfilter.nf_conntrack_max': '65536',
                        "uci get 'dropbear.@dropbear[0].Interface'": 'lan',
                        "uci get 'ttyd.@ttyd[0].interface'": '@lan',
                        'uci get vlmcsd.config.enabled': '0',
                        'uci get upnpd.config.enabled': '0',
                        'netstat -ltn': 'tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN\n'
                                        'tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN',
                        'uci show firewall': "firewall.@zone[0].name='lan'\n"
                                             "firewall.@zone[0].input='ACCEPT'\n"
                                             "firewall.@zone[0].forward='ACCEPT'\n"
                                             "firewall.@zone[1].name='wan'\n"
                                             "firewall.@zone[1].input='REJECT'\n"
                                             "firewall.@zone[1].forward='REJECT'\n",
                        'ip -4 addr show eth1': 'inet 192.0.2.15/24 scope global eth1',
                    }
                    if text in values:
                        return values[text], 0
                    if text.startswith('if test ! -e /etc/init.d/'):
                        return 'DISABLED', 0
                    if text.startswith(('ubus call ', 'apk info -e ', 'test -f ')):
                        return '', 0
                    self.fail(f'未知测试命令：{text}')

                serial.command.side_effect = command
                output = io.StringIO()
                wan_http = mock.Mock(return_value=(True, 'curl=7；HTTP=000；类型=；fixture refused'))
                if scenario == 'wan-reachable':
                    wan_http = mock.Mock(return_value=(False, 'curl=0；HTTP=200；类型=text/html；正文片段=luci'))
                with mock.patch.dict(globals(), SerialConsole=mock.Mock(return_value=serial),
                                     verified_image=mock.Mock(return_value=root / 'fixture.qcow2'),
                                     luci_response=mock.Mock(return_value=(True, 'HTTP=200；luci')),
                                     wan_response=wan_http), \
                        contextlib.redirect_stdout(output):
                    if scenario == 'interrupt':
                        with self.assertRaises(KeyboardInterrupt):
                            run_variant(run, root, 'v-test', root, 30, '192.168.1.4', 120)
                    else:
                        expected_ip = '192.168.1.1' if scenario == 'wrong-lan' else '192.168.1.4'
                        run_variant(run, root, 'v-test', root, 30, expected_ip, 60 if accelerator == 'kvm' else 120)
                serial.close.assert_called_once()
                if scenario == 'boot-failure':
                    serial.send.assert_not_called()
                elif scenario == 'interrupt':
                    serial.send.assert_called_once_with('\n')
                else:
                    serial.send.assert_any_call('poweroff\n')
                    serial.wait_exit.assert_called_once_with(60 if accelerator == 'kvm' else 120)
                    self.assertIn('LuCI HTTP', output.getvalue())
                if scenario != 'boot-failure':
                    self.assertNotEqual(run.boot_seconds, '-')
                if scenario in ('success', 'success-kvm'):
                    self.assertEqual(run.failed, 0)
                elif scenario != 'interrupt':
                    self.assertEqual(run.failed, 1)
                if scenario == 'wrong-lan':
                    self.assertIn('FAIL LAN 地址：预期=192.168.1.1/24；实际=192.168.1.4/24', output.getvalue())
                if scenario == 'wrong-prefix':
                    self.assertIn('FAIL LAN 地址：预期=192.168.1.4/24；实际=192.168.1.4/32', output.getvalue())
                if scenario == 'wrong-bbr':
                    self.assertIn('FAIL 默认拥塞控制：预期=bbr；实际=cubic', output.getvalue())
                if scenario == 'wrong-irqbalance':
                    self.assertIn('FAIL irqbalance 已启用：预期=1；实际=0', output.getvalue())
                if scenario == 'wan-reachable':
                    self.assertIn('FAIL WAN 管理面不可达', output.getvalue())
                    self.assertIn('HTTP=200', output.getvalue())

    def test_luci_http_waits_for_network_and_retries(self):
        clock = [500.0]
        events = []
        console = mock.Mock()
        run = VariantRun('squashfs-bios', 'tcg', 'fixture.log')

        def command(text, deadline):
            self.assertEqual(text, 'ip -4 addr show br-lan')
            self.assertEqual(deadline, 512)
            events.append('network')
            return ('br-lan DOWN' if len(events) == 1 else 'inet 192.168.1.4/24'), 0

        def curl(url, timeout):
            self.assertEqual(events[:2], ['network', 'network'])
            self.assertLessEqual(timeout, 512 - clock[0])
            events.append('curl')
            clock[0] += 1
            return events.count('curl') == 2, 'fixture HTTP response'

        console.command.side_effect = command
        console.pump.side_effect = lambda timeout: clock.__setitem__(0, clock[0] + timeout)
        output = io.StringIO()
        with mock.patch.object(time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.dict(globals(), luci_response=mock.Mock(side_effect=curl)), \
                contextlib.redirect_stdout(output):
            check_luci_http(run, console, 'http://127.0.0.1:8080/cgi-bin/luci/', '192.168.1.4', 12, 60)
        self.assertEqual(events, ['network', 'network', 'curl', 'curl'])
        self.assertEqual((run.passed, run.failed), (1, 0))
        self.assertNotIn(' INFO ', output.getvalue())

    def test_luci_http_failure_diagnostics_are_nonfatal(self):
        for scenario in ('http-timeout', 'network-timeout', 'network-prefix',
                         'network-prefix-serial-timeout', 'request-exception'):
            with self.subTest(scenario=scenario):
                clock = [500.0]
                diagnostics = []
                console = mock.Mock()
                run = VariantRun('squashfs-bios', 'tcg', 'fixture.log')

                def command(text, deadline):
                    if clock[0] < 512:
                        self.assertEqual(text, 'ip -4 addr show br-lan')
                        self.assertEqual(deadline, 512)
                        if scenario == 'network-prefix-serial-timeout' and console.command.call_count > 1:
                            clock[0] = 512
                            raise SmokeTimeout('fixture serial poll timeout')
                        clock[0] += 1
                        if scenario.startswith('network-prefix'):
                            return 'inet 192.168.1.4/32 scope global br-lan', 0
                        return ('br-lan DOWN' if scenario == 'network-timeout' else 'inet 192.168.1.4/24'), 0
                    self.assertEqual(deadline, clock[0] + 20)
                    diagnostics.append(text)
                    if len(diagnostics) == 1:
                        raise SmokeTimeout('fixture diagnostic timeout')
                    return 'fixture output ' * 50, 1

                def curl(url, timeout):
                    clock[0] += timeout
                    if scenario == 'request-exception':
                        raise subprocess.TimeoutExpired('curl', timeout)
                    return False, 'curl=28; HTTP=000; fixture timeout'

                console.command.side_effect = command
                console.pump.side_effect = lambda timeout: clock.__setitem__(0, clock[0] + timeout)
                output = io.StringIO()
                curl_mock = mock.Mock(side_effect=curl)
                with mock.patch.object(time, 'monotonic', side_effect=lambda: clock[0]), \
                        mock.patch.dict(globals(), luci_response=curl_mock), \
                        contextlib.redirect_stdout(output):
                    check_luci_http(run, console, 'http://127.0.0.1:8080/cgi-bin/luci/', '192.168.1.4', 12, 20)
                self.assertEqual(clock[0], 512)
                self.assertEqual((run.passed, run.failed), (0, 1))
                self.assertEqual(diagnostics, [
                    'ip -4 addr show br-lan', 'ip link show eth0', 'netstat -ltn',
                    'pgrep uhttpd || echo NO_UHTTPD', 'ping -c1 -W2 192.168.1.1',
                    'wget -q -O- -T5 http://127.0.0.1/cgi-bin/luci/ | head -c 200',
                    'ip neigh', 'nft list ruleset | grep -c .',
                ])
                lines = [line for line in output.getvalue().splitlines() if ' INFO ' in line]
                self.assertEqual(len(lines), 8)
                self.assertIn('fixture diagnostic timeout', lines[0])
                self.assertTrue(all(len(line.split('：', 1)[1]) <= 400 for line in lines))
                if scenario == 'network-timeout' or scenario.startswith('network-prefix'):
                    curl_mock.assert_not_called()
                if scenario.startswith('network-prefix'):
                    failure = next(line for line in output.getvalue().splitlines() if 'FAIL LuCI HTTP' in line)
                    self.assertIn('inet 192.168.1.4/32 scope global br-lan', failure)
                    if scenario == 'network-prefix-serial-timeout':
                        self.assertIn('fixture serial poll timeout', failure)

    def test_http_timeout_configuration(self):
        for kvm, value, expected in (
            (False, None, 120), (True, None, 60), (False, '7', 7),
            (False, '', None), (False, '0', None), (True, '-1', None), (True, '1.5', None),
        ):
            with self.subTest(kvm=kvm, value=value), tempfile.TemporaryDirectory(prefix='catwrt-fixture-') as work:
                environment = {'SMOKE_VARIANTS': 'squashfs-bios', 'SMOKE_LOG_DIR': work, 'SMOKE_IMAGE_DIR': work}
                if value is not None:
                    environment['SMOKE_HTTP_TIMEOUT'] = value
                variant = mock.Mock()
                with mock.patch.dict(os.environ, environment, clear=True), \
                        mock.patch.object(sys, 'argv', ['smoke-test']), \
                        mock.patch.object(shutil, 'which', return_value='fixture'), \
                        mock.patch.object(os, 'access', return_value=kvm), \
                        mock.patch.dict(globals(), run_variant=variant), \
                        contextlib.redirect_stdout(io.StringIO()):
                    if expected is None:
                        with self.assertRaisesRegex(SmokeError, 'SMOKE_HTTP_TIMEOUT'):
                            main()
                        variant.assert_not_called()
                    else:
                        self.assertEqual(main(), 0)
                        self.assertEqual(variant.call_args.args[-1], expected)

    def test_cleanup_terminates_kills_and_reaps(self):
        serial = object.__new__(SerialConsole)
        serial.process = mock.Mock()
        serial.process.poll.return_value = None
        serial.process.wait.side_effect = [subprocess.TimeoutExpired('fixture', 5), 0]
        serial.eof = True
        serial.selector = mock.Mock()
        serial.close()
        serial.process.terminate.assert_called_once()
        serial.process.kill.assert_called_once()
        self.assertEqual(serial.process.wait.call_count, 2)
        serial.selector.close.assert_called_once()
        serial.process.stdin.close.assert_called_once()
        serial.process.stdout.close.assert_called_once()


def main():
    if sys.argv[1:] == ['--self-test']:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTest)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    for tool in ('qemu-system-x86_64', 'curl'):
        if shutil.which(tool) is None:
            raise SmokeError(f'缺少 {tool}；请使用 docker/build.Dockerfile')
    version = release_value(Path('config/release.env').read_text(encoding='utf-8'), 'CATWRT_VERSION')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', version):
        raise SmokeError('CATWRT_VERSION 格式无效')
    variants = variants_from(os.environ.get('SMOKE_VARIANTS', 'squashfs-efi squashfs-bios'))
    accelerator = 'kvm' if os.access('/dev/kvm', os.R_OK | os.W_OK) else 'tcg'
    timeout_text = os.environ.get('SMOKE_BOOT_TIMEOUT', '90' if accelerator == 'kvm' else '300')
    if not re.fullmatch(r'[1-9][0-9]*', timeout_text):
        raise SmokeError('SMOKE_BOOT_TIMEOUT 必须是正整数秒数')
    http_timeout_text = os.environ.get('SMOKE_HTTP_TIMEOUT', '60' if accelerator == 'kvm' else '120')
    if not re.fullmatch(r'[1-9][0-9]*', http_timeout_text):
        raise SmokeError('SMOKE_HTTP_TIMEOUT 必须是正整数秒数')
    expected_ip = os.environ.get('SMOKE_EXPECT_LAN_IP', '192.168.1.4')
    try:
        ipaddress.IPv4Address(expected_ip)
    except ipaddress.AddressValueError:
        raise SmokeError('SMOKE_EXPECT_LAN_IP 必须是 IPv4 地址') from None
    log_dir = Path(os.environ.get('SMOKE_LOG_DIR', 'out/smoke'))
    log_dir.mkdir(parents=True, exist_ok=True)
    images = Path(os.environ.get('SMOKE_IMAGE_DIR', 'out/images')).resolve()
    runs = []
    try:
        for variant in variants:
            label = f'SMOKE_LOG_DIR/{variant}.log' if 'SMOKE_LOG_DIR' in os.environ else f'out/smoke/{variant}.log'
            run = VariantRun(variant, accelerator, label)
            runs.append(run)
            run_variant(run, images, version, log_dir, int(timeout_text), expected_ip, int(http_timeout_text))
    finally:
        print('\n变体                通过  失败  启动秒数  加速器', flush=True)
        for run in runs:
            print(f'{run.variant:<19} {run.passed:>4}  {run.failed:>4}  {run.boot_seconds:>8}  {run.accelerator}', flush=True)
    return 1 if any(run.failed for run in runs) else 0


def interrupted(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
try:
    sys.exit(main())
except KeyboardInterrupt:
    print('smoke-test：已中断，QEMU 已清理。', file=sys.stderr)
    sys.exit(130)
except (SmokeError, OSError) as error:
    print(f'smoke-test：{diagnostic(error)}', file=sys.stderr)
    sys.exit(1)
PY
