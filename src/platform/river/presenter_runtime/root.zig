//! Asynchronous River role presentation with Skia-rendered DMA-BUFs.
//!
//! The Wayland thread owns protocol objects and the final attach/commit edge.
//! Each role worker owns Lua composition and raster work. A bounded two-slot
//! pool crosses that boundary; no worker dereferences a Wayland object.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");
const wayland_dmabuf = @import("whirlpool-wayland-dmabuf");
const dmabuf = @import("whirlpool-dmabuf-allocator");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const graphics = @import("whirlpool-graphics");
const river_host = @import("whirlpool-river-host-runtime");
const river_presentation = @import("whirlpool-river-presentation");

const coordinator = host.river_coordinator;
const slot_count = 2;

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

const OwnedUpdate = script.program_loader.OwnedUpdate;

const SlotState = enum { free, rendering, ready, prepared, armed, submitted };

const Slot = struct {
    allocation: dmabuf.Buffer,
    image: dmabuf.VulkanImage,
    wl_buffer: *wayland_dmabuf.Buffer,
    state: SlotState = .free,

    fn deinit(self: *Slot, abandon: bool) void {
        if (!abandon) std.debug.assert(self.state == .free or self.state == .ready);
        if (abandon) self.wl_buffer.abandon() else self.wl_buffer.deinit();
        self.image.deinit();
        self.allocation.deinit();
        self.* = undefined;
    }
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
    composition: host.surface_composition.Composition,
    slots: [slot_count]Slot = undefined,
    initialized_slots: usize = 0,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    pending: ?OwnedUpdate = null,
    accepted: ?OwnedUpdate = null,
    worker_active: bool = false,
    closing: bool = false,
    retiring: bool = false,
    status: Registry.PresenterState = .waiting_for_buffer,
    ready_slot: ?usize = null,
    generation: u64 = 0,
    token: u64 = 0,

    fn init(self: *RolePresenter) !void {
        const descriptor = switch (self.role) {
            .shell => self.owner.surface,
            .decoration => self.owner.decoration_surface orelse self.owner.surface,
        };
        self.composition = try host.surface_composition.Composition.init(self.owner.allocator, descriptor.content);
        errdefer self.composition.deinit();
        const role_name = switch (self.role) {
            .shell => "shell",
            .decoration => "decoration",
        };
        const values = [_]script.program_loader.Value{.{ .string = role_name }};
        try self.composition.update(.{ .service = "surface-role", .values = &values });
        errdefer while (self.initialized_slots > 0) {
            self.initialized_slots -= 1;
            self.slots[self.initialized_slots].deinit(false);
        };
        while (self.initialized_slots < slot_count) : (self.initialized_slots += 1)
            self.slots[self.initialized_slots] = try self.createSlot();
        self.thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, workerMain, .{self});
    }

    fn createSlot(self: *RolePresenter) !Slot {
        var allocation = try dmabuf.Buffer.init(
            &self.owner.context.gbm,
            self.extent.width,
            self.extent.height,
            dmabuf.argb8888,
            self.owner.modifiers,
        );
        errdefer allocation.deinit();
        var image = try dmabuf.VulkanImage.init(self.owner.context, &allocation);
        errdefer image.deinit();
        var planes: [dmabuf.max_planes]wayland_dmabuf.Plane = undefined;
        for (allocation.planeSlice(), 0..) |plane, index| planes[index] = .{
            .fd = plane.fd,
            .offset = plane.offset,
            .stride = plane.stride,
        };
        const wl_buffer = try self.owner.dmabuf_manager.createBuffer(
            allocation.width,
            allocation.height,
            allocation.format,
            allocation.modifier,
            planes[0..allocation.plane_count],
        );
        return .{ .allocation = allocation, .image = image, .wl_buffer = wl_buffer };
    }

    fn enqueue(self: *RolePresenter, source: script.program_loader.Update) !void {
        self.lock();
        if (self.accepted) |*accepted| if (accepted.eql(source)) {
            self.unlock();
            return;
        };
        self.unlock();

        var request = try OwnedUpdate.clone(self.owner.allocator, source);
        var accepted = OwnedUpdate.clone(self.owner.allocator, source) catch |err| {
            request.deinit();
            return err;
        };
        var replaced: ?OwnedUpdate = null;
        var replaced_accepted: ?OwnedUpdate = null;
        self.lock();
        if (self.closing or self.retiring) {
            self.unlock();
            request.deinit();
            accepted.deinit();
            return error.SurfaceRoleRetiring;
        }
        replaced = self.pending;
        replaced_accepted = self.accepted;
        self.pending = request;
        self.accepted = accepted;
        self.changed.signal(self.owner.io);
        self.unlock();
        if (replaced) |*old| old.deinit();
        if (replaced_accepted) |*old| old.deinit();
    }

    fn workerMain(self: *RolePresenter) void {
        var renderer = graphics.skia.GpuRenderer.init(self.owner.context.skiaContext()) catch |err| {
            std.log.err("Skia DMA-BUF worker failed to initialize: {s}", .{@errorName(err)});
            return;
        };
        defer renderer.deinit();
        while (true) {
            self.lock();
            while (!self.closing and !self.canRender())
                self.changed.waitUncancelable(self.owner.io, &self.mutex);
            if (self.closing) {
                self.unlock();
                return;
            }
            var request = self.pending.?;
            self.pending = null;
            const slot_index = self.freeSlot() orelse unreachable;
            self.slots[slot_index].state = .rendering;
            self.worker_active = true;
            self.unlock();

            const rendered = self.render(&renderer, slot_index, request.value);
            request.deinit();

            self.lock();
            self.worker_active = false;
            if (rendered) |_| {
                if (self.closing or self.retiring) {
                    self.slots[slot_index].state = .free;
                } else {
                    self.slots[slot_index].state = .ready;
                    self.ready_slot = slot_index;
                    self.status = .ready;
                }
            } else |err| {
                self.slots[slot_index].state = .free;
                std.log.err("DMA-BUF surface worker failed: {s}", .{@errorName(err)});
            }
            if (self.retiring and self.status == .submitted and !self.hasSubmitted())
                self.status = .ready;
            self.changed.signal(self.owner.io);
            self.unlock();
        }
    }

    fn render(self: *RolePresenter, renderer: *graphics.skia.GpuRenderer, slot_index: usize, update: script.program_loader.Update) !void {
        try self.composition.update(update);
        var frame = try self.composition.snapshotAndLower(.{
            .width = self.extent.width,
            .height = self.extent.height,
        });
        defer frame.deinit();
        self.owner.gpu_mutex.lockUncancelable(self.owner.io);
        defer self.owner.gpu_mutex.unlock(self.owner.io);
        try renderer.begin(self.slots[slot_index].image.skiaTarget(), .{ 0, 0, 0, 0 });
        renderer.drawList(frame.drawList());
        try renderer.end(
            @intCast(dmabuf.vk.VK_IMAGE_LAYOUT_GENERAL),
            @intCast(dmabuf.vk.VK_QUEUE_FAMILY_FOREIGN_EXT),
        );
        self.slots[slot_index].image.markReleasedToWayland();
    }

    fn beginRetire(self: *RolePresenter) void {
        var abandoned: ?OwnedUpdate = null;
        self.lock();
        self.retiring = true;
        abandoned = self.pending;
        self.pending = null;
        if (self.worker_active and self.status == .waiting_for_buffer)
            self.status = .submitted;
        self.unlock();
        if (abandoned) |*request| request.deinit();
    }

    fn state(raw: *anyopaque) Registry.PresenterState {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        return self.status;
    }

    fn prepare(raw: *anyopaque, generation: u64, _: [4]f32, _: graphics.skia.DrawList) !u64 {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if (self.status != .ready or self.ready_slot == null) return error.NotReady;
        const index = self.ready_slot.?;
        self.slots[index].state = .prepared;
        self.generation = generation;
        self.token +%= 1;
        if (self.token == 0) self.token = 1;
        self.status = .prepared;
        return self.token;
    }

    fn arm(raw: *anyopaque, generation: u64, token: u64) !void {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if (self.status != .prepared or self.generation != generation or self.token != token)
            return error.StaleSubmission;
        self.slots[self.ready_slot.?].state = .armed;
        self.status = .armed;
    }

    fn commit(raw: *anyopaque) void {
        const self = from(raw);
        self.lock();
        std.debug.assert(self.status == .armed);
        const index = self.ready_slot.?;
        self.unlock();
        const slot = &self.slots[index];
        self.surface.attach(slot.wl_buffer.proxy, 0, 0);
        self.surface.damageBuffer(0, 0, @intCast(self.extent.width), @intCast(self.extent.height));
        slot.wl_buffer.markAttached();
        self.surface.commit();
        self.lock();
        slot.state = .submitted;
        self.ready_slot = null;
        self.status = .submitted;
        self.changed.signal(self.owner.io);
        const first = self.token == 1;
        self.unlock();
        if (first and self.role == .shell) std.log.info("River shell surface committed its first frame", .{});
    }

    fn discard(raw: *anyopaque, generation: u64, token: u64) void {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if ((self.status == .prepared or self.status == .armed) and self.generation == generation and self.token == token) {
            const index = self.ready_slot.?;
            self.slots[index].state = .ready;
            self.status = .ready;
        }
    }

    fn pollRelease(raw: *anyopaque) !bool {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if (self.status != .submitted) return error.NotSubmitted;
        self.reapReleasedLocked();
        if (self.hasSubmitted()) return false;
        self.status = .ready;
        return true;
    }

    fn destroy(raw: *anyopaque) void {
        const self = from(raw);
        const owner = self.owner;
        if (owner.created_product == self) owner.created_product = null;
        var abandoned: ?OwnedUpdate = null;
        var accepted: ?OwnedUpdate = null;
        self.lock();
        self.closing = true;
        abandoned = self.pending;
        self.pending = null;
        accepted = self.accepted;
        self.accepted = null;
        self.changed.broadcast(owner.io);
        self.unlock();
        if (abandoned) |*request| request.deinit();
        if (accepted) |*request| request.deinit();
        if (self.thread) |thread| thread.join();
        while (self.initialized_slots > 0) {
            self.initialized_slots -= 1;
            self.slots[self.initialized_slots].deinit(owner.abandoning);
        }
        self.composition.deinit();
        self.status = .destroyed;
        owner.allocator.destroy(self);
    }

    fn freeSlot(self: *RolePresenter) ?usize {
        for (&self.slots, 0..) |*slot, index| if (slot.state == .free) return index;
        return null;
    }
    fn hasSubmitted(self: *const RolePresenter) bool {
        for (&self.slots) |*slot| if (slot.state == .submitted) return true;
        return false;
    }
    fn canRender(self: *RolePresenter) bool {
        if (self.pending == null or self.ready_slot != null) return false;
        if (self.status == .prepared or self.status == .armed) return false;
        return self.freeSlot() != null;
    }
    fn reapReleased(self: *RolePresenter) void {
        self.lock();
        defer self.unlock();
        self.reapReleasedLocked();
    }
    fn reapReleasedLocked(self: *RolePresenter) void {
        var freed = false;
        for (&self.slots) |*slot| {
            if (slot.state != .submitted or !slot.wl_buffer.reusable()) continue;
            slot.state = .free;
            freed = true;
        }
        if (freed) self.changed.signal(self.owner.io);
    }
    fn lock(self: *RolePresenter) void {
        self.mutex.lockUncancelable(self.owner.io);
    }
    fn unlock(self: *RolePresenter) void {
        self.mutex.unlock(self.owner.io);
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
    io: std.Io,
    client: *client_api.Client,
    context: *dmabuf.VulkanContext,
    dmabuf_manager: *wayland_dmabuf.Manager,
    modifiers: []u64,
    gpu_mutex: std.Io.Mutex = .init,
    surface: *const script.config.SurfaceSpec,
    decoration_surface: ?*const script.config.SurfaceSpec,
    registry: Registry,
    queue: Queue,
    roles: std.ArrayList(RoleRecord) = .empty,
    created_product: ?*RolePresenter = null,
    abandoning: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *client_api.Client, queue: Queue, surface: *const script.config.SurfaceSpec, decoration_surface: ?*const script.config.SurfaceSpec) !*Runtime {
        if (!std.mem.eql(u8, surface.provider, "river") or !std.mem.eql(u8, surface.role, "shell") or !std.mem.eql(u8, surface.placement, "all-outputs"))
            return error.UnsupportedSurfaceDescriptor;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.client = client;
        self.context = try dmabuf.VulkanContext.init(allocator);
        errdefer self.context.deinit();
        self.dmabuf_manager = (try wayland_dmabuf.Manager.bind(allocator, client)) orelse return error.MissingLinuxDmabufGlobal;
        errdefer self.dmabuf_manager.deinit();
        const vulkan_modifiers = try self.context.supportedModifiers(allocator, dmabuf.vk.VK_FORMAT_B8G8R8A8_UNORM);
        defer allocator.free(vulkan_modifiers);
        var common: std.ArrayList(u64) = .empty;
        errdefer common.deinit(allocator);
        for (vulkan_modifiers) |modifier| {
            if (modifier == dmabuf.modifier_invalid) continue;
            if (self.dmabuf_manager.supports(wayland_dmabuf.argb8888, modifier)) try common.append(allocator, modifier);
        }
        self.modifiers = try common.toOwnedSlice(allocator);
        errdefer allocator.free(self.modifiers);
        if (self.modifiers.len == 0) return error.NoCommonDmabufModifier;
        self.gpu_mutex = .init;
        self.surface = surface;
        self.decoration_surface = decoration_surface;
        self.queue = queue;
        self.roles = .empty;
        self.created_product = null;
        self.abandoning = false;
        try self.roles.ensureTotalCapacity(allocator, 256);
        errdefer self.roles.deinit(allocator);
        self.registry = try Registry.init(allocator, .{ .factory = .{ .context = self, .create = createRoleProduct }, .max_roles = 256 });
        return self;
    }

    pub fn deinit(self: *Runtime) !void {
        if (self.registry.count() != 0) return error.PresentersStillRetained;
        try self.registry.deinit();
        self.roles.deinit(self.allocator);
        self.allocator.free(self.modifiers);
        self.dmabuf_manager.deinit();
        self.context.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Runtime) void {
        self.abandoning = true;
        self.registry.abandon();
        self.roles.deinit(self.allocator);
        self.allocator.free(self.modifiers);
        self.dmabuf_manager.abandon();
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
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        record.product.beginRetire();
        const status = try self.registry.retireRole(role);
        if (status == .release_safe) self.removeRole(role);
        return status;
    }

    pub fn pollReleases(self: *Runtime) !usize {
        for (self.roles.items) |record| record.product.reapReleased();
        return self.registry.pollReleases();
    }

    pub fn update(self: *Runtime, role: SurfaceRole, value: script.program_loader.Update) !void {
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        try record.product.enqueue(value);
    }

    pub fn presentAll(self: *Runtime, generation: u64) !void {
        if (generation == 0) return error.InvalidGeneration;
        const empty = graphics.skia.DrawList{ .ops = &.{} };
        for (self.roles.items) |record| {
            if (try self.registry.isRetiring(record.role)) continue;
            const submitted = self.registry.prepareDrawList(record.role, generation, .{ 0, 0, 0, 0 }, empty) catch |err| switch (err) {
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
    product.* = .{ .owner = owner, .role = info.role, .surface = info.surface, .extent = info.extent, .composition = undefined };
    try product.init();
    owner.created_product = product;
    return .{ .context = product, .vtable = &RolePresenter.vtable };
}
