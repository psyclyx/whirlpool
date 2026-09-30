//! Deciding which filesystems the status bar reports on.
//!
//! "Every mountpoint" is the wrong answer: bind mounts and btrfs subvolumes
//! repeat one device, every dataset of a ZFS pool shares the pool's free
//! space, and unmounted datasets or snapshots may hold most of what a pool
//! stores. So mounts are grouped by what actually owns the space (a ZFS pool,
//! or the backing device), reported once per group, and sized from the pool or
//! device rather than from any one dataset.

const std = @import("std");

pub const max_groups = 8;
const min_total_bytes: u64 = 512 * 1024 * 1024;

pub const Kind = enum { block, zfs };

pub const Group = struct {
    kind: Kind = .block,
    key: [64]u8 = undefined,
    key_len: u8 = 0,
    /// Shortest mountpoint seen for the group; it is what `df` is asked about.
    mount: [128]u8 = undefined,
    mount_len: u8 = 0,
    label: [24]u8 = undefined,
    label_len: u8 = 0,
    total: u64 = 0,
    used: u64 = 0,
    avail: u64 = 0,

    pub fn keySlice(self: *const Group) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn mountSlice(self: *const Group) []const u8 {
        return self.mount[0..self.mount_len];
    }

    pub fn labelSlice(self: *const Group) []const u8 {
        return self.label[0..self.label_len];
    }

    fn isRoot(self: *const Group) bool {
        return std.mem.eql(u8, self.mountSlice(), "/");
    }
};

const local_filesystems = [_][]const u8{
    "ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "zfs", "bcachefs", "ntfs", "ntfs3", "fuseblk", "exfat", "vfat",
};

const ignored_prefixes = [_][]const u8{
    "/boot", "/efi", "/run", "/sys", "/proc", "/dev", "/snap", "/var/lib/docker", "/var/lib/containers",
};

fn isLocalFilesystem(name: []const u8) bool {
    for (local_filesystems) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn isIgnoredMount(mount: []const u8) bool {
    for (ignored_prefixes) |prefix| {
        if (std.mem.eql(u8, mount, prefix)) return true;
        if (mount.len > prefix.len and std.mem.startsWith(u8, mount, prefix) and mount[prefix.len] == '/') return true;
    }
    return false;
}

fn copyInto(comptime len: usize, target: *[len]u8, source: []const u8) u8 {
    const count = @min(len, source.len);
    @memcpy(target[0..count], source[0..count]);
    return @intCast(count);
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

/// Group the mounts in /proc/self/mountinfo text. Returns the number of groups.
pub fn selectGroups(mountinfo: []const u8, groups: *[max_groups]Group) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // mount id
        _ = fields.next() orelse continue; // parent id
        _ = fields.next() orelse continue; // major:minor
        _ = fields.next() orelse continue; // root within the filesystem
        const mount = fields.next() orelse continue;
        // Skip mount options and optional fields up to the "-" separator.
        while (fields.next()) |field| if (std.mem.eql(u8, field, "-")) break;
        const filesystem = fields.next() orelse continue;
        const source = fields.next() orelse continue;
        if (!isLocalFilesystem(filesystem) or isIgnoredMount(mount)) continue;

        const is_zfs = std.mem.eql(u8, filesystem, "zfs");
        const key = if (is_zfs) source[0 .. std.mem.indexOfScalar(u8, source, '/') orelse source.len] else source;

        var found: ?*Group = null;
        for (groups[0..count]) |*group| {
            if (group.kind == (if (is_zfs) Kind.zfs else Kind.block) and std.mem.eql(u8, group.keySlice(), key)) {
                found = group;
                break;
            }
        }
        if (found) |group| {
            if (mount.len < group.mount_len) {
                group.mount_len = copyInto(128, &group.mount, mount);
                if (!is_zfs) group.label_len = copyInto(24, &group.label, baseName(mount));
            }
            continue;
        }
        if (count == max_groups) continue;
        var group = Group{ .kind = if (is_zfs) .zfs else .block };
        group.key_len = copyInto(64, &group.key, key);
        group.mount_len = copyInto(128, &group.mount, mount);
        group.label_len = copyInto(24, &group.label, if (is_zfs) key else baseName(mount));
        groups[count] = group;
        count += 1;
    }
    return count;
}

/// Fill `total`, `used` and `avail` from one line of `df -PB1 <mount>` output.
pub fn parseDf(output: []const u8, group: *Group) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return error.InvalidDf; // header
    const line = lines.next() orelse return error.InvalidDf;
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return error.InvalidDf;
    group.total = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidDf, 10);
    group.used = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidDf, 10);
    group.avail = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidDf, 10);
}

/// Replace ZFS groups' numbers with pool-wide ones from
/// `zfs list -Hp -d0 -o name,used,avail`, and add every pool that has no
/// mounted dataset (so nothing is filtered out just because it is not mounted).
/// `used` there includes snapshots and child datasets; `avail` is what can still
/// be written, after redundancy. Returns the new group count.
pub fn applyZfsList(output: []const u8, groups: *[max_groups]Group, count: usize) usize {
    var total = count;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const used = std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10) catch continue;
        const avail = std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10) catch continue;
        var found = false;
        for (groups[0..total]) |*group| {
            if (group.kind != .zfs or !std.mem.eql(u8, group.keySlice(), name)) continue;
            group.used = used;
            group.avail = avail;
            group.total = used +| avail;
            found = true;
        }
        if (found or total == max_groups) continue;
        var group = Group{ .kind = .zfs, .used = used, .avail = avail, .total = used +| avail };
        group.key_len = copyInto(64, &group.key, name);
        group.label_len = copyInto(24, &group.label, name);
        groups[total] = group;
        total += 1;
    }
    return total;
}

/// Order for display (root first, then largest) and drop groups too small to
/// matter (boot partitions, tiny scratch volumes). Returns the new count.
pub fn finalize(groups: []Group) usize {
    var count: usize = 0;
    for (groups) |group| {
        if (group.total < min_total_bytes) continue;
        groups[count] = group;
        count += 1;
    }
    std.mem.sort(Group, groups[0..count], {}, struct {
        fn before(_: void, left: Group, right: Group) bool {
            if (left.isRoot() != right.isRoot()) return left.isRoot();
            return left.total > right.total;
        }
    }.before);
    return count;
}

const sample_mountinfo =
    \\22 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw
    \\23 22 259:1 / /boot rw,relatime shared:2 - vfat /dev/nvme0n1p1 rw
    \\24 22 0:21 / /run rw,nosuid shared:3 - tmpfs tmpfs rw
    \\25 22 259:2 /nix/store /nix/store ro,relatime shared:1 - ext4 /dev/nvme0n1p2 rw
    \\26 22 0:40 / /proc rw - proc proc rw
    \\27 22 0:50 / /srv/tank rw,noatime shared:9 - zfs tank/root rw
    \\28 22 0:51 / /srv/tank/media rw,noatime shared:9 - zfs tank/media rw
    \\29 22 0:52 / /srv/tank/scratch rw,noatime shared:9 - zfs tank/scratch rw
    \\30 22 0:60 / /srv/bulk rw,noatime shared:9 - zfs bulk rw
    \\31 22 8:17 / /home rw,relatime shared:10 - btrfs /dev/sdb1 rw,subvolid=256
    \\32 22 8:17 /snaps /home/.snapshots rw,relatime shared:10 - btrfs /dev/sdb1 rw,subvolid=300
    \\33 22 0:70 / /mnt/share rw - nfs4 server:/export rw
    \\34 22 0:71 / /run/media/user/stick rw - vfat /dev/sdc1 rw
    \\
;

test "mounts group by what owns the space, not by mountpoint" {
    var groups: [max_groups]Group = undefined;
    const count = selectGroups(sample_mountinfo, &groups);
    // /, tank (three datasets), bulk, /home (two subvolumes); /boot, /run,
    // /proc, the nix store bind, network and removable mounts are not groups.
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualStrings("/", groups[0].mountSlice());
    try std.testing.expectEqualStrings("/", groups[0].labelSlice());
    try std.testing.expectEqual(Kind.zfs, groups[1].kind);
    try std.testing.expectEqualStrings("tank", groups[1].labelSlice());
    try std.testing.expectEqualStrings("/srv/tank", groups[1].mountSlice());
    try std.testing.expectEqualStrings("bulk", groups[2].labelSlice());
    try std.testing.expectEqualStrings("home", groups[3].labelSlice());
    try std.testing.expectEqualStrings("/home", groups[3].mountSlice());
}

test "zfs pools are sized from the pool, not from a dataset" {
    var groups: [max_groups]Group = undefined;
    const count = selectGroups(sample_mountinfo, &groups);
    // df of one dataset reports used = that dataset only.
    try parseDf(
        \\Filesystem 1-blocks Used Available Capacity Mounted on
        \\tank/root 4000000000000 1000000 3000000000000 1% /srv/tank
        \\
    , &groups[1]);
    try std.testing.expectEqual(@as(u64, 1000000), groups[1].used);
    const total = applyZfsList("tank\t4000000000000\t3000000000000\nbulk\t900000000000\t100000000000\nrpool\t1\t1\nempty\t2000000000000\t1000000000000\n", &groups, count);
    // A pool with nothing mounted (empty) still appears.
    try std.testing.expectEqual(count + 1, total);
    try std.testing.expectEqualStrings("empty", groups[count].labelSlice());
    try std.testing.expectEqual(@as(u64, 3_000_000_000_000), groups[count].total);
    try std.testing.expectEqual(@as(u8, 0), groups[count].mount_len);
    try std.testing.expectEqual(@as(u64, 4_000_000_000_000), groups[1].used);
    try std.testing.expectEqual(@as(u64, 3_000_000_000_000), groups[1].avail);
    try std.testing.expectEqual(@as(u64, 7_000_000_000_000), groups[1].total);
    try std.testing.expectEqual(@as(u64, 1_000_000_000_000), groups[2].total);
}

test "df numbers size a plain filesystem" {
    var group = Group{};
    try parseDf(
        \\Filesystem     1-blocks         Used   Available Capacity Mounted on
        \\/dev/nvme0n1p2 999000000000 612000000000 387000000000  62% /
        \\
    , &group);
    try std.testing.expectEqual(@as(u64, 999_000_000_000), group.total);
    try std.testing.expectEqual(@as(u64, 387_000_000_000), group.avail);
    try std.testing.expectError(error.InvalidDf, parseDf("only a header\n", &group));
}

test "root sorts first, then largest, and tiny filesystems are dropped" {
    var groups: [max_groups]Group = undefined;
    const count = selectGroups(sample_mountinfo, &groups);
    groups[0].total = 900_000_000_000; // /
    groups[1].total = 7_000_000_000_000; // tank
    groups[2].total = 1_000_000_000_000; // bulk
    groups[3].total = 100 * 1024 * 1024; // /home: under the threshold
    const kept = finalize(groups[0..count]);
    try std.testing.expectEqual(@as(usize, 3), kept);
    try std.testing.expectEqualStrings("/", groups[0].labelSlice());
    try std.testing.expectEqualStrings("tank", groups[1].labelSlice());
    try std.testing.expectEqualStrings("bulk", groups[2].labelSlice());
}
