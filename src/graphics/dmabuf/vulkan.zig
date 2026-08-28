//! Vulkan import of modifier-explicit GBM DMA-BUFs.
//!
//! This is deliberately not WSI: there is no VkSurfaceKHR, swapchain, acquire,
//! or present operation. Images are ordinary external-memory render targets;
//! Wayland presentation imports the same storage independently.

const std = @import("std");
const dmabuf = @import("root.zig");

pub const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const device_extensions = [_][*:0]const u8{
    vk.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    vk.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    vk.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    vk.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    get_memory_fd_properties: vk.PFN_vkGetMemoryFdPropertiesKHR = null,
    gbm: dmabuf.Device = undefined,
    gbm_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const self = try allocator.create(Context);
        self.* = .{ .allocator = allocator };
        errdefer {
            self.release();
            allocator.destroy(self);
        }
        try self.createInstance();
        const drm = try self.pickPhysicalDevice();
        self.gbm = try dmabuf.Device.openRenderNode(drm.renderMajor, drm.renderMinor);
        self.gbm_ready = true;
        try self.createDevice();
        return self;
    }

    pub fn deinit(self: *Context) void {
        const allocator = self.allocator;
        self.release();
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Return single-memory-plane modifiers usable as color targets and
    /// importable from DMA-BUF. The caller intersects this with Wayland v3's
    /// advertised explicit modifiers before asking GBM to allocate.
    pub fn supportedModifiers(
        self: *Context,
        allocator: std.mem.Allocator,
        format: vk.VkFormat,
    ) ![]u64 {
        var list = vk.VkDrmFormatModifierPropertiesListEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        };
        var properties = vk.VkFormatProperties2{
            .sType = vk.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
            .pNext = &list,
        };
        vk.vkGetPhysicalDeviceFormatProperties2(self.physical_device, format, &properties);
        const raw = try allocator.alloc(vk.VkDrmFormatModifierPropertiesEXT, list.drmFormatModifierCount);
        defer allocator.free(raw);
        list.pDrmFormatModifierProperties = raw.ptr;
        vk.vkGetPhysicalDeviceFormatProperties2(self.physical_device, format, &properties);

        var result: std.ArrayList(u64) = .empty;
        errdefer result.deinit(allocator);
        for (raw[0..list.drmFormatModifierCount]) |candidate| {
            if (candidate.drmFormatModifierPlaneCount != 1) continue;
            if ((candidate.drmFormatModifierTilingFeatures & vk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) == 0)
                continue;
            if (!self.modifierImportable(format, candidate.drmFormatModifier)) continue;
            try result.append(allocator, candidate.drmFormatModifier);
        }
        return result.toOwnedSlice(allocator);
    }

    fn modifierImportable(self: *Context, format: vk.VkFormat, modifier: u64) bool {
        var external = vk.VkPhysicalDeviceExternalImageFormatInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
            .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        var drm = vk.VkPhysicalDeviceImageDrmFormatModifierInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
            .pNext = &external,
            .drmFormatModifier = modifier,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        const input = vk.VkPhysicalDeviceImageFormatInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
            .pNext = &drm,
            .format = format,
            .type = vk.VK_IMAGE_TYPE_2D,
            .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        };
        var external_properties = vk.VkExternalImageFormatProperties{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        };
        var output = vk.VkImageFormatProperties2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
            .pNext = &external_properties,
        };
        if (vk.vkGetPhysicalDeviceImageFormatProperties2(self.physical_device, &input, &output) != vk.VK_SUCCESS)
            return false;
        return (external_properties.externalMemoryProperties.externalMemoryFeatures &
            vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT) != 0;
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
        };
        try check(vk.vkCreateInstance(&info, null, &self.instance));
    }

    fn pickPhysicalDevice(self: *Context) !vk.VkPhysicalDeviceDrmPropertiesEXT {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));
        for (devices[0..count]) |device| {
            if (!try supportsRequiredExtensions(self.allocator, device)) continue;
            var drm = vk.VkPhysicalDeviceDrmPropertiesEXT{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
            };
            var properties = vk.VkPhysicalDeviceProperties2{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                .pNext = &drm,
            };
            vk.vkGetPhysicalDeviceProperties2(device, &properties);
            if (drm.hasRender != vk.VK_TRUE) continue;
            var family_count: u32 = 0;
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);
            const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);
            for (families[0..family_count], 0..) |family, index| {
                if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
                self.physical_device = device;
                self.queue_family = @intCast(index);
                return drm;
            }
        }
        return error.NoDmabufDevice;
    }

    fn createDevice(self: *Context) !void {
        const priority: f32 = 1;
        const queue = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
        };
        try check(vk.vkCreateDevice(self.physical_device, &info, null, &self.device));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
        self.get_memory_fd_properties = @ptrCast(vk.vkGetDeviceProcAddr(
            self.device,
            "vkGetMemoryFdPropertiesKHR",
        ) orelse return error.MissingVulkanEntryPoint);
    }

    fn release(self: *Context) void {
        if (self.device != null) {
            _ = vk.vkDeviceWaitIdle(self.device);
            vk.vkDestroyDevice(self.device, null);
        }
        if (self.gbm_ready) self.gbm.deinit();
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
    }
};

pub const Image = struct {
    context: *Context,
    image: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    width: u32,
    height: u32,
    format: vk.VkFormat,

    pub fn init(context: *Context, buffer: *const dmabuf.Buffer) !Image {
        if (buffer.plane_count != 1) return error.MultiPlaneUnsupported;
        const format = drmToVulkan(buffer.format) orelse return error.UnsupportedFormat;
        var layout = vk.VkSubresourceLayout{
            .offset = buffer.planes[0].offset,
            .rowPitch = buffer.planes[0].stride,
        };
        var modifier = vk.VkImageDrmFormatModifierExplicitCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
            .drmFormatModifier = buffer.modifier,
            .drmFormatModifierPlaneCount = 1,
            .pPlaneLayouts = &layout,
        };
        var external = vk.VkExternalMemoryImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = &modifier,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        const info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = buffer.width, .height = buffer.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var self: Image = .{
            .context = context,
            .width = buffer.width,
            .height = buffer.height,
            .format = format,
        };
        errdefer self.deinit();
        try check(vk.vkCreateImage(context.device, &info, null, &self.image));

        var fd_properties = vk.VkMemoryFdPropertiesKHR{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
        };
        try check(context.get_memory_fd_properties.?(
            context.device,
            vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            buffer.planes[0].fd,
            &fd_properties,
        ));
        var requirements = vk.VkMemoryRequirements2{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2,
        };
        const requirements_info = vk.VkImageMemoryRequirementsInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
            .image = self.image,
        };
        vk.vkGetImageMemoryRequirements2(context.device, &requirements_info, &requirements);
        const memory_type = findMemoryType(
            context.physical_device,
            requirements.memoryRequirements.memoryTypeBits & fd_properties.memoryTypeBits,
        ) orelse return error.NoMemoryType;

        const imported_fd = std.c.fcntl(buffer.planes[0].fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (imported_fd < 0) return error.DuplicateFailed;
        var dedicated = vk.VkMemoryDedicatedAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = self.image,
        };
        var imported = vk.VkImportMemoryFdInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
            .pNext = &dedicated,
            .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            .fd = imported_fd,
        };
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &imported,
            .allocationSize = requirements.memoryRequirements.size,
            .memoryTypeIndex = memory_type,
        };
        const result = vk.vkAllocateMemory(context.device, &allocation, null, &self.memory);
        if (result != vk.VK_SUCCESS) {
            _ = std.c.close(imported_fd);
            return error.VulkanFailed;
        }
        const bind = vk.VkBindImageMemoryInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
            .image = self.image,
            .memory = self.memory,
        };
        try check(vk.vkBindImageMemory2(context.device, 1, &bind));
        return self;
    }

    pub fn deinit(self: *Image) void {
        if (self.image != null) vk.vkDestroyImage(self.context.device, self.image, null);
        if (self.memory != null) vk.vkFreeMemory(self.context.device, self.memory, null);
        self.* = undefined;
    }
};

fn supportsRequiredExtensions(allocator: std.mem.Allocator, device: vk.VkPhysicalDevice) !bool {
    var count: u32 = 0;
    try check(vk.vkEnumerateDeviceExtensionProperties(device, null, &count, null));
    const properties = try allocator.alloc(vk.VkExtensionProperties, count);
    defer allocator.free(properties);
    try check(vk.vkEnumerateDeviceExtensionProperties(device, null, &count, properties.ptr));
    for (device_extensions) |required| {
        var found = false;
        for (properties[0..count]) |candidate| {
            if (std.mem.eql(u8, std.mem.span(required), std.mem.sliceTo(&candidate.extensionName, 0))) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn findMemoryType(device: vk.VkPhysicalDevice, allowed: u32) ?u32 {
    var properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(device, &properties);
    var index: u32 = 0;
    while (index < properties.memoryTypeCount) : (index += 1) {
        if ((allowed & (@as(u32, 1) << @intCast(index))) != 0) return index;
    }
    return null;
}

fn drmToVulkan(format: u32) ?vk.VkFormat {
    return switch (format) {
        dmabuf.argb8888, dmabuf.xrgb8888 => vk.VK_FORMAT_B8G8R8A8_UNORM,
        else => null,
    };
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailed;
}

test "DMA-BUF renderer is WSI-free" {
    std.testing.refAllDecls(Context);
    std.testing.refAllDecls(Image);
    try std.testing.expect(@hasDecl(vk, "vkCreateImage"));
    try std.testing.expect(!@hasDecl(vk, "vkCreateWaylandSurfaceKHR"));
    try std.testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_B8G8R8A8_UNORM), drmToVulkan(dmabuf.argb8888).?);
}
