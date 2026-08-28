//! Host-visible Vulkan staging buffer for one surface frame.

const std = @import("std");
const graphics = @import("whirlpool-graphics");
const api = @import("api.zig");
const Context = @import("context.zig").Context;

const vk = api.vk;
const check = api.check;

pub const Staging = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: *anyopaque,
    bytes: usize,

    /// Allocate and map a tightly packed BGRA transfer buffer.
    pub fn init(context: *Context, width: u32, height: u32) !Staging {
        const bytes = try std.math.mul(usize, try std.math.mul(usize, width, 4), height);
        var buffer: vk.VkBuffer = null;
        var memory: vk.VkDeviceMemory = null;
        var mapped: ?*anyopaque = null;
        errdefer {
            if (mapped != null) vk.vkUnmapMemory(context.device, memory);
            if (buffer != null) vk.vkDestroyBuffer(context.device, buffer, null);
            if (memory != null) vk.vkFreeMemory(context.device, memory, null);
        }
        const info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = bytes,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check(vk.vkCreateBuffer(context.device, &info, null, &buffer));
        var requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(context.device, buffer, &requirements);
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try findMemoryType(context, requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
        };
        try check(vk.vkAllocateMemory(context.device, &allocation, null, &memory));
        try check(vk.vkBindBufferMemory(context.device, buffer, memory, 0));
        try check(vk.vkMapMemory(context.device, memory, 0, bytes, 0, &mapped));
        const staging = Staging{ .buffer = buffer, .memory = memory, .mapped = mapped.?, .bytes = bytes };
        staging.assertValid();
        return staging;
    }

    /// Unmap and release all staging resources.
    pub fn deinit(self: *Staging, context: *Context) void {
        self.assertValid();
        vk.vkUnmapMemory(context.device, self.memory);
        vk.vkDestroyBuffer(context.device, self.buffer, null);
        vk.vkFreeMemory(context.device, self.memory, null);
        self.* = undefined;
    }

    /// Copy a strided CPU frame into tightly packed mapped memory.
    pub fn copy(self: *Staging, frame: graphics.skia.Frame, packed_row: usize) void {
        self.assertValid();
        std.debug.assert(packed_row <= frame.row_bytes);
        std.debug.assert(self.bytes >= packed_row * frame.height);
        const destination: [*]u8 = @ptrCast(self.mapped);
        for (0..frame.height) |row| {
            const source_offset = row * frame.row_bytes;
            const target_offset = row * packed_row;
            @memcpy(destination[target_offset..][0..packed_row], frame.pixels[source_offset..][0..packed_row]);
        }
    }

    fn assertValid(self: *const Staging) void {
        std.debug.assert(self.buffer != null);
        std.debug.assert(self.memory != null);
        std.debug.assert(self.bytes > 0);
    }
};

fn findMemoryType(context: *Context, bits: u32, required: vk.VkMemoryPropertyFlags) !u32 {
    var properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(context.physical_device, &properties);
    var index: u32 = 0;
    while (index < properties.memoryTypeCount) : (index += 1) {
        if ((bits & (@as(u32, 1) << @intCast(index))) != 0 and
            (properties.memoryTypes[index].propertyFlags & required) == required)
            return index;
    }
    return error.NoHostVisibleMemory;
}
