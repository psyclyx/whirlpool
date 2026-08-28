//! River role-to-presentation lifetime bridge.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");
const wayland_client = @import("whirlpool-wayland-client");
const river_host_runtime = @import("whirlpool-river-host-runtime");
const river_role_lifecycle = @import("whirlpool-river-role-lifecycle");
const river_presenter_runtime = @import("whirlpool-river-presenter-runtime");

/// Owns the optional graphics runtime and its River role callback context.
pub const Bridge = struct {
    allocator: std.mem.Allocator = undefined,
    graphics: ?*river_presenter_runtime.Runtime = null,
    context: Context = undefined,
    input_seats: std.ArrayList(*InputSeat) = .empty,
    generation: u64 = 1,

    /// Initialize graphics for a configured surface and return role hooks.
    pub fn init(
        self: *Bridge,
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *wayland_client.Client,
        runtime: *river_host_runtime.Runtime,
        surface: ?*const script.config.SurfaceSpec,
        decoration_surface: ?*const script.config.SurfaceSpec,
    ) !river_role_lifecycle.Hooks {
        self.* = .{};
        self.allocator = allocator;
        const spec = surface orelse return .{};
        self.graphics = try river_presenter_runtime.Runtime.init(allocator, io, client, .{
            .context = @ptrCast(runtime),
            .submit = queueCommit,
        }, spec, decoration_surface);
        errdefer {
            self.graphics.?.deinit() catch {};
            self.graphics = null;
        }
        try runtime.setSurfaceHooks(self.graphics.?.surfaceHooks());
        self.context = .{ .runtime = runtime, .roles = undefined, .graphics = self.graphics.? };
        try self.bindInputSeats(client);
        return self.context.hooks();
    }

    /// Complete the callback context after role storage has a stable address.
    pub fn bindRoles(self: *Bridge, roles: *river_role_lifecycle.Runtime) void {
        if (self.graphics == null) return;
        std.debug.assert(self.context.graphics == self.graphics.?);
        self.context.roles = roles;
    }

    /// Poll graphics releases before role retirement reconciliation.
    pub fn pollReleases(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        _ = try graphics.pollReleases();
    }

    /// Update shell services and present all retained roles once per dispatch.
    pub fn present(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        std.debug.assert(self.generation != 0);
        try self.context.roles.forEachShell(&self.context, Context.updateShellServices);
        try self.context.roles.forEachDecoration(&self.context, Context.updateDecorationServices);
        try graphics.presentAll(self.generation);
        self.generation +|= 1;
        if (self.generation == 0) return error.GenerationExhausted;
    }

    /// Release graphics after orderly role retirement.
    pub fn deinit(self: *Bridge) !void {
        for (self.input_seats.items) |seat| seat.deinit();
        self.input_seats.deinit(self.allocator);
        if (self.graphics) |graphics| try graphics.deinit();
        self.* = undefined;
    }

    /// Drop graphics bookkeeping after transport loss.
    pub fn abandon(self: *Bridge) void {
        for (self.input_seats.items) |seat| seat.abandon();
        self.input_seats.deinit(self.allocator);
        if (self.graphics) |graphics| graphics.abandon();
        self.graphics = null;
    }

    fn bindInputSeats(self: *Bridge, client: *wayland_client.Client) !void {
        const globals = if (client.globals.items.len != 0) client.globals.items else try client.enumerateGlobals();
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "wl_seat")) continue;
            const proxy = try client.registry.bind(global.name, wayland.client.wl.Seat, @min(global.version, 9));
            errdefer proxy.release();
            const owner = try self.allocator.create(InputSeat);
            errdefer self.allocator.destroy(owner);
            owner.* = .{ .allocator = self.allocator, .context = &self.context, .seat = proxy };
            proxy.setListener(*InputSeat, InputSeat.onSeat, owner);
            try self.input_seats.append(self.allocator, owner);
        }
    }
};

const InputSeat = struct {
    allocator: std.mem.Allocator,
    context: *Context,
    seat: *wayland.client.wl.Seat,
    pointer: ?*wayland.client.wl.Pointer = null,
    output: ?host.types.OutputId = null,
    x: f64 = 0,
    y: f64 = 0,

    fn deinit(self: *InputSeat) void {
        if (self.pointer) |pointer| pointer.release();
        self.seat.release();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn abandon(self: *InputSeat) void {
        if (self.pointer) |pointer| @as(*wayland.client.wl.Proxy, @ptrCast(pointer)).destroy();
        @as(*wayland.client.wl.Proxy, @ptrCast(self.seat)).destroy();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn onSeat(seat: *wayland.client.wl.Seat, event: wayland.client.wl.Seat.Event, self: *InputSeat) void {
        switch (event) {
            .capabilities => |value| {
                if (value.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch return;
                    self.pointer.?.setListener(*InputSeat, onPointer, self);
                } else if (!value.capabilities.pointer) {
                    if (self.pointer) |pointer| pointer.release();
                    self.pointer = null;
                    self.output = null;
                }
            },
            .name => {},
        }
    }

    fn onPointer(_: *wayland.client.wl.Pointer, event: wayland.client.wl.Pointer.Event, self: *InputSeat) void {
        switch (event) {
            .enter => |value| {
                self.output = if (value.surface) |surface| self.context.roles.outputForSurface(surface) else null;
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
            },
            .leave => self.output = null,
            .motion => |value| {
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
            },
            .button => |value| if (value.state == .pressed and value.button == 0x110) {
                if (self.output) |output| self.context.activateTagAt(output, self.x) catch {};
            },
            .axis => |value| if (value.axis == .vertical_scroll) {
                if (self.output) |output| self.context.cycleTag(output, self.x, wayland.client.wl.Fixed.toDouble(value.value) > 0) catch {};
            },
            .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
        }
    }
};

pub const Context = struct {
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    graphics: *river_presenter_runtime.Runtime,

    pub fn hooks(self: *Context) river_role_lifecycle.Hooks {
        return .{
            .context = @ptrCast(self),
            .shell_created = onShellCreated,
            .shell_retire = onShellRetire,
            .decoration_created = onDecorationCreated,
            .decoration_retire = onDecorationRetire,
        };
    }

    fn activateTagAt(self: *Context, output_id: host.types.OutputId, x: f64) !void {
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse return error.UnknownOutput;
        const selected = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        var cursor: f64 = 0;
        for (0..9) |index| {
            const visible = index == selected or self.tagOccupied(world.tagAt(index));
            const width: f64 = if (visible) 30 else 1;
            if (visible and x >= cursor and x < cursor + width) {
                const tag = world.tagAt(index) orelse return;
                try self.runtime.queueIntent(.{ .set_active_tag = .{ .output = wm_output, .tag = tag } });
                return;
            }
            cursor += width + 8;
        }
    }

    fn cycleTag(self: *Context, output_id: host.types.OutputId, x: f64, next: bool) !void {
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse return error.UnknownOutput;
        const current = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        var cursor: f64 = 0;
        var over_tag = false;
        for (0..9) |index| {
            const visible = index == current or self.tagOccupied(world.tagAt(index));
            const width: f64 = if (visible) 30 else 1;
            if (visible and x >= cursor and x < cursor + width) over_tag = true;
            cursor += width + 8;
        }
        if (!over_tag) {
            const right_width: f64 = 592;
            const content_width: f64 = @floatFromInt(output.bounds.width);
            const center_start = @max(0, (content_width - right_width) / 2);
            const center_end = @max(center_start, content_width - right_width);
            if (x >= center_start and x < center_end) {
                try self.runtime.queueIntent(.{ .focus_direction = .{
                    .output = wm_output,
                    .direction = if (next) .right else .left,
                } });
            }
            return;
        }
        const target = if (next) @min(@as(usize, 8), current + 1) else if (current == 0) 0 else current - 1;
        if (target == current) return;
        try self.runtime.queueIntent(.{ .set_active_tag = .{ .output = wm_output, .tag = world.tagAt(target) orelse return } });
    }

    pub fn updateShellServices(raw: ?*anyopaque, output_id: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse
            return error.UnknownOutput;
        const ordinal = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        const tag = world.getTag(output.active_tag) orelse return error.UnknownTag;

        var occupied_storage: [9]script.program_loader.Value = undefined;
        for (&occupied_storage, 0..) |*item, index| item.* = .{ .boolean = tagOccupied(self, world.tagAt(index)) };

        var column_storage: [10][3]script.program_loader.Value = undefined;
        var columns: [10]script.program_loader.Value = undefined;
        var column_count: usize = 0;
        const focused_node = tag.focused;
        for (tag.columns.items) |column_id| {
            if (column_count == columns.len) break;
            const column = world.getColumn(column_id) orelse continue;
            column_storage[column_count] = .{
                .{ .number = column.width },
                .{ .number = @floatFromInt(countLeaves(world, column.root)) },
                .{ .boolean = if (focused_node) |node| (world.getNode(node) orelse return error.UnknownWindow).column == column_id else false },
            };
            columns[column_count] = .{ .array = &column_storage[column_count] };
            column_count += 1;
        }

        var app_id: []const u8 = "";
        var title: []const u8 = "";
        const focused = world.view().focusedWindow(wm_output);
        if (focused) |window| if (self.runtime.adapter.objects.wm_to_window.get(window)) |live_window| {
            const record = try self.runtime.adapter.objects.windowRecord(live_window);
            app_id = record.app_id;
            title = record.title;
        };

        const values = [_]script.program_loader.Value{
            .{ .number = @floatFromInt(ordinal + 1) },
            .{ .array = &occupied_storage },
            .{ .boolean = focusedOutput(self, wm_output) },
            .{ .string = app_id },
            .{ .string = title },
            .{ .array = columns[0..column_count] },
            .{ .number = @floatFromInt(output.bounds.width) },
            .{ .number = @floatFromInt(output.bounds.height) },
        };
        try self.graphics.update(.{ .shell = shell_id }, .{
            .service = "desktop",
            .values = &values,
        });
    }

    pub fn updateDecorationServices(raw: ?*anyopaque, window_id: host.types.WindowId, decoration_id: host.types.DecorationId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const record = try self.runtime.adapter.objects.windowRecord(window_id);
        const wm_window = record.wm_id orelse return;
        const world = self.runtime.adapter.worldView();
        const window = world.getWindow(wm_window) orelse return error.UnknownWindow;
        const is_focused = if (window.output) |output|
            if (world.view().focusedWindow(output)) |focused| focused == wm_window else false
        else
            false;
        var tab_values: [8]script.program_loader.Value = undefined;
        var tab_count: usize = 0;
        var active_tab: usize = 0;
        if (world.nodeForWindow(wm_window)) |leaf| {
            var parent = (world.getNode(leaf) orelse return error.UnknownWindow).parent;
            while (parent) |parent_id| {
                const node = world.getNode(parent_id) orelse break;
                if (node.mode == .tabbed) {
                    active_tab = node.active_child + 1;
                    for (node.children.items) |child| {
                        if (tab_count == tab_values.len) break;
                        const tab_window = activeLeafWindow(world, child.id) orelse continue;
                        const live_tab = self.runtime.adapter.objects.wm_to_window.get(tab_window) orelse continue;
                        const tab_record = try self.runtime.adapter.objects.windowRecord(live_tab);
                        tab_values[tab_count] = .{ .string = tab_record.title };
                        tab_count += 1;
                    }
                    break;
                }
                parent = node.parent;
            }
        }
        const values = [_]script.program_loader.Value{
            .{ .string = record.title },
            .{ .boolean = is_focused },
            .{ .string = record.app_id },
            .{ .array = tab_values[0..tab_count] },
            .{ .number = @floatFromInt(active_tab) },
        };
        try self.graphics.update(.{ .decoration = decoration_id }, .{
            .service = "decoration",
            .values = &values,
        });
    }

    fn tagOccupied(self: *const Context, maybe_tag: ?wm.TagId) bool {
        const wanted = maybe_tag orelse return false;
        const world = self.runtime.adapter.worldView();
        for (self.runtime.adapter.objects.window_order.items) |live_window| {
            const record = self.runtime.adapter.objects.windows.get(live_window) orelse continue;
            const wm_window = record.wm_id orelse continue;
            const window = world.getWindow(wm_window) orelse continue;
            if (window.tag == wanted and window.lifecycle == .managed) return true;
        }
        return false;
    }

    fn focusedOutput(self: *const Context, candidate: wm.OutputId) bool {
        const world = self.runtime.adapter.worldView();
        var best_output: ?wm.OutputId = null;
        var best_serial: u64 = 0;
        for (self.runtime.adapter.objects.window_order.items) |live_window| {
            const record = self.runtime.adapter.objects.windows.get(live_window) orelse continue;
            const wm_window = record.wm_id orelse continue;
            const window = world.getWindow(wm_window) orelse continue;
            if (window.output != null and (best_output == null or window.focus_serial > best_serial)) {
                best_output = window.output;
                best_serial = window.focus_serial;
            }
        }
        return (best_output orelse world.firstOutput()) == candidate;
    }

    fn countLeaves(world: *const wm.World, maybe_node: ?wm.NodeId) usize {
        const node = world.getNode(maybe_node orelse return 0) orelse return 0;
        if (node.isLeaf()) return 1;
        var result: usize = 0;
        for (node.children.items) |child| result += countLeaves(world, child.id);
        return result;
    }

    fn activeLeafWindow(world: *const wm.World, node_id: wm.NodeId) ?wm.WindowId {
        const node = world.getNode(node_id) orelse return null;
        if (node.window) |window| return window;
        if (node.children.items.len == 0 or node.active_child >= node.children.items.len) return null;
        return activeLeafWindow(world, node.children.items[node.active_child].id);
    }

    fn extent(width: i32, height: i32) !river_presenter_runtime.Extent {
        if (width <= 0 or height <= 0) return error.InvalidExtent;
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    fn shellExtent(self: *const Context, output: host.types.OutputId) !river_presenter_runtime.Extent {
        const size = (try self.roles.adapter.objects.outputSize(output)) orelse return error.OutputGeometryUnavailable;
        return extent(size.width, size.height);
    }

    fn decorationExtent(self: *const Context, window: host.types.WindowId) !river_presenter_runtime.Extent {
        const size: host.types.Size = (try self.roles.adapter.objects.actualWindowSize(window)) orelse .{ .width = 480, .height = 28 };
        return extent(size.width, 28);
    }
};

pub fn queueCommit(raw: ?*anyopaque, commit: host.river_coordinator.SubmittedCommit) !void {
    const runtime: *river_host_runtime.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try runtime.queueSubmittedCommit(commit);
}

fn onShellCreated(raw: ?*anyopaque, output: host.types.OutputId, shell: *wayland.client.river.ShellSurfaceV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    const shell_id = try self.roles.adapter.objects.shellSurfaceId(shell);
    const role_extent = try self.shellExtent(output);
    try self.graphics.createRole(.{ .shell = shell_id }, surface, role_extent);
    const bar_height = @min(self.graphics.surface.height, role_extent.height);
    const input_region = try self.roles.compositor.createRegion();
    defer input_region.destroy();
    if (bar_height != 0) input_region.add(0, @intCast(role_extent.height - bar_height), @intCast(role_extent.width), @intCast(bar_height));
    surface.setInputRegion(input_region);
    std.log.info("River shell surface ready (output {d})", .{output.value});
}

fn onShellRetire(raw: ?*anyopaque, _: host.types.OutputId, shell: host.types.ShellSurfaceId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    return retire(self, .{ .shell = shell });
}

fn onDecorationCreated(raw: ?*anyopaque, window: host.types.WindowId, id: host.types.DecorationId, _: *wayland.client.river.DecorationV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try self.graphics.createRole(.{ .decoration = id }, surface, try self.decorationExtent(window));
}

fn onDecorationRetire(raw: ?*anyopaque, _: host.types.WindowId, id: host.types.DecorationId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    return retire(self, .{ .decoration = id });
}

fn retire(self: *Context, role: host.river_coordinator.SurfaceRole) !river_role_lifecycle.RetirementStatus {
    try self.runtime.retireSurfaceRole(role);
    return switch (try self.graphics.retireRole(role)) {
        .pending_release => .pending_release,
        .release_safe => .release_safe,
    };
}
