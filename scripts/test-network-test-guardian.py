#!/usr/bin/env python3
"""Real subprocess tests. No network or launchd mutation; synthetic adapter only."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("network-test-guardian.py")


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gb-network-guardian-")
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.journal = self.root / "trial.json"
        self.state = self.root / "network.json"
        self.write(self.state, {"dns": {"trial": ["old"], "unrelated": ["keep"]},
                                "reserve": True, "usb": True, "dns_ok": True,
                                "https_ok": True, "vpn": "preserved"})
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream and not stream.closed: stream.close()
        # Stop any surviving detached guardian after each test, by its recorded identity.
        if self.journal.exists():
            try:
                data = json.loads(self.journal.read_text())
                owner = data.get("guardian")
                if owner:
                    spec = importlib.util.spec_from_file_location("guardian_test_cleanup", SCRIPT)
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    if module.process_alive(owner):
                        os.kill(owner["pid"], signal.SIGTERM)
            except (OSError, ValueError):
                pass
        self.temp.cleanup()

    def write(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def call(self, command, request=None, check=True):
        result = subprocess.run([sys.executable, str(SCRIPT), command, "--journal", str(self.journal)],
                                input=json.dumps(request or {}), capture_output=True, text=True, timeout=8)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result, json.loads(result.stdout)

    def request(self, **policy):
        return {"adapter": "synthetic", "state_path": str(self.state),
                "test_interface": "trial0", "reserve_interface": "reserve0",
                "policy": {"trial_seconds": 1.0, "rollback_seconds": 2.5,
                           "heartbeat_seconds": 0.15, "heartbeat_timeout": 0.45, **policy},
                "operations": [{"kind": "dns", "target": "trial", "before": ["old"], "owned": ["new"]}]}

    def arm(self, **policy):
        _, result = self.call("arm", self.request(**policy))
        self.assertFalse(result["permitted"])
        self.assertTrue(result["test_permitted"])
        self.assertEqual(result["trial_seconds"], policy.get("trial_seconds", 1.0))
        state = json.loads(self.state.read_text())
        state["dns"]["trial"] = ["new"]
        self.write(self.state, state)
        return result

    def runner(self):
        child = subprocess.Popen([sys.executable, str(SCRIPT), "run", "--journal", str(self.journal)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if self.call("status")[1]["phase"] == "running": return child
            time.sleep(0.02)
        self.fail("runner did not publish admission receipt")
        return child

    def settled(self, timeout=5):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            _, status = self.call("status")
            if status["phase"] in ("restored", "conflict", "failed"):
                return status
            time.sleep(0.04)
        self.fail("guardian did not restore by independent deadline")

    def test_vpn_tunnel_cannot_masquerade_as_independent_reserve(self):
        spec = importlib.util.spec_from_file_location("guardian_reserve_regression", SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        request = {"adapter": "macos", "test_interface": "en0", "reserve_interface": "utun7",
                   "operations": [{"kind": "dns", "target": "Wi-Fi", "before": [], "owned": ["127.0.0.1"]}],
                   "policy": module.POLICY}
        with self.assertRaisesRegex(module.Rejected, "reserve_physical_independence_unproven"):
            module.validate_request(request)

    def test_runner_sigkill_restores_and_records_verification(self):
        self.arm(trial_seconds=3.0, rollback_seconds=4.0)
        runner = self.runner()
        runner.kill()
        runner.wait(timeout=3)
        result = self.settled()
        self.assertEqual(result["phase"], "restored")
        self.assertEqual(result["reason"], "runner_lost")
        self.assertEqual(json.loads(self.state.read_text())["dns"], {"trial": ["old"], "unrelated": ["keep"]})
        self.assertTrue(all(result["verification"][key] for key in ("dns", "https", "vpn")))

    def test_launcher_sigkill_does_not_kill_detached_guardian(self):
        # A real parent arms the guardian and then remains alive until SIGKILL.
        code = "import subprocess,sys,time; subprocess.run(sys.argv[1:],input=sys.stdin.read(),text=True,check=True); time.sleep(30)"
        parent = subprocess.Popen([sys.executable, "-c", code, sys.executable, str(SCRIPT), "arm", "--journal", str(self.journal)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(parent)
        parent.stdin.write(json.dumps(self.request()))
        parent.stdin.close()
        response = json.loads(parent.stdout.readline())
        self.assertFalse(response["permitted"])
        self.assertTrue(response["test_permitted"])
        state = json.loads(self.state.read_text()); state["dns"]["trial"] = ["new"]
        self.write(self.state, state)
        parent.kill(); parent.wait(timeout=3)
        self.assertEqual(self.settled()["phase"], "restored")

    def test_hard_trial_deadline_restores_even_with_healthy_runner(self):
        self.arm()
        runner = self.runner()
        result = self.settled()
        self.assertEqual(result["phase"], "restored")
        self.assertEqual(result["reason"], "trial_deadline")
        runner.wait(timeout=3)

    def test_unrelated_changes_are_preserved_and_reported_as_conflict(self):
        self.arm()
        state = json.loads(self.state.read_text()); state["dns"]["trial"] = ["external"]
        self.write(self.state, state)
        _, result = self.call("restore")
        self.assertEqual(result["phase"], "conflict")
        self.assertEqual(json.loads(self.state.read_text())["dns"]["trial"], ["external"])
        _, repeated = self.call("restore")
        self.assertEqual(repeated["phase"], "conflict")

    def test_preflight_rejects_missing_reserve_usb_or_same_interface(self):
        for key in ("reserve", "usb"):
            state = json.loads(self.state.read_text()); state[key] = False
            self.write(self.state, state)
            result, reply = self.call("arm", self.request(), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.journal.exists())
            self.assertFalse(reply["ok"])
            state[key] = True; self.write(self.state, state)
        request = self.request(); request["reserve_interface"] = "trial0"
        self.assertNotEqual(self.call("arm", request, check=False)[0].returncode, 0)

    def test_malformed_symlink_and_public_journals_rejected(self):
        self.write(self.journal, {"version": 1})
        self.assertNotEqual(self.call("restore", check=False)[0].returncode, 0)
        self.journal.unlink()
        self.journal.symlink_to(self.state)
        self.assertNotEqual(self.call("restore", check=False)[0].returncode, 0)
        self.journal.unlink()
        self.arm()
        self.journal.chmod(0o644)
        self.assertNotEqual(self.call("restore", check=False)[0].returncode, 0)
        self.journal.chmod(0o600)

    def test_failed_verification_is_not_reported_as_restored(self):
        self.arm()
        state = json.loads(self.state.read_text()); state["https_ok"] = False
        self.write(self.state, state)
        _, result = self.call("restore")
        self.assertEqual(result["phase"], "failed")
        self.assertFalse(result["verification"]["https"])
        self.assertEqual(json.loads(self.state.read_text())["dns"]["trial"], ["old"])

    def test_live_but_stopped_runner_heartbeat_forces_restore(self):
        self.arm(trial_seconds=3, rollback_seconds=4)
        runner = self.runner()
        os.kill(runner.pid, signal.SIGSTOP)
        result = self.settled()
        self.assertEqual(result["phase"], "restored")
        self.assertEqual(result["reason"], "heartbeat_lost")

    def test_restarted_guardian_uses_original_deadlines(self):
        armed = self.arm(trial_seconds=2, rollback_seconds=3)
        data = json.loads(self.journal.read_text())
        os.kill(data["guardian"]["pid"], signal.SIGKILL)
        replacement = subprocess.Popen([sys.executable, str(SCRIPT), "run", "--guardian", "--journal", str(self.journal)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(replacement)
        result = self.settled()
        self.assertEqual(result["phase"], "restored")
        self.assertEqual(result["trial_deadline"], armed["trial_deadline"])
        replacement.wait(timeout=3)

    def test_boot_change_recovers_instead_of_continuing_trial(self):
        self.arm(trial_seconds=3, rollback_seconds=4)
        data = json.loads(self.journal.read_text()); data["boot"] = "earlier-boot"
        self.write(self.journal, data)
        self.assertEqual(self.settled()["reason"], "boot_changed")

    def test_rejects_secret_command_fields_and_default_routes(self):
        for extra in ({"password": "must-never-be-journaled"}, {"rollback_command": ["anything"]}):
            request = self.request(); request.update(extra)
            self.assertNotEqual(self.call("arm", request, check=False)[0].returncode, 0)
            self.assertFalse(self.journal.exists())
        request = self.request()
        request["operations"] = [{"kind": "route", "target": "0.0.0.0/0", "interface": "trial0",
                                  "before": None, "owned": "192.0.2.1"}]
        self.assertNotEqual(self.call("arm", request, check=False)[0].returncode, 0)

    def test_typed_route_wifi_group_restore_retains_unrelated_leases(self):
        state = json.loads(self.state.read_text())
        state.update(route={"192.0.2.0/24": None, "198.51.100.0/24": "external"},
                     wifi={"trial0": "saved-network"}, phone_group={"usb-phone": None})
        self.write(self.state, state)
        request = self.request(); request["usb"] = {"serial": "usb-phone"}
        token = "11111111-2222-3333-4444-555555555555"
        request["operations"] += [
            {"kind": "route", "target": "192.0.2.0/24", "interface": "trial0", "before": None, "owned": "192.0.2.1"},
            {"kind": "wifi", "target": "trial0", "before": "saved-network", "owned": "test-network", "token": token},
            {"kind": "phone_group", "target": "usb-phone", "before": None, "owned": "owned-group", "token": token}]
        self.call("arm", request)
        state["dns"]["trial"] = ["new"]; state["route"]["192.0.2.0/24"] = "192.0.2.1"
        state["wifi"]["trial0"] = "test-network"; state["phone_group"]["usb-phone"] = "owned-group"
        self.write(self.state, state)
        _, result = self.call("restore")
        self.assertEqual(result["phase"], "restored")
        current = json.loads(self.state.read_text())
        self.assertEqual(current["route"], {"192.0.2.0/24": None, "198.51.100.0/24": "external"})
        self.assertEqual(current["wifi"]["trial0"], "saved-network")
        self.assertIsNone(current["phone_group"]["usb-phone"])

    def test_preflight_is_nonmutating_and_never_grants_permission(self):
        before = self.state.read_bytes()
        result = subprocess.run([sys.executable, str(SCRIPT), "status", "--preflight", "--journal", str(self.journal)],
                                input=json.dumps(self.request()), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout)
        self.assertFalse(reply["permitted"])
        self.assertTrue(reply["preflight"]["reserve"] and reply["preflight"]["usb"])
        self.assertFalse(self.journal.exists())
        self.assertEqual(before, self.state.read_bytes())

    def test_rendered_launchagent_and_shared_command_budget(self):
        spec = importlib.util.spec_from_file_location("guardian_contract", SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        payload = module.launchagent_definition(["/absolute/python", "/absolute/guardian", "run", "--guardian"], "owned.trial")
        self.assertTrue(payload["RunAtLoad"])
        self.assertEqual(payload["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(payload["ProgramArguments"][2:], ["run", "--guardian"])
        module.EXECUTION_DEADLINE = module.clock() + 0.3
        with patch.object(module, "owned_process_run") as run:
            run.return_value.returncode = 0; run.return_value.stdout = b"ok"
            module.command(["/nonexecuted/typed-command"], timeout=10)
            self.assertLess(run.call_args.kwargs["timeout"], 0.3)
        module.EXECUTION_DEADLINE = module.clock() - 1
        with patch.object(module, "owned_process_run") as run:
            with self.assertRaises(module.Rejected): module.command(["/must-not-run"])
            run.assert_not_called()

    def test_undo_command_timeout_retires_its_entire_owned_process_group(self):
        spec = importlib.util.spec_from_file_location("guardian_process", SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        pidfile = self.root / "child.pid"
        code = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); open(sys.argv[1],'w').write(str(p.pid)); time.sleep(30)"
        identity = None
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                module.command([sys.executable, "-c", code, str(pidfile)], timeout=0.3)
            pid = int(pidfile.read_text())
            try: identity = module.process_identity(pid)
            except (module.Rejected, OSError): pass
            until = time.monotonic() + 2
            while identity and module.process_alive(identity) and time.monotonic() < until:
                time.sleep(0.02)
            self.assertFalse(identity and module.process_alive(identity), "timed-out undo left a live child that could mutate later")
        finally:
            if identity and module.process_alive(identity): os.kill(identity["pid"], signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
