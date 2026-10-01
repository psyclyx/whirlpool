//! Asynchronous DMA-BUF presentation for one ordinary Wayland surface.
//!
//! The Wayland thread owns imports, attach/commit, and release observation.
//! A worker owns retained Lua composition and direct Skia/Vulkan rendering.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");
const wayland_dmabuf = @import("whirlpool-wayland-dmabuf");
const dmabuf = @import("whirlpool-dmabuf-allocator");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const graphics = @import("whirlpool-graphics");

const slot_count = 2;
const OwnedUpdate = script.program_loader.OwnedUpdate;

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    gpu: *dmabuf.VulkanContext,
    manager: *wayland_dmabuf.Manager,
    modifiers: []u64,

    pub fn init(allocator: std.mem.Allocator, client: *client_api.Client) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        const gpu = try dmabuf.VulkanContext.init(allocator);
        errdefer gpu.deinit();
        const manager = (try wayland_dmabuf.Manager.bind(allocator, client)) orelse
            return error.MissingLinuxDmabufGlobal;
        errdefer manager.deinit();

        const vulkan_modifiers = try gpu.supportedModifiers(
            allocator,
            dmabuf.vk.VK_FORMAT_B8G8R8A8_UNORM,
        );
        defer allocator.free(vulkan_modifiers);
        var common: std.ArrayList(u64) = .empty;
        errdefer common.deinit(allocator);
        for (vulkan_modifiers) |modifier| {
            if (modifier == dmabuf.modifier_invalid) continue;
            if (manager.supports(wayland_dmabuf.argb8888, modifier))
                try common.append(allocator, modifier);
        }
        const modifiers = try common.toOwnedSlice(allocator);
        errdefer allocator.free(modifiers);
        if (modifiers.len == 0) return error.NoCommonDmabufModifier;
        self.* = .{
            .allocator = allocator,
            .gpu = gpu,
            .manager = manager,
            .modifiers = modifiers,
        };
        return self;
    }

    pub fn deinit(self: *Context) void {
        const allocator = self.allocator;
        allocator.free(self.modifiers);
        self.manager.deinit();
        self.gpu.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Context) void {
        const allocator = self.allocator;
        allocator.free(self.modifiers);
        self.manager.abandon();
        self.gpu.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

const SlotState = enum { free, rendering, ready, submitted };

const Slot = struct {
    allocation: dmabuf.Buffer,
    image: dmabuf.VulkanImage,
    wl_buffer: *wayland_dmabuf.Buffer,
    state: SlotState = .free,

    fn init(context: *Context, width: u32, height: u32) !Slot {
        var allocation = try dmabuf.Buffer.init(
            &context.gpu.gbm,
            width,
            height,
            dmabuf.argb8888,
            context.modifiers,
        );
        errdefer allocation.deinit();
        var image = try dmabuf.VulkanImage.init(context.gpu, &allocation);
        errdefer image.deinit();
        var planes: [dmabuf.max_planes]wayland_dmabuf.Plane = undefined;
        for (allocation.planeSlice(), 0..) |plane, index| planes[index] = .{
            .fd = plane.fd,
            .offset = plane.offset,
            .stride = plane.stride,
        };
        const wl_buffer = try context.manager.createBuffer(
            allocation.width,
            allocation.height,
            allocation.format,
            allocation.modifier,
            planes[0..allocation.plane_count],
        );
        return .{ .allocation = allocation, .image = image, .wl_buffer = wl_buffer };
    }

    fn deinit(self: *Slot, abandon_transport: bool) void {
        std.debug.assert(abandon_transport or self.wl_buffer.reusable());
        if (abandon_transport) self.wl_buffer.abandon() else self.wl_buffer.deinit();
        self.image.deinit();
        self.allocation.deinit();
        self.* = undefined;
    }
};

pub const Presenter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *Context,
    surface: *wayland.client.wl.Surface,
    composition: host.surface_composition.Composition,
    slots: [slot_count]Slot = undefined,
    initialized_slots: usize = 0,
    retired: std.ArrayList(Slot) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    pending: ?OwnedUpdate = null,
    frame_ms: ?f64 = null,
    render_requested: bool = false,
    worker_active: bool = false,
    closing: bool = false,
    ready_slot: ?usize = null,
    worker_error: ?anyerror = null,
    wake: ?Wake = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *Context,
        surface: *wayland.client.wl.Surface,
        descriptor: *const script.config.SurfaceSpec,
    ) !*Presenter {
        const self = try allocator.create(Presenter);
        errdefer allocator.destroy(self);
        var composition = try host.surface_composition.Composition.init(allocator, descriptor.content);
        errdefer composition.deinit();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .context = context,
            .surface = surface,
            .composition = composition,
        };
        self.thread = try std.Thread.spawn(
            .{ .stack_size = 2 * 1024 * 1024 },
            workerMain,
            .{self},
        );
        return self;
    }

    pub fn setWake(self: *Presenter, wake: Wake) void {
        self.lock();
        self.wake = wake;
        self.unlock();
    }

    /// Replace the active pool after an acknowledged layer-surface configure.
    /// Submitted old buffers remain retained until their release events arrive.
    pub fn configure(self: *Presenter, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidExtent;
        self.lock();
        const unchanged = self.initialized_slots != 0 and self.width == width and self.height == height;
        self.unlock();
        if (unchanged) return;

        var new_slots: [slot_count]Slot = undefined;
        var initialized: usize = 0;
        errdefer while (initialized > 0) {
            initialized -= 1;
            new_slots[initialized].deinit(false);
        };
        while (initialized < slot_count) : (initialized += 1)
            new_slots[initialized] = try Slot.init(self.context, width, height);
        try self.retired.ensureUnusedCapacity(self.allocator, slot_count);

        self.lock();
        while (self.worker_active)
            self.changed.waitUncancelable(self.io, &self.mutex);
        self.reapReleasedLocked();
        var index: usize = 0;
        while (index < self.initialized_slots) : (index += 1) {
            if (self.slots[index].state == .submitted)
                self.retired.appendAssumeCapacity(self.slots[index])
            else
                self.slots[index].deinit(false);
        }
        self.slots = new_slots;
        self.initialized_slots = slot_count;
        self.width = width;
        self.height = height;
        self.ready_slot = null;
        self.render_requested = true;
        self.changed.signal(self.io);
        self.unlock();
    }

    pub fn update(self: *Presenter, update_value: script.program_loader.Update) !void {
        var request = try OwnedUpdate.clone(self.allocator, update_value);
        var replaced: ?OwnedUpdate = null;
        self.lock();
        if (self.closing) {
            self.unlock();
            request.deinit();
            return error.PresenterClosing;
        }
        replaced = self.pending;
        self.pending = request;
        self.render_requested = true;
        self.changed.signal(self.io);
        self.unlock();
        if (replaced) |*old| old.deinit();
    }

    /// Coalesce a host-clock frame request independently from named service
    /// updates so acquisition and drawing cadence cannot overwrite each other.
    pub fn requestFrame(self: *Presenter, monotonic_ms: f64) !void {
        if (!std.math.isFinite(monotonic_ms) or monotonic_ms < 0) return error.InvalidFrameTime;
        self.lock();
        if (self.closing) {
            self.unlock();
            return error.PresenterClosing;
        }
        self.frame_ms = monotonic_ms;
        self.render_requested = true;
        self.changed.signal(self.io);
        self.unlock();
    }

    /// Adopt one completed DMA-BUF on the Wayland thread without waiting for
    /// Lua, Skia, Vulkan, or compositor release work.
    pub fn present(self: *Presenter) !bool {
        self.reapReleased();
        self.lock();
        if (self.worker_error) |err| {
            self.unlock();
            return err;
        }
        const index = self.ready_slot orelse {
            self.unlock();
            return false;
        };
        const slot = &self.slots[index];
        std.debug.assert(slot.state == .ready);
        slot.state = .submitted;
        self.ready_slot = null;
        self.changed.signal(self.io);
        self.unlock();

        self.surface.attach(slot.wl_buffer.proxy, 0, 0);
        self.surface.damageBuffer(0, 0, @intCast(self.width), @intCast(self.height));
        slot.wl_buffer.markAttached();
        self.surface.commit();
        return true;
    }

    pub fn deinit(self: *Presenter) !void {
        self.reapReleased();
        self.lock();
        if (self.hasSubmitted()) {
            self.unlock();
            return error.BuffersStillPresented;
        }
        self.closing = true;
        var pending = self.pending;
        self.pending = null;
        self.changed.broadcast(self.io);
        self.unlock();
        if (pending) |*request| request.deinit();
        if (self.thread) |thread| thread.join();
        self.destroy(false);
    }

    pub fn abandon(self: *Presenter) void {
        self.lock();
        self.closing = true;
        var pending = self.pending;
        self.pending = null;
        self.changed.broadcast(self.io);
        self.unlock();
        if (pending) |*request| request.deinit();
        if (self.thread) |thread| thread.join();
        self.destroy(true);
    }

    fn workerMain(self: *Presenter) void {
        var renderer = graphics.skia.GpuRenderer.init(self.context.gpu.skiaContext()) catch |err| {
            self.publishError(err);
            return;
        };
        defer renderer.deinit();
        self.composition.setTextMetrics(renderer.textMetrics());
        while (true) {
            self.lock();
            while (!self.closing and !self.canRender())
                self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.closing) {
                self.unlock();
                return;
            }
            var request = self.pending;
            self.pending = null;
            const frame_ms = self.frame_ms;
            self.frame_ms = null;
            self.render_requested = false;
            const index = self.freeSlot() orelse unreachable;
            self.slots[index].state = .rendering;
            self.worker_active = true;
            self.unlock();

            const rendered = self.render(&renderer, index, if (request) |*owned| owned.value else null, frame_ms);
            if (request) |*owned| owned.deinit();

            self.lock();
            self.worker_active = false;
            if (rendered) |_| {
                if (self.closing) {
                    self.slots[index].state = .free;
                } else {
                    self.slots[index].state = .ready;
                    self.ready_slot = index;
                }
            } else |err| {
                self.slots[index].state = .free;
                self.worker_error = err;
            }
            const wake = self.wake;
            self.changed.broadcast(self.io);
            self.unlock();
            if (wake) |callback| callback.run(callback.context);
        }
    }

    fn render(
        self: *Presenter,
        renderer: *graphics.skia.GpuRenderer,
        index: usize,
        update_value: ?script.program_loader.Update,
        frame_ms: ?f64,
    ) !void {
        if (update_value) |service_update| try self.composition.update(service_update);
        if (frame_ms) |now| {
            const values = [_]script.program_loader.Value{.{ .number = now }};
            try self.composition.update(.{ .service = "frame", .values = &values });
        }
        var frame = try self.composition.lower(.{
            .width = self.width,
            .height = self.height,
        });
        defer frame.deinit();
        try renderer.begin(self.slots[index].image.skiaTarget(), .{ 0, 0, 0, 0 });
        renderer.drawList(frame.drawList());
        try renderer.end(
            @intCast(dmabuf.vk.VK_IMAGE_LAYOUT_GENERAL),
            @intCast(dmabuf.vk.VK_QUEUE_FAMILY_FOREIGN_EXT),
        );
        self.slots[index].image.markReleasedToWayland();
    }

    fn publishError(self: *Presenter, err: anyerror) void {
        self.lock();
        self.worker_error = err;
        const wake = self.wake;
        self.changed.broadcast(self.io);
        self.unlock();
        if (wake) |callback| callback.run(callback.context);
    }

    fn reapReleased(self: *Presenter) void {
        self.lock();
        defer self.unlock();
        self.reapReleasedLocked();
    }

    fn reapReleasedLocked(self: *Presenter) void {
        for (self.slots[0..self.initialized_slots]) |*slot| {
            if (slot.state == .submitted and slot.wl_buffer.reusable()) {
                slot.state = .free;
            }
        }
        var index: usize = 0;
        while (index < self.retired.items.len) {
            if (!self.retired.items[index].wl_buffer.reusable()) {
                index += 1;
                continue;
            }
            var released = self.retired.orderedRemove(index);
            released.deinit(false);
        }
        self.changed.signal(self.io);
    }

    fn canRender(self: *Presenter) bool {
        return self.initialized_slots != 0 and
            self.render_requested and
            self.ready_slot == null and
            self.freeSlot() != null;
    }

    fn freeSlot(self: *Presenter) ?usize {
        for (self.slots[0..self.initialized_slots], 0..) |*slot, index|
            if (slot.state == .free) return index;
        return null;
    }

    fn hasSubmitted(self: *const Presenter) bool {
        for (self.slots[0..self.initialized_slots]) |slot|
            if (slot.state == .submitted) return true;
        for (self.retired.items) |slot|
            if (!slot.wl_buffer.reusable()) return true;
        return false;
    }

    fn destroy(self: *Presenter, abandon_transport: bool) void {
        while (self.initialized_slots > 0) {
            self.initialized_slots -= 1;
            self.slots[self.initialized_slots].deinit(abandon_transport);
        }
        for (self.retired.items) |*slot| slot.deinit(abandon_transport);
        self.retired.deinit(self.allocator);
        self.composition.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn lock(self: *Presenter) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Presenter) void {
        self.mutex.unlock(self.io);
    }
};

test "ordinary Wayland surfaces use a bounded DMA-BUF pool" {
    try std.testing.expectEqual(@as(usize, 2), slot_count);
    try std.testing.expect(@sizeOf(Presenter) > @sizeOf(host.surface_composition.Composition));
}
