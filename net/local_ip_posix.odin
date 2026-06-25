#+build linux, darwin, freebsd, netbsd, openbsd
package netplay

import "core:fmt"
import "core:sys/posix"

// Best-effort local LAN IPv4 of this host, for display when hosting a LAN game
// so the other player knows what address to type.
//
// core:net's interface enumeration is unimplemented on Linux, so we use the
// portable "connect a UDP socket toward a public address, then read its bound
// local address" trick. connect() makes the kernel pick the source interface/IP
// for that route (no packet is sent), which is the host's primary LAN address.
// Returns "" if it can't be determined. Result is temp-allocated.
host_lan_ip :: proc() -> string {
	fd := posix.socket(.INET, .DGRAM)
	if int(fd) < 0 do return ""
	defer posix.close(fd)

	dest: posix.sockaddr_in
	dest.sin_family = .INET
	dest.sin_port = u16be(53)
	posix.inet_pton(.INET, cstring("8.8.8.8"), &dest.sin_addr)
	if posix.connect(fd, cast(^posix.sockaddr)&dest, posix.socklen_t(size_of(dest))) != .OK {
		return ""
	}

	local: posix.sockaddr_in
	l := posix.socklen_t(size_of(local))
	if posix.getsockname(fd, cast(^posix.sockaddr)&local, &l) != .OK {
		return ""
	}

	b := transmute([4]u8)local.sin_addr.s_addr // s_addr is big-endian: bytes are the octets
	if b[0] == 0 do return ""
	return fmt.tprintf("%d.%d.%d.%d", b[0], b[1], b[2], b[3])
}
