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
#include "core/SkFontMgr.h"
#include "core/SkFontScanner.h"
#include "core/SkData.h"
#include "core/SkImage.h"
#include "core/SkImageInfo.h"
#include "core/SkPaint.h"
#include "core/SkPath.h"
#include "core/SkSamplingOptions.h"
#include "core/SkSurface.h"
#include "gpu/ganesh/GrBackendSurface.h"
#include "gpu/ganesh/GrDirectContext.h"
#include "gpu/ganesh/GrTypes.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/vk/GrVkBackendSurface.h"
#include "gpu/ganesh/vk/GrVkDirectContext.h"
#include "gpu/ganesh/vk/GrVkTypes.h"
#include "gpu/vk/VulkanBackendContext.h"
#include "gpu/vk/VulkanExtensions.h"
#include "gpu/vk/VulkanMutableTextureState.h"
#include "ports/SkFontMgr_empty.h"
#include "ports/SkFontMgr_directory.h"
#include "ports/SkFontMgr_fontconfig.h"
#include "ports/SkFontScanner_FreeType.h"

struct WhirlpoolSkia {
    SkColorType color_type = kBGRA_8888_SkColorType;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels;
    sk_sp<SkSurface> surface;
    SkCanvas *canvas = nullptr;
    sk_sp<SkFontMgr> font_manager;
    sk_sp<GrDirectContext> gpu_context;
    std::unordered_map<std::string, sk_sp<SkImage>> icon_cache;
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
    if (!instance || !physical_device || !device || !queue) return nullptr;
    auto *renderer = new (std::nothrow) WhirlpoolSkia();
    if (!renderer) return nullptr;
    renderer->color_type = kBGRA_8888_SkColorType;
    if (!initialize_fonts(renderer)) {
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

extern "C" void whirlpool_skia_draw_polygon(WhirlpoolSkia *renderer,
                                               const float *points, size_t point_count,
                                               float r, float g, float b, float a) {
    constexpr size_t kMaxPolygonPoints = 16;
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

extern "C" void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *text,
                                          size_t length, float x, float baseline, float size,
                                          float r, float g, float b, float a) {
    if (!renderer || !renderer->canvas || !text || length == 0 || size <= 0) return;
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    auto typeface = renderer->font_manager->legacyMakeTypeface(nullptr, SkFontStyle());
    if (!typeface) return;
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
            x = draw_text_run(renderer, run_start,
                              static_cast<size_t>(character_start - run_start),
                              x, baseline, size, paint, run_typeface);
            run_start = character_start;
            run_typeface = std::move(character_typeface);
        }
    }
    draw_text_run(renderer, run_start, static_cast<size_t>(end - run_start),
                  x, baseline, size, paint, run_typeface);
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
    const bool submitted = renderer->gpu_context->submit(GrSyncCpu::kYes);
    renderer->surface.reset();
    return submitted ? 0 : 1;
}
