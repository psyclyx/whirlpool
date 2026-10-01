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
/// Pause after a clock tick that drew nothing before asking for the next one.
const idle_tick_ms = 90;

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

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

const OwnedUpdate = script.program_loader.OwnedUpdate;
const max_update_services = 32;

/// How a service update reaches a surface program.
pub const Delivery = enum {
    /// Persistent state (what the desktop looks like): a newer value replaces
    /// an older one, and it is committed atomically with River's transaction.
    state,
    /// Measurements: a newer value replaces an older one, but drawing it never
    /// waits for (or manufactures) a River transaction.
    sample,
    /// Discrete events such as pointer input: values are appended, never
    /// coalesced away, and never wait for River.
    events,
};

const UpdateSet = struct {
    items: [max_update_services]?Entry = [_]?Entry{null} ** max_update_services,

    const Entry = struct { update: OwnedUpdate, delivery: Delivery };

    fn find(self: *UpdateSet, service: []const u8) ?*Entry {
        for (&self.items) |*item| if (item.*) |*entry|
            if (std.mem.eql(u8, entry.update.value.service, service)) return entry;
        return null;
    }

    fn equivalent(self: *UpdateSet, source: script.program_loader.Update) bool {
        const entry = self.find(source.service) orelse return false;
        return entry.update.eql(source);
    }

    fn canPut(self: *UpdateSet, service: []const u8) bool {
        if (self.find(service) != null) return true;
        for (self.items) |item| if (item == null) return true;
        return false;
    }

    /// Store `update`, returning whatever it displaced for the caller to free.
    /// Events are appended to any not yet delivered.
    fn put(self: *UpdateSet, allocator: std.mem.Allocator, update: OwnedUpdate, delivery: Delivery) !?OwnedUpdate {
        if (self.find(update.value.service)) |entry| {
            var replacement = update;
            if (delivery == .events) {
                const joined = try std.mem.concat(allocator, script.program_loader.Value, &.{ entry.update.value.values, update.value.values });
                defer allocator.free(joined);
                replacement = try OwnedUpdate.clone(allocator, .{ .service = update.value.service, .values = joined });
                var consumed = update;
                consumed.deinit();
            }
            const replaced = entry.update;
            entry.* = .{ .update = replacement, .delivery = delivery };
            return replaced;
        }
        for (&self.items) |*item| if (item.* == null) {
            item.* = .{ .update = update, .delivery = delivery };
            return null;
        };
        unreachable;
    }

    fn take(self: *UpdateSet) UpdateSet {
        const result = self.*;
        self.* = .{};
        return result;
    }

    fn isEmpty(self: *const UpdateSet) bool {
        for (self.items) |item| if (item != null) return false;
        return true;
    }

    /// Whether any update must reach the screen in step with River.
    fn requiresSync(self: *const UpdateSet) bool {
        for (self.items) |item| if (item) |entry| if (entry.delivery == .state) return true;
        return false;
    }

    fn apply(self: *UpdateSet, composition: *host.surface_composition.Composition) !void {
        for (&self.items) |*item| if (item.*) |*entry|
            try composition.update(entry.update.value);
    }

    fn deinit(self: *UpdateSet) void {
        for (&self.items) |*item| if (item.*) |*entry| entry.update.deinit();
        self.* = .{};
    }
};

const SlotState = enum { free, rendering, ready, prepared, armed, submitted };

const Slot = struct {
    allocation: dmabuf.Buffer,
    image: dmabuf.VulkanImage,
    wl_buffer: ?*wayland_dmabuf.Buffer = null,
    state: SlotState = .free,

    fn deinit(self: *Slot, abandon: bool) void {
        if (!abandon) std.debug.assert(self.state == .free or self.state == .ready);
        if (self.wl_buffer) |buffer| {
            if (abandon) buffer.abandon() else buffer.deinit();
        }
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
    composition: ?host.surface_composition.Composition = null,
    slots: [slot_count]Slot = undefined,
    initialized_slots: usize = 0,
    buffers_adopted: bool = false,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    pending: UpdateSet = .{},
    desired: UpdateSet = .{},
    desired_revision: u64 = 0,
    frame_ms: ?f64 = null,
    frame_callback: ?*wayland.client.wl.Callback = null,
    worker_active: bool = false,
    worker_error: ?anyerror = null,
    closing: bool = false,
    retiring: bool = false,
    detached: bool = false,
    surface_inert: bool = false,
    status: Registry.PresenterState = .waiting_for_buffer,
    /// Actions the surface program requested, for the main thread to perform.
    outbox: std.ArrayList(host.surface_composition.Action) = .empty,
    ready_slot: ?usize = null,
    ready_requires_sync: bool = false,
    generation: u64 = 0,
    token: u64 = 0,

    fn init(self: *RolePresenter) !void {
        const role_name = switch (self.role) {
            .shell => "shell",
            .decoration => "decoration",
        };
        const fields = [_]script.program_loader.Value.Field{.{ .key = "role", .value = .{ .string = role_name } }};
        const values = [_]script.program_loader.Value{.{ .object = &fields }};
        try self.enqueue(.{ .service = "surface-role", .values = &values }, .state);
        errdefer {
            self.pending.deinit();
            self.desired.deinit();
        }
        self.thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, workerMain, .{self});
    }

    fn createGraphicsSlot(self: *RolePresenter) !Slot {
        self.owner.gpu_mutex.lockUncancelable(self.owner.io);
        defer self.owner.gpu_mutex.unlock(self.owner.io);
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
        return .{ .allocation = allocation, .image = image };
    }

    fn createWaylandBuffer(self: *RolePresenter, allocation: *const dmabuf.Buffer) !*wayland_dmabuf.Buffer {
        var planes: [dmabuf.max_planes]wayland_dmabuf.Plane = undefined;
        for (allocation.planeSlice(), 0..) |plane, index| planes[index] = .{
            .fd = plane.fd,
            .offset = plane.offset,
            .stride = plane.stride,
        };
        return self.owner.dmabuf_manager.createBuffer(
            allocation.width,
            allocation.height,
            allocation.format,
            allocation.modifier,
            planes[0..allocation.plane_count],
        );
    }

    fn enqueue(self: *RolePresenter, source: script.program_loader.Update, delivery: Delivery) !void {
        // Events are never redundant; state and samples are when unchanged.
        if (delivery != .events) {
            self.lock();
            const unchanged = self.desired.equivalent(source);
            self.unlock();
            if (unchanged) return;
        }

        const allocator = self.owner.allocator;
        var request = try OwnedUpdate.clone(allocator, source);
        var desired: ?OwnedUpdate = if (delivery == .events) null else OwnedUpdate.clone(allocator, source) catch |err| {
            request.deinit();
            return err;
        };
        var replaced: ?OwnedUpdate = null;
        var replaced_desired: ?OwnedUpdate = null;
        self.lock();
        if (self.closing or self.retiring or !self.pending.canPut(source.service) or !self.desired.canPut(source.service)) {
            const retiring = self.closing or self.retiring;
            self.unlock();
            request.deinit();
            if (desired) |*value| value.deinit();
            return if (retiring) error.SurfaceRoleRetiring else error.SurfaceServiceLimitExceeded;
        }
        replaced = self.pending.put(allocator, request, delivery) catch |err| {
            self.unlock();
            if (desired) |*value| value.deinit();
            return err;
        };
        if (desired) |value| replaced_desired = self.desired.put(allocator, value, delivery) catch unreachable;
        // A frame rendered for older state is stale; one that merely lacks the
        // newest samples or events is not, and is still worth presenting.
        if (delivery == .state) {
            self.desired_revision +%= 1;
            if (self.desired_revision == 0) self.desired_revision = 1;
        }
        // A completed but unclaimed frame shows the previous desktop state.
        // Recycle it so fresh state never queues behind a frame waiting for a
        // River transaction. Samples and events just join the next frame:
        // recycling for each of them could starve presentation entirely.
        if (delivery == .state and self.status == .ready) {
            if (self.ready_slot) |index| {
                self.slots[index].state = .free;
                self.ready_slot = null;
                self.ready_requires_sync = false;
                self.status = .waiting_for_buffer;
            }
        }
        self.changed.signal(self.owner.io);
        self.unlock();
        if (replaced) |*old| old.deinit();
        if (replaced_desired) |*old| old.deinit();
    }

    fn workerMain(self: *RolePresenter) void {
        const descriptor = switch (self.role) {
            .shell => self.owner.surface,
            .decoration => self.owner.decoration_surface orelse {
                self.failWorker(error.MissingDecorationSurface);
                return;
            },
        };
        self.composition = host.surface_composition.Composition.init(
            self.owner.allocator,
            descriptor.module_path,
            descriptor.content,
        ) catch |err| {
            self.failWorker(err);
            return;
        };
        self.allocateSlots() catch |err| {
            self.failWorker(err);
            return;
        };
        self.owner.gpu_mutex.lockUncancelable(self.owner.io);
        var renderer = graphics.skia.GpuRenderer.init(self.owner.context.skiaContext()) catch |err| {
            self.owner.gpu_mutex.unlock(self.owner.io);
            self.failWorker(err);
            return;
        };
        if (self.composition) |*composition| composition.setTextMetrics(renderer.textMetrics());
        if (self.composition) |*composition| composition.setViewport(.{ .width = self.extent.width, .height = self.extent.height });
        self.owner.gpu_mutex.unlock(self.owner.io);
        // Tearing down a Skia context flushes and waits on the Vulkan queue
        // every role shares, and queue access must not race another role's
        // submission. That wait also retires this role's last frame, so its
        // images are idle by the time `destroy` frees them.
        defer {
            self.owner.gpu_mutex.lockUncancelable(self.owner.io);
            renderer.deinit();
            self.owner.gpu_mutex.unlock(self.owner.io);
        }
        while (true) {
            self.lock();
            while (!self.closing and !self.canRender())
                self.changed.waitUncancelable(self.owner.io, &self.mutex);
            if (self.closing) {
                self.unlock();
                return;
            }
            var requests = self.pending.take();
            const requires_sync = requests.requiresSync();
            const frame_ms = self.frame_ms;
            self.frame_ms = null;
            const revision = self.desired_revision;
            const slot_index = self.freeSlot() orelse unreachable;
            self.slots[slot_index].state = .rendering;
            self.worker_active = true;
            self.unlock();

            const rendered = self.render(&renderer, slot_index, &requests, frame_ms);
            requests.deinit();
            self.collectActions();

            self.lock();
            self.worker_active = false;
            var idle_tick = false;
            if (rendered) |drew| {
                if (!drew) {
                    self.slots[slot_index].state = .free;
                    idle_tick = true;
                } else if (self.closing or self.retiring or revision != self.desired_revision) {
                    self.slots[slot_index].state = .free;
                } else {
                    self.slots[slot_index].state = .ready;
                    self.ready_slot = slot_index;
                    self.ready_requires_sync = requires_sync;
                    self.status = .ready;
                }
            } else |err| {
                self.slots[slot_index].state = .free;
                if (revision == self.desired_revision) self.desired.deinit();
                std.log.err("DMA-BUF surface worker failed: {s}", .{@errorName(err)});
            }
            if (self.retiring and self.status == .submitted and !self.hasSubmitted())
                self.status = .ready;
            self.changed.signal(self.owner.io);
            self.unlock();
            // An idle tick asks the host for the next one after a pause, so a
            // quiet bar polls at a low rate instead of spinning.
            if (idle_tick) std.Io.sleep(self.owner.io, .fromMilliseconds(idle_tick_ms), .awake) catch {};
            self.owner.notifyWake();
        }
    }

    /// Move the program's requested actions to the outbox (worker thread).
    fn collectActions(self: *RolePresenter) void {
        const composition = &(self.composition orelse return);
        const actions = composition.takeActions() catch return;
        defer self.owner.allocator.free(actions);
        if (actions.len == 0) return;
        self.lock();
        self.outbox.appendSlice(self.owner.allocator, actions) catch {
            self.unlock();
            for (actions) |*action| action.deinit(self.owner.allocator);
            return;
        };
        self.unlock();
        self.owner.notifyWake();
    }

    fn allocateSlots(self: *RolePresenter) !void {
        var slots: [slot_count]Slot = undefined;
        var initialized: usize = 0;
        errdefer while (initialized > 0) {
            initialized -= 1;
            slots[initialized].deinit(false);
        };
        while (initialized < slot_count) : (initialized += 1)
            slots[initialized] = try self.createGraphicsSlot();

        self.lock();
        if (self.closing) {
            self.unlock();
            return error.PresenterClosing;
        }
        self.slots = slots;
        self.initialized_slots = slot_count;
        self.changed.broadcast(self.owner.io);
        self.unlock();
        self.owner.notifyWake();
    }

    fn adoptBuffers(self: *RolePresenter) !void {
        self.lock();
        if (self.worker_error) |err| {
            self.unlock();
            return err;
        }
        const ready = self.initialized_slots == slot_count;
        const adopted = self.buffers_adopted;
        self.unlock();
        if (!ready or adopted) return;

        var index: usize = 0;
        while (index < slot_count) : (index += 1) {
            if (self.slots[index].wl_buffer != null) continue;
            self.slots[index].wl_buffer = try self.createWaylandBuffer(&self.slots[index].allocation);
        }
        self.lock();
        self.buffers_adopted = true;
        self.unlock();
    }

    fn render(
        self: *RolePresenter,
        renderer: *graphics.skia.GpuRenderer,
        slot_index: usize,
        updates: *UpdateSet,
        frame_ms: ?f64,
    ) !bool {
        const composition = &(self.composition orelse return error.CompositionUnavailable);
        const frame_only = updates.isEmpty();
        try updates.apply(composition);
        if (frame_ms) |now| {
            const fields = [_]script.program_loader.Value.Field{.{ .key = "now", .value = .{ .number = now } }};
            const values = [_]script.program_loader.Value{.{ .object = &fields }};
            try composition.update(.{ .service = "frame", .values = &values });
        }
        // A clock tick that changed nothing draws nothing: no lowering, no GPU
        // work, no commit. Most ticks are like this, because plots move in
        // whole-pixel steps and unchanged properties do not dirty their nodes.
        if (frame_only and frame_ms != null and !composition.isDirty()) return false;
        var frame = try composition.lower(.{
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
        return true;
    }

    fn beginRetire(self: *RolePresenter) void {
        var abandoned: UpdateSet = .{};
        var detach = false;
        self.lock();
        self.retiring = true;
        if (!self.detached) {
            self.detached = true;
            detach = !self.surface_inert;
        }
        abandoned = self.pending.take();
        if (self.worker_active and self.status == .waiting_for_buffer)
            self.status = .submitted;
        self.unlock();
        abandoned.deinit();
        self.cancelFrameCallback();
        // A compositor may retain the surface's current DMA-BUF indefinitely
        // until it is replaced. Detach exactly once so retirement can observe
        // wl_buffer.release without destroying a still-borrowed surface.
        if (detach) {
            self.surface.attach(null, 0, 0);
            self.surface.commit();
        }
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
        if (!self.buffers_adopted or self.status != .ready or self.ready_slot == null)
            return error.NotReady;
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
        self.ensureFrameCallback() catch |err|
            std.log.warn("failed to request shell frame callback: {s}", .{@errorName(err)});
        self.lock();
        std.debug.assert(self.status == .armed);
        const index = self.ready_slot.?;
        self.unlock();
        const slot = &self.slots[index];
        self.surface.attach(slot.wl_buffer.?.proxy, 0, 0);
        self.surface.damageBuffer(0, 0, @intCast(self.extent.width), @intCast(self.extent.height));
        slot.wl_buffer.?.markAttached();
        self.surface.commit();
        self.lock();
        slot.state = .submitted;
        self.ready_slot = null;
        self.ready_requires_sync = false;
        self.status = .submitted;
        self.changed.signal(self.owner.io);
        const first = self.token == 1;
        self.unlock();
        if (first and self.role == .shell) std.log.info("River shell surface committed its first frame", .{});
    }

    /// Commit a frame-only shell update without manufacturing a River
    /// manage/render transaction. Persistent service updates still use the
    /// registry transaction so they remain atomic with policy state.
    fn presentAnimation(self: *RolePresenter) !bool {
        if (self.role != .shell or self.frame_callback != null) return false;
        self.lock();
        if (self.worker_error) |err| {
            self.unlock();
            return err;
        }
        const index = self.ready_slot orelse {
            self.unlock();
            return false;
        };
        if (self.status != .ready or !mayBypassRiverSync(self.role, self.ready_requires_sync)) {
            self.unlock();
            return false;
        }
        self.unlock();

        try self.ensureFrameCallback();
        const slot = &self.slots[index];
        self.surface.attach(slot.wl_buffer.?.proxy, 0, 0);
        self.surface.damageBuffer(0, 0, @intCast(self.extent.width), @intCast(self.extent.height));
        slot.wl_buffer.?.markAttached();
        self.surface.commit();

        self.lock();
        std.debug.assert(self.ready_slot == index and self.status == .ready);
        slot.state = .submitted;
        self.ready_slot = null;
        self.ready_requires_sync = false;
        self.status = .submitted;
        self.changed.signal(self.owner.io);
        self.unlock();
        return true;
    }

    fn ensureFrameCallback(self: *RolePresenter) !void {
        if (self.role != .shell or self.frame_callback != null) return;
        const callback = try self.surface.frame();
        callback.setListener(*RolePresenter, onFrame, self);
        self.frame_callback = callback;
    }

    fn cancelFrameCallback(self: *RolePresenter) void {
        if (self.frame_callback) |callback| {
            callback.destroy();
            self.frame_callback = null;
        }
    }

    fn onFrame(callback: *wayland.client.wl.Callback, event: wayland.client.wl.Callback.Event, self: *RolePresenter) void {
        switch (event) {
            .done => {
                std.debug.assert(self.frame_callback == callback);
                callback.destroy();
                self.frame_callback = null;
                self.owner.notifyWake();
            },
        }
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
        // The retiring worker may already have observed the release.
        if (self.status == .ready) return true;
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
        self.cancelFrameCallback();
        var abandoned: UpdateSet = .{};
        var desired: UpdateSet = .{};
        self.lock();
        self.closing = true;
        abandoned = self.pending.take();
        desired = self.desired.take();
        self.changed.broadcast(owner.io);
        self.unlock();
        abandoned.deinit();
        desired.deinit();
        if (self.thread) |thread| thread.join();
        while (self.initialized_slots > 0) {
            self.initialized_slots -= 1;
            self.slots[self.initialized_slots].deinit(owner.abandoning);
        }
        for (self.outbox.items) |*action| action.deinit(owner.allocator);
        self.outbox.deinit(owner.allocator);
        if (self.composition) |*composition| composition.deinit();
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
        if ((self.pending.isEmpty() and self.frame_ms == null) or self.ready_slot != null) return false;
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
            if (slot.state != .submitted or !slot.wl_buffer.?.reusable()) continue;
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
    fn failWorker(self: *RolePresenter, err: anyerror) void {
        self.lock();
        const closing = self.closing;
        if (!closing) self.worker_error = err;
        self.changed.broadcast(self.owner.io);
        self.unlock();
        if (!closing) self.owner.notifyWake();
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
    wake: ?Wake = null,
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
        self.wake = null;
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

    pub fn setWake(self: *Runtime, wake: Wake) void {
        std.debug.assert(self.roles.items.len == 0);
        self.wake = wake;
    }

    pub fn clearWake(self: *Runtime) void {
        self.wake = null;
    }

    pub fn createRole(self: *Runtime, role: SurfaceRole, surface: *wayland.client.wl.Surface, extent: Extent) !void {
        if (self.created_product != null) return error.ProductCreationReentered;
        try self.registry.createRole(.{ .role = role, .surface = surface, .extent = extent });
        const product = self.created_product orelse return error.ProductNotCreated;
        self.created_product = null;
        self.roles.appendAssumeCapacity(.{ .role = role, .extent = extent, .product = product });
    }

    /// The compositor invalidated the role's surface (its window closed); no
    /// further wl_surface requests may be made on it.
    pub fn markRoleInert(self: *Runtime, role: SurfaceRole) void {
        const record = self.findRole(role) orelse return;
        record.product.surface_inert = true;
    }

    pub fn retireRole(self: *Runtime, role: SurfaceRole) !Registry.RetirementStatus {
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        record.product.beginRetire();
        const status = try self.registry.retireRole(role);
        if (status == .release_safe) self.removeRole(role);
        return status;
    }

    pub fn pollReleases(self: *Runtime) !usize {
        for (self.roles.items) |record| {
            try record.product.adoptBuffers();
            record.product.reapReleased();
        }
        return self.registry.pollReleases();
    }

    /// Persistent state for a surface program, presented with River's next
    /// transaction.
    pub fn update(self: *Runtime, role: SurfaceRole, value: script.program_loader.Update) !void {
        return self.deliver(role, value, .state);
    }

    pub fn deliver(self: *Runtime, role: SurfaceRole, value: script.program_loader.Update, delivery: Delivery) !void {
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        try record.product.enqueue(value, delivery);
    }

    /// Hand every action surface programs requested to `visit` (main thread).
    pub fn drainActions(self: *Runtime, context: anytype, comptime visit: fn (@TypeOf(context), SurfaceRole, host.surface_composition.Action) void) void {
        for (self.roles.items) |record| {
            const product = record.product;
            product.lock();
            var taken = product.outbox;
            product.outbox = .empty;
            product.unlock();
            defer taken.deinit(self.allocator);
            for (taken.items) |*action| {
                visit(context, record.role, action.*);
                action.deinit(self.allocator);
            }
        }
    }

    /// Coalesce animation time separately from persistent service state. A
    /// newer clock sample must not invalidate a frame already being rendered.
    pub fn requestFrame(self: *Runtime, role: SurfaceRole, monotonic_ms: f64) !void {
        if (!std.math.isFinite(monotonic_ms) or monotonic_ms < 0) return error.InvalidFrameTime;
        const record = self.findRole(role) orelse return error.SurfaceRoleNotBound;
        const product = record.product;
        if (product.role != .shell or product.frame_callback != null) return;
        product.lock();
        if (product.closing or product.retiring) {
            product.unlock();
            return error.SurfaceRoleRetiring;
        }
        // The compositor callback starts exactly one frame. Do not let later
        // dispatches get ahead while that frame is rendering or waiting to be
        // committed; its completion will install the next callback. Pending
        // service updates do not hold it back: they render with this tick.
        if (product.worker_active or product.ready_slot != null or
            product.status == .prepared or product.status == .armed)
        {
            product.unlock();
            return;
        }
        product.frame_ms = monotonic_ms;
        product.changed.signal(self.io);
        product.unlock();
    }

    pub fn presentAll(self: *Runtime, generation: u64) !void {
        if (generation == 0) return error.InvalidGeneration;
        const empty = graphics.skia.DrawList{ .ops = &.{} };
        for (self.roles.items) |record| {
            if (try self.registry.isRetiring(record.role)) continue;
            if (try record.product.presentAnimation()) continue;
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

    fn notifyWake(self: *const Runtime) void {
        if (self.wake) |callback| callback.run(callback.context);
    }
};

fn createRoleProduct(raw: ?*anyopaque, info: Registry.CreateInfo) !Registry.Presenter {
    const owner: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingRuntime));
    const product = try owner.allocator.create(RolePresenter);
    errdefer owner.allocator.destroy(product);
    product.* = .{ .owner = owner, .role = info.role, .surface = info.surface, .extent = info.extent };
    try product.init();
    owner.created_product = product;
    return .{ .context = product, .vtable = &RolePresenter.vtable };
}

fn mayBypassRiverSync(role: SurfaceRole, requires_sync: bool) bool {
    return role == .shell and !requires_sync;
}

test "a transient frame sample is render work without a persistent revision" {
    var product: RolePresenter = undefined;
    product.pending = .{};
    product.frame_ms = 12;
    product.ready_slot = null;
    product.status = .waiting_for_buffer;
    for (&product.slots) |*slot| slot.state = .free;

    try std.testing.expect(product.canRender());
    product.frame_ms = null;
    try std.testing.expect(!product.canRender());
}

test "only frame-only shell work may bypass River synchronization" {
    try std.testing.expect(mayBypassRiverSync(.{ .shell = host.types.ShellSurfaceId.init(1) }, false));
    try std.testing.expect(!mayBypassRiverSync(.{ .shell = host.types.ShellSurfaceId.init(1) }, true));
    try std.testing.expect(!mayBypassRiverSync(.{ .decoration = host.types.DecorationId.init(2) }, false));
}
