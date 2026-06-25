#+build windows
package netplay

import "core:fmt"
import "core:net"

// Windows: core:net's enumerate_interfaces is implemented, so use it to find the
// first non-loopback, non-link-local IPv4 address. (The posix build uses a UDP
// connect trick instead, since interface enumeration is stubbed on Linux.)
host_lan_ip :: proc() -> string {
	ifaces, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil do return ""
	defer net.destroy_interfaces(ifaces, context.temp_allocator)

	for iface in ifaces {
		if .Loopback in iface.link.state do continue
		for lease in iface.unicast {
			#partial switch a in lease.address {
			case net.IP4_Address:
				if a == net.IP4_Loopback do continue
				if a[0] == 169 && a[1] == 254 do continue // link-local
				return fmt.tprintf("%d.%d.%d.%d", a[0], a[1], a[2], a[3])
			}
		}
	}
	return ""
}
