#!/usr/bin/env python3
"""Run the real patched Darwin open/claim/close bodies with fake IOKit callbacks.

Only the OS boundary is replaced. No libusb context, USB service, device,
authorization, or product runtime is created by this source regression.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile


darwin = Path(sys.argv[1]).resolve()
text = darwin.read_text()


def function(name):
    match = re.search(r"static (?:int|void) " + name + r"\s*\([^)]*\)\s*\{.*?^\}", text, re.M | re.S)
    if not match:
        raise AssertionError(f"Cannot locate production function {name} in {darwin}")
    return match.group()


with tempfile.TemporaryDirectory(prefix="gb-darwin-open-") as directory:
    root = Path(directory)
    source = root / "spec.c"
    source.write_text(r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <IOKit/IOReturn.h>
#include "galaxybridge_usb_policy.h"

enum libusb_error { LIBUSB_SUCCESS = 0, LIBUSB_ERROR_ACCESS = -3,
  LIBUSB_ERROR_NOT_FOUND = -5, LIBUSB_ERROR_NOT_SUPPORTED = -12, LIBUSB_ERROR_OTHER = -99 };
typedef void *io_service_t;
typedef void *LPVOID;
typedef int SInt32;
typedef unsigned long ULONG;
typedef struct FakeDevice **usb_device_t;
typedef struct FakeInterface **interface_t;
typedef struct FakePlugin IOCFPlugInInterface;
struct FakeDevice {
  IOReturn (*USBDeviceOpen)(usb_device_t);
  IOReturn (*USBDeviceClose)(usb_device_t);
  IOReturn (*CreateDeviceAsyncEventSource)(usb_device_t, void **);
};
struct FakeInterface {
  IOReturn (*USBInterfaceOpen)(interface_t);
  IOReturn (*CreateInterfaceAsyncEventSource)(interface_t, void **);
};
struct FakePlugin {
  IOReturn (*QueryInterface)(IOCFPlugInInterface **, void *, LPVOID);
  ULONG (*Release)(IOCFPlugInInterface **);
};
struct darwin_interface { interface_t interface; void *cfSource; };
struct darwin_device_handle_priv {
  bool is_open; void *cfSource; struct darwin_interface interfaces[4];
};
struct darwin_cached_device { usb_device_t device; int open_count; int first_config; };
struct libusb_device { struct darwin_cached_device *cached; };
struct libusb_device_handle {
  struct libusb_device *dev; struct darwin_device_handle_priv priv; unsigned claimed_interfaces;
};
struct libusb_context { int unused; };
#define usbi_get_device_handle_priv(h) (&(h)->priv)
#define DARWIN_CACHED_DEVICE(d) ((d)->cached)
#define HANDLE_CTX(h) ((void)(h), (struct libusb_context *)0)
#define IOINTERFACE(i) ((i)->interface)
#define IO_OBJECT_NULL NULL
#define USB_MAXINTERFACES 4
#define kIOUSBInterfaceUserClientTypeID NULL
#define kIOCFPlugInInterfaceID NULL
#define CFUUIDGetUUIDBytes(x) (x)
#define usbi_warn(ctx, ...) ((void)(ctx))
#define usbi_dbg(ctx, ...) ((void)(ctx))
#define usbi_info(ctx, ...) ((void)(ctx))
#define usbi_err(ctx, ...) ((void)(ctx))
static void *libusb_darwin_acfl, *kCFRunLoopCommonModes, *kCFRunLoopDefaultMode;
static void CFRetain(void *p) { (void)p; }
static void CFRelease(void *p) { (void)p; }
static void CFRunLoopAddSource(void *a, void *b, void *c) { (void)a; (void)b; (void)c; }
static void CFRunLoopRemoveSource(void *a, void *b, void *c) { (void)a; (void)b; (void)c; }
static IOReturn device_result, interface_result;
static int device_opens, device_closes, interface_opens;
static IOReturn ordinary_device_open(usb_device_t d) { (void)d; ++device_opens; return device_result; }
static IOReturn ordinary_device_close(usb_device_t d) { (void)d; ++device_closes; return kIOReturnSuccess; }
static IOReturn device_source(usb_device_t d, void **source) { (void)d; *source = (void *)1; return kIOReturnSuccess; }
static IOReturn ordinary_interface_open(interface_t i) { (void)i; ++interface_opens; return interface_result; }
static IOReturn interface_source(interface_t i, void **source) { (void)i; *source = (void *)2; return kIOReturnSuccess; }
static struct FakeDevice fake_device = { ordinary_device_open, ordinary_device_close, device_source };
static struct FakeDevice *device_pointer = &fake_device;
static struct FakeInterface fake_interface = { ordinary_interface_open, interface_source };
static struct FakeInterface *interface_pointer = &fake_interface;
static IOReturn query_interface(IOCFPlugInInterface **p, void *uuid, LPVOID out) {
  (void)p; (void)uuid; *(interface_t *)out = &interface_pointer; return kIOReturnSuccess;
}
static ULONG release_plugin(IOCFPlugInInterface **p) { (void)p; return 0; }
static IOCFPlugInInterface fake_plugin = { query_interface, release_plugin };
static IOCFPlugInInterface *plugin_pointer = &fake_plugin;
static int darwin_to_libusb(IOReturn result) {
  return result == kIOReturnSuccess ? LIBUSB_SUCCESS :
    result == kIOReturnExclusiveAccess ? LIBUSB_ERROR_ACCESS : LIBUSB_ERROR_OTHER;
}
static void libusb_release_interface(struct libusb_device_handle *h, int i) {
  h->claimed_interfaces &= ~(1U << i);
}
static IOReturn darwin_get_interface(usb_device_t d, uint8_t i, io_service_t *service) {
  (void)d; assert(i == 1); *service = (void *)3; return kIOReturnSuccess;
}
static enum libusb_error darwin_set_configuration(struct libusb_device_handle *h, int config) {
  (void)h; (void)config; assert(!"Acquisition must not change the device configuration");
  return LIBUSB_ERROR_NOT_SUPPORTED;
}
static IOReturn IOCreatePlugInInterfaceForService(io_service_t service, void *a, void *b,
                                                 IOCFPlugInInterface ***plugin, SInt32 *score) {
  assert(service == (void *)3); (void)a; (void)b; *plugin = &plugin_pointer; *score = 0;
  return kIOReturnSuccess;
}
static void IOObjectRelease(io_service_t service) { (void)service; }
static void *get_interface_interface_id(void) { return NULL; }
static int get_endpoints(struct libusb_device_handle *h, uint8_t i) { (void)h; assert(i == 1); return 0; }
static int darwin_release_interface(struct libusb_device_handle *h, uint8_t i) { (void)h; (void)i; return 0; }
'''
        + "\n\n".join(function(name) for name in ("galaxybridge_darwin_try_open", "darwin_open", "darwin_claim_interface", "darwin_close"))
        + r'''
static void expect_acquisition(IOReturn device_status, IOReturn interface_status,
                               bool device_allowed, bool interface_allowed) {
  struct darwin_cached_device cached = { &device_pointer, 0, 1 };
  struct libusb_device device = { &cached };
  struct libusb_device_handle handle = { .dev = &device };
  device_result = device_status; interface_result = interface_status;
  device_opens = device_closes = interface_opens = 0;
  int opened = darwin_open(&handle);
  if ((opened == 0) != device_allowed) {
    fprintf(stderr, "device status 0x%x: expected usable handle=%d, got error %d\n",
            device_status, device_allowed, opened);
    assert((opened == 0) == device_allowed);
  }
  assert(device_opens == 1);
  if (!device_allowed) {
    assert(cached.open_count == 0 && !handle.priv.is_open && interface_opens == 0);
    return;
  }
  assert(cached.open_count == 1);
  assert(handle.priv.is_open == (device_status == kIOReturnSuccess));
  int claimed = darwin_claim_interface(&handle, 1);
  assert((claimed == 0) == interface_allowed);
  assert(interface_opens == 1);
  darwin_close(&handle);
  assert(cached.open_count == 0);
  assert(device_closes == (device_status == kIOReturnSuccess ? 1 : 0));
}
int main(void) {
  /* A device-level owner must not prevent an ordinary lease of its free ADB interface. */
  expect_acquisition(kIOReturnExclusiveAccess, kIOReturnSuccess, true, true);
  expect_acquisition(kIOReturnSuccess, kIOReturnSuccess, true, true);
  /* Never broaden continuation to actual privilege/permission/device errors. */
  expect_acquisition(kIOReturnNotPrivileged, kIOReturnSuccess, false, false);
  expect_acquisition(kIOReturnNotPermitted, kIOReturnSuccess, false, false);
  expect_acquisition(kIOReturnNoDevice, kIOReturnSuccess, false, false);
  /* Busy or denied ADB interfaces must still fail even with a usable device handle. */
  expect_acquisition(kIOReturnExclusiveAccess, kIOReturnExclusiveAccess, true, false);
  expect_acquisition(kIOReturnExclusiveAccess, kIOReturnNotPrivileged, true, false);
  expect_acquisition(kIOReturnSuccess, kIOReturnExclusiveAccess, true, false);
  assert(galaxybridge_usb_reject_mutation() == LIBUSB_ERROR_NOT_SUPPORTED);
  puts("Darwin source regression passed: device-owner coexistence, permission denial, ordinary interface contention and close ownership.");
  return 0;
}
''')
    subprocess.run(["clang", "-Wall", "-Werror", "-I", str(darwin.parent), str(source), "-o", str(root / "spec")], check=True)
    subprocess.run([str(root / "spec")], check=True)
print("No physical USB context, enumeration, acquisition, reset or authorizations touched.")
