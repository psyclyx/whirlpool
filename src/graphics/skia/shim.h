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
void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *text, size_t length,
                              float x, float baseline, float size,
                              float r, float g, float b, float a);
void whirlpool_skia_draw_icon(WhirlpoolSkia *renderer, const char *source, size_t length,
                              float x, float y, float width, float height, float opacity);
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
