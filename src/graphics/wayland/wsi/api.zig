//! Vulkan ABI and operations shared by WSI resource owners.

pub const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("wayland-client-core.h");
    @cInclude("vulkan/vulkan.h");
});

pub const instance_extensions = [_][*:0]const u8{
    vk.VK_KHR_SURFACE_EXTENSION_NAME,
    vk.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
};

pub const device_extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

/// Record one image-layout and access transition.
pub fn barrier(
    command: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    source_access: vk.VkAccessFlags,
    destination_access: vk.VkAccessFlags,
    source_stage: vk.VkPipelineStageFlags,
    destination_stage: vk.VkPipelineStageFlags,
) void {
    const value = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = source_access,
        .dstAccessMask = destination_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(command, source_stage, destination_stage, 0, 0, null, 0, null, 1, &value);
}

/// Convert a non-success Vulkan result to the WSI error vocabulary.
pub fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailed;
}
