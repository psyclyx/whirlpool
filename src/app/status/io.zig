//! Cumulative I/O byte counters for the thing a filesystem lives on.
//!
//! A ZFS pool reports its own totals; any other filesystem is attributed to
//! the block device it is mounted from. Rates are derived by the caller from
//! successive readings (see rate.zig).

const std = @import("std");

pub const Counters = struct { read: u64, written: u64 };

/// `/proc/diskstats` counts 512-byte sectors regardless of the device's real
/// sector size.
const sector_bytes = 512;

/// Counters for one block device (a disk, partition or dm node) by kernel name.
pub fn parseDiskstats(diskstats: []const u8, device: []const u8) ?Counters {
    var lines = std.mem.splitScalar(u8, diskstats, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // major
        _ = fields.next() orelse continue; // minor
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, device)) continue;
        _ = fields.next() orelse return null; // reads completed
        _ = fields.next() orelse return null; // reads merged
        const sectors_read = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
        _ = fields.next() orelse return null; // ms reading
        _ = fields.next() orelse return null; // writes completed
        _ = fields.next() orelse return null; // writes merged
        const sectors_written = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
        return .{ .read = sectors_read *| sector_bytes, .written = sectors_written *| sector_bytes };
    }
    return null;
}

/// `/proc/spl/kstat/zfs/<pool>/io`: a header line, a line of column names
/// (`nread nwritten reads writes ...`), and a line of values.
pub fn parseZfsPoolIo(kstat: []const u8) ?Counters {
    var lines = std.mem.splitScalar(u8, kstat, '\n');
    while (lines.next()) |line| {
        var names = std.mem.tokenizeAny(u8, line, " \t");
        const first = names.next() orelse continue;
        if (!std.mem.eql(u8, first, "nread")) continue;
        const values_line = lines.next() orelse return null;
        var values = std.mem.tokenizeAny(u8, values_line, " \t");
        const read = std.fmt.parseUnsigned(u64, values.next() orelse return null, 10) catch return null;
        _ = names.next(); // nwritten is the second column in both lines
        const written = std.fmt.parseUnsigned(u64, values.next() orelse return null, 10) catch return null;
        return .{ .read = read, .written = written };
    }
    return null;
}

test "diskstats attributes a filesystem to the device it is mounted from" {
    const stats =
        \\ 259       0 nvme0n1 100 0 2000 0 50 0 4000 0 0 0 0
        \\ 259       2 nvme0n1p2 90 0 1001 0 45 0 3001 0 0 0 0
        \\ 252       0 dm-0 10 0 5000 0 10 0 6000 0 0 0 0
        \\
    ;
    const partition = parseDiskstats(stats, "nvme0n1p2").?;
    try std.testing.expectEqual(@as(u64, 1001 * 512), partition.read);
    try std.testing.expectEqual(@as(u64, 3001 * 512), partition.written);
    try std.testing.expectEqual(@as(u64, 6000 * 512), parseDiskstats(stats, "dm-0").?.written);
    try std.testing.expectEqual(@as(?Counters, null), parseDiskstats(stats, "sdz"));
}

test "zfs pool io reads the kstat value row" {
    const kstat =
        \\21 3 0x01 1 80 3428913648 12345678901234
        \\nread    nwritten reads    writes   wtime    wlentime wupdate  rtime    rlentime rupdate  wcnt     rcnt
        \\5000000 7000000  120      340      0        0        0        0        0        0        0        0
        \\
    ;
    const counters = parseZfsPoolIo(kstat).?;
    try std.testing.expectEqual(@as(u64, 5_000_000), counters.read);
    try std.testing.expectEqual(@as(u64, 7_000_000), counters.written);
    try std.testing.expectEqual(@as(?Counters, null), parseZfsPoolIo("nothing useful\n"));
}
