#!/usr/bin/env python3
"""Exercise native (and sibling Docker) TURN ACLs against the bundled helper.

All listeners bind loopback and credentials are synthetic. The probe allocates
one TURN UDP endpoint at a time and issues CREATE_PERMISSION requests only. It never
sends packets or opens connections to the peer IPs. Each helper and its temporary
configuration are removed after the test. Run with Python 3 on macOS/Xcode.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path
magic = 0x2112a442
secret = b"fixture-key-never-production-1234"
realm = b"audit-local"


def attr(kind, value):
    return struct.pack("!HH", kind, len(value)) + value + b"\0" * (-len(value) % 4)


def message(kind, attributes, key=None, transaction_id=None):
    transaction_id = transaction_id or os.urandom(12)
    body = b"".join(attributes)
    header = struct.pack("!HHI12s", kind, len(body) + (24 if key else 0), magic, transaction_id)
    if key:
        body += attr(8, hmac.new(key, header + body, hashlib.sha1).digest())
    return header + body, transaction_id


def parse(data, transaction_id):
    kind, size, cookie, received = struct.unpack("!HHI12s", data[:20])
    assert cookie == magic and received == transaction_id
    attributes = {}
    position = 20
    while position < 20 + size:
        attribute, count = struct.unpack("!HH", data[position:position + 4])
        position += 4
        attributes[attribute] = data[position:position + count]
        position += count + (-count % 4)
    error = attributes.get(9)
    code = error[2] * 100 + error[3] if error else None
    return kind, attributes, code


def run(root, config_name, ipv6=False):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = (root / config_name).read_text()
    config = "\n".join(line for line in config.splitlines() if not line.startswith("listening-port="))
    config += (f"\nlistening-port={port}\nlistening-ip=127.0.0.1\nrelay-ip=127.0.0.1"
               f"\nrelay-ip=::1\nno-tcp\nrelay-threads=1\npidfile={root}/fixture.pid\n")
    generated = root / "probe.conf"
    generated.write_text(config)
    generated.chmod(0o600)
    with (root / (config_name + ".log")).open("w") as log:
        process = subprocess.Popen([str(root / "turnserver-test"), "-c", str(generated)],
                                   cwd=root, stdout=log, stderr=subprocess.STDOUT)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(1)
                sock.bind(("127.0.0.1", 0))
                endpoint = ("127.0.0.1", port)

                def exchange(kind, attributes, key=None, transaction_id=None):
                    packet, transaction_id = message(kind, attributes, key, transaction_id)
                    sock.sendto(packet, endpoint)
                    return parse(sock.recv(65_535), transaction_id)

                allocate = [attr(0x19, b"\x11\0\0\0")]
                if ipv6:
                    allocate.append(attr(0x17, b"\x02\0\0\0"))
                deadline = time.monotonic() + 8
                while True:
                    try:
                        kind, attributes, code = exchange(3, allocate)
                        break
                    except socket.timeout:
                        if time.monotonic() > deadline:
                            raise
                assert code == 401, (kind, attributes, code)
                username = str(int(time.time()) + 600).encode() + b":audit"
                password = base64.b64encode(hmac.new(secret, username, hashlib.sha1).digest())
                # TURN's standard long-term authentication construction.
                key = hashlib.md5(username + b":" + realm + b":" + password).digest()
                auth = [attr(6, username), attr(0x14, realm), attr(0x15, attributes[0x15])]
                kind, attributes, code = exchange(3, allocate + auth, key)
                assert kind == 0x103, (kind, code, attributes)
                results = {}
                # CREATE_PERMISSION only: no SEND, CHANNEL_BIND, or peer connection.
                targets = (["::1", "::ffff:10.0.0.1", "fc00::1", "fe80::1", "2001:4860:4860::8888"] if ipv6 else
                           ["10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "100.64.0.1", "1.1.1.1"])
                for target in targets:
                    transaction_id = os.urandom(12)
                    packed = ipaddress.ip_address(target).packed
                    mask = struct.pack("!I", magic) + transaction_id
                    encoded_ip = bytes(value ^ mask[index] for index, value in enumerate(packed))
                    address = struct.pack("!BBH", 0, 2 if ipv6 else 1, 9999 ^ (magic >> 16)) + encoded_ip
                    kind, attributes, code = exchange(8, [attr(0x12, address)] + auth, key, transaction_id)
                    results[target] = {"type": hex(kind), "error": code}
                return results
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            generated.unlink(missing_ok=True)


def main():
    repository = Path(__file__).resolve().parents[1]
    runtime = repository / ".runtime"
    runtime.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn-peer-policy-", dir=runtime) as directory:
        root = Path(directory)
        source = repository / "Noctweave Relay"
        helper = root / "turnserver-test"
        shutil.copy2(source / "ManagedCoturn.bundle/Contents/MacOS/turnserver", helper)
        # The shipped helper inherits the parent app sandbox. Sign this disposable
        # test copy without inherited app entitlements so the CLI can launch it.
        subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True, capture_output=True)
        (root / "main.swift").write_text("""import Foundation
let c = try ManagedCoturnConfiguration(
    advertisedHost: "127.0.0.1", realm: "audit-local",
    sharedSecret: "fixture-key-never-production-1234", listeningPort: 54378,
    minimumRelayPort: 55110, maximumRelayPort: 55112)
print(c.configurationText)
""")
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / "module-cache"))
        subprocess.run(["xcrun", "swiftc", str(source / "ManagedCoturnService.swift"),
                        str(source / "RelaySecureFileIO.swift"), str(root / "main.swift"),
                        "-o", str(root / "configuration")], check=True, env=env)
        native = subprocess.check_output([str(root / "configuration")], text=True)
        (root / "native.conf").write_text(native)
        configurations = ["native.conf"]
        docker = repository.parent / "NoctweaveRelayServer/coturn/entrypoint.sh"
        if docker.exists():
            stub = root / "turnserver"
            stub.write_text('#!/bin/sh\ncp "$2" "$TURN_TEST_CAPTURE"\n')
            stub.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       TMPDIR=str(root), TURN_TEST_CAPTURE=str(root / "docker.conf"),
                       NOCTWEAVE_TURN_SHARED_SECRET=secret.decode(), TURN_REALM=realm.decode(),
                       TURN_MIN_PORT="55110", TURN_MAX_PORT="55112")
            subprocess.run(["sh", str(docker)], check=True, env=env)
            configurations.append("docker.conf")
        for name in configurations:
            results = run(root, name)
            print(name, json.dumps(results, sort_keys=True))
            for target in ["10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "100.64.0.1"]:
                assert results[target]["error"] == 403, (name, target, results[target])
            assert results["1.1.1.1"]["type"] == "0x108", (name, results["1.1.1.1"])
            ipv6_results = run(root, name, ipv6=True)
            print(name, "IPv6", json.dumps(ipv6_results, sort_keys=True))
            for target in ["::1", "::ffff:10.0.0.1", "fc00::1", "fe80::1"]:
                assert ipv6_results[target]["error"] == 403, (name, target, ipv6_results[target])
            assert ipv6_results["2001:4860:4860::8888"]["type"] == "0x108", (name, ipv6_results)
        print("Managed TURN peer policy checks passed (permissions only; no peer traffic).")

if __name__ == "__main__":
    main()
