//! WM-driven lifetime for River shell and decoration roles.
//!
//! This owns the join between the pure selection policy and generated River
//! objects.  It does not render; a presenter may subscribe to the typed role
//! callbacks and retain the borrowed surface/role pair until an explicit
//! release-safe retirement handshake completes.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const live = @import("whirlpool-river-live");
const world = @import("whirlpool-river-live-world");

const types = host.types;

pub const Hooks = struct {
    context: ?*anyopaque = null,
    shell_created: ?*const fn (?*anyopaque, types.OutputId, *wayland.client.river.ShellSurfaceV1, *wayland.client.wl.Surface) anyerror!void = null,
    shell_retire: ?*const fn (?*anyopaque, types.OutputId, types.ShellSurfaceId) anyerror!RetirementStatus = null,
    decoration_created: ?*const fn (?*anyopaque, types.WindowId, types.DecorationId, *wayland.client.river.DecorationV1, *wayland.client.wl.Surface) anyerror!void = null,
    decoration_retire: ?*const fn (?*anyopaque, types.WindowId, types.DecorationId, bool) anyerror!RetirementStatus = null,
};

pub const RetirementStatus = enum { pending_release, release_safe };
pub const ShellVisitor = *const fn (?*anyopaque, types.OutputId, types.ShellSurfaceId) anyerror!void;
pub const DecorationVisitor = *const fn (?*anyopaque, types.WindowId, types.DecorationId) anyerror!void;
const RecordState = enum { active, retiring };

const ShellRecord = struct {
    output: *wayland.client.river.OutputV1,
    output_id: types.OutputId,
    extent: types.Size,
    role: *wayland.client.river.ShellSurfaceV1,
    surface: *wayland.client.wl.Surface,
    state: RecordState = .active,
};

const DecorationRecord = struct {
    window: types.WindowId,
    extent: types.Size,
    decoration: *wayland.client.river.DecorationV1,
    surface: *wayland.client.wl.Surface,
    id: types.DecorationId,
    state: RecordState = .active,
};

const DecorationLifetime = struct {
    allocator: std.mem.Allocator,
    active: std.AutoHashMap(types.WindowId, void),

    fn init(allocator: std.mem.Allocator) DecorationLifetime {
        return .{ .allocator = allocator, .active = .init(allocator) };
    }

    fn deinit(self: *DecorationLifetime) void {
        self.active.deinit();
        self.* = undefined;
    }

    fn reconcile(
        self: *DecorationLifetime,
        selected: []const types.WindowId,
        context: ?*anyopaque,
        create: *const fn (?*anyopaque, types.WindowId) anyerror!void,
        destroy: *const fn (?*anyopaque, types.WindowId) anyerror!void,
    ) !void {
        for (selected) |window| std.debug.assert(window.value != 0);
        try self.createMissing(selected, context, create, destroy);
        try self.destroyStale(selected, context, destroy);
    }

    fn createMissing(
        self: *DecorationLifetime,
        selected: []const types.WindowId,
        context: ?*anyopaque,
        create: *const fn (?*anyopaque, types.WindowId) anyerror!void,
        destroy: *const fn (?*anyopaque, types.WindowId) anyerror!void,
    ) !void {
        for (selected) |window| {
            if (self.active.contains(window)) continue;
            try create(context, window);
            self.active.put(window, {}) catch |err| {
                destroy(context, window) catch {};
                return err;
            };
            std.debug.assert(self.active.contains(window));
        }
    }

    fn destroyStale(
        self: *DecorationLifetime,
        selected: []const types.WindowId,
        context: ?*anyopaque,
        destroy: *const fn (?*anyopaque, types.WindowId) anyerror!void,
    ) !void {
        var stale = std.ArrayList(types.WindowId).empty;
        defer stale.deinit(self.allocator);
        var iterator = self.active.keyIterator();
        while (iterator.next()) |window| {
            if (!containsWindow(selected, window.*)) try stale.append(self.allocator, window.*);
        }
        for (stale.items) |window| {
            try destroy(context, window);
            std.debug.assert(self.active.remove(window));
            std.debug.assert(!self.active.contains(window));
        }
    }

    fn containsWindow(windows: []const types.WindowId, target: types.WindowId) bool {
        std.debug.assert(target.value != 0);
        for (windows) |window| if (window.value == target.value) return true;
        return false;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    manager: *live.Manager,
    adapter: *world.Adapter,
    compositor: *wayland.client.wl.Compositor,
    hooks: Hooks,
    shells: std.ArrayList(ShellRecord) = .empty,
    decorations: std.ArrayList(DecorationRecord) = .empty,
    decoration_lifetime: DecorationLifetime,

    pub fn init(
        allocator: std.mem.Allocator,
        manager: *live.Manager,
        adapter: *world.Adapter,
        compositor: *wayland.client.wl.Compositor,
        hooks: Hooks,
    ) Runtime {
        return .{
            .allocator = allocator,
            .manager = manager,
            .adapter = adapter,
            .compositor = compositor,
            .hooks = hooks,
            .decoration_lifetime = .init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) !void {
        if (self.shells.items.len != 0 or self.decorations.items.len != 0)
            return error.RolesStillRetained;
        self.decoration_lifetime.deinit();
        self.decorations.deinit(self.allocator);
        self.shells.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drop bookkeeping after transport loss. The manager remains the owner
    /// of generated proxies and abandons them after this runtime is gone.
    pub fn abandon(self: *Runtime) void {
        self.decoration_lifetime.deinit();
        self.decorations.deinit(self.allocator);
        self.shells.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn forEachShell(self: *const Runtime, context: ?*anyopaque, visit: ShellVisitor) !void {
        for (self.shells.items) |record| {
            if (record.state != .active) continue;
            const shell_id = try self.adapter.objects.shellSurfaceId(record.role);
            try visit(context, record.output_id, shell_id);
        }
    }

    pub fn forEachDecoration(self: *const Runtime, context: ?*anyopaque, visit: DecorationVisitor) !void {
        for (self.decorations.items) |record| {
            if (record.state == .active) try visit(context, record.window, record.id);
        }
    }

    pub fn outputForSurface(self: *const Runtime, surface: *wayland.client.wl.Surface) ?types.OutputId {
        for (self.shells.items) |record| if (record.surface == surface) return record.output_id;
        return null;
    }

    /// Reconcile only from the post-dispatch safe point.  Role creation and
    /// destruction are therefore ordered outside generated listeners and can
    /// never expose a half-created surface to a presenter.
    pub fn reconcile(self: *Runtime) !void {
        try self.reconcileShells();
        // Manage reconciliation removes a closed window record before role
        // reconciliation runs. Mark its borrowed decoration for retirement
        // before either retirement advancement or extent lookup needs that
        // record again.
        try self.retireOrphanDecorations();
        try self.advanceDecorationRetirements();
        try self.reconcileDecorationExtents();
        var selection = try self.adapter.visibleTiledDecorationSelection();
        defer selection.deinit();

        var selected = std.ArrayList(types.WindowId).empty;
        defer selected.deinit(self.allocator);
        for (selection.outputs.items) |output| for (output.windows) |window| {
            // A window identity arrives before its first committed dimensions.
            // Wait for that protocol fact instead of creating a guessed-size
            // buffer which can never be resized in place.
            if (try self.adapter.objects.actualWindowSize(window) != null)
                try selected.append(self.allocator, window);
        };
        try self.decoration_lifetime.reconcile(selected.items, self, createDecoration, destroyDecoration);
        try self.advanceDecorationRetirements();
    }

    fn retireOrphanDecorations(self: *Runtime) !void {
        for (self.decorations.items) |*record| {
            if (record.state != .active or self.adapter.objects.windows.contains(record.window)) continue;
            record.state = .retiring;
            const role_index = self.managerDecorationIndex(record.decoration) orelse
                return error.RoleOwnershipLost;
            try self.manager.requestDecorationRoleRetirement(role_index);
        }
    }

    fn reconcileDecorationExtents(self: *Runtime) !void {
        for (self.decorations.items) |*record| {
            if (record.state != .active) continue;
            const extent = (try self.adapter.objects.actualWindowSize(record.window)) orelse continue;
            if (!decorationExtentChanged(record.extent, extent)) continue;
            const role_index = self.managerDecorationIndex(record.decoration) orelse
                return error.RoleOwnershipLost;
            try self.manager.requestDecorationRoleRetirement(role_index);
        }
    }

    fn reconcileShells(self: *Runtime) !void {
        // Detect geometry changes before advancing retirements. A replacement
        // is created below in this same safe point whenever the old presenter
        // is already release-safe.
        for (self.manager.outputs.items) |output| {
            const output_id = try self.adapter.objects.outputId(output);
            const extent = (try self.adapter.objects.outputSize(output_id)) orelse continue;
            if (self.findActiveShell(output)) |record| {
                if (record.state == .active and shellExtentChanged(record.extent, extent)) {
                    const role_index = self.managerShellIndex(record.role) orelse
                        return error.RoleOwnershipLost;
                    try self.manager.requestOutputShellRoleRetirement(role_index);
                }
            }
        }

        var index: usize = 0;
        while (index < self.shells.items.len) {
            const manager_index = self.managerShellIndex(self.shells.items[index].role);
            if (manager_index) |role_index| {
                if (!self.manager.output_shell_roles.items[role_index].retirement_requested and
                    self.shells.items[index].state == .active)
                {
                    index += 1;
                    continue;
                }
                try self.manager.requestOutputShellRoleRetirement(role_index);
            } else if (self.shells.items[index].state == .active) {
                return error.RoleOwnershipLost;
            }

            self.shells.items[index].state = .retiring;
            if (!try self.advanceShellRetirement(index)) index += 1;
        }

        for (self.manager.outputs.items) |output| {
            // Create the replacement while the retiring role still owns its
            // protocol objects. Besides minimizing the uncovered interval,
            // this prevents a compositor from mistaking an allocator-reused
            // shell identity for an unchanged render-list entry.
            if (self.findActiveShell(output) != null) continue;
            const output_id = try self.adapter.objects.outputId(output);
            // Output identity arrives before its dimensions. Creating the role
            // in that interval would force presentation to guess a buffer size.
            const extent = (try self.adapter.objects.outputSize(output_id)) orelse continue;
            const role_index = try self.manager.createOutputShellRole(self.compositor, output);
            const role = self.manager.output_shell_roles.items[role_index];
            self.shells.append(self.allocator, .{
                .output = output,
                .output_id = output_id,
                .extent = extent,
                .role = role.shell_surface,
                .surface = role.surface,
            }) catch |err| {
                self.rollbackShell(role_index);
                return err;
            };
            if (self.hooks.shell_created) |hook| hook(self.hooks.context, output_id, role.shell_surface, role.surface) catch |err| {
                _ = self.shells.pop();
                self.rollbackShell(role_index);
                return err;
            };
        }
    }

    fn createDecoration(raw: ?*anyopaque, window: types.WindowId) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        for (self.decorations.items) |record| if (record.window.value == window.value) return;
        const extent = (try self.adapter.objects.actualWindowSize(window)) orelse
            return error.WindowGeometryUnavailable;
        const proxy = try self.adapter.objects.windowProxy(window);
        const index = try self.manager.createDecorationRole(self.compositor, proxy, true);
        const role = self.manager.decoration_roles.items[index];
        const id = self.adapter.objects.decorationId(role.decoration) catch |err| {
            self.rollbackDecoration(index);
            return err;
        };
        self.decorations.append(self.allocator, .{ .window = window, .extent = extent, .decoration = role.decoration, .surface = role.surface, .id = id }) catch |err| {
            self.rollbackDecoration(index);
            return err;
        };
        if (self.hooks.decoration_created) |hook| hook(self.hooks.context, window, id, role.decoration, role.surface) catch |err| {
            _ = self.decorations.pop();
            self.rollbackDecoration(index);
            return err;
        };
    }

    fn destroyDecoration(raw: ?*anyopaque, window: types.WindowId) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        var index: usize = 0;
        while (index < self.decorations.items.len) : (index += 1) {
            if (self.decorations.items[index].window.value != window.value) continue;
            self.decorations.items[index].state = .retiring;
            const manager_index = self.managerDecorationIndex(self.decorations.items[index].decoration) orelse
                return error.RoleOwnershipLost;
            try self.manager.requestDecorationRoleRetirement(manager_index);
            _ = try self.advanceDecorationRetirement(index);
            return;
        }
    }

    fn advanceDecorationRetirements(self: *Runtime) !void {
        var index: usize = 0;
        while (index < self.decorations.items.len) {
            const manager_index = self.managerDecorationIndex(self.decorations.items[index].decoration) orelse
                return error.RoleOwnershipLost;
            if (!self.manager.decoration_roles.items[manager_index].retirement_requested and
                self.decorations.items[index].state == .active)
            {
                index += 1;
                continue;
            }
            self.decorations.items[index].state = .retiring;
            try self.manager.requestDecorationRoleRetirement(manager_index);
            if (!try self.advanceDecorationRetirement(index)) index += 1;
        }
    }

    fn advanceShellRetirement(self: *Runtime, index: usize) !bool {
        const record = self.shells.items[index];
        const shell_id = try self.adapter.objects.shellSurfaceId(record.role);
        const status = if (self.hooks.shell_retire) |hook|
            try hook(self.hooks.context, record.output_id, shell_id)
        else
            RetirementStatus.release_safe;
        if (status == .pending_release) return false;

        const manager_index = self.managerShellIndex(record.role) orelse return error.RoleOwnershipLost;
        try self.manager.finishOutputShellRoleRetirement(manager_index);
        _ = self.shells.orderedRemove(index);
        return true;
    }

    fn advanceDecorationRetirement(self: *Runtime, index: usize) !bool {
        const record = self.decorations.items[index];
        const manager_index = self.managerDecorationIndex(record.decoration) orelse return error.RoleOwnershipLost;
        const status = if (self.hooks.decoration_retire) |hook|
            try hook(self.hooks.context, record.window, record.id, self.manager.decoration_roles.items[manager_index].inert)
        else
            RetirementStatus.release_safe;
        if (status == .pending_release) return false;

        try self.manager.finishDecorationRoleRetirement(manager_index);
        _ = self.decoration_lifetime.active.remove(record.window);
        _ = self.decorations.orderedRemove(index);
        return true;
    }

    fn rollbackShell(self: *Runtime, index: usize) void {
        self.manager.requestOutputShellRoleRetirement(index) catch return;
        self.manager.finishOutputShellRoleRetirement(index) catch {};
    }

    fn rollbackDecoration(self: *Runtime, index: usize) void {
        self.manager.requestDecorationRoleRetirement(index) catch return;
        self.manager.finishDecorationRoleRetirement(index) catch {};
    }

    fn findActiveShell(self: *const Runtime, output: *wayland.client.river.OutputV1) ?*const ShellRecord {
        for (self.shells.items) |*shell|
            if (shell.output == output and shell.state == .active) return shell;
        return null;
    }

    fn managerShellIndex(self: *const Runtime, role: *wayland.client.river.ShellSurfaceV1) ?usize {
        for (self.manager.output_shell_roles.items, 0..) |shell, index|
            if (shell.shell_surface == role) return index;
        return null;
    }

    fn managerDecorationIndex(self: *const Runtime, decoration: *wayland.client.river.DecorationV1) ?usize {
        for (self.manager.decoration_roles.items, 0..) |role, index|
            if (role.decoration == decoration) return index;
        return null;
    }
};

fn shellExtentChanged(current: types.Size, next: types.Size) bool {
    return !std.meta.eql(current, next);
}

fn decorationExtentChanged(current: types.Size, next: types.Size) bool {
    return current.width != next.width;
}

test "role lifecycle has explicit hook and ownership seams" {
    try std.testing.expect(@sizeOf(Runtime) > 0);
    _ = Runtime.reconcile;
}

test "orphaned window decorations retire before extent lookup" {
    var manager: live.Manager = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .proxy = undefined,
    };
    defer manager.decoration_roles.deinit(manager.allocator);
    try manager.decoration_roles.append(manager.allocator, .{
        .window = @ptrFromInt(0x2000),
        .surface = @ptrFromInt(0x2010),
        .decoration = @ptrFromInt(0x2020),
    });

    var adapter = world.Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    var runtime = Runtime.init(
        std.testing.allocator,
        &manager,
        &adapter,
        undefined,
        .{},
    );
    defer runtime.abandon();
    try runtime.decorations.append(std.testing.allocator, .{
        .window = types.WindowId.init(7),
        .extent = .{ .width = 800, .height = 600 },
        .decoration = @ptrFromInt(0x2020),
        .surface = @ptrFromInt(0x2010),
        .id = types.DecorationId.init(9),
    });

    try runtime.retireOrphanDecorations();
    try std.testing.expectEqual(RecordState.retiring, runtime.decorations.items[0].state);
    try std.testing.expect(manager.decoration_roles.items[0].retirement_requested);
}

test "shell extent changes require fresh presentation ownership" {
    try std.testing.expect(!shellExtentChanged(
        .{ .width = 1920, .height = 1080 },
        .{ .width = 1920, .height = 1080 },
    ));
    try std.testing.expect(shellExtentChanged(
        .{ .width = 1920, .height = 1080 },
        .{ .width = 2560, .height = 1440 },
    ));
}

test "decoration extent follows width but not content height" {
    try std.testing.expect(!decorationExtentChanged(
        .{ .width = 800, .height = 600 },
        .{ .width = 800, .height = 720 },
    ));
    try std.testing.expect(decorationExtentChanged(
        .{ .width = 800, .height = 600 },
        .{ .width = 1024, .height = 600 },
    ));
}

var retire_hook_inert: ?bool = null;

fn recordInertRetire(_: ?*anyopaque, _: types.WindowId, _: types.DecorationId, inert: bool) anyerror!RetirementStatus {
    retire_hook_inert = inert;
    return .pending_release;
}

test "decorations of a closed window retire as inert" {
    const window: *wayland.client.river.WindowV1 = @ptrFromInt(0x3000);
    var manager: live.Manager = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .proxy = undefined,
    };
    defer manager.decoration_roles.deinit(manager.allocator);
    try manager.decoration_roles.append(manager.allocator, .{
        .window = window,
        .surface = @ptrFromInt(0x3010),
        .decoration = @ptrFromInt(0x3020),
    });
    try std.testing.expect(!manager.decoration_roles.items[0].inert);

    var adapter = world.Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    var runtime = Runtime.init(std.testing.allocator, &manager, &adapter, undefined, .{
        .decoration_retire = recordInertRetire,
    });
    defer runtime.abandon();
    try runtime.decorations.append(std.testing.allocator, .{
        .window = types.WindowId.init(7),
        .extent = .{ .width = 800, .height = 600 },
        .decoration = @ptrFromInt(0x3020),
        .surface = @ptrFromInt(0x3010),
        .id = types.DecorationId.init(9),
    });

    // Retirement for an ordinary reason (e.g. a resize) may still touch the surface.
    retire_hook_inert = null;
    try manager.requestDecorationRoleRetirement(0);
    try runtime.advanceDecorationRetirements();
    try std.testing.expectEqual(@as(?bool, false), retire_hook_inert);

    // Once River sends `closed`, the surface is inert and must not be committed.
    manager.requestDecorationsForWindowRetirement(window);
    try std.testing.expect(manager.decoration_roles.items[0].inert);
    retire_hook_inert = null;
    try runtime.advanceDecorationRetirements();
    try std.testing.expectEqual(@as(?bool, true), retire_hook_inert);
}
