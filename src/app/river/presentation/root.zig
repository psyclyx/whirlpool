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
const status_app = @import("whirlpool-app-status");
const desktop_icons = @import("whirlpool-app-desktop-icons");
const window_strip = @import("window_strip.zig");

/// Owns the optional graphics runtime and its River role callback context.
pub const Bridge = struct {
    allocator: std.mem.Allocator = undefined,
    graphics: ?*river_presenter_runtime.Runtime = null,
    status: ?*status_app.Service = null,
    icons: ?*desktop_icons.Service = null,
    status_revision: u64 = 0,
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
        self.status = try status_app.Service.init(allocator, io);
        errdefer {
            self.status.?.deinit();
            self.status = null;
        }
        self.icons = try desktop_icons.Service.init(allocator, io);
        errdefer {
            self.icons.?.deinit();
            self.icons = null;
        }
        try runtime.setSurfaceHooks(self.graphics.?.surfaceHooks());
        self.context = .{ .allocator = allocator, .runtime = runtime, .roles = undefined, .graphics = self.graphics.?, .icons = self.icons.? };
        try self.bindInputSeats(client);
        return self.context.hooks();
    }

    /// Complete the callback context after role storage has a stable address.
    pub fn bindRoles(self: *Bridge, roles: *river_role_lifecycle.Runtime) void {
        if (self.graphics == null) return;
        std.debug.assert(self.context.graphics == self.graphics.?);
        self.context.roles = roles;
    }

    pub fn setWake(self: *Bridge, wake: river_presenter_runtime.Wake) void {
        if (self.graphics) |graphics| graphics.setWake(wake);
        if (self.status) |status| status.setWake(.{ .context = wake.context, .run = wake.run });
        if (self.icons) |icons| icons.setWake(.{ .context = wake.context, .run = wake.run });
    }

    pub fn clearWake(self: *Bridge) void {
        if (self.status) |status| status.clearWake();
        if (self.icons) |icons| icons.clearWake();
        if (self.graphics) |graphics| graphics.clearWake();
    }

    /// Poll graphics releases before role retirement reconciliation.
    pub fn pollReleases(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        _ = try graphics.pollReleases();
    }

    /// Update shell services and present all retained roles once per dispatch.
    pub fn present(self: *Bridge) !void {
        if (self.graphics == null) return;
        if (self.status.?.latestAfter(self.status_revision)) |latest| {
            self.status_revision = latest.revision;
            self.context.status = latest.value;
        }
        try self.context.roles.forEachShell(&self.context, Context.updateShellServices);
        try self.context.roles.forEachShell(&self.context, Context.updateStatusServices);
        try self.context.roles.forEachDecoration(&self.context, Context.updateDecorationServices);
        try self.collectReady();
    }

    /// Claim worker-completed frames before an already-staged River render
    /// transaction is drained. This is deliberately separate from service
    /// updates: the worker may finish between the manage and render edges.
    pub fn collectReady(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        std.debug.assert(self.generation != 0);
        try graphics.presentAll(self.generation);
        self.generation +|= 1;
        if (self.generation == 0) return error.GenerationExhausted;
    }

    /// Release graphics after orderly role retirement.
    pub fn deinit(self: *Bridge) !void {
        for (self.input_seats.items) |seat| seat.deinit();
        self.input_seats.deinit(self.allocator);
        if (self.status) |status| status.deinit();
        if (self.icons) |icons| icons.deinit();
        if (self.graphics) |graphics| {
            self.context.deinit();
            try graphics.deinit();
        }
        self.* = undefined;
    }

    /// Drop graphics bookkeeping after transport loss.
    pub fn abandon(self: *Bridge) void {
        for (self.input_seats.items) |seat| seat.abandon();
        self.input_seats.deinit(self.allocator);
        if (self.status) |status| status.deinit();
        self.status = null;
        if (self.icons) |icons| icons.deinit();
        self.icons = null;
        if (self.graphics) |graphics| {
            self.context.deinit();
            graphics.abandon();
        }
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
                if (self.output) |output| self.context.activateAt(output, self.x) catch {};
            },
            .axis => |value| if (value.axis == .vertical_scroll) {
                if (self.output) |output| self.context.scrollAt(output, self.x, wayland.client.wl.Fixed.toDouble(value.value)) catch {};
            },
            .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
        }
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    graphics: *river_presenter_runtime.Runtime,
    icons: *desktop_icons.Service,
    status: status_app.Snapshot = .{},
    strip_states: std.AutoHashMapUnmanaged(u64, StripState) = .empty,

    const StripState = struct {
        offset: u32 = 0,
        focused: ?wm.WindowId = null,
        focused_x: ?u32 = null,
        viewport_width: u32 = 0,
    };

    const workspace_gap: u32 = 8;
    const workspace_visible_width: u32 = 30;
    const workspace_hidden_width: u32 = 1;
    const workspace_padding_right: u32 = 8;
    const right_width_without_battery: u32 = 549;
    const right_width_with_battery: u32 = 592;

    fn deinit(self: *Context) void {
        self.strip_states.deinit(self.allocator);
    }

    pub fn hooks(self: *Context) river_role_lifecycle.Hooks {
        return .{
            .context = @ptrCast(self),
            .shell_created = onShellCreated,
            .shell_retire = onShellRetire,
            .decoration_created = onDecorationCreated,
            .decoration_retire = onDecorationRetire,
        };
    }

    fn activateAt(self: *Context, output_id: host.types.OutputId, x: f64) !void {
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse return error.UnknownOutput;
        const selected = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        const workspace_width = self.workspaceWidth(world, selected);
        if (x >= @as(f64, @floatFromInt(workspace_width))) {
            const viewport = self.stripViewport(try self.presentationWidth(output_id), workspace_width);
            const right_edge = workspace_width + viewport;
            if (x >= @as(f64, @floatFromInt(right_edge))) return;
            const focused = world.view().focusedWindow(wm_output);
            const strip = try self.buildWindowStrip(world, wm_output, output.active_tag, focused);
            const state = try self.stripState(output_id);
            const local = x - @as(f64, @floatFromInt(workspace_width)) + @as(f64, @floatFromInt(state.offset));
            if (local < 0 or local > std.math.maxInt(u32)) return;
            const token = strip.tokenAt(@intFromFloat(local)) orelse return;
            if (token.window) |window| try self.runtime.queueIntent(.{ .focus_window = window });
            return;
        }

        var cursor: f64 = 0;
        for (0..9) |index| {
            const visible = index == selected or self.tagOccupied(world, world.tagAt(index));
            const width: f64 = if (visible) workspace_visible_width else workspace_hidden_width;
            if (visible and x >= cursor and x < cursor + width) {
                const tag = world.tagAt(index) orelse return;
                try self.runtime.queueIntent(.{ .set_active_tag = .{ .output = wm_output, .tag = tag } });
                return;
            }
            cursor += width + workspace_gap;
        }
    }

    fn scrollAt(self: *Context, output_id: host.types.OutputId, x: f64, delta: f64) !void {
        if (delta == 0) return;
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse return error.UnknownOutput;
        const current = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        const workspace_width = self.workspaceWidth(world, current);
        if (x >= @as(f64, @floatFromInt(workspace_width))) {
            const viewport = self.stripViewport(try self.presentationWidth(output_id), workspace_width);
            if (x >= @as(f64, @floatFromInt(workspace_width + viewport))) return;
            const strip = try self.buildWindowStrip(world, wm_output, output.active_tag, world.view().focusedWindow(wm_output));
            const state = try self.stripState(output_id);
            const amount: i32 = if (delta > 0) 96 else if (delta < 0) -96 else 0;
            state.offset = window_strip.pan(state.offset, amount, viewport, strip.content_width);
            return;
        }
        const next = delta > 0;
        const target = if (next) @min(@as(usize, 8), current + 1) else if (current == 0) 0 else current - 1;
        if (target == current) return;
        try self.runtime.queueIntent(.{ .set_active_tag = .{ .output = wm_output, .tag = world.tagAt(target) orelse return } });
    }

    fn buildWindowStrip(self: *Context, world: *const wm.World, output: wm.OutputId, tag: wm.TagId, focused: ?wm.WindowId) !window_strip.Strip {
        var projection = try self.runtime.layoutProjection(self.allocator, output);
        defer if (projection) |*value| value.deinit();
        var strip = if (projection) |*value|
            window_strip.fromProjection(value)
        else
            window_strip.build(world, tag, focused);
        for (strip.tokens[0..strip.len]) |*token| if (token.window) |window| {
            if (self.runtime.adapter.objects.wm_to_window.get(window)) |live_window| {
                const record = try self.runtime.adapter.objects.windowRecord(live_window);
                token.width = window_strip.widthForAppId(record.app_id);
            }
        };
        strip.reflow();
        return strip;
    }

    pub fn updateShellServices(raw: ?*anyopaque, output_id: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse
            return error.UnknownOutput;
        const ordinal = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        var occupied_storage: [9]script.program_loader.Value = undefined;
        for (&occupied_storage, 0..) |*item, index| item.* = .{ .boolean = self.tagOccupied(world, world.tagAt(index)) };

        const focused = world.view().focusedWindow(wm_output);
        const strip = try self.buildWindowStrip(world, wm_output, output.active_tag, focused);

        const workspace_width = self.workspaceWidth(world, ordinal);
        const viewport = self.stripViewport(try self.presentationWidth(output_id), workspace_width);
        const strip_state = try self.stripState(output_id);
        const focused_x = if (strip.focused_index) |index| strip.tokens[index].x else null;
        if (strip_state.focused != focused or strip_state.focused_x != focused_x or strip_state.viewport_width != viewport) {
            strip_state.offset = window_strip.reveal(strip_state.offset, viewport, &strip);
            strip_state.focused = focused;
            strip_state.focused_x = focused_x;
            strip_state.viewport_width = viewport;
        } else {
            strip_state.offset = window_strip.pan(strip_state.offset, 0, viewport, strip.content_width);
        }

        var token_storage: [window_strip.max_tokens][9]script.program_loader.Value = undefined;
        var tokens: [window_strip.max_tokens]script.program_loader.Value = undefined;
        for (strip.slice(), 0..) |token, index| {
            var app_id: []const u8 = "";
            var title: []const u8 = "";
            var icon_source: []const u8 = "";
            if (token.window) |window| if (self.runtime.adapter.objects.wm_to_window.get(window)) |live_window| {
                const record = try self.runtime.adapter.objects.windowRecord(live_window);
                app_id = record.app_id;
                title = record.title;
                icon_source = try self.icons.pathFor(app_id);
            };
            token_storage[index] = .{
                .{ .number = @floatFromInt(@intFromEnum(token.kind)) },
                .{ .string = token.labelSlice() },
                .{ .string = app_id },
                .{ .string = title },
                .{ .boolean = token.focused },
                .{ .number = @floatFromInt(token.width) },
                .{ .string = icon_source },
                .{ .boolean = token.selected },
                .{ .string = token.mark.slice() },
            };
            tokens[index] = .{ .array = &token_storage[index] };
        }

        const values = [_]script.program_loader.Value{
            .{ .number = @floatFromInt(ordinal + 1) },
            .{ .array = &occupied_storage },
            .{ .array = tokens[0..strip.len] },
            .{ .number = @floatFromInt(strip_state.offset) },
            .{ .number = @floatFromInt(strip.content_width) },
            .{ .boolean = strip_state.offset != 0 },
            .{ .boolean = strip_state.offset +| viewport < strip.content_width },
        };
        try self.graphics.update(.{ .shell = shell_id }, .{
            .service = "desktop",
            .values = &values,
        });
    }

    pub fn updateStatusServices(raw: ?*anyopaque, _: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        var cpu_history: [status_app.history_len]script.program_loader.Value = undefined;
        var rx_history: [status_app.history_len]script.program_loader.Value = undefined;
        var tx_history: [status_app.history_len]script.program_loader.Value = undefined;
        for (0..status_app.history_len) |index| {
            cpu_history[index] = .{ .number = self.status.cpu_history[index] };
            rx_history[index] = .{ .number = self.status.network_rx_history[index] };
            tx_history[index] = .{ .number = self.status.network_tx_history[index] };
        }
        const values = [_]script.program_loader.Value{
            .{ .string = &self.status.time },
            .{ .string = &self.status.dow },
            .{ .string = &self.status.date },
            .{ .number = @floatFromInt(self.status.cpu_percent) },
            .{ .array = &cpu_history },
            .{ .number = @floatFromInt(self.status.memory_percent) },
            .{ .number = @floatFromInt(self.status.disk_percent) },
            .{ .number = self.status.network_rx },
            .{ .number = self.status.network_tx },
            .{ .array = &rx_history },
            .{ .array = &tx_history },
            .{ .number = @floatFromInt(self.status.audio_percent) },
            .{ .boolean = self.status.audio_muted },
            .{ .boolean = self.status.audio_visible },
            .{ .boolean = self.status.battery_present },
            .{ .number = @floatFromInt(self.status.battery_percent) },
            .{ .boolean = self.status.battery_charging },
        };
        try self.graphics.update(.{ .shell = shell_id }, .{ .service = "status", .values = &values });
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

    fn tagOccupied(self: *const Context, world: *const wm.World, maybe_tag: ?wm.TagId) bool {
        const wanted = maybe_tag orelse return false;
        for (self.runtime.adapter.objects.window_order.items) |live_window| {
            const record = self.runtime.adapter.objects.windows.get(live_window) orelse continue;
            const wm_window = record.wm_id orelse continue;
            const window = world.getWindow(wm_window) orelse continue;
            if (window.tag == wanted and window.lifecycle == .managed) return true;
        }
        return false;
    }

    fn workspaceWidth(self: *const Context, world: *const wm.World, selected: usize) u32 {
        var width: u32 = workspace_padding_right + workspace_gap * 8;
        for (0..9) |index| {
            const visible = index == selected or self.tagOccupied(world, world.tagAt(index));
            width += if (visible) workspace_visible_width else workspace_hidden_width;
        }
        return width;
    }

    fn stripViewport(self: *const Context, output_width: u32, workspace_width: u32) u32 {
        const right_width: u32 = if (self.status.battery_present) right_width_with_battery else right_width_without_battery;
        return @max(1, output_width -| workspace_width -| right_width);
    }

    fn presentationWidth(self: *const Context, output: host.types.OutputId) !u32 {
        const size = (try self.roles.adapter.objects.outputSize(output)) orelse return error.OutputGeometryUnavailable;
        if (size.width <= 0) return error.InvalidExtent;
        return @intCast(size.width);
    }

    fn stripState(self: *Context, output: host.types.OutputId) !*StripState {
        const entry = try self.strip_states.getOrPut(self.allocator, output.value);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
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
        const size = (try self.roles.adapter.objects.actualWindowSize(window)) orelse
            return error.WindowGeometryUnavailable;
        const border_width = self.roles.adapter.windowBorderWidth();
        const framed_width = try std.math.add(
            i32,
            size.width,
            try std.math.mul(i32, border_width, 2),
        );
        return extent(framed_width, 28);
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

fn onShellRetire(raw: ?*anyopaque, output: host.types.OutputId, shell: host.types.ShellSurfaceId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    _ = self.strip_states.remove(output.value);
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
