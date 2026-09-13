#!/usr/bin/env python3
"""Exercise nonseizing acquisition policy against fake USB callbacks.

This deliberately never creates a libusb context or enumerates/acquires a
physical device. Real Darwin interface coexistence still needs hardware QA.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

header = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="gb-usb-policy-") as directory:
    root = Path(directory)
    source = root / "policy.c"
    source.write_text(r'''
#include <assert.h>
#include "galaxybridge_usb_policy.h"
struct Device { int calls; int result; };
static int ordinary_open(void *opaque) {
  struct Device *device = opaque;
  device->calls++;
  return device->result;
}
int main(void) {
  struct Device available = {0, 0};
  struct Device busy = {0, -6};
  struct Device denied = {0, -3};
  assert(galaxybridge_usb_open_once(&available, ordinary_open) == 0);
  assert(available.calls == 1);
  assert(galaxybridge_usb_open_once(&busy, ordinary_open) == -6);
  assert(busy.calls == 1);
  assert(galaxybridge_usb_open_once(&denied, ordinary_open) == -3);
  assert(denied.calls == 1);
  assert(galaxybridge_usb_reject_mutation() == -12);
  return 0;
}
''')
    subprocess.run(["clang", "-Wall", "-Werror", "-I", str(header.parent), str(source), "-o", str(root / "spec")], check=True)
    subprocess.run([str(root / "spec")], check=True)
print("USB policy fixture passed: one ordinary open, busy/denied propagated, mutating device operations unsupported.")
print("No physical USB context, enumeration, acquisition, reset or authorizations touched.")
