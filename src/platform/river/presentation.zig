//! Retained, role-keyed River surface presentation.
//!
//! This module joins renderer-owned frames to the host's `SurfaceHooks`
//! transaction without owning River proxies or choosing a graphics backend.
//! A mandatory factory creates one opaque presenter aggregate per role. In the
//! Vulkan/Skia host that aggregate owns the per-role renderer and Wayland WSI
//! presenter; the `wl_surface` is borrowed from the protocol-role owner and
//! must outlive the aggregate.
//!
//! The module is generic only to keep the River host, generated Wayland, and
//! graphics packages out of its dependency graph. A production instantiation
//! supplies these declarations on `Api`:
//!
//! - `SurfaceRole = host.river_coordinator.SurfaceRole`
//! - `SubmittedCommit = host.river_coordinator.SubmittedCommit`
//! - `SurfaceHooks = river_host_runtime.SurfaceHooks`
//! - `Surface = *wayland.client.wl.Surface`
//! - `DrawList = graphics.skia.DrawList`

const std = @import("std");

pub fn Registry(comptime Api: type) type {
    const SurfaceRole = Api.SurfaceRole;
    const SubmittedCommit = Api.SubmittedCommit;
    const SurfaceHooks = Api.SurfaceHooks;
    const Surface = Api.Surface;
    const DrawList = Api.DrawList;

    comptime {
        if (!@hasField(SubmittedCommit, "role") or
            !@hasField(SubmittedCommit, "generation") or
            !@hasField(SubmittedCommit, "token"))
            @compileError("SubmittedCommit must contain role, generation, and token fields");
        if (@FieldType(SubmittedCommit, "role") != SurfaceRole)
            @compileError("SubmittedCommit.role must be Api.SurfaceRole");
        if (!@hasField(SurfaceHooks, "context") or
            !@hasField(SurfaceHooks, "prepare") or
            !@hasField(SurfaceHooks, "commit") or
            !@hasField(SurfaceHooks, "discard"))
            @compileError("SurfaceHooks must contain context, prepare, commit, and discard fields");
    }

    return struct {
        const Self = @This();

        pub const PresenterState = enum {
            waiting_for_buffer,
            ready,
            prepared,
            armed,
            submitted,
            destroyed,
        };

        /// Role teardown is a two-phase operation. `pending_release` keeps the
        /// presenter and its borrowed surface alive; `release_safe` means the
        /// complete presenter aggregate has been destroyed and the protocol
        /// owner may now destroy the wl_surface.
        pub const RetirementStatus = enum {
            pending_release,
            release_safe,
        };

        pub const Extent = struct {
            width: u32,
            height: u32,

            fn validate(self: Extent) !void {
                if (self.width == 0 or self.height == 0) return error.InvalidExtent;
            }
        };

        /// The surface remains owned by the River protocol-role layer. The
        /// factory may borrow it until its returned Presenter is destroyed.
        pub const CreateInfo = struct {
            role: SurfaceRole,
            surface: Surface,
            extent: Extent,
        };

        pub const PresenterVTable = struct {
            state: *const fn (*anyopaque) PresenterState,
            prepare_draw_list: *const fn (*anyopaque, u64, [4]f32, DrawList) anyerror!u64,
            prepare_submitted: *const fn (*anyopaque, u64, u64) anyerror!void,
            commit_prepared: *const fn (*anyopaque) void,
            discard_submitted: *const fn (*anyopaque, u64, u64) void,
            /// Query release progress without waiting. A true result must move
            /// the presenter from submitted to ready; false leaves it submitted.
            poll_release: *const fn (*anyopaque) anyerror!bool,
            /// Destroy the complete factory product exactly once. This must not
            /// destroy CreateInfo.surface, which is only borrowed.
            deinit: *const fn (*anyopaque) void,
        };

        /// Unique ownership transfers from Factory.create to this registry.
        /// Copying a Presenter outside that hand-off duplicates ownership and is
        /// a contract violation.
        pub const Presenter = struct {
            context: *anyopaque,
            vtable: *const PresenterVTable,

            fn stateOf(self: Presenter) PresenterState {
                return self.vtable.state(self.context);
            }

            fn prepareDrawList(
                self: Presenter,
                generation: u64,
                clear: [4]f32,
                draw_list: DrawList,
            ) !u64 {
                return self.vtable.prepare_draw_list(self.context, generation, clear, draw_list);
            }

            fn prepareSubmitted(self: Presenter, generation: u64, token: u64) !void {
                return self.vtable.prepare_submitted(self.context, generation, token);
            }

            fn commitPrepared(self: Presenter) void {
                self.vtable.commit_prepared(self.context);
            }

            fn discardSubmitted(self: Presenter, generation: u64, token: u64) void {
                self.vtable.discard_submitted(self.context, generation, token);
            }

            fn pollRelease(self: Presenter) !bool {
                return self.vtable.poll_release(self.context);
            }

            fn deinit(self: Presenter) void {
                self.vtable.deinit(self.context);
            }
        };

        pub const Factory = struct {
            context: ?*anyopaque = null,
            /// On success, returns one live, uniquely owned aggregate in either
            /// waiting_for_buffer or ready state. Failure retains all ownership.
            create: *const fn (?*anyopaque, CreateInfo) anyerror!Presenter,
        };

        pub const Config = struct {
            factory: Factory,
            /// A hard ownership bound. init reserves all registry pointer
            /// storage, so SurfaceHooks never allocate.
            max_roles: usize,
        };

        const Identity = struct {
            generation: u64,
            token: u64,
        };

        const Entry = struct {
            role: SurfaceRole,
            presenter: Presenter,
            pending: ?Identity = null,
            retiring: bool = false,
        };

        allocator: std.mem.Allocator,
        factory: Factory,
        max_roles: usize,
        entries: std.ArrayList(*Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            if (config.max_roles == 0) return error.InvalidRoleCapacity;
            var self = Self{
                .allocator = allocator,
                .factory = config.factory,
                .max_roles = config.max_roles,
            };
            errdefer self.entries.deinit(allocator);
            try self.entries.ensureTotalCapacity(allocator, config.max_roles);
            return self;
        }

        /// Deinitialization is intentionally strict: protocol-role teardown must
        /// first destroy every presenter while its borrowed wl_surface is live.
        pub fn deinit(self: *Self) !void {
            if (self.entries.items.len != 0) return error.PresentersStillRetained;
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// Tear down retained presenters when the Wayland transport has gone
        /// away and protocol retirement can no longer complete.
        pub fn abandon(self: *Self) void {
            for (self.entries.items) |entry| {
                entry.presenter.deinit();
                self.allocator.destroy(entry);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        pub fn contains(self: *const Self, role: SurfaceRole) bool {
            return self.findIndex(role) != null;
        }

        pub fn stateOf(self: *const Self, role: SurfaceRole) !PresenterState {
            return (self.find(role) orelse return error.SurfaceRoleNotBound).presenter.stateOf();
        }

        pub fn isRetiring(self: *const Self, role: SurfaceRole) !bool {
            return (self.find(role) orelse return error.SurfaceRoleNotBound).retiring;
        }

        /// Fallible, allocating role setup. No role becomes visible until the
        /// factory product and stable registry entry both exist.
        pub fn createRole(self: *Self, info: CreateInfo) !void {
            try info.extent.validate();
            if (self.findIndex(info.role) != null) return error.SurfaceRoleAlreadyBound;
            if (self.entries.items.len == self.max_roles) return error.SurfaceRegistryFull;

            const presenter = try self.factory.create(self.factory.context, info);
            errdefer presenter.deinit();
            switch (presenter.stateOf()) {
                .waiting_for_buffer, .ready => {},
                else => return error.InvalidInitialPresenterState,
            }

            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.* = .{ .role = info.role, .presenter = presenter };
            self.entries.appendAssumeCapacity(entry);
        }

        /// Destroys only an idle presenter. Submitted buffers must first be
        /// released through pollReleases; rendered but uncommitted frames must
        /// first be discarded through discardSubmitted/SurfaceHooks.discard.
        pub fn destroyRole(self: *Self, role: SurfaceRole) !void {
            const index = self.findIndex(role) orelse return error.SurfaceRoleNotBound;
            const entry = self.entries.items[index];
            if (entry.pending != null) return error.UncommittedFrame;
            switch (entry.presenter.stateOf()) {
                .waiting_for_buffer, .ready => {},
                .submitted => return error.ReleasePending,
                .prepared, .armed => return error.UncommittedFrame,
                .destroyed => return error.PresenterAlreadyDestroyed,
            }

            _ = self.entries.orderedRemove(index);
            entry.presenter.deinit();
            self.allocator.destroy(entry);
        }

        /// Start or advance release-safe role retirement. Prepared work is
        /// cancelled immediately; a submitted buffer remains retained until a
        /// later nonblocking poll observes its compositor release point.
        /// `release_safe` is returned only after the presenter aggregate has
        /// been destroyed and no longer borrows the role's wl_surface.
        pub fn retireRole(self: *Self, role: SurfaceRole) !RetirementStatus {
            const index = self.findIndex(role) orelse return error.SurfaceRoleNotBound;
            const entry = self.entries.items[index];
            entry.retiring = true;

            if (entry.pending) |identity| {
                entry.presenter.discardSubmitted(identity.generation, identity.token);
                entry.pending = null;
            }

            switch (entry.presenter.stateOf()) {
                .submitted => return .pending_release,
                .waiting_for_buffer, .ready => {},
                .prepared, .armed => return error.InvalidPresenterTransition,
                .destroyed => return error.PresenterAlreadyDestroyed,
            }

            _ = self.entries.orderedRemove(index);
            entry.presenter.deinit();
            self.allocator.destroy(entry);
            return .release_safe;
        }

        /// Render one role and return the exact opaque commit accepted by
        /// host_runtime.queueSubmittedCommit. If queueing fails, the caller must
        /// pass the returned value to discardSubmitted.
        pub fn prepareDrawList(
            self: *Self,
            role: SurfaceRole,
            generation: u64,
            clear: [4]f32,
            draw_list: DrawList,
        ) !SubmittedCommit {
            if (generation == 0) return error.InvalidGeneration;
            const entry = self.find(role) orelse return error.SurfaceRoleNotBound;
            if (entry.retiring) return error.SurfaceRoleRetiring;
            if (entry.pending != null) return error.FrameAlreadyPending;
            switch (entry.presenter.stateOf()) {
                .waiting_for_buffer, .ready => {},
                .prepared, .armed => return error.FrameAlreadyPending,
                .submitted => return error.ReleasePending,
                .destroyed => return error.PresenterAlreadyDestroyed,
            }

            const token = try entry.presenter.prepareDrawList(generation, clear, draw_list);
            if (token == 0) {
                entry.presenter.discardSubmitted(generation, token);
                return error.InvalidSubmission;
            }
            if (entry.presenter.stateOf() != .prepared) return error.InvalidPresenterTransition;
            entry.pending = .{ .generation = generation, .token = token };
            return .{ .role = role, .generation = generation, .token = token };
        }

        /// Nonblocking release polling for every submitted role.
        pub fn pollReleases(self: *Self) !usize {
            var released: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.presenter.stateOf() != .submitted) continue;
                const did_release = try entry.presenter.pollRelease();
                const state = entry.presenter.stateOf();
                if (did_release) {
                    if (state != .ready) return error.InvalidPresenterTransition;
                    released += 1;
                } else if (state != .submitted) {
                    return error.InvalidPresenterTransition;
                }
            }
            return released;
        }

        pub fn surfaceHooks(self: *Self) SurfaceHooks {
            return .{
                .context = self,
                .prepare = prepareHook,
                .commit = commitHook,
                .discard = discardHook,
            };
        }

        pub fn discardSubmitted(self: *Self, submitted: SubmittedCommit) void {
            discardHook(self, submitted);
        }

        fn prepareHook(raw: ?*anyopaque, submitted: SubmittedCommit) anyerror!void {
            const self = from(raw);
            const entry = self.find(submitted.role) orelse return error.SurfaceRoleNotBound;
            const identity = entry.pending orelse return error.SurfaceNotPrepared;
            if (identity.generation != submitted.generation or identity.token != submitted.token)
                return error.StaleSubmission;

            switch (entry.presenter.stateOf()) {
                .prepared => {
                    try entry.presenter.prepareSubmitted(identity.generation, identity.token);
                    if (entry.presenter.stateOf() != .armed) return error.InvalidPresenterTransition;
                },
                // Preflight can be retried after another role failed. The
                // concrete presenter is not itself idempotent, so the
                // registry retains the identity which makes this safe.
                .armed => {},
                else => return error.SurfaceNotPrepared,
            }
        }

        fn commitHook(raw: ?*anyopaque, submitted: SubmittedCommit) void {
            const self = from(raw);
            const entry = self.find(submitted.role) orelse unreachable;
            const identity = entry.pending orelse unreachable;
            std.debug.assert(identity.generation == submitted.generation);
            std.debug.assert(identity.token == submitted.token);
            std.debug.assert(entry.presenter.stateOf() == .armed);
            entry.presenter.commitPrepared();
            std.debug.assert(entry.presenter.stateOf() == .submitted);
            entry.pending = null;
        }

        fn discardHook(raw: ?*anyopaque, submitted: SubmittedCommit) void {
            const self = from(raw);
            const entry = self.find(submitted.role) orelse return;
            const identity = entry.pending orelse return;
            if (identity.generation != submitted.generation or identity.token != submitted.token) return;
            entry.presenter.discardSubmitted(identity.generation, identity.token);
            std.debug.assert(entry.presenter.stateOf() == .ready);
            entry.pending = null;
        }

        fn find(self: *const Self, role: SurfaceRole) ?*Entry {
            const index = self.findIndex(role) orelse return null;
            return self.entries.items[index];
        }

        fn findIndex(self: *const Self, role: SurfaceRole) ?usize {
            for (self.entries.items, 0..) |entry, index|
                if (std.meta.eql(entry.role, role)) return index;
            return null;
        }

        fn from(raw: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(raw orelse unreachable));
        }
    };
}

const TestRole = union(enum) { shell: u64, decoration: u64 };
const TestSubmission = struct { role: TestRole, generation: u64, token: u64 };
const TestHooks = struct {
    context: ?*anyopaque,
    prepare: *const fn (?*anyopaque, TestSubmission) anyerror!void,
    commit: *const fn (?*anyopaque, TestSubmission) void,
    discard: *const fn (?*anyopaque, TestSubmission) void,
};
const TestSurface = struct { id: u64 };
const TestDrawList = struct { operation_count: usize };
const TestApi = struct {
    pub const SurfaceRole = TestRole;
    pub const SubmittedCommit = TestSubmission;
    pub const SurfaceHooks = TestHooks;
    pub const Surface = *TestSurface;
    pub const DrawList = TestDrawList;
};
const TestRegistry = Registry(TestApi);

const TestPresenter = struct {
    owner: *TestFactory,
    role: TestRole,
    state: TestRegistry.PresenterState = .ready,
    generation: u64 = 0,
    token: u64 = 0,
    arm_calls: usize = 0,
    commit_calls: usize = 0,
    discard_calls: usize = 0,
    fail_arm: bool = false,
    release_ready: bool = false,

    fn stateOf(raw: *anyopaque) TestRegistry.PresenterState {
        return from(raw).state;
    }

    fn prepareDrawList(raw: *anyopaque, generation: u64, _: [4]f32, draw_list: TestDrawList) !u64 {
        const self = from(raw);
        if (self.state != .ready) return error.NotReady;
        if (draw_list.operation_count == 0) return error.EmptyDrawList;
        self.generation = generation;
        self.token = generation * 100 + roleValue(self.role);
        self.state = .prepared;
        return self.token;
    }

    fn prepareSubmitted(raw: *anyopaque, generation: u64, token: u64) !void {
        const self = from(raw);
        self.arm_calls += 1;
        if (self.fail_arm) return error.PreflightFailed;
        if (self.state != .prepared or self.generation != generation or self.token != token)
            return error.StaleSubmission;
        self.state = .armed;
    }

    fn commitPrepared(raw: *anyopaque) void {
        const self = from(raw);
        std.debug.assert(self.state == .armed);
        self.commit_calls += 1;
        self.state = .submitted;
    }

    fn discardSubmitted(raw: *anyopaque, generation: u64, token: u64) void {
        const self = from(raw);
        if ((self.state == .prepared or self.state == .armed) and
            self.generation == generation and self.token == token)
        {
            self.discard_calls += 1;
            self.owner.discarded += 1;
            self.state = .ready;
        }
    }

    fn pollRelease(raw: *anyopaque) !bool {
        const self = from(raw);
        if (self.state != .submitted) return error.NotSubmitted;
        if (!self.release_ready) return false;
        self.state = .ready;
        return true;
    }

    fn deinit(raw: *anyopaque) void {
        const self = from(raw);
        const owner = self.owner;
        self.state = .destroyed;
        owner.destroyed += 1;
        owner.allocator.destroy(self);
    }

    fn from(raw: *anyopaque) *TestPresenter {
        return @ptrCast(@alignCast(raw));
    }

    const vtable = TestRegistry.PresenterVTable{
        .state = stateOf,
        .prepare_draw_list = prepareDrawList,
        .prepare_submitted = prepareSubmitted,
        .commit_prepared = commitPrepared,
        .discard_submitted = discardSubmitted,
        .poll_release = pollRelease,
        .deinit = deinit,
    };
};

const TestFactory = struct {
    allocator: std.mem.Allocator,
    created: usize = 0,
    destroyed: usize = 0,
    discarded: usize = 0,
    fail_create: bool = false,
    products: [4]?*TestPresenter = .{null} ** 4,

    fn interface(self: *TestFactory) TestRegistry.Factory {
        return .{ .context = self, .create = create };
    }

    fn create(raw: ?*anyopaque, info: TestRegistry.CreateInfo) !TestRegistry.Presenter {
        const self: *TestFactory = @ptrCast(@alignCast(raw orelse unreachable));
        if (self.fail_create) return error.FactoryUnavailable;
        const product = try self.allocator.create(TestPresenter);
        product.* = .{ .owner = self, .role = info.role };
        self.products[self.created] = product;
        self.created += 1;
        return .{ .context = product, .vtable = &TestPresenter.vtable };
    }
};

fn roleValue(role: TestRole) u64 {
    return switch (role) {
        .shell => |value| value,
        .decoration => |value| value,
    };
}

test "retained presenters dispatch by exact role and release gates destruction" {
    var factory = TestFactory{ .allocator = std.testing.allocator };
    var registry = try TestRegistry.init(std.testing.allocator, .{
        .factory = factory.interface(),
        .max_roles = 2,
    });
    defer registry.deinit() catch unreachable;
    var first_surface = TestSurface{ .id = 1 };
    var second_surface = TestSurface{ .id = 2 };
    const first_role = TestRole{ .decoration = 11 };
    const second_role = TestRole{ .decoration = 12 };
    try registry.createRole(.{ .role = first_role, .surface = &first_surface, .extent = .{ .width = 80, .height = 24 } });
    try registry.createRole(.{ .role = second_role, .surface = &second_surface, .extent = .{ .width = 90, .height = 24 } });

    const submitted = try registry.prepareDrawList(second_role, 3, .{ 0, 0, 0, 1 }, .{ .operation_count = 2 });
    const hooks = registry.surfaceHooks();
    try hooks.prepare(hooks.context, submitted);
    hooks.commit(hooks.context, submitted);

    try std.testing.expectEqual(TestRegistry.PresenterState.ready, try registry.stateOf(first_role));
    try std.testing.expectEqual(TestRegistry.PresenterState.submitted, try registry.stateOf(second_role));
    try std.testing.expectError(error.ReleasePending, registry.destroyRole(second_role));
    try std.testing.expectEqual(@as(usize, 0), try registry.pollReleases());
    factory.products[1].?.release_ready = true;
    try std.testing.expectEqual(@as(usize, 1), try registry.pollReleases());
    try registry.destroyRole(second_role);
    try registry.destroyRole(first_role);
    try std.testing.expectEqual(@as(usize, 2), factory.destroyed);
}

test "retirement cancels prepared work and retains submitted roles until release" {
    var factory = TestFactory{ .allocator = std.testing.allocator };
    var registry = try TestRegistry.init(std.testing.allocator, .{
        .factory = factory.interface(),
        .max_roles = 2,
    });
    defer registry.deinit() catch unreachable;
    var prepared_surface = TestSurface{ .id = 1 };
    var submitted_surface = TestSurface{ .id = 2 };
    const prepared_role = TestRole{ .shell = 13 };
    const submitted_role = TestRole{ .decoration = 14 };
    try registry.createRole(.{ .role = prepared_role, .surface = &prepared_surface, .extent = .{ .width = 80, .height = 24 } });
    try registry.createRole(.{ .role = submitted_role, .surface = &submitted_surface, .extent = .{ .width = 80, .height = 24 } });

    _ = try registry.prepareDrawList(prepared_role, 1, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 });
    try std.testing.expectEqual(TestRegistry.RetirementStatus.release_safe, try registry.retireRole(prepared_role));
    try std.testing.expectEqual(@as(usize, 1), factory.discarded);

    const submitted = try registry.prepareDrawList(submitted_role, 2, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 });
    const hooks = registry.surfaceHooks();
    try hooks.prepare(hooks.context, submitted);
    hooks.commit(hooks.context, submitted);
    try std.testing.expectEqual(TestRegistry.RetirementStatus.pending_release, try registry.retireRole(submitted_role));
    try std.testing.expect(try registry.isRetiring(submitted_role));
    try std.testing.expectError(
        error.SurfaceRoleRetiring,
        registry.prepareDrawList(submitted_role, 3, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 }),
    );

    factory.products[1].?.release_ready = true;
    try std.testing.expectEqual(@as(usize, 1), try registry.pollReleases());
    try std.testing.expectEqual(TestRegistry.RetirementStatus.release_safe, try registry.retireRole(submitted_role));
    try std.testing.expectEqual(@as(usize, 2), factory.destroyed);
}

test "preflight is idempotent after another role fails" {
    var factory = TestFactory{ .allocator = std.testing.allocator };
    var registry = try TestRegistry.init(std.testing.allocator, .{
        .factory = factory.interface(),
        .max_roles = 2,
    });
    defer registry.deinit() catch unreachable;
    var first_surface = TestSurface{ .id = 1 };
    var second_surface = TestSurface{ .id = 2 };
    const first_role = TestRole{ .shell = 21 };
    const second_role = TestRole{ .decoration = 22 };
    try registry.createRole(.{ .role = first_role, .surface = &first_surface, .extent = .{ .width = 100, .height = 40 } });
    try registry.createRole(.{ .role = second_role, .surface = &second_surface, .extent = .{ .width = 100, .height = 20 } });
    const first = try registry.prepareDrawList(first_role, 4, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 });
    const second = try registry.prepareDrawList(second_role, 5, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 });
    const hooks = registry.surfaceHooks();

    try hooks.prepare(hooks.context, first);
    factory.products[1].?.fail_arm = true;
    try std.testing.expectError(error.PreflightFailed, hooks.prepare(hooks.context, second));
    factory.products[1].?.fail_arm = false;
    try hooks.prepare(hooks.context, first);
    try hooks.prepare(hooks.context, second);
    try std.testing.expectEqual(@as(usize, 1), factory.products[0].?.arm_calls);

    hooks.discard(hooks.context, first);
    hooks.discard(hooks.context, second);
    try registry.destroyRole(first_role);
    try registry.destroyRole(second_role);
}

test "factory, capacity, and discard contracts have no fallback" {
    var factory = TestFactory{ .allocator = std.testing.allocator };
    var registry = try TestRegistry.init(std.testing.allocator, .{
        .factory = factory.interface(),
        .max_roles = 1,
    });
    defer registry.deinit() catch unreachable;
    var surface = TestSurface{ .id = 1 };
    const role = TestRole{ .decoration = 31 };

    try std.testing.expectError(error.InvalidExtent, registry.createRole(.{
        .role = role,
        .surface = &surface,
        .extent = .{ .width = 0, .height = 20 },
    }));
    factory.fail_create = true;
    try std.testing.expectError(error.FactoryUnavailable, registry.createRole(.{
        .role = role,
        .surface = &surface,
        .extent = .{ .width = 20, .height = 20 },
    }));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    factory.fail_create = false;
    try registry.createRole(.{ .role = role, .surface = &surface, .extent = .{ .width = 20, .height = 20 } });
    try std.testing.expectError(error.SurfaceRoleAlreadyBound, registry.createRole(.{
        .role = role,
        .surface = &surface,
        .extent = .{ .width = 20, .height = 20 },
    }));
    try std.testing.expectError(error.SurfaceRegistryFull, registry.createRole(.{
        .role = .{ .shell = 32 },
        .surface = &surface,
        .extent = .{ .width = 20, .height = 20 },
    }));

    const submitted = try registry.prepareDrawList(role, 6, .{ 0, 0, 0, 1 }, .{ .operation_count = 1 });
    try std.testing.expectError(error.UncommittedFrame, registry.destroyRole(role));
    registry.discardSubmitted(.{ .role = role, .generation = submitted.generation, .token = submitted.token + 1 });
    try std.testing.expectError(error.UncommittedFrame, registry.destroyRole(role));
    registry.discardSubmitted(submitted);
    try registry.destroyRole(role);
    try std.testing.expectEqual(@as(usize, 1), factory.created);
    try std.testing.expectEqual(@as(usize, 1), factory.destroyed);
}

test "registry refuses deinit while roles remain retained" {
    var factory = TestFactory{ .allocator = std.testing.allocator };
    var registry = try TestRegistry.init(std.testing.allocator, .{
        .factory = factory.interface(),
        .max_roles = 1,
    });
    var surface = TestSurface{ .id = 1 };
    const role = TestRole{ .shell = 41 };
    try registry.createRole(.{ .role = role, .surface = &surface, .extent = .{ .width = 1, .height = 1 } });
    try std.testing.expectError(error.PresentersStillRetained, registry.deinit());
    try registry.destroyRole(role);
    try registry.deinit();
}
