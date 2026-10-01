//! Ownership boundary for one retained Lua surface program.
//!
//! The descriptor supplies source; this object owns the VM, installed program,
//! and retained composition. Platform presenters only provide extents and
//! named service updates.

const std = @import("std");
const script = @import("whirlpool-script");
const lua_composition = @import("lua/composition.zig");

pub const Action = lua_composition.Action;

pub const Composition = struct {
    vm: script.program_loader.Vm,
    program: script.program_loader.Program,
    retained: lua_composition.Composition,

    /// `source` mounts the surface (see `script.config.SurfaceSpec.content`);
    /// it `require`s modules on `module_path` (a `package.path`).
    pub fn init(allocator: std.mem.Allocator, module_path: []const u8, source: []const u8) !Composition {
        var vm = try script.program_loader.Vm.init(true);
        errdefer vm.deinit();
        try script.modules.install(&vm, module_path);
        // Surface programs are policy callbacks, not data providers: no file,
        // process or environment access, so they cannot block a render worker.
        // Data comes from host services. Reading the clock is not I/O, so `os`
        // keeps its time functions (a clock is formatted with `os.date`).
        vm.removeGlobal("io");
        try vm.run(
            \\local date, time, clock, difftime = os.date, os.time, os.clock, os.difftime
            \\os = { date = date, time = time, clock = clock, difftime = difftime }
        , "=whirlpool.sandbox");

        const loader = script.program_loader.Loader.init(allocator, .{});
        var program = try loader.load("surface", &.{.{ .name = "surface", .source = source }});
        errdefer program.deinit();

        const retained = try lua_composition.Composition.mount(allocator, &vm, &program, .{});
        return .{ .vm = vm, .program = program, .retained = retained };
    }

    /// Mount content module `name` exactly as a configured surface would,
    /// with options given as a Lua literal (e.g. "{}").
    pub fn initModule(allocator: std.mem.Allocator, module_path: []const u8, name: []const u8, options: []const u8) !Composition {
        const entry = try script.config.surfaceEntry(allocator, name, options);
        defer allocator.free(entry);
        return init(allocator, module_path, entry);
    }

    pub fn deinit(self: *Composition) void {
        self.retained.deinit();
        self.program.deinit();
        self.vm.deinit();
        self.* = undefined;
    }

    pub fn update(self: *Composition, update_value: script.program_loader.Update) !void {
        try self.retained.update(&self.vm, &self.program, update_value);
    }

    /// Whether anything has changed since the last frame was lowered.
    pub fn isDirty(self: *const Composition) bool {
        return self.retained.isDirty();
    }

    pub fn lower(
        self: *Composition,
        viewport: @import("skia_scene.zig").Viewport,
    ) !lua_composition.Frame {
        return self.retained.lower(viewport);
    }

    /// Actions the surface program requested since the last call; the caller
    /// owns them (free each with `deinit(allocator)`).
    pub fn takeActions(self: *Composition) ![]Action {
        return self.retained.takeActions();
    }

    /// The surface's size, so geometry queries work before the first frame.
    pub fn setViewport(self: *Composition, viewport: @import("skia_scene.zig").Viewport) void {
        self.retained.viewport = viewport;
    }

    /// Measure text with the fonts of the renderer that will draw it.
    pub fn setTextMetrics(self: *Composition, metrics: @import("whirlpool-graphics").skia.TextMetrics) void {
        self.retained.setMeasurer(@import("skia_scene.zig").measurer(metrics));
    }
};

test "surface composition mounts retained Lua source" {
    var composition = try Composition.init(std.testing.allocator, script.modules.source_tree_path,
        \\return function(root)
        \\  local label = root:text({ text = 'surface' })
        \\  return { update = function() label:set('text', 'updated') end }
        \\end
    );
    defer composition.deinit();

    var frame = try composition.lower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "surface composition cannot perform file or process I/O" {
    var composition = try Composition.init(std.testing.allocator, script.modules.source_tree_path,
        \\assert(io == nil)
        \\assert(os.execute == nil and os.getenv == nil and os.remove == nil)
        \\assert(type(os.date("%H")) == "string")
        \\return function(root)
        \\  root:text({ text = string.format("%s", "pure") })
        \\  return { update = function() end }
        \\end
    );
    defer composition.deinit();
}

test "surface controllers can retain nodes created during later updates" {
    var composition = try Composition.init(std.testing.allocator, script.modules.source_tree_path,
        \\return function(root)
        \\  local child
        \\  return { update = function()
        \\    if not child then child = root:text({ text = 'late' }) end
        \\  end }
        \\end
    );
    defer composition.deinit();

    try composition.update(.{ .service = "grow", .values = &.{} });
    try composition.update(.{ .service = "grow", .values = &.{} });
    var frame = try composition.lower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

const values = @import("values.zig");
const Op = @import("whirlpool-graphics").skia.DrawOp;
const Value = values.Value;
const bar_width = 900;
const bar_height = 38;

fn findText(frame: *const lua_composition.Frame, text: []const u8) ?@FieldType(Op, "text") {
    for (frame.drawList().ops) |op| if (op == .text and std.mem.eql(u8, op.text.text, text)) return op.text;
    return null;
}

const BarTest = struct {
    arena: std.heap.ArenaAllocator,
    shell: Composition,
    now: f64 = 1000,

    fn init(self: *BarTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.shell = try Composition.initModule(std.testing.allocator, script.modules.source_tree_path, "lib.bar", "{}");
        self.shell.setViewport(.{ .width = bar_width, .height = bar_height });
    }

    fn deinit(self: *BarTest) void {
        self.shell.deinit();
        self.arena.deinit();
    }

    fn b(self: *BarTest) values.Builder {
        return .{ .arena = self.arena.allocator() };
    }

    fn send(self: *BarTest, service: []const u8, value: Value) !void {
        try self.shell.update(.{ .service = service, .values = &.{value} });
    }

    fn frame(self: *BarTest, advance: f64) !void {
        self.now += advance;
        try self.send("frame", self.b().object(.{.{ "now", self.now }}));
    }

    fn lower(self: *BarTest) !lua_composition.Frame {
        return self.shell.lower(.{ .width = bar_width, .height = bar_height });
    }

    fn pointer(self: *BarTest, kind: []const u8, x: f64, y: f64, pressed: bool, dy: f64) !void {
        try self.send("pointer", self.b().object(.{
            .{ "type", kind }, .{ "x", x }, .{ "y", y }, .{ "button", 0x110 },
            .{ "pressed", pressed }, .{ "dx", 0 }, .{ "dy", dy },
        }));
    }

    fn window(self: *BarTest, id: u32, app_id: []const u8, focused: bool) Value {
        const b_ = self.b();
        const id_text = std.fmt.allocPrint(self.arena.allocator(), "{d}", .{id}) catch unreachable;
        return b_.object(.{
            .{ "kind", "window" },  .{ "label", "" },        .{ "detail", "" },
            .{ "focused", focused }, .{ "overlay", false },  .{ "window", id },
            .{ "app_id", app_id },   .{ "title", "a title" }, .{ "icon", "" },
            .{ "action", "focus-window" }, .{ "args", b_.array(&.{b_.from(id_text)}) },
        });
    }

    fn desktop(self: *BarTest, windows: []const Value) !void {
        const b_ = self.b();
        var tags: [5]Value = undefined;
        for (&tags, 0..) |*tag, index| tag.* = b_.object(.{ .{ "occupied", index == 0 or index == 3 }, .{ "active", index == 1 } });
        try self.send("desktop", b_.object(.{
            .{ "tag", 2 }, .{ "focused", true }, .{ "tags", b_.array(&tags) }, .{ "items", b_.array(windows) },
        }));
    }
};

test "the bar shows the active tag and occupied ones, and the windows on this tag" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    try bar.desktop(&.{ bar.window(11, "foot", true), bar.window(12, "firefox", false) });
    var frame = try bar.lower();
    defer frame.deinit();
    for ([_][]const u8{ "1", "2", "4", "foot", "firefox" }) |text| try std.testing.expect(findText(&frame, text) != null);
    for ([_][]const u8{ "3", "5" }) |text| try std.testing.expect(findText(&frame, text) == null);
}

test "clicking a window asks the layout to focus it; clicking a tag shows it" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    try bar.desktop(&.{ bar.window(11, "foot", true), bar.window(12, "firefox", false) });
    var frame = try bar.lower();
    const firefox = findText(&frame, "firefox").?;
    const tag = findText(&frame, "4").?;
    frame.deinit();

    for ([_]@FieldType(Op, "text"){ firefox, tag }) |target| {
        try bar.pointer("motion", target.x + 2, target.baseline, false, 0);
        try bar.pointer("button", target.x + 2, target.baseline, true, 0);
        try bar.pointer("button", target.x + 2, target.baseline, false, 0);
    }
    const actions = try bar.shell.takeActions();
    defer {
        for (actions) |*action| action.deinit(std.testing.allocator);
        std.testing.allocator.free(actions);
    }
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("layout", actions[0].name);
    try std.testing.expectEqualStrings("focus-window", actions[0].args[0]);
    try std.testing.expectEqualStrings("12", actions[0].args[1]);
    try std.testing.expectEqualStrings("focus-tag", actions[1].args[0]);
    try std.testing.expectEqualStrings("4", actions[1].args[1]);
}

test "hovering a window item changes how it is drawn" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    try bar.desktop(&.{ bar.window(11, "foot", true), bar.window(12, "firefox", false) });
    var before = try bar.lower();
    const firefox = findText(&before, "firefox").?;
    var colors_before = std.ArrayList(f32).empty;
    defer colors_before.deinit(std.testing.allocator);
    for (before.drawList().ops) |op| if (op == .polygon) try colors_before.append(std.testing.allocator, op.polygon.color.r);
    before.deinit();

    try bar.pointer("enter", firefox.x, firefox.baseline, false, 0);
    var after = try bar.lower();
    defer after.deinit();
    var changed: usize = 0;
    var index: usize = 0;
    for (after.drawList().ops) |op| if (op == .polygon) {
        if (op.polygon.color.r != colors_before.items[index]) changed += 1;
        index += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), changed);
}

test "the window list follows focus, and the wheel scrolls it" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    var windows: [16]Value = undefined;
    const names = [_][]const u8{ "w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "wa", "wb", "wc", "wd", "we", "wf" };
    for (&windows, names, 0..) |*window, name, index| window.* = bar.window(@intCast(index + 1), name, index == 15);
    try bar.desktop(&windows);
    for (0..20) |_| try bar.frame(50);
    var followed = try bar.lower();
    const last = findText(&followed, "wf").?;
    const first_x = findText(&followed, "w0").?.x;
    followed.deinit();
    // The focused (last) window is scrolled into view.
    try std.testing.expect(last.x > 0 and last.x < bar_width);
    try std.testing.expect(first_x < 0);

    // The wheel scrolls back towards the start.
    try bar.pointer("enter", last.x, last.baseline, false, 0);
    try bar.pointer("scroll", last.x, last.baseline, false, -200);
    for (0..20) |_| try bar.frame(50);
    var scrolled = try bar.lower();
    defer scrolled.deinit();
    try std.testing.expect(findText(&scrolled, "w0").?.x > first_x);
}

test "a status panel stays hidden until its source reports" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    var before = try bar.lower();
    try std.testing.expect(findText(&before, "87%") == null);
    before.deinit();
    const b = bar.b();
    try bar.send("battery", b.object(.{
        .{ "t", b.numbers(&.{0}) },       .{ "present", b.numbers(&.{1}) },
        .{ "percent", b.numbers(&.{87}) }, .{ "charging", b.numbers(&.{0}) },
        .{ "on_ac", b.numbers(&.{1}) },
    }));
    var after = try bar.lower();
    defer after.deinit();
    try std.testing.expect(findText(&after, "87%") != null);
}

test "network readouts are rates computed from cumulative counters" {
    var bar: BarTest = undefined;
    try bar.init();
    defer bar.deinit();
    const b = bar.b();
    const arena = bar.arena.allocator();
    // A steady 1 MB/s down, 0 up: 8.0 Mb/s.
    const rates = [_]f64{1e6} ** 12;
    try bar.send("network", b.object(.{
        .{ "t", b.numbers(values.times(arena, 1000, 500, 12)) },
        .{ "rx", b.numbers(values.counter(arena, &rates, 500)) },
        .{ "tx", b.numbers(&([_]f64{0} ** 12)) },
        .{ "interface", "eth0" },
    }));
    try bar.frame(100);
    var frame = try bar.lower();
    defer frame.deinit();
    try std.testing.expect(findText(&frame, "8.0") != null);
    try std.testing.expect(findText(&frame, "Mb/s") != null);
}

test "window titles show on decorations, brighter when focused" {
    var decoration = try Composition.initModule(std.testing.allocator, script.modules.source_tree_path, "lib.decorator", "{}");
    defer decoration.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = values.Builder{ .arena = arena.allocator() };
    try decoration.update(.{ .service = "decoration", .values = &.{b.object(.{
        .{ "title", "notes.txt" }, .{ "app_id", "foot" }, .{ "focused", true },
    })} });
    var frame = try decoration.lower(.{ .width = 300, .height = 28 });
    defer frame.deinit();
    try std.testing.expect(findText(&frame, "notes.txt") != null);
}
