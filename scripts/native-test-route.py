#!/usr/bin/env python3
"""Select a local non-P2P IPv4 route fixture without sending network traffic."""
import ipaddress
import re
import socket
import subprocess
import sys

for _, interface in socket.if_nameindex():
    info = subprocess.run(['/sbin/ifconfig', interface], text=True, capture_output=True)
    flags = re.search(r'flags=\d+<([^>]+)>', info.stdout)
    if not flags:
        continue
    names = set(flags.group(1).split(','))
    if 'UP' not in names or names & {'LOOPBACK', 'POINTOPOINT'}:
        continue
    address = re.search(r'\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)', info.stdout)
    if not address:
        continue
    source = ipaddress.IPv4Address(address[1])
    mask = ipaddress.IPv4Address(int(address[2], 16))
    network = ipaddress.IPv4Network(f'{source}/{mask}', strict=False)
    if source.is_link_local or source.is_loopback or network.num_addresses < 4:
        continue
    # A same-subnet destination makes the kernel select this LAN source;
    # UDP connect() in the test performs route selection only, never send().
    target = network.network_address + 1
    if target == source:
        target += 1
    print(target)
    sys.exit(0)
sys.exit('Native route test requires an active non-loopback, non-P2P IPv4 LAN interface; set GB_QUIC_ROUTE_TEST_DESTINATION explicitly for a suitable route.')
