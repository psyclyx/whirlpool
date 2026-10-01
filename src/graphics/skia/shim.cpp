#include "shim.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <memory>
#include <cstdlib>
#include <cstdio>
#include <string>
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
#include "core/SkPaint.h"
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
    std::unordered_map<std::string, sk_sp<SkImage>> icon_cache;
    std::unordered_map<std::string, CachedText> text_cache;
};

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
    return renderer;
}

extern "C" void whirlpool_skia_destroy(WhirlpoolSkia *renderer) {
    if (!renderer) return;
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
static const CachedText *cached_text(WhirlpoolSkia *renderer, const char *text,
                                     size_t length, float size) {
    std::string key(reinterpret_cast<const char *>(&size), sizeof(size));
    key.append(text, length);
    auto found = renderer->text_cache.find(key);
    if (found != renderer->text_cache.end()) return &found->second;
    // A bar with unbounded distinct strings (window titles) must not grow
    // without limit.
    if (renderer->text_cache.size() > 1024) renderer->text_cache.clear();

    const auto& typeface = renderer->default_typeface;
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
extern "C" float whirlpool_skia_measure_text(WhirlpoolSkia *renderer, const char *text,
                                             size_t length, float size) {
    if (!renderer || !text || length == 0 || size <= 0 || !renderer->default_typeface) return 0;
    return cached_text(renderer, text, length, size)->width;
}

// How many bytes of `text` (a whole number of characters) fit in `max_width`
// at `size`, with the same font fallback as drawing. Prefixes are not cached:
// layout asks only when a text's box narrows below the text.
extern "C" size_t whirlpool_skia_fit_text(WhirlpoolSkia *renderer, const char *text,
                                          size_t length, float size, float max_width) {
    if (!renderer || !text || length == 0 || size <= 0 || !renderer->default_typeface) return 0;
    const char *end = text + length;
    const char *cursor = text;
    float used = 0;
    size_t fitted = 0;
    while (cursor < end) {
        const char *start = cursor;
        const SkUnichar character = next_utf8(&cursor, end);
        auto typeface = typeface_for(renderer, renderer->default_typeface, character);
        SkFont font(typeface ? typeface : renderer->default_typeface, size);
        used += font.measureText(start, static_cast<size_t>(cursor - start), SkTextEncoding::kUTF8);
        if (used > max_width) break;
        fitted = static_cast<size_t>(cursor - text);
    }
    return fitted;
}

// `anchor`: 0 draws from x, 1 centres on x, 2 ends at x. `middle` treats y as
// the vertical centre of the capital letters instead of the alphabetic
// baseline, so text can be centred in a box without knowing its font metrics.
extern "C" void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *text,
                                          size_t length, float x, float y, float size,
                                          float r, float g, float b, float a,
                                          int anchor, int middle) {
    if (!renderer || !renderer->canvas || !text || length == 0 || size <= 0) return;
    if (!renderer->default_typeface) return;
    const CachedText *entry = cached_text(renderer, text, length, size);
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

static sk_sp<SkImage> load_svg_icon(const std::string& path) {
    GError *error = nullptr;
    RsvgHandle *handle = rsvg_handle_new_from_file(path.c_str(), &error);
    if (!handle) {
        if (error) g_error_free(error);
        return nullptr;
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
        return nullptr;
    }
    cairo_surface_flush(surface);
    const size_t stride = static_cast<size_t>(cairo_image_surface_get_stride(surface));
    auto pixels = SkData::MakeWithCopy(cairo_image_surface_get_data(surface),
                                       stride * raster_size);
    cairo_surface_destroy(surface);
    if (error) g_error_free(error);
    if (!pixels) return nullptr;
    const auto info = SkImageInfo::MakeN32Premul(raster_size, raster_size);
    return SkImages::RasterFromData(info, std::move(pixels), stride);
}

static sk_sp<SkImage> load_icon(const std::string& path) {
    if (ends_with_case_insensitive(path, ".svg") ||
        ends_with_case_insensitive(path, ".svgz"))
        return load_svg_icon(path);
    auto encoded = SkData::MakeFromFileName(path.c_str());
    return encoded ? SkImages::DeferredFromEncodedData(std::move(encoded)) : nullptr;
}

extern "C" void whirlpool_skia_draw_icon(WhirlpoolSkia *renderer,
                                            const char *source, size_t length,
                                            float x, float y, float width, float height,
                                            float opacity) {
    if (!renderer || !renderer->canvas || !source || length == 0 ||
        width <= 0 || height <= 0 || opacity <= 0) return;
    const std::string key(source, length);
    auto found = renderer->icon_cache.find(key);
    if (found == renderer->icon_cache.end())
        found = renderer->icon_cache.emplace(key, load_icon(key)).first;
    const auto& image = found->second;
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
