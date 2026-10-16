// The test runner inserts the driver's actual gatewayAddress implementation into Check.
let scoped = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fe80::1%lo0")!), port: 443)
let address = try Check.gatewayAddress(scoped)!
precondition(address.family == 6 && address.interface_index != 0)
let unscoped = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 443)
do { _ = try Check.gatewayAddress(unscoped); fatalError("unscoped link-local endpoint accepted") } catch {}
let usb4 = try Check.gatewayAddress(.hostPort(host: .ipv4(.loopback), port: 443))
precondition(usb4 == nil)
let usb6 = try Check.gatewayAddress(.hostPort(host: .ipv6(.loopback), port: 443))
precondition(usb6 == nil)
let literal = try Check.gatewayAddress(.hostPort(host: .ipv4(IPv4Address("192.0.2.1")!), port: 443))!
precondition(literal.family == 4)
do { _ = try Check.gatewayAddress(.hostPort(host: .name("fixture.invalid", nil), port: 443)); fatalError("unresolved hostname accepted") } catch {}
print("Gateway endpoint scope PASS: resolved scope preserved, ambiguous addresses rejected, USB loopback exempt.")
