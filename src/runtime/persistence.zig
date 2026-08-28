//! Durable, transport-independent runtime checkpoint persistence.
//!
//! The wire format is deliberately small and fixed-size. It contains only
//! lifecycle observations and runtime metadata; it does not contain sockets,
//! process handles, Wayland objects, or WM state. Store is the only part
//! that performs filesystem I/O, and it materializes a complete checkpoint by
//! syncing a temporary file before atomically replacing the destination.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");

pub const FormatVersion: u16 = 1;
pub const MaxCheckpointBytes: usize = 128;
pub const HeaderSize: usize = 20;
pub const PayloadSize: usize = 44;
pub const EncodedSize: usize = HeaderSize + PayloadSize;

const Magic = "WHIRLRT1";
const ChecksumOffset: usize = 16;

pub const RuntimeMetadata = struct {
    /// Monotonic caller-owned checkpoint number. It is persisted as data; the
    /// persistence layer never invents or increments it.
    checkpoint_sequence: u64 = 0,
    /// Last accepted transport-neutral action/request identifier.
    last_request_id: u64 = 0,
};

pub const Checkpoint = struct {
    lifecycle: lifecycle.Snapshot,
    metadata: RuntimeMetadata = .{},
};

pub const EncodeError = error{
    BufferTooSmall,
};

pub const DecodeError = error{
    Empty,
    TooLarge,
    Truncated,
    Corrupt,
    UnsupportedVersion,
};

/// Serialize one complete checkpoint into caller-owned bounded storage.
/// Nothing is allocated and no runtime side effect occurs.
pub fn serialize(checkpoint: Checkpoint, buffer: []u8) EncodeError![]u8 {
    if (buffer.len < EncodedSize) return error.BufferTooSmall;

    var bytes = buffer[0..EncodedSize];
    @memset(bytes, 0);
    @memcpy(bytes[0..Magic.len], Magic);
    putInt(bytes[8..10], FormatVersion);
    putInt(bytes[10..12], @as(u16, HeaderSize));
    putInt(bytes[12..16], @as(u32, PayloadSize));

    const payload = bytes[HeaderSize..];
    payload[0] = stateCode(checkpoint.lifecycle.state);
    payload[1] = failureCode(checkpoint.lifecycle.last_failure);
    putInt(payload[4..12], checkpoint.lifecycle.revision);
    putInt(payload[12..20], checkpoint.lifecycle.launches);
    putInt(payload[20..28], checkpoint.lifecycle.reloads);
    putInt(payload[28..36], checkpoint.metadata.checkpoint_sequence);
    putInt(payload[36..44], checkpoint.metadata.last_request_id);

    putInt(bytes[ChecksumOffset..20], checksum(bytes));
    return bytes;
}

/// Decode one complete checkpoint. The destination is returned by value, so a
/// rejected or truncated input cannot partially restore runtime state.
pub fn deserialize(bytes: []const u8) DecodeError!Checkpoint {
    if (bytes.len == 0) return error.Empty;
    if (bytes.len > MaxCheckpointBytes) return error.TooLarge;
    if (bytes.len < HeaderSize) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..Magic.len], Magic)) return error.Corrupt;

    const version = getInt(u16, bytes[8..10]);
    if (version != FormatVersion) return error.UnsupportedVersion;
    if (getInt(u16, bytes[10..12]) != HeaderSize) return error.Corrupt;
    if (getInt(u32, bytes[12..16]) != PayloadSize) return error.Corrupt;
    if (bytes.len < EncodedSize) return error.Truncated;
    if (bytes.len != EncodedSize) return error.Corrupt;
    if (getInt(u32, bytes[ChecksumOffset..20]) != checksum(bytes)) return error.Corrupt;

    const payload = bytes[HeaderSize..EncodedSize];
    if (payload[2] != 0 or payload[3] != 0) return error.Corrupt;

    const state = decodeState(payload[0]) orelse return error.Corrupt;
    const last_failure = if (payload[1] == 0)
        null
    else
        decodeFailure(payload[1]) orelse return error.Corrupt;

    return .{
        .lifecycle = .{
            .state = state,
            .revision = getInt(u64, payload[4..12]),
            .launches = getInt(u64, payload[12..20]),
            .reloads = getInt(u64, payload[20..28]),
            .last_failure = last_failure,
        },
        .metadata = .{
            .checkpoint_sequence = getInt(u64, payload[28..36]),
            .last_request_id = getInt(u64, payload[36..44]),
        },
    };
}

/// A filesystem-backed checkpoint store. The directory is supplied by the
/// owner, which keeps path scope explicit and makes this type independent of
/// process, socket, Wayland, and WM ownership.
pub const Store = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn init(io: std.Io, dir: std.Io.Dir) Store {
        return .{ .io = io, .dir = dir };
    }

    /// Write a fully encoded checkpoint to path. The old destination is
    /// untouched unless the new file has been completely written and synced.
    pub fn save(self: Store, path: []const u8, checkpoint: Checkpoint) !void {
        var encoded: [EncodedSize]u8 = undefined;
        const bytes = try serialize(checkpoint, &encoded);

        var atomic = try self.dir.createFileAtomic(self.io, path, .{
            .replace = true,
        });
        defer atomic.deinit(self.io);

        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    /// Read and validate one bounded checkpoint from path.
    pub fn load(self: Store, path: []const u8) !Checkpoint {
        const file = try self.dir.openFile(self.io, path, .{
            .allow_directory = false,
        });
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.size > MaxCheckpointBytes) return error.TooLarge;

        var bytes: [MaxCheckpointBytes]u8 = undefined;
        const size: usize = @intCast(stat.size);
        const count = try file.readPositionalAll(self.io, bytes[0..size], 0);
        if (count != size) return error.Truncated;
        return deserialize(bytes[0..count]);
    }
};

fn stateCode(state: lifecycle.State) u8 {
    return @intFromEnum(state);
}

fn failureCode(failure: ?lifecycle.Failure) u8 {
    return if (failure) |value| @intFromEnum(value) + 1 else 0;
}

fn decodeState(code: u8) ?lifecycle.State {
    return if (code < @typeInfo(lifecycle.State).@"enum".fields.len)
        @enumFromInt(code)
    else
        null;
}

fn decodeFailure(code: u8) ?lifecycle.Failure {
    if (code == 0) return null;
    const value = code - 1;
    return if (value < @typeInfo(lifecycle.Failure).@"enum".fields.len)
        @enumFromInt(value)
    else
        null;
}

fn putInt(destination: []u8, value: anytype) void {
    std.mem.writeInt(@TypeOf(value), destination[0..@sizeOf(@TypeOf(value))], value, .little);
}

fn getInt(comptime T: type, source: []const u8) T {
    return std.mem.readInt(T, source[0..@sizeOf(T)], .little);
}

fn checksum(bytes: []const u8) u32 {
    var hash: std.hash.Crc32 = .init();
    hash.update(bytes[0..ChecksumOffset]);
    hash.update(bytes[ChecksumOffset + @sizeOf(u32) .. EncodedSize]);
    return hash.final();
}

test "checkpoint serialization round-trips lifecycle and runtime metadata" {
    const expected: Checkpoint = .{
        .lifecycle = .{
            .state = .reloading,
            .revision = 42,
            .launches = 3,
            .reloads = 7,
            .last_failure = .reload,
        },
        .metadata = .{
            .checkpoint_sequence = 11,
            .last_request_id = 99,
        },
    };

    var encoded: [EncodedSize]u8 = undefined;
    const bytes = try serialize(expected, &encoded);
    try std.testing.expectEqual(EncodedSize, bytes.len);
    try std.testing.expectEqualDeep(expected, try deserialize(bytes));
}

test "checkpoint corruption is rejected" {
    const checkpoint: Checkpoint = .{
        .lifecycle = .{
            .state = .running,
            .revision = 2,
            .launches = 1,
            .reloads = 0,
            .last_failure = null,
        },
    };
    var encoded: [EncodedSize]u8 = undefined;
    _ = try serialize(checkpoint, &encoded);

    encoded[HeaderSize + 4] ^= 0x80;
    try std.testing.expectError(error.Corrupt, deserialize(&encoded));
}

test "checkpoint truncation is rejected" {
    const checkpoint: Checkpoint = .{ .lifecycle = .{
        .state = .stopped,
        .revision = 0,
        .launches = 0,
        .reloads = 0,
        .last_failure = null,
    } };
    var encoded: [EncodedSize]u8 = undefined;
    _ = try serialize(checkpoint, &encoded);

    try std.testing.expectError(error.Truncated, deserialize(encoded[0 .. EncodedSize - 1]));
}

test "checkpoint codec enforces fixed bounds" {
    const checkpoint: Checkpoint = .{ .lifecycle = .{
        .state = .stopped,
        .revision = 0,
        .launches = 0,
        .reloads = 0,
        .last_failure = null,
    } };
    var short_buffer: [EncodedSize - 1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, serialize(checkpoint, &short_buffer));

    var oversized: [MaxCheckpointBytes + 1]u8 = undefined;
    try std.testing.expectError(error.TooLarge, deserialize(&oversized));
}

test "store atomically writes and reads a complete checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const checkpoint: Checkpoint = .{
        .lifecycle = .{
            .state = .failed,
            .revision = 9,
            .launches = 2,
            .reloads = 1,
            .last_failure = .transport,
        },
        .metadata = .{ .checkpoint_sequence = 4, .last_request_id = 8 },
    };
    const store = Store.init(std.testing.io, tmp.dir);
    try store.save("runtime.chk", checkpoint);
    try std.testing.expectEqualDeep(checkpoint, try store.load("runtime.chk"));
}
