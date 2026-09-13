#!/usr/bin/env python3
"""Controlled hardware check: every attached debug phone must already be held by developer ADB.

This explicitly enables production nonseizing USB enumeration. Do not run if any
attached debug interface is free: a free interface can receive the temporary
identity's normal Android authorization request. This script never launches the
developer adb executable, sends a phone command, or calls kill-server.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time


ADB_SHA = "738ece088e3a573ca1d53ee1ece43e7e36694905c1f9045772cbf9bb5842a122"
USB_SHA = "2454bcff28c0ad0f9aeaaaa097eec5d954689984674fecc958c2f7d3271259e7"
CONTRACT = b"galaxybridge-owned-adb-v2 keydir-only no-autostart parent-stdin usb-nonseizing-optin\n"


def exact(stream, count):
    result = b""
    while len(result) < count:
        chunk = stream.recv(count - len(result))
        if not chunk:
            raise RuntimeError("developer ADB closed its observation stream")
        result += chunk
    return result


def frame(stream):
    count = int(exact(stream, 4), 16)
    if count > 65535:
        raise RuntimeError("invalid developer ADB response")
    return exact(stream, count)


def service(request):
    stream = socket.create_connection(("127.0.0.1", 5037), timeout=3)
    try:
        encoded = request.encode("ascii")
        stream.sendall(f"{len(encoded):04x}".encode("ascii") + encoded)
        if exact(stream, 4) != b"OKAY":
            raise RuntimeError("developer ADB refused read-only observation")
        return stream
    except BaseException:
        stream.close()
        raise


def devices():
    with service("host:devices-l") as stream:
        return sorted(frame(stream).decode().splitlines())


def developer_pid():
    found = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:5037", "-sTCP:LISTEN"],
                           capture_output=True, text=True, check=True)
    pids = set(found.stdout.split())
    if len(pids) != 1:
        raise RuntimeError("expected one existing developer ADB server")
    return int(pids.pop())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True, type=Path)
    parser.add_argument("--expect-developer-usb", required=True, action="append", metavar="SERIAL")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    adb = args.adb.resolve(strict=True)
    for path, digest in [(adb, ADB_SHA), (adb.parent / "libusb-1.0.0.dylib", USB_SHA)]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("unreviewed owned ADB or USB library; nothing was launched")
    # Reserve a new evidence file before touching hardware. Never overwrite a report.
    with args.output.open("x") as report:
        evidence = {"passed": False, "adb_sha256": ADB_SHA, "usb_policy": "usb-nonseizing-v1"}
        tracking = None
        watcher = None
        stop = threading.Event()
        updates = []
        errors = []
        try:
            pid = developer_pid()
            baseline = devices()
            usb_serials = set()
            for line in baseline:
                fields = line.split()
                if any(field.startswith("usb:") for field in fields):
                    if len(fields) < 2 or fields[1] != "device":
                        raise RuntimeError("developer USB transport is not authorized and ready")
                    usb_serials.add(fields[0])
            if usb_serials != set(args.expect_developer_usb):
                raise RuntimeError("developer USB inventory does not match the explicit expected phones")
            evidence.update(developer_pid_before=pid, developer_devices_before=baseline)
            tracking = service("host:track-devices-l")
            if sorted(frame(tracking).decode().splitlines()) != baseline:
                raise RuntimeError("developer device state changed before the test")

            def observe():
                try:
                    while not stop.is_set():
                        updates.append(sorted(frame(tracking).decode().splitlines()))
                except Exception as error:
                    if not stop.is_set():
                        errors.append(str(error))

            # Block until data; shutdown below wakes this exact read without polling.
            tracking.settimeout(None)
            watcher = threading.Thread(target=observe, daemon=True)
            watcher.start()
            with tempfile.TemporaryDirectory(prefix="gbusb-", dir="/private/tmp") as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                keys = root / "keys"
                keys.mkdir(mode=0o700)
                endpoint = "localfilesystem:" + str(root / "s")
                env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                       "GALAXYBRIDGE_ADB_USER_DIR": str(keys),
                       "GALAXYBRIDGE_ADB_PARENT_PIPE": "stdin-v1",
                       "GALAXYBRIDGE_ADB_USB_POLICY": "usb-nonseizing-v1",
                       "ADB_USB": "0", "ADB_EMU": "0", "ADB_REJECT_KILL_SERVER": "1",
                       "ADB_TRACE": "", "ANDROID_ADB_LOG_PATH": "/dev/null"}

                def run(*arguments):
                    return subprocess.run([str(adb), *arguments], env=env,
                                          capture_output=True, timeout=4)

                probe = run("gb-runtime-contract")
                if probe.returncode or probe.stdout != CONTRACT:
                    raise RuntimeError("owned ADB contract rejected")
                if run("-L", endpoint, "keygen", str(keys / "adbkey")).returncode:
                    raise RuntimeError("could not generate isolated temporary fixture identity")
                server = subprocess.Popen([str(adb), "-L", endpoint, "nodaemon", "server"],
                                          env=env, stdin=subprocess.PIPE,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                evidence["owned_pid"] = server.pid
                try:
                    deadline = time.monotonic() + 3
                    while not (root / "s").exists():
                        if server.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("owned ADB did not start")
                        time.sleep(0.02)
                    # Observe hotplug enumeration for three seconds, not merely socket creation.
                    for _ in range(12):
                        result = run("-L", endpoint, "devices", "-l")
                        if result.returncode or result.stdout.strip() != b"List of devices attached":
                            raise RuntimeError("owned ADB acquired a transport or query failed")
                        time.sleep(0.25)
                finally:
                    server.stdin.close()
                    try:
                        server.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        server.terminate()
                        try:
                            server.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait(timeout=2)
                        errors.append("owned ADB needed forced exact-child cleanup")
                    evidence["owned_exit_code"] = server.returncode
            evidence.update(developer_pid_after=developer_pid(), developer_devices_after=devices())
            if evidence["developer_pid_after"] != pid or evidence["developer_devices_after"] != baseline:
                raise RuntimeError("developer ADB identity or device inventory changed")
            if server.returncode != 0 or errors or any(update != baseline for update in updates):
                raise RuntimeError("server lifetime or uninterrupted coexistence check failed")
            evidence["passed"] = True
        except Exception as error:
            evidence["error"] = str(error)
        finally:
            stop.set()
            if tracking is not None:
                try:
                    tracking.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                tracking.close()
            if watcher is not None:
                watcher.join(timeout=1)
            if "developer_pid_before" in evidence:
                try:
                    evidence.update(developer_pid_after=developer_pid(), developer_devices_after=devices())
                    if (evidence["developer_pid_after"] != evidence["developer_pid_before"] or
                            evidence["developer_devices_after"] != evidence["developer_devices_before"] or
                            any(update != evidence["developer_devices_before"] for update in updates)):
                        errors.append("developer ADB changed during the observation interval")
                except Exception as error:
                    errors.append("developer ADB final observation failed: " + str(error))
            evidence.update(developer_tracking_updates=updates, observation_errors=errors)
            if errors:
                evidence["passed"] = False
            json.dump(evidence, report, indent=2)
            report.write("\n")
        print("PASS" if evidence["passed"] else "FAIL", args.output)
        return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
