//! Host composition of an installed Lua retained program.
//!
//! Lua emits only script-level node ids, kinds, and bounded property values.
//! This adapter owns the translation to UI mount/node handles, snapshots the
//! complete retained tree, and lowers those snapshots through skia_scene.
//! No Wayland, Vulkan, Skia native pointer, or WM object enters this module.

const std = @import("std");
const script = @import("whirlpool-script");
const lua_program = script.program_loader;
const ui = @import("whirlpool-ui");
const graphics = @import("whirlpool-graphics");
const property_decoder = @import("properties.zig");
const skia_scene = @import("../skia_scene.zig");

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

/// A request from the program to its host (`whirlpool.surface.act`).
pub const Action = struct {
    name: []u8,
    args: [][]u8,

    pub fn deinit(self: *Action, allocator: Allocator) void {
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// More than this many pending actions means a runaway program.
const max_pending_actions = 64;

pub const Composition = struct {
    allocator: Allocator,
    options: Options,
    scene: *ui.Scene,
    mount_context: ui.MountContext,
    nodes: std.ArrayList(?ui.NodeHandle) = .empty,
    delta: ui.SceneDelta,
    in_batch: bool = false,
    stats: Stats = .{},
    /// How text is measured for layout; the renderer's fonts once one exists.
    measurer: ui.Measurer = ui.Measurer.estimate,
    /// The surface size last drawn, which geometry queries are answered for.
    viewport: ?skia_scene.Viewport = null,
    /// Actions the program asked for, waiting for the host to take them.
    actions: std.ArrayList(Action) = .empty,

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
        for (self.actions.items) |*action| action.deinit(self.allocator);
        self.actions.deinit(self.allocator);
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
            .bounds = sinkBounds,
            .act = sinkAct,
        };
    }

    /// Whether anything has changed since the last frame was lowered.
    pub fn isDirty(self: *const Composition) bool {
        return self.scene.hasDirtyNodes();
    }

    pub fn setMeasurer(self: *Composition, measurer: ui.Measurer) void {
        self.measurer = measurer;
        // Widths measured with other metrics are wrong now.
        self.scene.layout_dirty = true;
        self.scene.layout_viewport = .{ -1, -1 };
        for (self.nodes.items) |maybe| if (maybe) |handle| {
            if (self.scene.getLayoutMut(handle)) |state| {
                state.intrinsic = .{ std.math.nan(f32), std.math.nan(f32) };
                state.fit_width = -1;
            }
        };
    }

    /// Lay out (if anything changed) and lower the retained tree to a complete
    /// renderer-neutral draw list, which borrows from the scene until it is
    /// next mutated. Dirty bits are cleared only after lowering succeeds; a
    /// rejected frame can therefore be retried.
    pub fn lower(self: *Composition, viewport: skia_scene.Viewport) !Frame {
        self.viewport = viewport;
        const lowered = try skia_scene.lower(self.allocator, self.scene, viewport, self.measurer);
        self.scene.clearDirty();
        return .{ .lowered = lowered, .node_count = self.scene.liveNodeCount() };
    }

    /// Where a node sits on the surface, laid out as of now: staged property
    /// changes are committed first, so a program may set properties and then
    /// ask where they put things. Null before the surface has a size, or for
    /// an invisible node.
    pub fn bounds(self: *Composition, id: lua_program.NodeId) !?ui.Box {
        if (id == 0 or id >= self.nodes.items.len) return error.StaleNode;
        const handle = self.nodes.items[id] orelse return error.StaleNode;
        if (self.in_batch) try self.delta.apply(self.scene);
        const viewport = self.viewport orelse return null;
        ui.layout.update(self.scene, .{
            .width = @floatFromInt(viewport.width),
            .height = @floatFromInt(viewport.height),
        }, self.measurer);
        return ui.layout.bounds(self.scene, handle);
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
            .polygon => .polygon,
            .text => .text,
            .icon => .icon,
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
        return property_decoder.apply(self, id, key, value);
    }

    /// The actions requested since the last call; the caller owns them.
    pub fn takeActions(self: *Composition) ![]Action {
        return self.actions.toOwnedSlice(self.allocator);
    }

    fn sinkAct(context: ?*anyopaque, name: []const u8, args: []const []const u8) anyerror!void {
        const self = fromContext(context);
        if (self.actions.items.len >= max_pending_actions) return error.TooManyActions;
        const owned_args = try self.allocator.alloc([]u8, args.len);
        var copied: usize = 0;
        errdefer {
            for (owned_args[0..copied]) |arg| self.allocator.free(arg);
            self.allocator.free(owned_args);
        }
        for (args, owned_args) |arg, *destination| {
            destination.* = try self.allocator.dupe(u8, arg);
            copied += 1;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.actions.append(self.allocator, .{ .name = owned_name, .args = owned_args });
    }

    fn sinkBounds(context: ?*anyopaque, id: lua_program.NodeId) anyerror!?[4]f32 {
        const box = (try fromContext(context).bounds(id)) orelse return null;
        return .{ box.x, box.y, box.width, box.height };
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
};

fn fromContext(context: ?*anyopaque) *Composition {
    return @ptrCast(@alignCast(context orelse unreachable));
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
                "  row:shape({ flex = 1, color = { 0.2, 0.4, 0.6, 1 } })\n" ++
                "end",
        },
    };
    var loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();

    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();
    try std.testing.expectEqual(@as(usize, 4), composition.nodeCount());

    var frame = try composition.lower(.{ .width = 320, .height = 80 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 4), frame.node_count);
    try std.testing.expectEqual(@as(usize, 2), frame.operationCount());
    try std.testing.expectEqualStrings("hello", frame.drawList().ops[0].text.text);
}

test "Lua defines arbitrary filled polygons through the retained contract" {
    var vm = try lua_program.Vm.init(true);
    defer vm.deinit();

    const modules = [_]lua_program.Module{.{
        .name = "main",
        .source =
        \\return function(parent)
        \\  parent:polygon({
        \\    width = 40, height = 20, fill = { 1, 0.5, 0, 1 },
        \\    points = { { 0.25, 0 }, { 1.25, 0 }, { 1, 1 }, { 0, 1 } },
        \\  })
        \\end
        ,
    }};
    var loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();
    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();

    var frame = try composition.lower(.{ .width = 80, .height = 20 });
    defer frame.deinit();
    const polygon = frame.drawList().ops[0].polygon;
    try std.testing.expectEqual(@as(u8, 4), polygon.points.len);
    try std.testing.expectEqual(@as(f32, 10), polygon.points.points[0].x);
    try std.testing.expectEqual(@as(f32, 50), polygon.points.points[1].x);
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
    var frame = try composition.lower(.{ .width = 320, .height = 80 });
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

    var before = try composition.lower(.{ .width = 80, .height = 24 });
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 2), before.operationCount());

    try composition.update(&vm, &program, .{ .service = "workspaces", .values = &.{} });
    var after = try composition.lower(.{ .width = 80, .height = 24 });
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 2), after.operationCount());
    try std.testing.expectEqual(@as(f32, 0.2), after.drawList().ops[0].rect.color.r);
    try std.testing.expectEqualStrings("1", after.drawList().ops[1].text.text);
    try std.testing.expectEqual(@as(f32, 0.1), after.drawList().ops[1].text.color.r);
}

test "Lua asks where a node was laid out, including changes staged in the same update" {
    var vm = try lua_program.Vm.init(true);
    defer vm.deinit();
    const modules = [_]lua_program.Module{.{
        .name = "main",
        .source =
        \\return function(parent)
        \\  local row = parent:row({ gap = 5 })
        \\  local first = row:shape({ width = 20 })
        \\  local second = row:shape({ width = 10 })
        \\  local report = parent:text({ text = '' })
        \\  return { update = function(_, service)
        \\    if service == 'widen' then first:set('width', 40) end
        \\    local box = second:bounds()
        \\    report:set('text', box and string.format('%d,%d,%d', box.x, box.width, box.height) or 'unknown')
        \\  end }
        \\end
        ,
    }};
    const loader = lua_program.Loader.init(std.testing.allocator, .{});
    var program = try loader.load("main", &modules);
    defer program.deinit();
    var composition = try Composition.mount(std.testing.allocator, &vm, &program, .{});
    defer composition.deinit();

    const Report = struct {
        fn text(target: *Composition) ![]const u8 {
            var frame = try target.lower(.{ .width = 100, .height = 30 });
            defer frame.deinit();
            for (frame.drawList().ops) |op| if (op == .text) return op.text.text;
            return error.MissingReport;
        }
    };
    try composition.update(&vm, &program, .{ .service = "look" });
    try std.testing.expectEqualStrings("unknown", try Report.text(&composition));
    try composition.update(&vm, &program, .{ .service = "look" });
    try std.testing.expectEqualStrings("25,10,30", try Report.text(&composition));
    try composition.update(&vm, &program, .{ .service = "widen" });
    try std.testing.expectEqualStrings("45,10,30", try Report.text(&composition));
}
