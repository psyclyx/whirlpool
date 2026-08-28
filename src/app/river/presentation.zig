//! River role-to-presentation lifetime bridge.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const wayland_client = @import("whirlpool-wayland-client");
const river_host_runtime = @import("whirlpool-river-host-runtime");
const river_role_lifecycle = @import("whirlpool-river-role-lifecycle");
const river_presenter_runtime = @import("whirlpool-river-presenter-runtime");

/// Owns the optional graphics runtime and its River role callback context.
pub const Bridge = struct {
    graphics: ?*river_presenter_runtime.Runtime = null,
    context: Context = undefined,
    generation: u64 = 1,

    /// Initialize graphics for a configured surface and return role hooks.
    pub fn init(
        self: *Bridge,
        allocator: std.mem.Allocator,
        client: *wayland_client.Client,
        runtime: *river_host_runtime.Runtime,
        surface: ?*const script.config.SurfaceSpec,
    ) !river_role_lifecycle.Hooks {
        self.* = .{};
        const spec = surface orelse return .{};
        self.graphics = try river_presenter_runtime.Runtime.init(allocator, client, .{
            .context = @ptrCast(runtime),
            .submit = queueCommit,
        }, spec);
        errdefer {
            self.graphics.?.deinit() catch {};
            self.graphics = null;
        }
        try runtime.setSurfaceHooks(self.graphics.?.surfaceHooks());
        self.context = .{ .runtime = runtime, .roles = undefined, .graphics = self.graphics.? };
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
        try graphics.presentAll(self.generation);
        self.generation +|= 1;
        if (self.generation == 0) return error.GenerationExhausted;
    }

    /// Release graphics after orderly role retirement.
    pub fn deinit(self: *Bridge) !void {
        if (self.graphics) |graphics| try graphics.deinit();
        self.* = undefined;
    }

    /// Drop graphics bookkeeping after transport loss.
    pub fn abandon(self: *Bridge) void {
        if (self.graphics) |graphics| graphics.abandon();
        self.graphics = null;
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

    pub fn updateShellServices(raw: ?*anyopaque, output_id: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const world = self.runtime.adapter.worldView();
        const output = world.getOutput(try self.runtime.adapter.objects.wmOutputId(output_id)) orelse
            return error.UnknownOutput;
        const ordinal = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;
        const values = [_]script.program_loader.Value{.{ .number = @floatFromInt(ordinal + 1) }};
        try self.graphics.update(.{ .shell = shell_id }, .{
            .service = "workspaces",
            .values = &values,
        });
    }

    fn extent(width: i32, height: i32) !river_presenter_runtime.Extent {
        if (width <= 0 or height <= 0) return error.InvalidExtent;
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    fn shellExtent(self: *const Context, output: host.types.OutputId) !river_presenter_runtime.Extent {
        return extentFromOptional(try self.roles.adapter.objects.outputSize(output), .{ .width = 1280, .height = 720 });
    }

    fn decorationExtent(self: *const Context, window: host.types.WindowId) !river_presenter_runtime.Extent {
        return extentFromOptional(try self.roles.adapter.objects.actualWindowSize(window), .{ .width = 480, .height = 32 });
    }

    fn extentFromOptional(size: ?host.types.Size, fallback: host.types.Size) !river_presenter_runtime.Extent {
        const value = size orelse fallback;
        return extent(value.width, value.height);
    }
};

pub fn queueCommit(raw: ?*anyopaque, commit: host.river_coordinator.SubmittedCommit) !void {
    const runtime: *river_host_runtime.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try runtime.queueSubmittedCommit(commit);
}

fn onShellCreated(raw: ?*anyopaque, output: host.types.OutputId, shell: *wayland.client.river.ShellSurfaceV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    const shell_id = try self.roles.adapter.objects.shellSurfaceId(shell);
    try self.graphics.createRole(.{ .shell = shell_id }, surface, try self.shellExtent(output));
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
