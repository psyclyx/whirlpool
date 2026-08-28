#include "shim.h"

#include <memory>
#include <cstdlib>
#include <cstdio>
#include <vector>

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkColorSpace.h"
#include "core/SkFont.h"
#include "core/SkFontMgr.h"
#include "core/SkFontScanner.h"
#include "core/SkImageInfo.h"
#include "core/SkPaint.h"
#include "core/SkSurface.h"
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
};

static SkImageInfo frame_info(const WhirlpoolSkia *renderer) {
    return SkImageInfo::Make(renderer->width, renderer->height,
                             renderer->color_type, kPremul_SkAlphaType, nullptr);
}

extern "C" WhirlpoolSkia *whirlpool_skia_create(int bgra) {
    auto *renderer = new (std::nothrow) WhirlpoolSkia();
    if (!renderer) return nullptr;
    renderer->color_type = bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType;
    if (const char *font_dir = std::getenv("WHIRLPOOL_FONT_DIR"))
        renderer->font_manager = SkFontMgr_New_Custom_Directory(font_dir);
    if (!renderer->font_manager)
        renderer->font_manager = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    if (!renderer->font_manager)
        renderer->font_manager = SkFontMgr_New_Custom_Empty();
    if (!renderer->font_manager) {
        delete renderer;
        return nullptr;
    }
    return renderer;
}

extern "C" void whirlpool_skia_destroy(WhirlpoolSkia *renderer) {
    if (!renderer) return;
    renderer->canvas = nullptr;
    renderer->surface.reset();
    delete renderer;
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

extern "C" void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *text,
                                          size_t length, float x, float baseline, float size,
                                          float r, float g, float b, float a) {
    if (!renderer || !renderer->canvas || !text || length == 0 || size <= 0) return;
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    auto typeface = renderer->font_manager->legacyMakeTypeface(nullptr, SkFontStyle());
    if (!typeface) return;
    SkFont font(std::move(typeface), size);
    renderer->canvas->drawSimpleText(text, length, SkTextEncoding::kUTF8, x, baseline,
                                     font, paint);
}

extern "C" const uint8_t *whirlpool_skia_end(WhirlpoolSkia *renderer, size_t *row_bytes) {
    if (!renderer || !renderer->surface) return nullptr;
    if (row_bytes) *row_bytes = static_cast<size_t>(renderer->width) * 4;
    renderer->canvas = nullptr;
    return renderer->pixels.data();
}
