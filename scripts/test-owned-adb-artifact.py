#!/usr/bin/env python3
"""Exercise the actual patched ADB using only private socket/key fixtures."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("adb", type=Path)
parser.add_argument("--write-contract", action="store_true")
args = parser.parse_args()
adb = args.adb.resolve()
with tempfile.TemporaryDirectory(prefix="gbadb-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    root.chmod(0o700)
    keys = root / "keys"
    keys.mkdir(mode=0o700)
    fake_home = root / "home"
    fake_home.mkdir(mode=0o700)
    developer = fake_home / ".android"
    developer.mkdir(mode=0o700)
    (developer / "adbkey").write_text("developer-sentinel-do-not-read")
    socket_path = root / "s"
    endpoint = "localfilesystem:" + str(socket_path)
    env = {"PATH": "/usr/bin:/bin", "GALAXYBRIDGE_ADB_USER_DIR": str(keys),
           "HOME": str(fake_home), "ADB_VENDOR_KEYS": str(developer / "adbkey"),
           "ADB_USB": "1", "ADB_EMU": "1", "ADB_TRACE": ""}
    def run(*arguments, timeout=4, overrides=None):
        return subprocess.run([str(adb), *arguments], env=env | (overrides or {}),
                              capture_output=True, timeout=timeout)
    assert run("gb-runtime-contract").stdout == b"galaxybridge-owned-adb-v2 keydir-only no-autostart parent-stdin usb-nonseizing-optin\n"
    assert run("-L", endpoint, "devices").returncode != 0
    assert not socket_path.exists(), "client must not create a daemon"
    assert not (keys / "adbkey").exists(), "client must not generate a key"
    generated = run("-L", endpoint, "keygen", str(keys / "adbkey"))
    assert generated.returncode == 0, generated.stderr
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in keys.iterdir()}
    assert set(before) == {"adbkey", "adbkey.pub"}
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in keys.iterdir())
    assert run("-L", endpoint, "keygen", str(keys / "adbkey")).returncode != 0
    # The explicit endpoint wins over every inherited selector. Hostile vendor
    # keys are malformed deliberately: successful server startup proves ignored.
    env.update(ADB_SERVER_SOCKET="tcp:127.0.0.1:1", ANDROID_ADB_SERVER_PORT="1",
               ANDROID_SERIAL="unrelated", GALAXYBRIDGE_ADB_PARENT_PIPE="stdin-v1")
    server = subprocess.Popen([str(adb), "-L", endpoint, "nodaemon", "server"], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise AssertionError(server.stderr.read().decode())
            if socket_path.exists():
                ready = run("-L", endpoint, "devices", "-l")
                if ready.returncode == 0:
                    break
            time.sleep(0.02)
        else:
            raise AssertionError("private server did not become ready")
        assert b"List of devices attached" in ready.stdout
        assert not ready.stdout.strip().splitlines()[1:], "USB/emulator scan must stay disabled"
        with ThreadPoolExecutor(max_workers=24) as concurrent:
            burst = list(concurrent.map(lambda _: run("-L", endpoint, "devices"), range(48)))
        assert all(result.returncode == 0 for result in burst), [result.stderr for result in burst if result.returncode]
        assert run("devices").returncode != 0, "environment endpoint cannot replace -L"
        assert run("-L", endpoint, "kill-server").returncode != 0
        assert server.poll() is None, "client cannot terminate the owned server"
        # Starting a second foreground owner must never unlink/replace the socket.
        inode = socket_path.stat().st_ino
        second = subprocess.Popen([str(adb), "-L", endpoint, "nodaemon", "server"], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        second.wait(timeout=3)
        second.stdin.close()
        assert second.returncode != 0 and socket_path.stat().st_ino == inode
        assert server.poll() is None
        # Parent pipe EOF (also caused by parent process exit) ends the exact child.
        server.stdin.close()
        server.wait(timeout=3)
        assert server.returncode == 0
        assert run("-L", endpoint, "devices").returncode != 0
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=3)
        server.stderr.close()
    assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in keys.iterdir()}
    assert (developer / "adbkey").read_text() == "developer-sentinel-do-not-read"
    assert len(list(developer.iterdir())) == 1
    socket_path.unlink(missing_ok=True)
    # Exercise the actual crash boundary as well as explicit EOF. This separate
    # supervisor owns the write end; the test process never inherits it.
    supervisor_code = """
import subprocess, sys, time
child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(child.pid, flush=True)
while True:
    time.sleep(1)
"""
    supervisor = subprocess.Popen([sys.executable, "-c", supervisor_code, str(adb),
                                   "-L", endpoint, "nodaemon", "server"], env=env,
                                  stdout=subprocess.PIPE, text=True)
    owned_pid = int(supervisor.stdout.readline())
    try:
        for _ in range(100):
            if socket_path.exists() and run("-L", endpoint, "devices").returncode == 0:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("crash fixture server did not become ready")
        supervisor.kill()
        supervisor.wait(timeout=3)
        for _ in range(150):
            status = subprocess.run(["/bin/ps", "-p", str(owned_pid), "-o", "stat="],
                                    capture_output=True, text=True).stdout.strip()
            # A terminated orphan awaiting launchd reaping has no executable
            # thread or open descriptors; it cannot keep the endpoint alive.
            if not status or status.startswith("Z"):
                break
            time.sleep(0.02)
        else:
            raise AssertionError("owned server survived its parent's SIGKILL")
        assert run("-L", endpoint, "devices").returncode != 0
    finally:
        if supervisor.poll() is None:
            supervisor.kill()
            supervisor.wait(timeout=3)
        supervisor.stdout.close()
    socket_path.unlink(missing_ok=True)
    # An unrelated mismatched server must get only host:version, never host:kill.
    requests = []
    fixture = socket.socket(socket.AF_UNIX)
    fixture.bind(str(socket_path))
    fixture.listen()
    fixture.settimeout(0.8)
    def mismatch_server():
        while True:
            try:
                connection, _ = fixture.accept()
            except socket.timeout:
                break
            with connection:
                size = int(connection.recv(4), 16)
                requests.append(connection.recv(size))
                connection.sendall(b"OKAY00040000")
    observer = threading.Thread(target=mismatch_server)
    observer.start()
    assert run("-L", endpoint, "devices").returncode != 0
    observer.join(timeout=2)
    fixture.close()
    assert requests == [b"host:version"], requests
    socket_path.unlink()
    # Wrong permissions and symlink key directories fail before any fallback.
    keys.chmod(0o755)
    assert run("version").returncode != 0
    keys.chmod(0o700)
    alias = root / "key-alias"
    alias.symlink_to(keys)
    assert run("version", overrides={"GALAXYBRIDGE_ADB_USER_DIR": str(alias)}).returncode != 0
    assert run("version", overrides={"GALAXYBRIDGE_ADB_USER_DIR": ""}).returncode != 0
    # Corrupt established Wi-Fi trust must survive a rejected server start.
    trust = keys / "adb_known_hosts.pb"
    trust.write_bytes(b"corrupt-established-trust\xff")
    trust.chmod(0o600)
    corrupt_server = subprocess.Popen([str(adb), "-L", endpoint, "nodaemon", "server"], env=env,
                                      stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    corrupt_server.wait(timeout=3)
    corrupt_server.stdin.close()
    assert corrupt_server.returncode != 0 and trust.read_bytes() == b"corrupt-established-trust\xff"
print("Owned ADB artifact contract passed: private keys/socket, no fallback or restart, no USB, no replacement, parent EOF/SIGKILL, preserved corrupt trust.")

if args.write_contract:
    runtime = adb.parent
    contract = {"contract": "galaxybridge-owned-adb-v2", "usb_policy": "nonseizing-v1",
                "adb_sha256": hashlib.sha256(adb.read_bytes()).hexdigest(),
                "libusb_sha256": hashlib.sha256((runtime / "libusb-1.0.0.dylib").read_bytes()).hexdigest()}
    (runtime / "OWNED-CONTRACT.json").write_text(json.dumps(contract, indent=2) + "\n")
