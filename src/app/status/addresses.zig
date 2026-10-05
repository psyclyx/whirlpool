//! The addresses worth showing: the default route's interface's IPv4 address
//! and its stable public IPv6 address, and any tunnel's (WireGuard, tun) IPv4.
//! IPv4 is read with ioctls on a throwaway socket and IPv6 from
//! /proc/net/if_inet6, so no program runs and no libc is needed.

const std = @import("std");
const linux = std.os.linux;

pub const max_tunnels = 3;

pub const Address = struct {
    interface: [16]u8 = undefined,
    interface_len: u8 = 0,
    /// Dotted quad, e.g. `10.0.10.102`, or IPv6 in its short form.
    text: [40]u8 = undefined,
    text_len: u8 = 0,

    pub fn interfaceSlice(self: *const Address) []const u8 {
        return self.interface[0..self.interface_len];
    }

    pub fn textSlice(self: *const Address) []const u8 {
        return self.text[0..self.text_len];
    }
};

/// Interfaces with no link-layer header (ARPHRD_NONE): WireGuard and tun.
const arphrd_none = 65534;

/// The IPv4 address of `interface` (empty when it has none).
pub fn read(interface: []const u8) Address {
    var address = Address{};
    address.interface_len = @intCast(@min(address.interface.len, interface.len));
    @memcpy(address.interface[0..address.interface_len], interface[0..address.interface_len]);
    if (interface.len >= linux.IFNAMESIZE) return address;
    const socket = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return address;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    var request = std.mem.zeroes(linux.ifreq);
    @memcpy(request.ifrn.name[0..interface.len], interface);
    if (linux.errno(linux.ioctl(fd, linux.SIOCGIFADDR, @intFromPtr(&request))) != .SUCCESS) return address;
    const inet: *const linux.sockaddr.in = @ptrCast(@alignCast(&request.ifru.addr));
    const octets: [4]u8 = @bitCast(inet.addr);
    const text = std.fmt.bufPrint(&address.text, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }) catch return address;
    address.text_len = @intCast(text.len);
    return address;
}

/// Tunnels that are up and have an address.
pub fn tunnels(io: std.Io, found: *[max_tunnels]Address) usize {
    var count: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/net", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (count == max_tunnels) break;
        var path: [64]u8 = undefined;
        var value: [16]u8 = undefined;
        const type_path = std.fmt.bufPrint(&path, "{s}/type", .{entry.name}) catch continue;
        const kind = std.fmt.parseUnsigned(u32, std.mem.trim(u8, dir.readFile(io, type_path, &value) catch continue, " \n"), 10) catch continue;
        if (kind != arphrd_none) continue;
        const address = read(entry.name);
        if (address.text_len == 0) continue;
        found[count] = address;
        count += 1;
    }
    std.mem.sort(Address, found[0..count], {}, struct {
        fn before(_: void, left: Address, right: Address) bool {
            return std.mem.order(u8, left.interfaceSlice(), right.interfaceSlice()) == .lt;
        }
    }.before);
    return count;
}

// /proc/net/if_inet6 flags (IFA_F_*) that rule an address out: temporary
// (privacy), failed duplicate detection, deprecated, tentative.
const temporary = 0x01;
const unusable = 0x08 | 0x20 | 0x40;

/// The IPv6 address of `interface` worth showing (empty when it has none):
/// global scope, preferring a stable public address, then a stable unique
/// local one (fc00::/7), then a temporary one.
pub fn readIpv6(io: std.Io, interface: []const u8) Address {
    var buffer: [8192]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, "/proc/net/if_inet6", &buffer) catch return .{};
    return pickIpv6(data, interface);
}

pub fn pickIpv6(if_inet6: []const u8, interface: []const u8) Address {
    var address = Address{};
    address.interface_len = @intCast(@min(address.interface.len, interface.len));
    @memcpy(address.interface[0..address.interface_len], interface[0..address.interface_len]);
    var best: ?[16]u8 = null;
    var best_rank: u8 = 0;
    var lines = std.mem.splitScalar(u8, if_inet6, '\n');
    while (lines.next()) |line| {
        // address, interface index, prefix length, scope, flags, name
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hex = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const scope = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 16) catch continue;
        const flags = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 16) catch continue;
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, interface) or scope != 0 or flags & unusable != 0 or hex.len != 32) continue;
        var bytes: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex) catch continue;
        const local = bytes[0] & 0xfe == 0xfc;
        const rank: u8 = if (flags & temporary != 0) 1 else if (local) 2 else 3;
        if (rank > best_rank) {
            best, best_rank = .{ bytes, rank };
        }
    }
    const bytes = best orelse return address;
    const text = formatIpv6(&address.text, bytes);
    address.text_len = @intCast(text.len);
    return address;
}

/// RFC 5952 form: lowercase, no leading zeros, the longest run of two or
/// more zero groups (the first, on a tie) as `::`.
pub fn formatIpv6(buffer: *[40]u8, bytes: [16]u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (&groups, 0..) |*group, index| group.* = @as(u16, bytes[index * 2]) << 8 | bytes[index * 2 + 1];
    var run_start: usize = 8;
    var run_len: usize = 0;
    var index: usize = 0;
    while (index < 8) {
        if (groups[index] != 0) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < 8 and groups[index] == 0) index += 1;
        if (index - start > run_len and index - start >= 2) {
            run_start, run_len = .{ start, index - start };
        }
    }
    var writer = std.Io.Writer.fixed(buffer);
    index = 0;
    while (index < 8) {
        if (index == run_start) {
            writer.writeAll("::") catch unreachable;
            index += run_len;
            continue;
        }
        if (index != 0 and index != run_start + run_len) writer.writeByte(':') catch unreachable;
        writer.print("{x}", .{groups[index]}) catch unreachable;
        index += 1;
    }
    return writer.buffered();
}

test "ipv6 addresses are written in their short form" {
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2001:db8::1", formatIpv6(&buffer, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expectEqualStrings("::1", formatIpv6(&buffer, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expectEqualStrings("fd9a:e830:4b1e:a::104", formatIpv6(&buffer, .{ 0xfd, 0x9a, 0xe8, 0x30, 0x4b, 0x1e, 0, 0x0a, 0, 0, 0, 0, 0, 0, 0x01, 0x04 }));
    // A lone zero group stays a 0.
    try std.testing.expectEqualStrings("2001:db8:0:1:1:1:1:1", formatIpv6(&buffer, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 }));
}

test "the stable public ipv6 address is preferred" {
    const table =
        \\26010602920284d01a3acde3229c6ba0 07 40 00 01      br0
        \\fe800000000000004c3b65fffedc8cf4 07 40 20 80      br0
        \\fd9ae8304b1e000a4c3b65fffedc8cf4 07 40 00 00      br0
        \\26010602920284d04c3b65fffedc8cf4 07 40 00 00      br0
        \\20010db8000000000000000000000001 03 40 00 00     eth9
        \\
    ;
    try std.testing.expectEqualStrings("2601:602:9202:84d0:4c3b:65ff:fedc:8cf4", pickIpv6(table, "br0").textSlice());
    try std.testing.expectEqual(@as(u8, 0), pickIpv6(table, "wlan0").text_len);
}

test "the loopback interface has its address" {
    const loopback = read("lo");
    try std.testing.expectEqualStrings("127.0.0.1", loopback.textSlice());
    try std.testing.expectEqual(@as(u8, 0), read("no-such-interface0").text_len);
}
