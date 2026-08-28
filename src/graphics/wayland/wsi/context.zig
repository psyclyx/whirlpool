//! Shared Vulkan device context for one Wayland display.

const std = @import("std");
const api = @import("api.zig");
const vk = api.vk;
const check = api.check;
const instance_extensions = api.instance_extensions;
const device_extensions = api.device_extensions;

/// Device-level Wayland WSI state shared by every surface on one display.
/// The heap allocation keeps pointers retained by per-surface swapchains
/// stable even when their platform runtimes move.
pub const Context = struct {
    allocator: std.mem.Allocator,
    display: *anyopaque,
    instance: vk.VkInstance = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    swapchain_count: usize = 0,

    /// Create the shared Vulkan instance, device, and presentation queue.
    pub fn init(allocator: std.mem.Allocator, display: *anyopaque) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .display = display };
        errdefer self.release();
        try self.createInstance();
        try self.pickDevice();
        try self.createDevice();
        self.assertReady();
        return self;
    }

    /// Release a context after all child swapchains are gone.
    pub fn deinit(self: *Context) void {
        self.assertReady();
        std.debug.assert(self.swapchain_count == 0);
        const allocator = self.allocator;
        self.release();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn release(self: *Context) void {
        if (self.device != null) {
            _ = vk.vkDeviceWaitIdle(self.device);
            vk.vkDestroyDevice(self.device, null);
        }
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
        self.device = null;
        self.instance = null;
    }

    fn createInstance(self: *Context) !void {
        const app = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "whirlpool",
            .applicationVersion = 1,
            .pEngineName = "whirlpool",
            .engineVersion = 1,
            .apiVersion = vk.VK_API_VERSION_1_1,
        };
        const info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app,
            .enabledExtensionCount = instance_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&instance_extensions),
        };
        try check(vk.vkCreateInstance(&info, null, &self.instance));
    }

    fn pickDevice(self: *Context) !void {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));
        var score: u32 = 0;
        for (devices[0..count]) |device| {
            var family_count: u32 = 0;
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);
            const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);
            for (families[0..family_count], 0..) |family, index| {
                if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
                if (vk.vkGetPhysicalDeviceWaylandPresentationSupportKHR(
                    device,
                    @intCast(index),
                    @ptrCast(self.display),
                ) != vk.VK_TRUE) continue;
                var properties: vk.VkPhysicalDeviceProperties = undefined;
                vk.vkGetPhysicalDeviceProperties(device, &properties);
                const candidate: u32 = switch (properties.deviceType) {
                    vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
                    vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
                    vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
                    else => 1,
                };
                if (candidate > score) {
                    score = candidate;
                    self.physical_device = device;
                    self.queue_family = @intCast(index);
                }
            }
        }
        if (self.physical_device == null) return error.NoPresentDevice;
    }

    fn createDevice(self: *Context) !void {
        const priority: f32 = 1;
        const queue_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
        };
        try check(vk.vkCreateDevice(self.physical_device, &info, null, &self.device));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
        std.debug.assert(self.device != null);
        std.debug.assert(self.queue != null);
    }

    fn assertReady(self: *const Context) void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device != null);
        std.debug.assert(self.queue != null);
    }
};
