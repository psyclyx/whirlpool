#include "shim.h"

#include <algorithm>
#include <cctype>
#include <condition_variable>
#include <deque>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <librsvg/rsvg.h>

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkColorSpace.h"
#include "core/SkFont.h"
#include "core/SkFontMetrics.h"
#include "core/SkFontMgr.h"
#include "core/SkFontScanner.h"
#include "core/SkData.h"
#include "core/SkImage.h"
#include "core/SkImageInfo.h"
#include "core/SkMatrix.h"
#include "core/SkPaint.h"
#include "effects/SkGradient.h"
#include "core/SkPath.h"
#include "core/SkSamplingOptions.h"
#include "core/SkSurface.h"
#include "core/SkTextBlob.h"
#include "gpu/ganesh/GrBackendSurface.h"
#include "gpu/ganesh/GrDirectContext.h"
#include "gpu/ganesh/GrTypes.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/vk/GrVkBackendSurface.h"
#include "gpu/ganesh/vk/GrVkDirectContext.h"
#include "gpu/ganesh/vk/GrVkTypes.h"
#include "gpu/vk/VulkanBackendContext.h"
#include "gpu/vk/VulkanExtensions.h"
#include "gpu/vk/VulkanMemoryAllocator.h"
#include "gpu/vk/VulkanMutableTextureState.h"
#include "ports/SkFontMgr_empty.h"
#include "ports/SkFontMgr_directory.h"
#include "ports/SkFontMgr_fontconfig.h"
#include "ports/SkFontScanner_FreeType.h"

// Skia 148 no longer creates a default allocator, and requires the client to
// supply one in VulkanBackendContext::fMemoryAllocator. This one gives every
// resource its own VkDeviceMemory; that is simple and correct, and adequate
// for a shell UI whose working set is a handful of small buffers.
class DedicatedMemoryAllocator final : public skgpu::VulkanMemoryAllocator {
public:
    DedicatedMemoryAllocator(VkPhysicalDevice physical_device, VkDevice device)
        : device_(device) {
        vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_);
        VkPhysicalDeviceProperties properties;
        vkGetPhysicalDeviceProperties(physical_device, &properties);
        atom_size_ = properties.limits.nonCoherentAtomSize;
    }

    VkResult allocateImageMemory(VkImage image, uint32_t,
                                 skgpu::VulkanBackendMemory *out) override {
        VkMemoryRequirements requirements;
        vkGetImageMemoryRequirements(device_, image, &requirements);
        return allocate(requirements, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, out);
    }

    VkResult allocateBufferMemory(VkBuffer buffer, BufferUsage usage, uint32_t,
                                  skgpu::VulkanBackendMemory *out) override {
        VkMemoryRequirements requirements;
        vkGetBufferMemoryRequirements(device_, buffer, &requirements);
        constexpr VkMemoryPropertyFlags visible =
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        switch (usage) {
        case BufferUsage::kGpuOnly:
            return allocate(requirements, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, out);
        case BufferUsage::kCpuWritesGpuReads:
            return allocate(requirements, visible, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, out);
        case BufferUsage::kTransfersFromCpuToGpu:
            return allocate(requirements, visible, 0, out);
        case BufferUsage::kTransfersFromGpuToCpu:
            return allocate(requirements, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                            VK_MEMORY_PROPERTY_HOST_CACHED_BIT, out);
        }
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    void getAllocInfo(const skgpu::VulkanBackendMemory &handle,
                      skgpu::VulkanAlloc *info) const override {
        const Block *block = from(handle);
        info->fMemory = block->memory;
        info->fOffset = 0;
        info->fSize = block->size;
        info->fFlags = 0;
        if (block->properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
            info->fFlags |= skgpu::VulkanAlloc::kMappable_Flag;
        if ((block->properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            !(block->properties & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            info->fFlags |= skgpu::VulkanAlloc::kNoncoherent_Flag;
        info->fBackendMemory = handle;
    }

    VkResult mapMemory(const skgpu::VulkanBackendMemory &handle, void **data) override {
        Block *block = from(handle);
        if (!block->mapped) {
            const VkResult result =
                vkMapMemory(device_, block->memory, 0, VK_WHOLE_SIZE, 0, &block->mapped);
            if (result != VK_SUCCESS) return result;
        }
        *data = block->mapped;
        return VK_SUCCESS;
    }

    void unmapMemory(const skgpu::VulkanBackendMemory &handle) override {
        Block *block = from(handle);
        if (!block->mapped) return;
        vkUnmapMemory(device_, block->memory);
        block->mapped = nullptr;
    }

    VkResult flushMemory(const skgpu::VulkanBackendMemory &handle, VkDeviceSize offset,
                         VkDeviceSize size) override {
        const Block *block = from(handle);
        const VkMappedMemoryRange range = mapped_range(block, offset, size);
        return vkFlushMappedMemoryRanges(device_, 1, &range);
    }

    VkResult invalidateMemory(const skgpu::VulkanBackendMemory &handle, VkDeviceSize offset,
                              VkDeviceSize size) override {
        const Block *block = from(handle);
        const VkMappedMemoryRange range = mapped_range(block, offset, size);
        return vkInvalidateMappedMemoryRanges(device_, 1, &range);
    }

    void freeMemory(const skgpu::VulkanBackendMemory &handle) override {
        Block *block = from(handle);
        if (block->mapped) vkUnmapMemory(device_, block->memory);
        vkFreeMemory(device_, block->memory, nullptr);
        total_ -= block->size;
        delete block;
    }

    std::pair<uint64_t, uint64_t> totalAllocatedAndUsedMemory() const override {
        return {total_, total_};
    }

private:
    struct Block {
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkDeviceSize size = 0;
        VkMemoryPropertyFlags properties = 0;
        void *mapped = nullptr;
    };

    static Block *from(skgpu::VulkanBackendMemory handle) {
        return reinterpret_cast<Block *>(handle);
    }

    // Non-coherent ranges must be aligned to nonCoherentAtomSize. A range that
    // reaches the end of the block may use VK_WHOLE_SIZE instead of rounding up.
    VkMappedMemoryRange mapped_range(const Block *block, VkDeviceSize offset,
                                     VkDeviceSize size) const {
        const VkDeviceSize start = offset - offset % atom_size_;
        VkDeviceSize end = (offset + size + atom_size_ - 1) / atom_size_ * atom_size_;
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        range.memory = block->memory;
        range.offset = start;
        range.size = end >= block->size ? VK_WHOLE_SIZE : end - start;
        return range;
    }

    bool find_type(uint32_t type_bits, VkMemoryPropertyFlags wanted, uint32_t *out) const {
        for (uint32_t index = 0; index < memory_.memoryTypeCount; ++index) {
            if (!(type_bits & (1u << index))) continue;
            if ((memory_.memoryTypes[index].propertyFlags & wanted) != wanted) continue;
            *out = index;
            return true;
        }
        return false;
    }

    VkResult allocate(const VkMemoryRequirements &requirements,
                      VkMemoryPropertyFlags required, VkMemoryPropertyFlags preferred,
                      skgpu::VulkanBackendMemory *out) {
        uint32_t type = 0;
        if (!(preferred && find_type(requirements.memoryTypeBits, required | preferred, &type)) &&
            !find_type(requirements.memoryTypeBits, required, &type))
            return VK_ERROR_FEATURE_NOT_PRESENT;
        VkMemoryAllocateInfo info{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        info.allocationSize = requirements.size;
        info.memoryTypeIndex = type;
        auto *block = new (std::nothrow) Block();
        if (!block) return VK_ERROR_OUT_OF_HOST_MEMORY;
        const VkResult result = vkAllocateMemory(device_, &info, nullptr, &block->memory);
        if (result != VK_SUCCESS) {
            delete block;
            return result;
        }
        block->size = requirements.size;
        block->properties = memory_.memoryTypes[type].propertyFlags;
        total_ += block->size;
        *out = reinterpret_cast<skgpu::VulkanBackendMemory>(block);
        return VK_SUCCESS;
    }

    VkDevice device_;
    VkPhysicalDeviceMemoryProperties memory_{};
    VkDeviceSize atom_size_ = 1;
    uint64_t total_ = 0;
};

struct CachedRun {
    sk_sp<SkTextBlob> blob;
    float offset;
};
struct CachedText {
    std::vector<CachedRun> runs;
    float width = 0;
    float cap_height = 0;
};

// Shaped text, cached per (text, size); see `cached_text`.
struct WhirlpoolSkia {
    SkColorType color_type = kBGRA_8888_SkColorType;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels;
    sk_sp<SkSurface> surface;
    SkCanvas *canvas = nullptr;
    sk_sp<SkFontMgr> font_manager;
    sk_sp<SkTypeface> default_typeface;
    sk_sp<GrDirectContext> gpu_context;
    // Icons this renderer has drawn, or found unreadable (null).
    std::unordered_map<std::string, sk_sp<SkImage>> icon_cache;
    // Called from the icon store's worker when an icon this renderer drew
    // while it was loading is ready (see icon_image).
    WhirlpoolSkiaIconWake icon_wake = nullptr;
    void *icon_wake_context = nullptr;
    // Whether the frame being drawn met an icon still loading.
    bool icons_pending = false;
    std::unordered_map<std::string, CachedText> text_cache;
    // Typefaces by requested family name, resolved once each.
    std::unordered_map<std::string, sk_sp<SkTypeface>> families;
};

static void retain_icons();
static void release_icons(WhirlpoolSkia *renderer);

static SkImageInfo frame_info(const WhirlpoolSkia *renderer) {
    return SkImageInfo::Make(renderer->width, renderer->height,
                             renderer->color_type, kPremul_SkAlphaType, nullptr);
}

static bool initialize_fonts(WhirlpoolSkia *renderer) {
    if (const char *font_dir = std::getenv("WHIRLPOOL_FONT_DIR"))
        renderer->font_manager = SkFontMgr_New_Custom_Directory(font_dir);
    if (!renderer->font_manager)
        renderer->font_manager = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    if (!renderer->font_manager)
        renderer->font_manager = SkFontMgr_New_Custom_Empty();
    if (renderer->font_manager)
        renderer->default_typeface =
            renderer->font_manager->legacyMakeTypeface(nullptr, SkFontStyle());
    return renderer->font_manager != nullptr;
}

static SkUnichar next_utf8(const char **cursor, const char *end) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(*cursor);
    const size_t available = static_cast<size_t>(end - *cursor);
    if (available == 0) return 0xfffd;

    uint32_t codepoint = bytes[0];
    size_t count = 1;
    if ((bytes[0] & 0xe0) == 0xc0) {
        codepoint = bytes[0] & 0x1f;
        count = 2;
    } else if ((bytes[0] & 0xf0) == 0xe0) {
        codepoint = bytes[0] & 0x0f;
        count = 3;
    } else if ((bytes[0] & 0xf8) == 0xf0) {
        codepoint = bytes[0] & 0x07;
        count = 4;
    } else if (bytes[0] >= 0x80) {
        *cursor += 1;
        return 0xfffd;
    }

    if (count > available) {
        *cursor += 1;
        return 0xfffd;
    }
    for (size_t index = 1; index < count; ++index) {
        if ((bytes[index] & 0xc0) != 0x80) {
            *cursor += 1;
            return 0xfffd;
        }
        codepoint = (codepoint << 6) | (bytes[index] & 0x3f);
    }
    *cursor += count;
    return static_cast<SkUnichar>(codepoint);
}

static sk_sp<SkTypeface> typeface_for(WhirlpoolSkia *renderer,
                                      const sk_sp<SkTypeface>& primary,
                                      SkUnichar character) {
    if (primary && primary->unicharToGlyph(character) != 0) return primary;
    auto fallback = renderer->font_manager->matchFamilyStyleCharacter(
        nullptr, primary ? primary->fontStyle() : SkFontStyle(), nullptr, 0, character);
    if (fallback && fallback->unicharToGlyph(character) != 0) return fallback;
    return primary;
}

static float draw_text_run(WhirlpoolSkia *renderer, const char *text, size_t length,
                           float x, float baseline, float size, const SkPaint& paint,
                           const sk_sp<SkTypeface>& typeface) {
    if (!typeface || length == 0) return x;
    SkFont font(typeface, size);
    renderer->canvas->drawSimpleText(text, length, SkTextEncoding::kUTF8, x, baseline,
                                     font, paint);
    return x + font.measureText(text, length, SkTextEncoding::kUTF8);
}

extern "C" WhirlpoolSkia *whirlpool_skia_create(int bgra) {
    auto *renderer = new (std::nothrow) WhirlpoolSkia();
    if (!renderer) return nullptr;
    renderer->color_type = bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType;
    if (!initialize_fonts(renderer)) {
        delete renderer;
        return nullptr;
    }
    retain_icons();
    return renderer;
}

extern "C" WhirlpoolSkia *whirlpool_skia_create_vulkan(
        void *instance, void *physical_device, void *device, void *queue,
        uint32_t queue_family) {
    if (!instance || !physical_device || !device || !queue) {
        std::fprintf(stderr, "skia: null vulkan handle (instance=%p physical_device=%p device=%p queue=%p)\n",
                     instance, physical_device, device, queue);
        return nullptr;
    }
    auto *renderer = new (std::nothrow) WhirlpoolSkia();
    if (!renderer) {
        std::fprintf(stderr, "skia: renderer allocation failed\n");
        return nullptr;
    }
    renderer->color_type = kBGRA_8888_SkColorType;
    if (!initialize_fonts(renderer)) {
        std::fprintf(stderr, "skia: font manager initialization failed\n");
        delete renderer;
        return nullptr;
    }
    skgpu::VulkanBackendContext backend;
    backend.fInstance = static_cast<VkInstance>(instance);
    backend.fPhysicalDevice = static_cast<VkPhysicalDevice>(physical_device);
    backend.fDevice = static_cast<VkDevice>(device);
    backend.fQueue = static_cast<VkQueue>(queue);
    backend.fGraphicsQueueIndex = queue_family;
    backend.fMaxAPIVersion = VK_API_VERSION_1_1;
    backend.fMemoryAllocator = sk_make_sp<DedicatedMemoryAllocator>(
        backend.fPhysicalDevice, backend.fDevice);
    backend.fGetProc = [](const char *name, VkInstance vk_instance, VkDevice vk_device) {
        if (vk_device != VK_NULL_HANDLE)
            return vkGetDeviceProcAddr(vk_device, name);
        return vkGetInstanceProcAddr(vk_instance, name);
    };
    skgpu::VulkanExtensions extensions;
    const char *device_extensions[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
        VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
    };
    extensions.init(backend.fGetProc, backend.fInstance, backend.fPhysicalDevice,
                    0, nullptr,
                    static_cast<uint32_t>(sizeof(device_extensions) /
                                          sizeof(device_extensions[0])),
                    device_extensions);
    backend.fVkExtensions = &extensions;
    renderer->gpu_context = GrDirectContexts::MakeVulkan(backend);
    if (!renderer->gpu_context) {
        std::fprintf(stderr, "skia: GrDirectContexts::MakeVulkan failed (queue_family=%u)\n",
                     queue_family);
        delete renderer;
        return nullptr;
    }
    retain_icons();
    return renderer;
}

extern "C" void whirlpool_skia_destroy(WhirlpoolSkia *renderer) {
    if (!renderer) return;
    release_icons(renderer);
    renderer->canvas = nullptr;
    renderer->surface.reset();
    renderer->gpu_context.reset();
    delete renderer;
}

extern "C" int whirlpool_skia_begin_vulkan(
        WhirlpoolSkia *renderer, uint32_t width, uint32_t height,
        void *image, void *memory, uint64_t memory_size,
        uint32_t format, uint32_t layout, uint32_t queue_family) {
    if (!renderer || !renderer->gpu_context || !image || !memory ||
        width == 0 || height == 0) return 1;
    renderer->icons_pending = false;
    renderer->surface.reset();
    GrVkImageInfo image_info{};
    image_info.fImage = static_cast<VkImage>(image);
    // Ganesh borrows this render target. The allocation remains owned by the
    // DMA-BUF slot and the API explicitly permits an empty allocation for a
    // borrowed render target.
    (void)memory_size;
    image_info.fImageTiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    image_info.fImageLayout = static_cast<VkImageLayout>(layout);
    image_info.fFormat = static_cast<VkFormat>(format);
    image_info.fImageUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                  VK_IMAGE_USAGE_SAMPLED_BIT |
                                  VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                  VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    image_info.fSampleCount = 1;
    image_info.fLevelCount = 1;
    image_info.fCurrentQueueFamily = queue_family;
    image_info.fSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    auto target = GrBackendTextures::MakeVk(width, height, image_info);
    if (!target.isValid()) return 2;
    renderer->surface = SkSurfaces::WrapBackendTexture(
        renderer->gpu_context.get(), target, kTopLeft_GrSurfaceOrigin,
        0, renderer->color_type, nullptr, nullptr);
    if (!renderer->surface) return 3;
    renderer->width = width;
    renderer->height = height;
    renderer->canvas = renderer->surface->getCanvas();
    return renderer->canvas ? 0 : 1;
}

extern "C" int whirlpool_skia_begin(WhirlpoolSkia *renderer, uint32_t width, uint32_t height) {
    if (!renderer || width == 0 || height == 0) return 1;
    renderer->icons_pending = false;
    if (renderer->width != width || renderer->height != height || !renderer->surface) {
        renderer->width = width;
        renderer->height = height;
        renderer->pixels.assign(static_cast<size_t>(width) * height * 4, 0);
        renderer->surface = SkSurfaces::WrapPixels(frame_info(renderer), renderer->pixels.data(),
                                                   static_cast<size_t>(width) * 4);
        if (!renderer->surface) return 1;
    }
    renderer->canvas = renderer->surface->getCanvas();
    return renderer->canvas ? 0 : 1;
}

extern "C" void whirlpool_skia_clear(WhirlpoolSkia *renderer,
                                      float r, float g, float b, float a) {
    if (renderer && renderer->canvas)
        renderer->canvas->clear(SkColor4f{r, g, b, a}.toSkColor());
}

extern "C" void whirlpool_skia_draw_rect(WhirlpoolSkia *renderer,
                                          float x, float y, float width, float height,
                                          float radius, float r, float g, float b, float a) {
    if (!renderer || !renderer->canvas) return;
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    const SkRect rect = SkRect::MakeXYWH(x, y, width, height);
    if (radius > 0)
        renderer->canvas->drawRoundRect(rect, radius, radius, paint);
    else
        renderer->canvas->drawRect(rect, paint);
}

extern "C" void whirlpool_skia_draw_rect_radial(WhirlpoolSkia *renderer,
                                                 float x, float y, float width, float height,
                                                 float radius, float r, float g, float b, float a,
                                                 float cr, float cg, float cb, float ca) {
    if (!renderer || !renderer->canvas || width <= 0 || height <= 0) return;
    const SkColor4f colors[2] = {SkColor4f{cr, cg, cb, ca}, SkColor4f{r, g, b, a}};
    SkGradient::Interpolation interpolation;
    // Premultiplied, so a transparent end fades instead of greying.
    interpolation.fInPremul = SkGradient::Interpolation::InPremul::kYes;
    const SkGradient gradient(SkGradient::Colors(SkSpan<const SkColor4f>(colors, 2), SkTileMode::kClamp),
                              interpolation);
    // A unit circle at the centre, stretched so the corners reach the edge.
    const float reach = 1.41421356f;
    const SkMatrix local = SkMatrix::Translate(x + width / 2, y + height / 2) *
                           SkMatrix::Scale(width / 2 * reach, height / 2 * reach);
    SkPaint paint;
    paint.setAntiAlias(true);
    // A gentle gradient spans few 8-bit steps; dithering hides the bands.
    paint.setDither(true);
    paint.setShader(SkShaders::RadialGradient(SkPoint{0, 0}, 1, gradient, &local));
    const SkRect rect = SkRect::MakeXYWH(x, y, width, height);
    if (radius > 0)
        renderer->canvas->drawRoundRect(rect, radius, radius, paint);
    else
        renderer->canvas->drawRect(rect, paint);
}

// Polygons and polygon clips carry at most this many vertices (the retained
// UI's limit).
constexpr size_t kMaxPolygonPoints = 16;

extern "C" void whirlpool_skia_draw_polygon(WhirlpoolSkia *renderer,
                                               const float *points, size_t point_count,
                                               float r, float g, float b, float a) {
    if (!renderer || !renderer->canvas || !points ||
        point_count < 3 || point_count > kMaxPolygonPoints) return;
    SkPoint vertices[kMaxPolygonPoints];
    for (size_t index = 0; index < point_count; ++index)
        vertices[index] = SkPoint::Make(points[index * 2], points[index * 2 + 1]);
    const SkPath path = SkPath::Polygon(
        SkSpan<const SkPoint>(vertices, point_count), true);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    renderer->canvas->drawPath(path, paint);
}

static constexpr size_t kMaxGradientStops = 64;

static float read_float(const uint8_t *bytes) {
    // Little-endian, as the UI encodes it; this is every target we build.
    float value;
    std::memcpy(&value, bytes, sizeof value);
    return value;
}

extern "C" void whirlpool_skia_draw_polygon_gradient(WhirlpoolSkia *renderer,
                                                        const float *points, size_t point_count,
                                                        const uint8_t *gradient, size_t gradient_length,
                                                        float left, float bottom, float opacity) {
    if (!renderer || !renderer->canvas || !points || !gradient ||
        point_count < 3 || point_count > kMaxPolygonPoints) return;
    constexpr size_t header = 4, stride = 20;
    if (gradient_length < header + stride || (gradient_length - header) % stride != 0) return;
    const size_t count = std::min((gradient_length - header) / stride, kMaxGradientStops);
    const float slant = read_float(gradient);
    SkColor4f colors[kMaxGradientStops];
    float xs[kMaxGradientStops];
    for (size_t index = 0; index < count; ++index) {
        const uint8_t *stop = gradient + header + index * stride;
        xs[index] = read_float(stop);
        colors[index] = SkColor4f{read_float(stop + 4), read_float(stop + 8),
                                  read_float(stop + 12), read_float(stop + 16) * opacity};
    }

    SkPoint vertices[kMaxPolygonPoints];
    for (size_t index = 0; index < point_count; ++index)
        vertices[index] = SkPoint::Make(points[index * 2], points[index * 2 + 1]);
    const SkPath path = SkPath::Polygon(SkSpan<const SkPoint>(vertices, point_count), true);
    SkPaint paint;
    paint.setAntiAlias(true);
    const float first = xs[0], last = xs[count - 1];
    if (count == 1 || last - first < 1e-3f) {
        paint.setColor4f(colors[count - 1], nullptr);
        renderer->canvas->drawPath(path, paint);
        return;
    }
    float positions[kMaxGradientStops];
    for (size_t index = 0; index < count; ++index)
        positions[index] = (xs[index] - first) / (last - first);
    SkGradient::Interpolation interpolation;
    // Premultiplied, so a transparent stop fades instead of greying.
    interpolation.fInPremul = SkGradient::Interpolation::InPremul::kYes;
    const SkGradient description(
        SkGradient::Colors(SkSpan<const SkColor4f>(colors, count),
                           SkSpan<const float>(positions, count), SkTileMode::kClamp),
        interpolation);
    // The gradient runs along x in its own space; the local matrix leans it,
    // taking (u, v) to (u + slant * (bottom - v), v), so the colour at the
    // bottom's x holds along a line rising `slant` pixels right per pixel up.
    const SkPoint ends[2] = {SkPoint::Make(left + first, 0), SkPoint::Make(left + last, 0)};
    const SkMatrix lean = SkMatrix::MakeAll(1, -slant, slant * bottom, 0, 1, 0, 0, 0, 1);
    // Gentle gradients span few 8-bit steps; dithering hides the bands.
    paint.setDither(true);
    paint.setShader(SkShaders::LinearGradient(ends, description, &lean));
    renderer->canvas->drawPath(path, paint);
}

struct TextRun {
    const char *start;
    size_t length;
    sk_sp<SkTypeface> typeface;
};

// Split text into runs that each resolve to a single typeface, so glyphs the
// primary font lacks fall back per character.
static std::vector<TextRun> split_text_runs(WhirlpoolSkia *renderer,
                                            const sk_sp<SkTypeface>& typeface,
                                            const char *text, size_t length) {
    std::vector<TextRun> runs;
    const char *end = text + length;
    const char *cursor = text;
    const char *run_start = text;
    sk_sp<SkTypeface> run_typeface;
    while (cursor < end) {
        const char *character_start = cursor;
        const SkUnichar character = next_utf8(&cursor, end);
        auto character_typeface = typeface_for(renderer, typeface, character);
        if (!run_typeface) {
            run_typeface = std::move(character_typeface);
        } else if (character_typeface && character_typeface->uniqueID() != run_typeface->uniqueID()) {
            runs.push_back({run_start, static_cast<size_t>(character_start - run_start), run_typeface});
            run_start = character_start;
            run_typeface = std::move(character_typeface);
        }
    }
    runs.push_back({run_start, static_cast<size_t>(end - run_start), run_typeface});
    return runs;
}

// Shaped text is expensive relative to a bar that repeats the same few strings
// every frame, so the runs (glyph selection and font fallback included), the
// advance width and the cap height are computed once per (text, size) and the
// resulting blobs are redrawn from the cache.
// The typeface for a family name (empty: the default), falling back to the
// default when the font manager knows no such family.
static const sk_sp<SkTypeface>& family_typeface(WhirlpoolSkia *renderer, const char *family,
                                                size_t family_length) {
    if (!family || family_length == 0 || !renderer->font_manager) return renderer->default_typeface;
    std::string name(family, family_length);
    auto found = renderer->families.find(name);
    if (found != renderer->families.end()) return found->second;
    sk_sp<SkTypeface> typeface = renderer->font_manager->matchFamilyStyle(name.c_str(), SkFontStyle());
    if (!typeface) typeface = renderer->default_typeface;
    return renderer->families.emplace(std::move(name), std::move(typeface)).first->second;
}

static const CachedText *cached_text(WhirlpoolSkia *renderer, const char *family, size_t family_length,
                                     const char *text, size_t length, float size) {
    std::string key(reinterpret_cast<const char *>(&size), sizeof(size));
    key.append(family ? family : "", family ? family_length : 0);
    key.push_back('\0');
    key.append(text, length);
    auto found = renderer->text_cache.find(key);
    if (found != renderer->text_cache.end()) return &found->second;
    // A bar with unbounded distinct strings (window titles) must not grow
    // without limit.
    if (renderer->text_cache.size() > 1024) renderer->text_cache.clear();

    const auto& typeface = family_typeface(renderer, family, family_length);
    CachedText entry;
    float cursor = 0;
    for (const auto& run : split_text_runs(renderer, typeface, text, length)) {
        if (!run.typeface || run.length == 0) continue;
        SkFont font(run.typeface, size);
        entry.runs.push_back({SkTextBlob::MakeFromText(run.start, run.length, font,
                                                       SkTextEncoding::kUTF8),
                              cursor});
        cursor += font.measureText(run.start, run.length, SkTextEncoding::kUTF8);
    }
    entry.width = cursor;
    SkFontMetrics metrics;
    SkFont(typeface, size).getMetrics(&metrics);
    entry.cap_height = metrics.fCapHeight > 0 ? metrics.fCapHeight : size * 0.7f;
    return &renderer->text_cache.emplace(std::move(key), std::move(entry)).first->second;
}

// The advance width `whirlpool_skia_draw_text` gives `text` at `size`.
extern "C" float whirlpool_skia_measure_text(WhirlpoolSkia *renderer, const char *family,
                                             size_t family_length, const char *text,
                                             size_t length, float size) {
    if (!renderer || !text || length == 0 || size <= 0 || !renderer->default_typeface) return 0;
    return cached_text(renderer, family, family_length, text, length, size)->width;
}

// How many bytes of `text` (a whole number of characters) fit in `max_width`
// at `size`, with the same font fallback as drawing. Prefixes are not cached:
// layout asks only when a text's box narrows below the text.
extern "C" size_t whirlpool_skia_fit_text(WhirlpoolSkia *renderer, const char *family,
                                          size_t family_length, const char *text,
                                          size_t length, float size, float max_width) {
    if (!renderer || !text || length == 0 || size <= 0 || !renderer->default_typeface) return 0;
    const auto& primary = family_typeface(renderer, family, family_length);
    const char *end = text + length;
    const char *cursor = text;
    float used = 0;
    size_t fitted = 0;
    while (cursor < end) {
        const char *start = cursor;
        const SkUnichar character = next_utf8(&cursor, end);
        auto typeface = typeface_for(renderer, primary, character);
        SkFont font(typeface ? typeface : primary, size);
        used += font.measureText(start, static_cast<size_t>(cursor - start), SkTextEncoding::kUTF8);
        if (used > max_width) break;
        fitted = static_cast<size_t>(cursor - text);
    }
    return fitted;
}

// `anchor`: 0 draws from x, 1 centres on x, 2 ends at x. `middle` treats y as
// the vertical centre of the capital letters instead of the alphabetic
// baseline, so text can be centred in a box without knowing its font metrics.
extern "C" void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *family,
                                          size_t family_length, const char *text,
                                          size_t length, float x, float y, float size,
                                          float r, float g, float b, float a,
                                          int anchor, int middle) {
    if (!renderer || !renderer->canvas || !text || length == 0 || size <= 0) return;
    if (!renderer->default_typeface) return;
    const CachedText *entry = cached_text(renderer, family, family_length, text, length, size);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    if (anchor != 0) x -= anchor == 1 ? entry->width / 2 : entry->width;
    const float baseline = middle ? y + entry->cap_height / 2 : y;
    for (const auto& run : entry->runs)
        renderer->canvas->drawTextBlob(run.blob, x + run.offset, baseline, paint);
}

static bool ends_with_case_insensitive(const std::string& value, const char *suffix) {
    const size_t suffix_length = std::strlen(suffix);
    if (value.size() < suffix_length) return false;
    const size_t start = value.size() - suffix_length;
    for (size_t index = 0; index < suffix_length; ++index) {
        const unsigned char left = static_cast<unsigned char>(value[start + index]);
        const unsigned char right = static_cast<unsigned char>(suffix[index]);
        if (std::tolower(left) != std::tolower(right)) return false;
    }
    return true;
}

// Icons are read and rasterized off the render path. Drawing an icon that is
// not loaded yet asks the icon store for it and draws nothing; the store's
// worker thread decodes it to CPU pixels, then calls the wake of every
// renderer that asked, so its owner renders again. Each renderer wraps ready
// pixels in its own SkImage, on its own thread, the next time it draws one.

// Decoded pixels, premultiplied N32; no data means the icon could not be read.
struct IconPixels {
    sk_sp<SkData> data;
    SkImageInfo info;
    size_t row_bytes = 0;
};

static IconPixels load_svg_icon(const std::string& path) {
    GError *error = nullptr;
    RsvgHandle *handle = rsvg_handle_new_from_file(path.c_str(), &error);
    if (!handle) {
        if (error) g_error_free(error);
        return {};
    }
    constexpr int raster_size = 64;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                           raster_size, raster_size);
    cairo_t *context = cairo_create(surface);
    const RsvgRectangle viewport{0, 0, raster_size, raster_size};
    const gboolean rendered = rsvg_handle_render_document(handle, context, &viewport, &error);
    cairo_destroy(context);
    g_object_unref(handle);
    if (!rendered || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (error) g_error_free(error);
        cairo_surface_destroy(surface);
        return {};
    }
    cairo_surface_flush(surface);
    const size_t stride = static_cast<size_t>(cairo_image_surface_get_stride(surface));
    auto pixels = SkData::MakeWithCopy(cairo_image_surface_get_data(surface),
                                       stride * raster_size);
    cairo_surface_destroy(surface);
    if (error) g_error_free(error);
    if (!pixels) return {};
    return {std::move(pixels), SkImageInfo::MakeN32Premul(raster_size, raster_size), stride};
}

static IconPixels load_icon(const std::string& path) {
    if (ends_with_case_insensitive(path, ".svg") ||
        ends_with_case_insensitive(path, ".svgz"))
        return load_svg_icon(path);
    auto encoded = SkData::MakeFromFileName(path.c_str());
    if (!encoded) return {};
    // Decoded here in full, so drawing never decodes lazily.
    auto image = SkImages::DeferredFromEncodedData(std::move(encoded));
    if (!image || image->width() <= 0 || image->height() <= 0) return {};
    const auto info = SkImageInfo::MakeN32Premul(image->width(), image->height());
    const size_t row_bytes = info.minRowBytes();
    auto pixels = SkData::MakeUninitialized(info.computeByteSize(row_bytes));
    if (!pixels || !image->readPixels(nullptr, info, pixels->writable_data(), row_bytes, 0, 0,
                                      SkImage::kDisallow_CachingHint))
        return {};
    return {std::move(pixels), info, row_bytes};
}

struct IconStore {
    enum class State { pending, ready, failed };
    struct Entry {
        State state = State::pending;
        IconPixels pixels;
        // Renderers that drew the icon while it was pending, to wake.
        std::vector<WhirlpoolSkia *> waiting;
    };
    std::mutex mutex;
    std::condition_variable work;
    std::condition_variable settled;
    std::unordered_map<std::string, Entry> entries;
    std::deque<std::string> queue;
    std::thread worker;
    // A worker runs while `epoch` is the one it started in.
    uint64_t epoch = 0;
    // Requests the worker has taken and not finished.
    size_t loading = 0;
    size_t renderers = 0;
};

// Never destroyed, so no static destructor can run while a renderer lives.
static IconStore& icon_store() {
    static IconStore *store = new IconStore();
    return *store;
}

static void icon_worker(IconStore *store, uint64_t epoch) {
    std::unique_lock<std::mutex> lock(store->mutex);
    for (;;) {
        store->work.wait(lock, [&] { return store->epoch != epoch || !store->queue.empty(); });
        if (store->epoch != epoch) return;
        std::string path = std::move(store->queue.front());
        store->queue.pop_front();
        store->loading++;
        lock.unlock();
        IconPixels pixels = load_icon(path);
        lock.lock();
        store->loading--;
        auto found = store->entries.find(path);
        if (found != store->entries.end() && found->second.state == IconStore::State::pending) {
            auto& entry = found->second;
            entry.state = pixels.data ? IconStore::State::ready : IconStore::State::failed;
            entry.pixels = std::move(pixels);
            // Called under the store's lock, so no renderer can be destroyed
            // meanwhile: a wake must not call back into the store.
            for (auto *renderer : entry.waiting)
                if (renderer->icon_wake) renderer->icon_wake(renderer->icon_wake_context);
            entry.waiting.clear();
        }
        if (store->queue.empty() && store->loading == 0) store->settled.notify_all();
    }
}

static void retain_icons() {
    auto& store = icon_store();
    std::lock_guard<std::mutex> lock(store.mutex);
    store.renderers++;
}

// The last renderer stops the worker; requests still pending are forgotten,
// so a later renderer asks for them afresh.
static void release_icons(WhirlpoolSkia *renderer) {
    auto& store = icon_store();
    std::thread finished;
    {
        std::lock_guard<std::mutex> lock(store.mutex);
        for (auto& [path, entry] : store.entries)
            entry.waiting.erase(std::remove(entry.waiting.begin(), entry.waiting.end(), renderer),
                                entry.waiting.end());
        if (--store.renderers == 0 && store.worker.joinable()) {
            store.epoch++;
            store.work.notify_all();
            finished = std::move(store.worker);
            store.queue.clear();
            for (auto it = store.entries.begin(); it != store.entries.end();)
                it = it->second.state == IconStore::State::pending ? store.entries.erase(it) : std::next(it);
            store.settled.notify_all();
        }
    }
    if (finished.joinable()) finished.join();
}

// The icon at `path` for this renderer, or null while it loads (or if it
// cannot be read). Never reads a file.
static sk_sp<SkImage> icon_image(WhirlpoolSkia *renderer, const std::string& path) {
    auto cached = renderer->icon_cache.find(path);
    if (cached != renderer->icon_cache.end()) return cached->second;
    auto& store = icon_store();
    std::lock_guard<std::mutex> lock(store.mutex);
    auto [found, inserted] = store.entries.try_emplace(path);
    auto& entry = found->second;
    if (entry.state == IconStore::State::pending) {
        if (inserted) {
            store.queue.push_back(path);
            if (!store.worker.joinable()) store.worker = std::thread(icon_worker, &store, store.epoch);
            store.work.notify_one();
        }
        if (std::find(entry.waiting.begin(), entry.waiting.end(), renderer) == entry.waiting.end())
            entry.waiting.push_back(renderer);
        renderer->icons_pending = true;
        return nullptr;
    }
    sk_sp<SkImage> image;
    if (entry.state == IconStore::State::ready)
        image = SkImages::RasterFromData(entry.pixels.info, entry.pixels.data, entry.pixels.row_bytes);
    renderer->icon_cache.emplace(path, image);
    return image;
}

extern "C" void whirlpool_skia_set_icon_wake(WhirlpoolSkia *renderer,
                                               WhirlpoolSkiaIconWake wake, void *context) {
    if (!renderer) return;
    auto& store = icon_store();
    std::lock_guard<std::mutex> lock(store.mutex);
    renderer->icon_wake = wake;
    renderer->icon_wake_context = context;
}

extern "C" int whirlpool_skia_wait_icons(WhirlpoolSkia *renderer) {
    if (!renderer || !renderer->icons_pending) return 0;
    auto& store = icon_store();
    std::unique_lock<std::mutex> lock(store.mutex);
    store.settled.wait(lock, [&] { return store.queue.empty() && store.loading == 0; });
    renderer->icons_pending = false;
    return 1;
}

extern "C" void whirlpool_skia_draw_icon(WhirlpoolSkia *renderer,
                                            const char *source, size_t length,
                                            float x, float y, float width, float height,
                                            float opacity) {
    if (!renderer || !renderer->canvas || !source || length == 0 ||
        width <= 0 || height <= 0 || opacity <= 0) return;
    const auto image = icon_image(renderer, std::string(source, length));
    if (!image || image->width() <= 0 || image->height() <= 0) return;

    const float scale = std::min(width / image->width(), height / image->height());
    const float drawn_width = image->width() * scale;
    const float drawn_height = image->height() * scale;
    const SkRect destination = SkRect::MakeXYWH(
        x + (width - drawn_width) * 0.5f,
        y + (height - drawn_height) * 0.5f,
        drawn_width, drawn_height);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setAlphaf(std::min(1.0f, opacity));
    renderer->canvas->drawImageRect(image, destination,
        SkSamplingOptions(SkFilterMode::kLinear), &paint);
}

extern "C" void whirlpool_skia_push_clip(WhirlpoolSkia *renderer,
                                           float x, float y, float width, float height) {
    if (!renderer || !renderer->canvas) return;
    renderer->canvas->save();
    renderer->canvas->clipRect(SkRect::MakeXYWH(x, y, std::max(0.0f, width), std::max(0.0f, height)));
}

// Like whirlpool_skia_push_clip, but to a polygon (antialiased), so content
// can be cut along a slanted edge.
extern "C" void whirlpool_skia_push_clip_polygon(WhirlpoolSkia *renderer,
                                                   const float *points, size_t point_count) {
    if (!renderer || !renderer->canvas || !points) return;
    renderer->canvas->save();
    if (point_count < 3 || point_count > kMaxPolygonPoints) return;
    SkPoint vertices[kMaxPolygonPoints];
    for (size_t index = 0; index < point_count; ++index)
        vertices[index] = SkPoint::Make(points[index * 2], points[index * 2 + 1]);
    renderer->canvas->clipPath(SkPath::Polygon(SkSpan<const SkPoint>(vertices, point_count), true), true);
}

extern "C" void whirlpool_skia_pop_clip(WhirlpoolSkia *renderer) {
    if (!renderer || !renderer->canvas) return;
    renderer->canvas->restore();
}

extern "C" const uint8_t *whirlpool_skia_end(WhirlpoolSkia *renderer, size_t *row_bytes) {
    if (!renderer || !renderer->surface) return nullptr;
    if (row_bytes) *row_bytes = static_cast<size_t>(renderer->width) * 4;
    renderer->canvas = nullptr;
    return renderer->pixels.data();
}

extern "C" int whirlpool_skia_end_vulkan(
        WhirlpoolSkia *renderer, uint32_t final_layout, uint32_t final_queue_family) {
    if (!renderer || !renderer->gpu_context || !renderer->surface) return 1;
    renderer->canvas = nullptr;
    const auto final_state = skgpu::MutableTextureStates::MakeVulkan(
        static_cast<VkImageLayout>(final_layout), final_queue_family);
    GrFlushInfo flush_info;
    renderer->gpu_context->flush(renderer->surface.get(), flush_info, &final_state);
    // Queue ownership is released to VK_QUEUE_FAMILY_FOREIGN_EXT above, so
    // the compositor observes completion through the DMA-BUF's implicit
    // synchronization. Waiting for the entire Vulkan queue here needlessly
    // serialized every frame on the CPU.
    const bool submitted = renderer->gpu_context->submit(GrSyncCpu::kNo);
    renderer->surface.reset();
    return submitted ? 0 : 1;
}
