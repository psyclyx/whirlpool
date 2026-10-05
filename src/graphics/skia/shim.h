#ifndef WHIRLPOOL_SKIA_SHIM_H
#define WHIRLPOOL_SKIA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WhirlpoolSkia WhirlpoolSkia;
// Called from another thread when an icon a renderer drew while it was still
// loading is ready: the renderer's owner should draw again. It must not call
// back into the renderer.
typedef void (*WhirlpoolSkiaIconWake)(void *context);

WhirlpoolSkia *whirlpool_skia_create(int bgra);
WhirlpoolSkia *whirlpool_skia_create_vulkan(void *instance, void *physical_device,
                                             void *device, void *queue,
                                             uint32_t queue_family);
void whirlpool_skia_destroy(WhirlpoolSkia *renderer);
int whirlpool_skia_begin(WhirlpoolSkia *renderer, uint32_t width, uint32_t height);
void whirlpool_skia_clear(WhirlpoolSkia *renderer, float r, float g, float b, float a);
void whirlpool_skia_draw_rect(WhirlpoolSkia *renderer, float x, float y, float width,
                              float height, float radius, float r, float g, float b, float a);
// A radial gradient from (cr, cg, cb, ca) at the centre out to (r, g, b, a) at
// the corners, stretched to the rect.
void whirlpool_skia_draw_rect_radial(WhirlpoolSkia *renderer, float x, float y, float width,
                                     float height, float radius, float r, float g, float b, float a,
                                     float cr, float cg, float cb, float ca);
// A polygon filled with a linear gradient: `gradient` holds `gradient_length`
// bytes of little-endian floats, a slant and then x, r, g, b, a per stop
// (increasing x). A stop's x is measured from `left` along the row `bottom`;
// the colour at (x, y) is the gradient's at x - slant * (bottom - y), so
// isolines lean. Every stop's alpha is scaled by `opacity`.
void whirlpool_skia_draw_polygon_gradient(WhirlpoolSkia *renderer, const float *points,
                                          size_t point_count, const uint8_t *gradient,
                                          size_t gradient_length, float left, float bottom,
                                          float opacity);
void whirlpool_skia_draw_polygon(WhirlpoolSkia *renderer, const float *points,
                                 size_t point_count, float r, float g, float b, float a);
// `family` names a font family (length 0: the default typeface).
void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *family, size_t family_length,
                              const char *text, size_t length,
                              float x, float y, float size,
                              float r, float g, float b, float a,
                              int anchor, int middle);
// Draws nothing until the icon has loaded, which happens on a worker thread.
void whirlpool_skia_draw_icon(WhirlpoolSkia *renderer, const char *source, size_t length,
                              float x, float y, float width, float height, float opacity);
void whirlpool_skia_set_icon_wake(WhirlpoolSkia *renderer, WhirlpoolSkiaIconWake wake,
                                  void *context);
// If the last frame met icons still loading, wait until every requested icon
// has loaded and return 1 (draw again to show them); otherwise return 0.
// For offline rendering (tests, previews), never a live render loop.
int whirlpool_skia_wait_icons(WhirlpoolSkia *renderer);
float whirlpool_skia_measure_text(WhirlpoolSkia *renderer, const char *family, size_t family_length,
                                  const char *text, size_t length, float size);
size_t whirlpool_skia_fit_text(WhirlpoolSkia *renderer, const char *family, size_t family_length,
                               const char *text, size_t length, float size, float max_width);
void whirlpool_skia_push_clip(WhirlpoolSkia *renderer, float x, float y, float width, float height);
void whirlpool_skia_push_clip_polygon(WhirlpoolSkia *renderer, const float *points, size_t point_count);
void whirlpool_skia_pop_clip(WhirlpoolSkia *renderer);
const uint8_t *whirlpool_skia_end(WhirlpoolSkia *renderer, size_t *row_bytes);
int whirlpool_skia_begin_vulkan(WhirlpoolSkia *renderer, uint32_t width, uint32_t height,
                                void *image, void *memory, uint64_t memory_size,
                                uint32_t format, uint32_t layout,
                                uint32_t queue_family);
int whirlpool_skia_end_vulkan(WhirlpoolSkia *renderer, uint32_t final_layout,
                              uint32_t final_queue_family);

#ifdef __cplusplus
}
#endif

#endif
