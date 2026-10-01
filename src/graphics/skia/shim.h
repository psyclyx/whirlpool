#ifndef WHIRLPOOL_SKIA_SHIM_H
#define WHIRLPOOL_SKIA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WhirlpoolSkia WhirlpoolSkia;

WhirlpoolSkia *whirlpool_skia_create(int bgra);
WhirlpoolSkia *whirlpool_skia_create_vulkan(void *instance, void *physical_device,
                                             void *device, void *queue,
                                             uint32_t queue_family);
void whirlpool_skia_destroy(WhirlpoolSkia *renderer);
int whirlpool_skia_begin(WhirlpoolSkia *renderer, uint32_t width, uint32_t height);
void whirlpool_skia_clear(WhirlpoolSkia *renderer, float r, float g, float b, float a);
void whirlpool_skia_draw_rect(WhirlpoolSkia *renderer, float x, float y, float width,
                              float height, float radius, float r, float g, float b, float a);
void whirlpool_skia_draw_polygon(WhirlpoolSkia *renderer, const float *points,
                                 size_t point_count, float r, float g, float b, float a);
// `family` names a font family (length 0: the default typeface).
void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *family, size_t family_length,
                              const char *text, size_t length,
                              float x, float y, float size,
                              float r, float g, float b, float a,
                              int anchor, int middle);
void whirlpool_skia_draw_icon(WhirlpoolSkia *renderer, const char *source, size_t length,
                              float x, float y, float width, float height, float opacity);
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
