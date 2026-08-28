//! `zwp_linux_dmabuf_v1` buffer import and release ownership.
//!
//! Allocation and rendering deliberately live elsewhere. This package owns
//! only the Wayland-thread objects: advertised format/modifier capabilities,
//! creation of a `wl_buffer` from DMA-BUF planes, and compositor release.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");

pub const argb8888 = fourcc('A', 'R', '2', '4');
pub const xrgb8888 = fourcc('X', 'R', '2', '4');
pub const modifier_invalid: u64 = 0x00ff_ffff_ffff_ffff;

pub const FormatModifier = struct {
    format: u32,
    modifier: u64,
};

pub const Plane = struct {
    /// Borrowed for this call. Wayland receives a duplicate and may close it.
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    proxy: *wayland.client.zwp.LinuxDmabufV1,
    formats: std.ArrayList(FormatModifier) = .empty,
    listener_error: ?anyerror = null,

    /// Heap ownership is required because Wayland retains the listener data
    /// pointer until the protocol object is destroyed.
    pub fn bind(allocator: std.mem.Allocator, client: *client_api.Client) !?*Manager {
        const globals = if (client.globals.items.len == 0)
            try client.enumerateGlobals()
        else
            client.globals.items;
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "zwp_linux_dmabuf_v1")) continue;
            const proxy = client.registry.bind(
                global.name,
                wayland.client.zwp.LinuxDmabufV1,
                @min(global.version, 3),
            ) catch return error.BindFailed;
            const self = try allocator.create(Manager);
            self.* = .{ .allocator = allocator, .proxy = proxy };
            proxy.setListener(*Manager, onEvent, self);
            errdefer {
                proxy.destroy();
                self.formats.deinit(allocator);
                allocator.destroy(self);
            }
            try client.roundtrip();
            try self.requireHealthy();
            return self;
        }
        return null;
    }

    pub fn deinit(self: *Manager) void {
        const allocator = self.allocator;
        self.proxy.destroy();
        self.formats.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Manager) void {
        const allocator = self.allocator;
        @as(*wayland.client.wl.Proxy, @ptrCast(self.proxy)).destroy();
        self.formats.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn supports(self: *const Manager, format: u32, modifier: u64) bool {
        for (self.formats.items) |candidate| {
            if (candidate.format == format and candidate.modifier == modifier) return true;
        }
        return false;
    }

    /// Import planes synchronously with create_immed. This must run on the
    /// Wayland thread. The returned owner remains heap-stable for its release
    /// listener and borrows no file descriptors from the caller.
    pub fn createBuffer(
        self: *Manager,
        width: u32,
        height: u32,
        format: u32,
        modifier: u64,
        planes: []const Plane,
    ) !*Buffer {
        try self.requireHealthy();
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
            return error.InvalidExtent;
        if (planes.len == 0 or planes.len > 4) return error.InvalidPlaneCount;
        if (!self.supports(format, modifier)) return error.UnsupportedFormatModifier;

        const params = try self.proxy.createParams();
        defer params.destroy();
        for (planes, 0..) |plane, index| {
            params.add(
                // libwayland duplicates fd arguments while marshalling; the
                // allocation owner retains this descriptor.
                plane.fd,
                @intCast(index),
                plane.offset,
                plane.stride,
                @truncate(modifier >> 32),
                @truncate(modifier),
            );
        }
        const proxy = try params.createImmed(
            @intCast(width),
            @intCast(height),
            format,
            .{},
        );
        errdefer proxy.destroy();
        const owner = try self.allocator.create(Buffer);
        owner.* = .{ .allocator = self.allocator, .proxy = proxy };
        proxy.setListener(*Buffer, Buffer.onEvent, owner);
        return owner;
    }

    fn requireHealthy(self: *const Manager) !void {
        if (self.listener_error) |err| return err;
    }

    fn remember(self: *Manager, value: FormatModifier) void {
        if (self.supports(value.format, value.modifier)) return;
        self.formats.append(self.allocator, value) catch {
            self.listener_error = error.OutOfMemory;
        };
    }

    fn onEvent(
        _: *wayland.client.zwp.LinuxDmabufV1,
        event: wayland.client.zwp.LinuxDmabufV1.Event,
        self: *Manager,
    ) void {
        switch (event) {
            // v3 compositors send modifier events. Retain the v1 format event
            // as the legacy implicit-modifier capability.
            .format => |value| self.remember(.{
                .format = value.format,
                .modifier = modifier_invalid,
            }),
            .modifier => |value| self.remember(.{
                .format = value.format,
                .modifier = (@as(u64, value.modifier_hi) << 32) | value.modifier_lo,
            }),
        }
    }
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    proxy: *wayland.client.wl.Buffer,
    attached: bool = false,
    released: bool = true,

    pub fn markAttached(self: *Buffer) void {
        std.debug.assert(!self.attached or self.released);
        self.attached = true;
        self.released = false;
    }

    pub fn reusable(self: *const Buffer) bool {
        return !self.attached or self.released;
    }

    pub fn deinit(self: *Buffer) void {
        std.debug.assert(self.reusable());
        const allocator = self.allocator;
        self.proxy.destroy();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Buffer) void {
        const allocator = self.allocator;
        @as(*wayland.client.wl.Proxy, @ptrCast(self.proxy)).destroy();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn onEvent(
        _: *wayland.client.wl.Buffer,
        event: wayland.client.wl.Buffer.Event,
        self: *Buffer,
    ) void {
        switch (event) {
            .release => self.released = true,
        }
    }
};

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) |
        (@as(u32, b) << 8) |
        (@as(u32, c) << 16) |
        (@as(u32, d) << 24);
}

test "DRM fourcc values match the kernel ABI" {
    try std.testing.expectEqual(@as(u32, 0x3432_5241), argb8888);
    try std.testing.expectEqual(@as(u32, 0x3432_5258), xrgb8888);
}

test "modifier halves round trip" {
    const value: u64 = 0x1020_3040_5060_7080;
    const hi: u32 = @truncate(value >> 32);
    const lo: u32 = @truncate(value);
    try std.testing.expectEqual(value, (@as(u64, hi) << 32) | lo);
}
