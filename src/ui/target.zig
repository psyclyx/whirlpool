//! A host-independent surface target used by tests and fixture hosts.

const std = @import("std");
const tree = @import("tree.zig");

const Allocator = std.mem.Allocator;

pub const SurfaceDescription = struct {
    width: u32,
    height: u32,
    scale: f32 = 1,
};

pub const TargetError = error{
    InvalidSurface,
};

pub const Frame = struct {
    serial: u64,
    surface: SurfaceDescription,
    nodes: []tree.NodeSnapshot,
};

/// Captures dirty scene submissions without depending on a window-system
/// surface or graphics API. Frames own copied text and remain valid after the
/// source scene changes.
pub const RecordingTarget = struct {
    allocator: Allocator,
    surface: SurfaceDescription,
    frames: std.ArrayList(Frame) = .empty,
    next_serial: u64 = 1,

    pub fn init(allocator: Allocator, surface: SurfaceDescription) TargetError!RecordingTarget {
        try validateSurface(surface);
        return .{ .allocator = allocator, .surface = surface };
    }

    pub fn deinit(self: *RecordingTarget) void {
        self.clear();
        self.frames.deinit(self.allocator);
    }

    pub fn clear(self: *RecordingTarget) void {
        for (self.frames.items) |frame| tree.Scene.freeSnapshots(self.allocator, frame.nodes);
        self.frames.clearRetainingCapacity();
    }

    pub fn present(self: *RecordingTarget, scene: *tree.Scene) !bool {
        const nodes = try scene.snapshotDirtyAlloc(self.allocator);
        if (nodes.len == 0) {
            self.allocator.free(nodes);
            return false;
        }
        errdefer tree.Scene.freeSnapshots(self.allocator, nodes);

        try self.frames.append(self.allocator, .{
            .serial = self.next_serial,
            .surface = self.surface,
            .nodes = nodes,
        });
        self.next_serial +|= 1;
        scene.clearDirty();
        return true;
    }

    pub fn frameCount(self: *const RecordingTarget) usize {
        return self.frames.items.len;
    }

    pub fn lastFrame(self: *const RecordingTarget) ?*const Frame {
        if (self.frames.items.len == 0) return null;
        return &self.frames.items[self.frames.items.len - 1];
    }
};

fn validateSurface(surface: SurfaceDescription) TargetError!void {
    if (surface.width == 0 or surface.height == 0 or
        !std.math.isFinite(surface.scale) or surface.scale <= 0) return error.InvalidSurface;
}

test "recording target captures dirty nodes and clears the submitted dirty set" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const root = try mount.create(.row, null);
    const label = try mount.text(root, "before");
    var delta = @import("scene.zig").SceneDelta.init(std.testing.allocator);
    defer delta.deinit();
    try delta.setText(label, "after");
    try delta.apply(&scene);

    var target = try RecordingTarget.init(std.testing.allocator, .{ .width = 320, .height = 40 });
    defer target.deinit();
    try std.testing.expect(try target.present(&scene));
    try std.testing.expectEqual(@as(usize, 1), target.frameCount());
    try std.testing.expectEqualStrings("after", findFrameText(target.lastFrame().?, label));
    try std.testing.expect(!try target.present(&scene));

    try delta.setText(label, "later");
    try delta.apply(&scene);
    try std.testing.expect(try target.present(&scene));
    try std.testing.expectEqualStrings("after", findFrameText(&target.frames.items[0], label));
    try std.testing.expectEqualStrings("later", findFrameText(target.lastFrame().?, label));
}

test "newly mounted nodes are dirty until their first presentation" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const label = try mount.text(null, "initial");
    var target = try RecordingTarget.init(std.testing.allocator, .{ .width = 320, .height = 40 });
    defer target.deinit();

    try std.testing.expect(try target.present(&scene));
    try std.testing.expectEqual(@as(usize, 1), target.frameCount());
    try std.testing.expectEqualStrings("initial", findFrameText(target.lastFrame().?, label));
    try std.testing.expect(!try target.present(&scene));
}

fn findFrameText(frame: *const Frame, handle: tree.NodeHandle) []const u8 {
    for (frame.nodes) |node| if (node.handle.eql(handle)) return node.properties.text;
    unreachable;
}

test "recording target rejects unusable surfaces before capturing a scene" {
    try std.testing.expectError(error.InvalidSurface, RecordingTarget.init(
        std.testing.allocator,
        .{ .width = 0, .height = 40 },
    ));
    try std.testing.expectError(error.InvalidSurface, RecordingTarget.init(
        std.testing.allocator,
        .{ .width = 320, .height = 40, .scale = 0 },
    ));
}
