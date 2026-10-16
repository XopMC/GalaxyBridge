#!/usr/bin/env python3
"""Bounded network trial guardian; JSON stdin/stdout, no shell execution.

Commands: arm/status/run/restore --journal ABSOLUTE_PRIVATE_PATH. `arm` reads a
JSON request, validates baseline leases and reserve/USB, persists undo BEFORE
returning permission. `run` owns the test heartbeat (no arbitrary test command);
`run --guardian` is the independent recovery worker. A test driver starts run,
then performs ONLY the journaled mutations after arm returned permitted=true.
Production arm installs/bootstraps a private per-trial user LaunchAgent with
restart-on-failure (no root installation); it never
uses an app process as supervisor. Existing journals are never overwritten.
Run --guardian can resume a journal after a crash without extending deadlines.
`status --preflight` reads the same request without changing networking,
installing a service, or creating a journal; it never grants trial permission.

Request: adapter=macos|synthetic, test_interface, reserve_interface, operations.
macos additionally requires https_url, dns_name, usb={adb_path,socket_path,
keys_path,serial,server:{pid,start}}, and optional recovery_adapter executable
plus recovery_adapter_sha256. Existing utun interfaces require vpn_interface
and a successful HTTPS probe bound to it, before AND after the trial.
Operations: dns(target=network service,before/owned=DNS arrays); route(target=
non-default CIDR,interface,before=null,owned=gateway); wifi(target=interface,
before/owned=SSID,token); phone_group(target=USB serial,token,before=null,
owned=group identity). Wi-Fi/phone require a separately reviewed typed adapter;
no password, command text or arbitrary undo code is stored in the journal.
Adapter JSON protocol: {action:inspect|restore,operation,usb}; inspect replies
{supported:true,current:<owned/before>,saved_network:true for wifi}; restore
must atomically compare the token/current owned value and undo only its lease,
replying {outcome:restored|unchanged|conflict}. Missing adapter fails closed.

Production trial=30s, rollback deadline=60s, heartbeat=1s/timeout=3s. Max four
operations, each bounded at 2s. DNS/HTTPS/VPN receipts contain booleans only.
No default-route, VPN, global DNS deletion, sudo or installer. Route undo only
removes a newly created exact CIDR/gateway/interface lease; replacement routes
are unsupported. DNS restore compares exact service state first. The reserve
must be a DIFFERENT live interface and pass interface-bound HTTPS. USB requires
a private independent ADB daemon reparented to launchd, not the app's runtime.
Synthetic adapter uses a private file and permits short test-only policy.

Limits: host sleep/kernel hangs cannot meet wall-clock bounds; launchd restart
is essential against guardian death. Reboot resumes immediate recovery, never
continues a trial. Wi-Fi/phone adapters are intentionally unavailable until
implemented/validated; no disruptive trial is permitted without them. Native
networksetup/route have no atomic CAS; external simultaneous admin edits can
race a compare+restore. Unknown/conflicting state is retained for manual review.
"""
import argparse
import ctypes
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import time
import uuid
from urllib.parse import urlparse

TERMINAL = {"restored", "conflict", "failed"}
EXECUTION_DEADLINE = None
POLICY = {"trial_seconds": 30.0, "rollback_seconds": 60.0,
          "heartbeat_seconds": 1.0, "heartbeat_timeout": 3.0}


if sys.platform == "darwin":
    class _Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    _system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    _system.mach_continuous_time.restype = ctypes.c_uint64
    _timebase = _Timebase()
    _system.mach_timebase_info(ctypes.byref(_timebase))
    def clock():
        # Unlike Python's mach_absolute_time-based monotonic clock, continuous
        # time advances through sleep: waking must not renew a dangerous trial.
        return _system.mach_continuous_time() * _timebase.numer / _timebase.denom / 1_000_000_000
else:
    def clock():
        return time.clock_gettime(getattr(time, "CLOCK_BOOTTIME", time.CLOCK_MONOTONIC))


class Rejected(Exception):
    pass


def require(value, code):
    if not value:
        raise Rejected(code)


def private_path(path, exists=True):
    p = Path(path)
    require(p.is_absolute() and str(p.resolve()) == str(p), "noncanonical_path")
    parent = p.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid() and
            stat.S_IMODE(parent.st_mode) == 0o700, "unsafe_directory")
    if exists:
        info = p.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
                stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1, "unsafe_file")
    return p


def read_private(path):
    p = private_path(path)
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        require(os.fstat(stream.fileno()).st_size <= 131072, "oversize_journal")
        return json.load(stream)


def atomic_write(path, value):
    p = private_path(path, exists=False)
    tmp = p.with_name(p.name + "." + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"), allow_nan=False)
            stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp, p)
        directory = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if tmp.exists(): tmp.unlink()


@contextlib.contextmanager
def lock(path, suffix=".lock", nonblocking=False):
    p = private_path(str(path) + suffix, exists=False)
    fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        private_path(p)
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        yield
    finally:
        os.close(fd)


def bounded_timeout(timeout):
    if EXECUTION_DEADLINE is not None:
        timeout = min(timeout, EXECUTION_DEADLINE - clock() - 0.1)
    require(timeout > 0, "rollback_budget_exhausted")
    return timeout


def owned_process_run(argv, timeout, env=None, input=None):
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                               close_fds=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(input=input, timeout=timeout)
    except BaseException:
        # The unreaped leader pins this exact process-group identity. Never
        # signal an arbitrary journal PID or a system daemon on timeout.
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def command(argv, timeout=2, env=None):
    result = owned_process_run(argv, timeout=bounded_timeout(timeout), env=env)
    require(result.returncode == 0 and len(result.stdout) <= 131072, "adapter_command_failed")
    return result.stdout.decode("utf-8", errors="strict")


def boot_identity():
    if sys.platform == "darwin":
        return command(["/usr/sbin/sysctl", "-n", "kern.boottime"]).strip()
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def process_identity(pid=None):
    pid = pid or os.getpid()
    if sys.platform == "darwin":
        started = command(["/bin/ps", "-p", str(pid), "-o", "lstart="]).strip()
    else:
        raw = Path(f"/proc/{pid}/stat").read_text()
        fields = raw[raw.rfind(")") + 1:].split()
        require(fields[0] != "Z", "process_gone")
        started = fields[19]
    require(bool(started), "process_gone")
    return {"pid": pid, "start": started}


def process_alive(identity):
    try:
        return identity == process_identity(identity["pid"])
    except (OSError, Rejected, KeyError, subprocess.SubprocessError):
        return False


def interface(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,15}", value), "invalid_interface")
    return value


def validate_request(request):
    require(isinstance(request, dict) and request.get("adapter") in ("synthetic", "macos"), "invalid_adapter")
    require(set(request) <= {"adapter", "test_interface", "reserve_interface", "policy", "operations", "state_path",
                             "https_url", "dns_name", "usb", "recovery_adapter", "recovery_adapter_sha256", "vpn_interface"}, "unsupported_request_field")
    interface(request.get("test_interface")); interface(request.get("reserve_interface"))
    require(request["test_interface"] != request["reserve_interface"], "reserve_not_independent")
    if request["adapter"] == "macos":
        # These are the physical links backing the trial and its reserve, not
        # VPN/utun names. Distinct virtual interface names prove nothing about
        # their shared Wi-Fi dependency. Unsupported topology fails closed.
        require(re.fullmatch(r"en[0-9]+", request["reserve_interface"]) is not None and
                re.fullmatch(r"en[0-9]+", request["test_interface"]) is not None,
                "reserve_physical_independence_unproven")
    policy = request.get("policy", POLICY)
    require(set(policy) == set(POLICY) and all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and x > 0 for x in policy.values()), "invalid_policy")
    require(policy["heartbeat_seconds"] < policy["heartbeat_timeout"] < policy["trial_seconds"] < policy["rollback_seconds"], "invalid_deadlines")
    require(request["adapter"] == "synthetic" or policy == POLICY, "production_policy_fixed")
    ops = request.get("operations")
    require(isinstance(ops, list) and 1 <= len(ops) <= 4, "invalid_operations")
    targets = set()
    for op in ops:
        require(isinstance(op, dict) and op.get("kind") in ("dns", "route", "wifi", "phone_group"), "unsupported_operation")
        require(set(op) <= {"kind", "target", "before", "owned", "interface", "token"}, "unsupported_operation_field")
        target = op.get("target")
        require(isinstance(target, str) and 0 < len(target) <= 128 and not target.startswith("-") and not any(ord(c) < 32 for c in target), "invalid_target")
        key = (op["kind"], target)
        require(key not in targets, "duplicate_lease"); targets.add(key)
        require("before" in op and "owned" in op and op["before"] != op["owned"], "invalid_lease")
        if op["kind"] == "dns":
            for values in (op["before"], op["owned"]):
                require(isinstance(values, list) and len(values) <= 8 and all(isinstance(v, str) and 0 < len(v) <= 64 for v in values), "invalid_dns")
                if request["adapter"] == "macos":
                    for value in values: ipaddress.ip_address(value)
        elif op["kind"] == "route":
            network = ipaddress.ip_network(target, strict=True)
            require(network.prefixlen > 0 and op["before"] is None, "replacement_or_default_route_unsupported")
            require(ipaddress.ip_address(op["owned"]).version == network.version, "invalid_gateway")
            interface(op.get("interface"))
        else:
            require(isinstance(op.get("token"), str) and re.fullmatch(r"[a-f0-9-]{32,64}", op["token"]), "invalid_ownership_token")
            if op["kind"] == "wifi":
                require(target == request["test_interface"], "wifi_interface_mismatch")
                require(all(isinstance(op[k], str) and 0 < len(op[k].encode()) <= 32 for k in ("before", "owned")), "invalid_ssid")
            else:
                require(target == request.get("usb", {}).get("serial") and op["before"] is None, "usb_group_mismatch")
                require(isinstance(op["owned"], str) and 0 < len(op["owned"]) <= 128, "invalid_group_identity")
    request = dict(request); request["policy"] = policy
    return request


class SyntheticAdapter:
    def __init__(self, request):
        self.request = request
        self.path = request["state_path"]
        read_private(self.path)

    def preflight(self):
        state = read_private(self.path)
        require(state.get("reserve") is True and state.get("usb") is True, "reserve_or_usb_unverified")
        return {"reserve": True, "usb": True, "vpn_baseline": state.get("vpn")}

    def current(self, op):
        return read_private(self.path).get(op["kind"], {}).get(op["target"])

    def restore(self, op):
        state = read_private(self.path)
        current = state.get(op["kind"], {}).get(op["target"])
        if current == op["before"]: return "unchanged"
        if current != op["owned"]: return "conflict"
        state[op["kind"]][op["target"]] = op["before"]
        atomic_write(self.path, state)
        return "restored"

    def verify(self, baseline):
        state = read_private(self.path)
        return {"dns": state.get("dns_ok") is True, "https": state.get("https_ok") is True,
                "vpn": state.get("vpn") == baseline["vpn_baseline"]}


class MacOSAdapter:
    def __init__(self, request):
        require(sys.platform == "darwin", "macos_required")
        self.request = request
        url = urlparse(request.get("https_url", ""))
        require(url.scheme == "https" and url.hostname and not url.username and not url.password and not url.query and not url.fragment, "invalid_https_probe")
        require(re.fullmatch(r"[A-Za-z0-9.-]{1,253}", request.get("dns_name", "")), "invalid_dns_probe")
        self.usb = request.get("usb", {})
        require(set(self.usb) == {"adb_path", "socket_path", "keys_path", "serial", "server"}, "invalid_usb_config")
        private_path(self.usb.get("socket_path", ""), exists=False)
        keys = Path(self.usb.get("keys_path", ""))
        private_path(keys / "adbkey")
        self.adb = self.trusted_executable(self.usb.get("adb_path", ""))
        require(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", self.usb.get("serial", "")), "usb_serial_required")
        self.helper = request.get("recovery_adapter")
        if self.helper:
            self.helper = self.trusted_executable(self.helper)

    @staticmethod
    def trusted_executable(value):
        p = Path(value)
        require(p.is_absolute() and p.resolve() == p, "invalid_adapter_path")
        info = p.stat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid in (0, os.getuid()) and info.st_mode & 0o022 == 0 and os.access(p, os.X_OK), "unsafe_executable")
        return str(p)

    def usb_command(self, args):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "ADB_USB": "1", "ADB_EMU": "0",
               "GALAXYBRIDGE_ADB_USER_DIR": self.usb["keys_path"], "ADB_VENDOR_KEYS": self.usb["keys_path"],
               "ADB_REJECT_KILL_SERVER": "1", "ADB_TRACE": "", "ANDROID_ADB_LOG_PATH": "/dev/null"}
        return command([self.adb, "-L", "localfilesystem:" + self.usb["socket_path"]] + args, env=env)

    def vpn(self):
        names = command(["/sbin/ifconfig", "-l"]).split()
        tunnels = {}
        for name in names:
            if re.fullmatch(r"utun[0-9]+", name):
                text = command(["/sbin/ifconfig", name])
                # Exclude changing counters; retain flags and interface addresses.
                tunnels[name] = [line.strip() for line in text.splitlines()
                                 if "flags=" in line or line.strip().startswith(("inet ", "inet6 "))]
        sessions = hashlib.sha256(command(["/usr/sbin/scutil", "--nc", "list"]).encode()).hexdigest()
        return {"sessions": sessions, "tunnels": tunnels}

    def https(self, bound=None):
        args = ["/usr/bin/curl", "--silent", "--fail", "--output", "/dev/null", "--max-time", "2", "--proto", "=https"]
        if bound: args += ["--interface", bound]
        command(args + [self.request["https_url"]], timeout=2.5)

    def preflight(self):
        inventory = command(["/usr/sbin/networksetup", "-listallhardwareports"])
        physical = set(re.findall(r"(?m)^Device: (en[0-9]+)$", inventory))
        require(self.request["reserve_interface"] in physical and self.request["test_interface"] in physical,
                "reserve_physical_independence_unproven")
        reserve = command(["/sbin/ifconfig", self.request["reserve_interface"]])
        require("RUNNING" in reserve and ("inet " in reserve or "inet6 " in reserve), "reserve_not_live")
        self.https(bound=self.request["reserve_interface"])
        server = self.usb.get("server", {})
        require(process_alive(server), "independent_usb_server_missing")
        require(command(["/bin/ps", "-p", str(server["pid"]), "-o", "ppid="]).strip() == "1", "usb_server_not_independent")
        cmdline = command(["/bin/ps", "-p", str(server["pid"]), "-o", "command="])
        require(self.usb["socket_path"] in cmdline, "usb_server_endpoint_mismatch")
        devices = self.usb_command(["devices", "-l"])
        require(any(line.split()[:2] == [self.usb["serial"], "device"] and "usb:" in line for line in devices.splitlines()), "usb_transport_unverified")
        require(self.usb_command(["-s", self.usb["serial"], "shell", "echo", "GB_GUARDIAN_USB_OK"]).strip() == "GB_GUARDIAN_USB_OK", "usb_control_unverified")
        vpn = self.vpn()
        if vpn["tunnels"]:
            require(self.request.get("vpn_interface") in vpn["tunnels"], "vpn_probe_required")
            self.https(bound=self.request["vpn_interface"])
        baseline = {"reserve": True, "usb": True, "vpn_baseline": vpn}
        require(all(self.verify(baseline).values()), "baseline_verification_failed")
        return baseline

    def helper_call(self, action, op):
        require(self.helper is not None, "typed_recovery_adapter_unavailable")
        identity = hashlib.sha256(Path(self.helper).read_bytes()).hexdigest()
        require(identity == self.request.get("recovery_adapter_sha256"), "recovery_adapter_changed")
        result = owned_process_run([self.helper], input=json.dumps({"action": action, "operation": op, "usb": self.usb}).encode(),
                                   timeout=bounded_timeout(2))
        require(result.returncode == 0 and len(result.stdout) <= 8192, "recovery_adapter_failed")
        return json.loads(result.stdout)

    def current(self, op):
        if op["kind"] == "dns":
            text = command(["/usr/sbin/networksetup", "-getdnsservers", op["target"]]).strip()
            return [] if text.startswith("There aren't any DNS Servers set on ") else text.splitlines()
        if op["kind"] == "route":
            # Exact destination/mask guard prevents accidentally deleting a fallback/default route.
            family = ["-inet6"] if ipaddress.ip_network(op["target"]).version == 6 else ["-inet"]
            try: text = command(["/sbin/route", "-n", "get"] + family + ["-net", op["target"]])
            except Rejected: return None
            fields = dict(re.findall(r"^\s*(destination|mask|gateway|interface):\s*(\S+)", text, re.M))
            try:
                dest = fields["destination"]
                if "/" not in dest:
                    dest += "/" + fields.get("mask", "128" if ":" in dest else "32")
                if ipaddress.ip_network(dest, strict=False) != ipaddress.ip_network(op["target"]): return None
                return fields["gateway"] if fields.get("interface") == op["interface"] else "conflict"
            except (KeyError, ValueError): return "conflict"
        result = self.helper_call("inspect", op)
        require(result.get("supported") is True and (op["kind"] != "wifi" or result.get("saved_network") is True), "owned_recovery_unavailable")
        return result.get("current")

    def restore(self, op):
        current = self.current(op)
        if current == op["before"]: return "unchanged"
        if current != op["owned"]: return "conflict"
        if op["kind"] == "dns":
            command(["/usr/sbin/networksetup", "-setdnsservers", op["target"]] + (op["before"] or ["Empty"]))
        elif op["kind"] == "route":
            family = ["-inet6"] if ipaddress.ip_network(op["target"]).version == 6 else ["-inet"]
            command(["/sbin/route", "-n", "delete"] + family + ["-net", op["target"], op["owned"], "-ifscope", op["interface"]])
        else:
            result = self.helper_call("restore", op).get("outcome")
            require(result in ("restored", "unchanged", "conflict"), "invalid_recovery_result")
            return result
        return "restored" if self.current(op) == op["before"] else "conflict"

    def verify(self, baseline):
        result = {"dns": False, "https": False, "vpn": False}
        try: result["dns"] = bool(command(["/usr/bin/dscacheutil", "-q", "host", "-a", "name", self.request["dns_name"]]).strip())
        except (Rejected, subprocess.SubprocessError): pass
        try: self.https(); result["https"] = True
        except (Rejected, subprocess.SubprocessError): pass
        try:
            result["vpn"] = self.vpn() == baseline["vpn_baseline"]
            if result["vpn"] and baseline["vpn_baseline"]["tunnels"]:
                self.https(bound=self.request["vpn_interface"])
        except (Rejected, subprocess.SubprocessError): result["vpn"] = False
        return result


def adapter(request):
    return SyntheticAdapter(request) if request["adapter"] == "synthetic" else MacOSAdapter(request)


def load(path):
    data = read_private(path)
    require(isinstance(data, dict) and data.get("version") == 1 and data.get("uid") == os.getuid(), "invalid_journal")
    require(str(uuid.UUID(data["id"])) == data["id"], "invalid_journal_id")
    validate_request(data["request"])
    require(data["phase"] in {"armed", "running", "restoring"} | TERMINAL, "invalid_phase")
    for key in ("armed_at", "trial_deadline", "rollback_deadline", "heartbeat"):
        require(isinstance(data[key], (int, float)) and math.isfinite(data[key]), "invalid_clock")
    require(data["trial_deadline"] == data["armed_at"] + data["request"]["policy"]["trial_seconds"] and
            data["rollback_deadline"] == data["armed_at"] + data["request"]["policy"]["rollback_seconds"], "modified_deadline")
    require(isinstance(data["boot"], str) and data["baseline"].get("reserve") is True and data["baseline"].get("usb") is True, "invalid_preflight_receipt")
    return data


def public_status(data):
    return {"ok": True, "id": data["id"], "phase": data["phase"], "reason": data.get("reason"),
            "trial_deadline": data["trial_deadline"], "rollback_deadline": data["rollback_deadline"],
            "trial_seconds": data["request"]["policy"]["trial_seconds"],
            "guardian_alive": process_alive(data.get("guardian", {})),
            "within_rollback_deadline": data.get("within_rollback_deadline"),
            "verification": data.get("verification", {}), "undo": data.get("undo", [])}


def restore(path, reason="manual", retry=False):
    global EXECUTION_DEADLINE
    with lock(path):
        data = load(path)
        if data["phase"] in TERMINAL and not (retry and data["phase"] == "failed"): return public_status(data)
        same_boot = data["boot"] == boot_identity()
        # All undo AND verification calls share one absolute budget. A process
        # restarted after reboot/deadline gets a bounded emergency recovery,
        # never a renewed trial or a false on-time receipt.
        EXECUTION_DEADLINE = data["rollback_deadline"] if same_boot and clock() < data["rollback_deadline"] else clock() + 10
        data["phase"] = "restoring"; data["reason"] = reason
        atomic_write(path, data)
        undo = []; network = adapter(data["request"])
        for op in reversed(data["request"]["operations"]):
            try: outcome = network.restore(op)
            except (OSError, Rejected, ValueError, subprocess.SubprocessError): outcome = "failed"
            undo.append({"kind": op["kind"], "outcome": outcome})
            data["undo"] = undo; atomic_write(path, data)
        data["verification"] = network.verify(data["baseline"])
        outcomes = [item["outcome"] for item in undo]
        data["phase"] = "failed" if "failed" in outcomes or not all(data["verification"].values()) else "conflict" if "conflict" in outcomes else "restored"
        data["finished_at"] = clock()
        data["within_rollback_deadline"] = same_boot and data["finished_at"] <= data["rollback_deadline"]
        atomic_write(path, data)
        EXECUTION_DEADLINE = None
        return public_status(data)


def guardian(path):
    with lock(path, suffix=".guardian", nonblocking=True):
        with lock(path):
            data = load(path)
            if data["phase"] in TERMINAL: return public_status(data)
            data["guardian"] = process_identity(); atomic_write(path, data)
        while True:
            with lock(path): data = load(path)
            if data["phase"] in TERMINAL: return public_status(data)
            now = clock(); policy = data["request"]["policy"]
            reason = None
            if data["boot"] != boot_identity(): reason = "boot_changed"
            elif data["phase"] == "restoring": reason = "recovery_incomplete"
            elif now >= data["trial_deadline"]: reason = "trial_deadline"
            elif data.get("runner") and not process_alive(data["runner"]): reason = "runner_lost"
            elif now - data["heartbeat"] >= policy["heartbeat_timeout"]: reason = "heartbeat_lost"
            if reason:
                result = restore(path, reason)
                while result["phase"] == "failed" and data["boot"] == boot_identity() and clock() + 15 < data["rollback_deadline"]:
                    time.sleep(0.5)
                    result = restore(path, reason, retry=True)
                return result
            time.sleep(min(0.1, policy["heartbeat_seconds"]))


def runner(path):
    identity = process_identity()
    with lock(path):
        data = load(path)
        require(data["phase"] == "armed" and process_alive(data.get("guardian", {})) and
                data["boot"] == boot_identity() and clock() < data["trial_deadline"], "trial_not_admitted")
        data["runner"] = identity; data["phase"] = "running"; data["heartbeat"] = clock()
        atomic_write(path, data)
    while True:
        with lock(path):
            data = load(path)
            if data["phase"] in TERMINAL: return public_status(data)
            require(data.get("runner") == identity, "runner_replaced")
            data["heartbeat"] = clock(); atomic_write(path, data)
        time.sleep(data["request"]["policy"]["heartbeat_seconds"])


def launchagent_definition(args, label):
    return {"Label": label, "ProgramArguments": args, "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 1,
            "ProcessType": "Background", "Umask": 0o077}


def arm(path, request):
    request = validate_request(request)
    network = adapter(request); baseline = network.preflight()
    for op in request["operations"]:
        require(network.current(op) == op["before"], "baseline_lease_mismatch")
    with lock(path):
        require(not Path(path).exists(), "journal_already_exists")
        now = clock(); policy = request["policy"]
        data = {"version": 1, "uid": os.getuid(), "id": str(uuid.uuid4()), "boot": boot_identity(),
                "phase": "armed", "request": request, "baseline": baseline, "armed_at": now,
                "trial_deadline": now + policy["trial_seconds"], "rollback_deadline": now + policy["rollback_seconds"], "heartbeat": now}
        atomic_write(path, data)
    args = [sys.executable, str(Path(__file__).resolve()), "run", "--guardian", "--journal", str(path)]
    try:
        if request["adapter"] == "macos":
            label = "com.xopmc.GalaxyBridge.network-test." + data["id"]
            agents = Path.home() / "Library" / "LaunchAgents"
            agents.mkdir(mode=0o700, exist_ok=True)
            info = agents.lstat()
            require(agents.resolve() == agents and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o022 == 0, "unsafe_launchagent_directory")
            plist = agents / (label + ".plist")
            content = plistlib.dumps(launchagent_definition(args, label))
            fd = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(content); stream.flush(); os.fsync(stream.fileno())
            directory = os.open(agents, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(directory)
            finally: os.close(directory)
            command(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], timeout=5)
        else:
            subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
    except (OSError, Rejected, subprocess.SubprocessError):
        restore(path, "guardian_start_failed")
        raise Rejected("guardian_start_failed")
    until = clock() + min(2, policy["heartbeat_timeout"])
    while clock() < until:
        with lock(path): current = load(path)
        if process_alive(current.get("guardian", {})) and current["phase"] == "armed":
            # A synthetic receipt can NEVER authorize real network changes.
            real = request["adapter"] == "macos"
            return {**public_status(current), "permitted": real, "test_permitted": not real}
        time.sleep(0.02)
    restore(path, "guardian_not_ready")
    raise Rejected("guardian_not_ready")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("arm", "status", "run", "restore"))
    parser.add_argument("--journal", required=True)
    parser.add_argument("--guardian", action="store_true")
    parser.add_argument("--preflight", action="store_true")
    args = parser.parse_args()
    try:
        private_path(args.journal, exists=False)
        require(not args.preflight or args.command == "status", "preflight_requires_status")
        if args.preflight:
            request = validate_request(json.load(sys.stdin))
            network = adapter(request); receipt = network.preflight()
            for op in request["operations"]:
                require(network.current(op) == op["before"], "baseline_lease_mismatch")
            result = {"ok": True, "permitted": False, "preflight": {"reserve": receipt["reserve"], "usb": receipt["usb"]}}
        elif args.command == "arm": result = arm(args.journal, json.load(sys.stdin))
        elif args.command == "restore": result = restore(args.journal, retry=True)
        elif args.command == "run": result = guardian(args.journal) if args.guardian else runner(args.journal)
        else:
            with lock(args.journal): result = public_status(load(args.journal))
        print(json.dumps(result, separators=(",", ":")), flush=True)
    except (OSError, ValueError, KeyError, TypeError, Rejected, subprocess.SubprocessError) as error:
        # Fixed error codes only: never print config, commands, SSIDs, paths, keys or raw stderr.
        code = str(error) if isinstance(error, Rejected) else type(error).__name__
        print(json.dumps({"ok": False, "error": code}), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
