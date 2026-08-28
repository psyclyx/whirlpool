//! River role presentation through ordinary Vulkan Wayland WSI.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const graphics = @import("whirlpool-graphics");
const wsi = @import("whirlpool-wayland-wsi");
const river_host = @import("whirlpool-river-host-runtime");
const river_presentation = @import("whirlpool-river-presentation");

const coordinator = host.river_coordinator;

pub const Api = struct {
    pub const SurfaceRole = coordinator.SurfaceRole;
    pub const SubmittedCommit = coordinator.SubmittedCommit;
    pub const SurfaceHooks = river_host.SurfaceHooks;
    pub const Surface = *wayland.client.wl.Surface;
    pub const DrawList = graphics.skia.DrawList;
};
pub const Registry = river_presentation.Registry(Api);
pub const Extent = Registry.Extent;
pub const SurfaceRole = Api.SurfaceRole;
pub const SubmittedCommit = Api.SubmittedCommit;
pub const SurfaceHooks = Api.SurfaceHooks;
pub const Factory = Registry.Factory;

pub const Queue = struct {
    context: ?*anyopaque = null,
    submit: *const fn (?*anyopaque, SubmittedCommit) anyerror!void,
};

const RoleRecord = struct {
    role: SurfaceRole,
    extent: Extent,
    product: *RolePresenter,
};

const RolePresenter = struct {
    owner: *Runtime,
    role: SurfaceRole,
    surface: *wayland.client.wl.Surface,
    extent: Extent,
    renderer: graphics.skia.Renderer,
    presenter: wsi.Swapchain,
    composition: host.surface_composition.Composition,
    status: Registry.PresenterState = .ready,
    generation: u64 = 0,
    token: u64 = 0,

    fn init(self: *RolePresenter) !void {
        self.renderer = try graphics.skia.Renderer.init(true);
        errdefer self.renderer.deinit();
        self.presenter = try wsi.Swapchain.init(
            self.owner.context,
            @ptrCast(self.surface),
            self.extent.width,
            self.extent.height,
        );
        errdefer self.presenter.deinit();
        self.composition = try host.surface_composition.Composition.init(self.owner.allocator, self.owner.surface.content);
    }

    fn state(raw: *anyopaque) Registry.PresenterState {
        return from(raw).status;
    }

    fn prepare(raw: *anyopaque, generation: u64, clear: [4]f32, draw_list: graphics.skia.DrawList) !u64 {
        const self = from(raw);
        if (self.status != .ready) return error.FrameAlreadyPending;
        try self.renderer.begin(self.extent.width, self.extent.height, clear);
        self.renderer.drawList(draw_list);
        const frame = try self.renderer.end();
        try self.presenter.uploadAndSubmit(frame);
        self.generation = generation;
        self.token +%= 1;
        if (self.token == 0) self.token = 1;
        self.status = .prepared;
        return self.token;
    }

    fn arm(raw: *anyopaque, generation: u64, token: u64) !void {
        const self = from(raw);
        if (self.status != .prepared or self.generation != generation or self.token != token)
            return error.StaleSubmission;
        self.status = .armed;
    }

    fn commit(raw: *anyopaque) void {
        const self = from(raw);
        std.debug.assert(self.status == .armed);
        self.presenter.commit();
        self.status = .submitted;
        if (self.token == 1) switch (self.role) {
            .shell => std.log.info("River shell surface committed its first frame", .{}),
            .decoration => {},
        };
    }

    fn discard(raw: *anyopaque, generation: u64, token: u64) void {
        const self = from(raw);
        if ((self.status == .prepared or self.status == .armed) and
            self.generation == generation and self.token == token)
        {
            self.presenter.discard();
            self.status = .ready;
        }
    }

    fn pollRelease(raw: *anyopaque) !bool {
        const self = from(raw);
        if (self.status != .submitted) return error.NotSubmitted;
        if (!try self.presenter.submittedComplete()) return false;
        self.status = .ready;
        return true;
    }

    fn destroy(raw: *anyopaque) void {
        const self = from(raw);
        const owner = self.owner;
        if (owner.created_product == self) owner.created_product = null;
        self.presenter.deinit();
        self.composition.deinit();
        self.renderer.deinit();
        self.status = .destroyed;
        owner.allocator.destroy(self);
    }

    fn from(raw: *anyopaque) *RolePresenter {
        return @ptrCast(@alignCast(raw));
    }

    const vtable = Registry.PresenterVTable{
        .state = state,
        .prepare_draw_list = prepare,
        .prepare_submitted = arm,
        .commit_prepared = commit,
        .discard_submitted = discard,
        .poll_release = pollRelease,
        .deinit = destroy,
    };
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    client: *client_api.Client,
    context: *wsi.Context,
    surface: *const script.config.SurfaceSpec,
    registry: Registry,
    queue: Queue,
    roles: std.ArrayList(RoleRecord) = .empty,
    created_product: ?*RolePresenter = null,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *client_api.Client,
        queue: Queue,
        surface: *const script.config.SurfaceSpec,
    ) !*Runtime {
        if (!std.mem.eql(u8, surface.provider, "river") or
            !std.mem.eql(u8, surface.role, "shell") or
            !std.mem.eql(u8, surface.placement, "all-outputs"))
            return error.UnsupportedSurfaceDescriptor;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.client = client;
        self.context = try wsi.Context.init(allocator, @ptrCast(client.display));
        errdefer self.context.deinit();
        self.surface = surface;
        self.queue = queue;
        self.roles = .empty;
        self.created_product = null;
        try self.roles.ensureTotalCapacity(allocator, 256);
        errdefer self.roles.deinit(allocator);
        self.registry = try Registry.init(allocator, .{
            .factory = .{ .context = self, .create = createRoleProduct },
            .max_roles = 256,
        });
        return self;
    }

    pub fn deinit(self: *Runtime) !void {
        if (self.registry.count() != 0) return error.PresentersStillRetained;
        try self.registry.deinit();
        self.roles.deinit(self.allocator);
        self.context.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Runtime) void {
        self.registry.abandon();
        self.roles.deinit(self.allocator);
        self.context.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn surfaceHooks(self: *Runtime) SurfaceHooks {
        return self.registry.surfaceHooks();
    }
    pub fn factory(self: *Runtime) Factory {
        return .{ .context = self, .create = createRoleProduct };
    }

    pub fn createRole(self: *Runtime, role: SurfaceRole, surface: *wayland.client.wl.Surface, extent: Extent) !void {
        if (self.created_product != null) return error.ProductCreationReentered;
        try self.registry.createRole(.{ .role = role, .surface = surface, .extent = extent });
        const product = self.created_product orelse return error.ProductNotCreated;
        self.created_product = null;
        self.roles.appendAssumeCapacity(.{ .role = role, .extent = extent, .product = product });
    }

    pub fn retireRole(self: *Runtime, role: SurfaceRole) !Registry.RetirementStatus {
        const status = try self.registry.retireRole(role);
        if (status == .release_safe) self.removeRole(role);
        return status;
    }

    pub fn pollReleases(self: *Runtime) !usize {
        return self.registry.pollReleases();
    }

    pub fn update(self: *Runtime, role: SurfaceRole, value: script.program_loader.Update) !void {
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        try record.product.composition.update(value);
    }

    pub fn presentRole(self: *Runtime, role: SurfaceRole, generation: u64, extent: Extent) !SubmittedCommit {
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        if (!std.meta.eql(record.extent, extent)) return error.RoleExtentChanged;
        if (try self.registry.isRetiring(role)) return error.SurfaceRoleRetiring;
        return switch (role) {
            .shell => blk: {
                var frame = try record.product.composition.snapshotAndLower(.{
                    .width = extent.width,
                    .height = extent.height,
                });
                defer frame.deinit();
                break :blk try self.registry.prepareDrawList(role, generation, .{ 0, 0, 0, 0 }, frame.drawList());
            },
            .decoration => self.registry.prepareDrawList(role, generation, .{ 0.03, 0.04, 0.06, 1 }, .{ .ops = &.{} }),
        };
    }

    pub fn presentAll(self: *Runtime, generation: u64) !void {
        if (generation == 0) return error.InvalidGeneration;
        for (self.roles.items) |record| {
            if (try self.registry.isRetiring(record.role)) continue;
            const submitted = self.presentRole(record.role, generation, record.extent) catch |err| switch (err) {
                error.NotReady, error.ReleasePending, error.FrameAlreadyPending => continue,
                else => return err,
            };
            self.queue.submit(self.queue.context, submitted) catch |err| {
                self.registry.discardSubmitted(submitted);
                return err;
            };
        }
    }

    fn removeRole(self: *Runtime, role: SurfaceRole) void {
        for (self.roles.items, 0..) |record, index| if (std.meta.eql(record.role, role)) {
            _ = self.roles.orderedRemove(index);
            return;
        };
    }

    fn findRole(self: *const Runtime, role: SurfaceRole) ?*const RoleRecord {
        for (self.roles.items) |*record| if (std.meta.eql(record.role, role)) return record;
        return null;
    }
};

fn createRoleProduct(raw: ?*anyopaque, info: Registry.CreateInfo) !Registry.Presenter {
    const owner: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingRuntime));
    const product = try owner.allocator.create(RolePresenter);
    errdefer owner.allocator.destroy(product);
    product.* = undefined;
    product.owner = owner;
    product.role = info.role;
    product.surface = info.surface;
    product.extent = info.extent;
    product.status = .ready;
    product.generation = 0;
    product.token = 0;
    try product.init();
    owner.created_product = product;
    return .{ .context = product, .vtable = &RolePresenter.vtable };
}

test "River presenter runtime uses one concrete WSI ownership seam" {
    try std.testing.expect(@sizeOf(Runtime) > 0);
    _ = RolePresenter.vtable;
}
