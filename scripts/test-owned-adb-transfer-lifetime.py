#!/usr/bin/env python3
"""Exercise actual AOSP USB methods with a synthetic concurrent libusb boundary."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]).read_text()
def block(marker):
 start=source.index(marker);opening=source.index('{',start);depth=0
 for end in range(opening,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:return source[start:end+1]
 raise AssertionError(marker)
markers=['void LibUsbDevice::ReleaseInterface()', 'void LibUsbDevice::CloseDeviceHandle()',
         'void LibUsbDevice::ClearEndpoints()', 'bool LibUsbDevice::Read(', 'bool LibUsbDevice::Write(',
         'bool LibUsbDevice::Open()', 'bool LibUsbDevice::Close()']
if 'int LibUsbDevice::BulkTransfer(' in source:markers.append('int LibUsbDevice::BulkTransfer(')
fixture=(root/'scripts/fixtures/OwnedUSBTransferLifetimeSpec.cpp').read_text().replace('// ACTUAL_METHODS','\n'.join(block(m) for m in markers))
with tempfile.TemporaryDirectory(prefix='gb-usb-transfer-lifetime-') as temporary:
 p=Path(temporary);(p/'spec.cpp').write_text(fixture)
 subprocess.run(['xcrun','clang++','-std=c++20','-pthread','-Wall','-Wextra','-Wno-unused-parameter',str(p/'spec.cpp'),'-o',str(p/'spec')],check=True)
 subprocess.run([str(p/'spec')],check=True,timeout=10)
