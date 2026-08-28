//! Host composition of an installed Lua retained program.
//!
//! Lua emits only script-level node ids, kinds, and scalar property values.
//! This adapter owns the translation to UI mount/node handles, snapshots the
//! complete retained tree, and lowers those snapshots through skia_scene.
//! No Wayland, Vulkan, Skia native pointer, or WM object enters this module.

const std = @import("std");
const script = @import("whirlpool-script");
const lua_program = script.program_loader;
const ui = @import("whirlpool-ui");
const graphics = @import("whirlpool-graphics");
const skia_scene = @import("skia_scene.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    max_nodes: usize = 4096,
    default_shape_width: ?u32 = null,
    default_shape_height: ?u32 = null,
};

pub const Stats = struct {
    created_nodes: usize = 0,
    applied_properties: usize = 0,
};

pub const Frame = struct {
    lowered: skia_scene.OwnedDrawList,
    node_count: usize,

    pub fn drawList(self: *const Frame) graphics.skia.DrawList {
        return self.lowered.drawList();
    }

    pub fn operationCount(self: *const Frame) usize {
        return self.lowered.operationCount();
    }

    pub fn deinit(self: *Frame) void {
        self.lowered.deinit();
        self.* = undefined;
    }
};

pub const Composition = struct {
    allocator: Allocator,
    options: Options,
    scene: *ui.Scene,
    mount_context: ui.MountContext,
    nodes: std.ArrayList(?ui.NodeHandle) = .empty,
    delta: ui.SceneDelta,
    in_batch: bool = false,
    stats: Stats = .{},

    /// Allocate a scene, mount the program once, and apply its initial
    /// property batch. The VM remains owned by the caller.
    pub fn mount(
        allocator: Allocator,
        vm: *lua_program.Vm,
        program: *const lua_program.Program,
        options: Options,
    ) !Composition {
        var result = try empty(allocator, options);
        errdefer result.deinit();

        const target = result.sink();
        try program.instantiate(vm, &target);
        return result;
    }

    /// Apply one named provider/service update through the Lua controller and
    /// atomically commit the resulting retained-property changes.
    pub fn update(
        self: *Composition,
        vm: *lua_program.Vm,
        program: *const lua_program.Program,
        value: lua_program.Update,
    ) !void {
        const target = self.sink();
        try program.update(vm, &target, value);
    }

    fn empty(allocator: Allocator, options: Options) !Composition {
        const scene = try allocator.create(ui.Scene);
        scene.* = ui.Scene.init(allocator);
        errdefer {
            scene.deinit();
            allocator.destroy(scene);
        }
        var mount_context = try scene.mount();
        errdefer mount_context.deinit();
        return .{
            .allocator = allocator,
            .options = options,
            .scene = scene,
            .mount_context = mount_context,
            .delta = ui.SceneDelta.init(allocator),
        };
    }

    pub fn deinit(self: *Composition) void {
        self.delta.deinit();
        self.nodes.deinit(self.allocator);
        self.mount_context.deinit();
        self.scene.deinit();
        self.allocator.destroy(self.scene);
        self.* = undefined;
    }

    pub fn sceneView(self: *Composition) *ui.Scene {
        return self.scene;
    }

    pub fn nodeCount(self: *const Composition) usize {
        return self.scene.liveNodeCount();
    }

    pub fn statsView(self: *const Composition) Stats {
        return self.stats;
    }

    fn sink(self: *Composition) lua_program.Sink {
        return .{
            .context = @ptrCast(self),
            .begin = sinkBegin,
            .create = sinkCreate,
            .set = sinkSet,
            .finish = sinkFinish,
        };
    }

    /// Snapshot all retained nodes in tree order and lower them to a complete
    /// renderer-neutral draw list. Dirty bits are cleared only after lowering
    /// succeeds; a rejected frame can therefore be retried.
    pub fn snapshotAndLower(self: *Composition, viewport: skia_scene.Viewport) !Frame {
        var snapshots = std.ArrayList(ui.NodeSnapshot).empty;
        defer {
            for (snapshots.items) |snapshot| {
                if (snapshot.properties.text.len != 0) self.allocator.free(snapshot.properties.text);
            }
            snapshots.deinit(self.allocator);
        }

        try self.collectSnapshots(null, &snapshots);
        const lowered = try skia_scene.lower(self.allocator, snapshots.items, viewport);
        self.scene.clearDirty();
        return .{ .lowered = lowered, .node_count = snapshots.items.len };
    }

    fn collectSnapshots(self: *Composition, parent: ?ui.NodeHandle, output: *std.ArrayList(ui.NodeSnapshot)) !void {
        const children = try self.scene.childrenAlloc(self.allocator, parent);
        defer self.allocator.free(children);
        for (children) |handle| {
            var snapshot = self.scene.node(handle) orelse return error.StaleNode;
            if (snapshot.properties.text.len != 0)
                snapshot.properties.text = try self.allocator.dupe(u8, snapshot.properties.text);
            errdefer if (snapshot.properties.text.len != 0) self.allocator.free(snapshot.properties.text);
            try output.append(self.allocator, snapshot);
            try self.collectSnapshots(handle, output);
        }
    }

    fn sinkBegin(context: ?*anyopaque) anyerror!void {
        const self = fromContext(context);
        if (self.in_batch) return error.InvalidBatch;
        self.delta.rollback();
        self.in_batch = true;
    }

    fn sinkCreate(context: ?*anyopaque, id: lua_program.NodeId, kind: lua_program.NodeKind, parent: ?lua_program.NodeId) anyerror!void {
        const self = fromContext(context);
        if (!self.in_batch) return error.InvalidBatch;
        if (id == 0 or id > self.options.max_nodes) return error.NodeLimitExceeded;
        try self.ensureNodeSlot(id);
        if (self.nodes.items[id] != null) return error.DuplicateNode;

        const parent_handle = if (parent) |parent_id| blk: {
            if (parent_id == 0 or parent_id > self.options.max_nodes) return error.InvalidParent;
            break :blk self.nodes.items[parent_id] orelse return error.InvalidParent;
        } else null;

        const ui_kind: ui.NodeKind = switch (kind) {
            .row => .row,
            .column => .column,
            .stack => .stack,
            .spacer => .spacer,
            .shape => .shape,
            .text => .text,
            // Icons remain a retained text node at this scalar UI boundary.
            // The package's name/size/color properties still retain their
            // meaning through sinkSet.
            .icon => .text,
        };
        const handle = try self.mount_context.create(ui_kind, parent_handle);
        self.nodes.items[id] = handle;
        self.stats.created_nodes += 1;

        if (ui_kind == .shape) {
            if (self.options.default_shape_width) |width| try self.delta.setWidth(handle, width);
            if (self.options.default_shape_height) |height| try self.delta.setHeight(handle, height);
        }
    }

    fn sinkSet(context: ?*anyopaque, id: lua_program.NodeId, key: []const u8, value: lua_program.Value) anyerror!void {
        const self = fromContext(context);
        if (!self.in_batch) return error.InvalidBatch;
        if (id == 0 or id >= self.nodes.items.len) return error.StaleNode;
        const handle = self.nodes.items[id] orelse return error.StaleNode;
        const snapshot = self.scene.node(handle) orelse return error.StaleNode;

        if (std.mem.eql(u8, key, "text")) {
            return self.setText(handle, value);
        } else if (std.mem.eql(u8, key, "name")) {
            return self.setText(handle, value);
        } else if (std.mem.eql(u8, key, "width")) {
            return self.setU32(handle, value, .width);
        } else if (std.mem.eql(u8, key, "height")) {
            return self.setU32(handle, value, .height);
        } else if (std.mem.eql(u8, key, "gap")) {
            return self.setU32(handle, value, .gap);
        } else if (std.mem.eql(u8, key, "flex")) {
            return self.setU32(handle, value, .flex);
        } else if (std.mem.eql(u8, key, "font_size") or std.mem.eql(u8, key, "size")) {
            return self.setFontSize(handle, value);
        } else if (std.mem.eql(u8, key, "opacity")) {
            return self.setOpacity(handle, value);
        } else if (std.mem.eql(u8, key, "padding")) {
            return self.setPadding(handle, value);
        } else if (std.mem.eql(u8, key, "radius")) {
            return self.setRadius(handle, value);
        } else if (std.mem.eql(u8, key, "fill") or std.mem.eql(u8, key, "color")) {
            return self.setColor(snapshot.kind, handle, value);
        } else if (std.mem.eql(u8, key, "text_color")) {
            return self.setTextColor(handle, value);
        }

        return error.InvalidProperty;
    }

    fn sinkFinish(context: ?*anyopaque) anyerror!void {
        const self = fromContext(context);
        if (!self.in_batch) return;
        try self.delta.apply(self.scene);
        self.in_batch = false;
    }

    fn ensureNodeSlot(self: *Composition, id: lua_program.NodeId) !void {
        while (self.nodes.items.len <= id) try self.nodes.append(self.allocator, null);
    }

    fn setText(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        switch (value) {
            .string => |text| try self.delta.setText(handle, text),
            else => return error.InvalidProperty,
        }
        self.stats.applied_properties += 1;
    }

    fn setU32(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value, property: U32Property) !void {
        const number = try integerValue(value);
        if (number > std.math.maxInt(u32)) return error.InvalidProperty;
        const converted: u32 = @intCast(number);
        switch (property) {
            .width => try self.delta.setWidth(handle, converted),
            .height => try self.delta.setHeight(handle, converted),
            .gap => try self.delta.setGap(handle, converted),
            .flex => try self.delta.setFlex(handle, converted),
        }
        self.stats.applied_properties += 1;
    }

    fn setFontSize(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        const number = try integerValue(value);
        if (number == 0 or number > std.math.maxInt(u16)) return error.InvalidProperty;
        try self.delta.setFontSize(handle, @intCast(number));
        self.stats.applied_properties += 1;
    }

    fn setOpacity(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        const number = try finiteNumber(value);
        try self.delta.setOpacity(handle, @floatCast(number));
        self.stats.applied_properties += 1;
    }

    fn setRadius(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        const number = try finiteNumber(value);
        try self.delta.setRadius(handle, @floatCast(number));
        self.stats.applied_properties += 1;
    }

    fn setPadding(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        const values = array(value, 4) orelse return error.InvalidProperty;
        const edges = ui.Edges{
            .top = try arrayU32(values[0]),
            .right = try arrayU32(values[1]),
            .bottom = try arrayU32(values[2]),
            .left = try arrayU32(values[3]),
        };
        try self.delta.setPadding(handle, edges);
        self.stats.applied_properties += 1;
    }

    fn setColor(self: *Composition, kind: ui.NodeKind, handle: ui.NodeHandle, value: lua_program.Value) !void {
        const color = try colorValue(value);
        if (kind == .shape) {
            try self.delta.setFill(handle, color);
        } else if (kind == .text) {
            try self.delta.setTextColor(handle, color);
        } else {
            return error.InvalidProperty;
        }
        self.stats.applied_properties += 1;
    }

    fn setTextColor(self: *Composition, handle: ui.NodeHandle, value: lua_program.Value) !void {
        try self.delta.setTextColor(handle, try colorValue(value));
        self.stats.applied_properties += 1;
    }
};

const U32Property = enum { width, height, gap, flex };

fn fromContext(context: ?*anyopaque) *Composition {
    return @ptrCast(@alignCast(context orelse unreachable));
}

fn finiteNumber(value: lua_program.Value) !f64 {
    return switch (value) {
        .number => |number| if (std.math.isFinite(number) and number >= 0) number else error.InvalidProperty,
        else => error.InvalidProperty,
    };
}

fn integerValue(value: lua_program.Value) !u64 {
    const number = try finiteNumber(value);
    if (@floor(number) != number) return error.InvalidProperty;
    return @intFromFloat(number);
}

fn array(value: lua_program.Value, minimum: usize) ?[]const lua_program.Value {
    return switch (value) {
        .array => |items| if (items.len >= minimum) items else null,
        else => null,
    };
}

fn arrayU32(value: lua_program.Value) !u32 {
    const number = try integerValue(value);
    if (number > std.math.maxInt(u32)) return error.InvalidProperty;
    return @intCast(number);
}

fn colorValue(value: lua_program.Value) !ui.Color {
    const values = array(value, 3) orelse return error.InvalidProperty;
    const alpha = if (values.len >= 4) try finiteNumber(values[3]) else 1;
    const color = ui.Color{
        .r = @floatCast(try finiteNumber(values[0])),
        .g = @floatCast(try finiteNumber(values[1])),
        .b = @floatCast(try finiteNumber(values[2])),
        .a = @floatCast(alpha),
    };
    if (color.r > 1 or color.g > 1 or color.b > 1 or color.a > 1) return error.InvalidProperty;
    return color;
}

test "composition mounts an equivalent Lua retained program and lowers a complete snapshot" {
    var vm = try lua_program.Vm.init(true);
    defer vm.deinit();

    const modules = [_]lua_program.Module{
        .{
            .name = "main",
            .source = "return function(parent)\n" ++
                "  local row = parent:row({ gap = 4 })\n" ++
                "  row:text({ text = 'hello', font_size = 18 })\n" ++
                "  row:shape({ color = { 0.2, 0.4, 0.6, 1 } })\n" ++
                "end",
        },
    };
    var loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();

    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();
    try std.testing.expectEqual(@as(usize, 4), composition.nodeCount());

    var frame = try composition.snapshotAndLower(.{ .width = 320, .height = 80 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 4), frame.node_count);
    try std.testing.expectEqual(@as(usize, 2), frame.operationCount());
    try std.testing.expectEqualStrings("hello", frame.drawList().ops[0].text.text);
}

test "named service updates mutate the retained Lua controller" {
    var vm = try lua_program.Vm.init(true);
    defer vm.deinit();
    const modules = [_]lua_program.Module{.{
        .name = "main",
        .source =
        \\return function(parent)
        \\  local label = parent:text({ text = 'before' })
        \\  return { update = function(_, service, values)
        \\    if service == 'example' then label:set('text', values[1]) end
        \\  end }
        \\end
        ,
    }};
    const loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();
    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();

    try composition.update(&vm, &program, .{
        .service = "example",
        .values = &.{.{ .string = "after" }},
    });
    var frame = try composition.snapshotAndLower(.{ .width = 320, .height = 80 });
    defer frame.deinit();
    try std.testing.expectEqualStrings("after", frame.drawList().ops[0].text.text);
}

test "updates repaint the complete composed tree instead of only dirty nodes" {
    var vm = try lua_program.Vm.init(true);
    defer vm.deinit();
    const modules = [_]lua_program.Module{.{
        .name = "main",
        .source =
        \\return function(parent)
        \\  local panel = parent:stack({ width = 80, height = 24 })
        \\  local background = panel:shape({ fill = { 0.1, 0.1, 0.1, 1 } })
        \\  local label = panel:text({ text = '1', text_color = { 1, 1, 1, 1 } })
        \\  return { update = function(_, service)
        \\    if service == 'workspaces' then
        \\      background:set('fill', { 0.2, 0.7, 0.95, 1 })
        \\      label:set('text_color', { 0.1, 0.1, 0.1, 1 })
        \\    end
        \\  end }
        \\end
        ,
    }};
    const loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();
    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();

    var before = try composition.snapshotAndLower(.{ .width = 80, .height = 24 });
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 2), before.operationCount());

    try composition.update(&vm, &program, .{ .service = "workspaces", .values = &.{} });
    var after = try composition.snapshotAndLower(.{ .width = 80, .height = 24 });
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 2), after.operationCount());
    try std.testing.expectEqual(@as(f32, 0.2), after.drawList().ops[0].rect.color.r);
    try std.testing.expectEqualStrings("1", after.drawList().ops[1].text.text);
    try std.testing.expectEqual(@as(f32, 0.1), after.drawList().ops[1].text.color.r);
}
