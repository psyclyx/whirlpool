//! Cumulative I/O byte counters for the block devices a filesystem lives on.
//!
//! A ZFS pool is attributed to its leaf devices (OpenZFS no longer keeps a
//! per-pool `io` kstat), so its figures are physical traffic: redundancy,
//! scrubs and resilvers included. Rates are derived by whoever draws them.

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

