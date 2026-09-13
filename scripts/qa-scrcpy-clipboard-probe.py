#!/usr/bin/env python3
"""Internal hardware probe for the pinned scrcpy 4.1 clipboard channel."""

import argparse
import os
import socket
import struct
import subprocess
import sys
import time


def receive_exact(connection: socket.socket, length: int) -> bytes:
    value = bytearray()
    while len(value) < length:
        chunk = connection.recv(length - len(value))
        if not chunk:
            raise RuntimeError("scrcpy clipboard socket closed")
        value.extend(chunk)
    return bytes(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--get", action="store_true")
    operation.add_argument("--set")
    args = parser.parse_args()

    adb = os.environ.get(
        "ADB",
        os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
    )
    scid = int.from_bytes(os.urandom(4), "big") & 0x7FFFFFFF or 1
    socket_name = f"scrcpy_{scid:08x}"
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.run(
        [
            adb,
            "-s",
            args.serial,
            "push",
            "-q",
            os.path.join(root, "third_party/scrcpy/scrcpy-server-v4.1"),
            "/data/local/tmp/scrcpy-server.jar",
        ],
        check=True,
    )
    port = subprocess.check_output(
        [adb, "-s", args.serial, "forward", "tcp:0", f"localabstract:{socket_name}"],
        text=True,
    ).strip()
    server = subprocess.Popen(
        [
            adb,
            "-s",
            args.serial,
            "shell",
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            "4.1",
            f"scid={scid:08x}",
            "log_level=info",
            "tunnel_forward=true",
            "send_device_meta=false",
            "send_stream_meta=true",
            "send_frame_meta=true",
            "clipboard_autosync=false",
            "cleanup=false",
            "power_on=false",
            "video=false",
            "audio=false",
            "keep_active=false",
        ],
        stdin=subprocess.DEVNULL,
        # Keep the probe's stdout machine-readable: only the clipboard value
        # is written there. scrcpy diagnostics remain visible on stderr.
        stdout=sys.stderr,
        # Keep server diagnostics visible: this is an explicit Internal probe,
        # and a protocol/version failure must not be collapsed to socket EOF.
        stderr=None,
    )
    connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    connection.settimeout(3)
    try:
        deadline = time.monotonic() + 3
        while True:
            ready = subprocess.run(
                [adb, "-s", args.serial, "shell", "grep", "-F", f"@{socket_name}", "/proc/net/unix"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            ).returncode == 0
            if ready:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("scrcpy clipboard socket was not created")
            time.sleep(0.05)
        while True:
            try:
                connection.connect(("127.0.0.1", int(port)))
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        if receive_exact(connection, 1) != b"\x00":
            raise RuntimeError("invalid scrcpy tunnel preamble")
        if args.get:
            connection.sendall(b"\x08\x00")
            if receive_exact(connection, 1) != b"\x00":
                raise RuntimeError("unexpected scrcpy device message")
            length = struct.unpack(">I", receive_exact(connection, 4))[0]
            sys.stdout.buffer.write(receive_exact(connection, length))
            sys.stdout.buffer.write(b"\n")
        else:
            content = args.set.encode("utf-8")
            sequence = 1
            connection.sendall(
                b"\x09" + struct.pack(">Q", sequence) + b"\x00" + struct.pack(">I", len(content)) + content
            )
            if receive_exact(connection, 1) != b"\x01":
                raise RuntimeError("missing scrcpy clipboard acknowledgement")
            acknowledged = struct.unpack(">Q", receive_exact(connection, 8))[0]
            if acknowledged != sequence:
                raise RuntimeError("wrong scrcpy clipboard acknowledgement")
    finally:
        connection.close()
        server.terminate()
        try:
            server.wait(timeout=1)
        except subprocess.TimeoutExpired:
            server.kill()
        subprocess.run(
            [adb, "-s", args.serial, "forward", "--remove", f"tcp:{port}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
