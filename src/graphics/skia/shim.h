#ifndef WHIRLPOOL_SKIA_SHIM_H
#define WHIRLPOOL_SKIA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WhirlpoolSkia WhirlpoolSkia;

WhirlpoolSkia *whirlpool_skia_create(int bgra);
void whirlpool_skia_destroy(WhirlpoolSkia *renderer);
int whirlpool_skia_begin(WhirlpoolSkia *renderer, uint32_t width, uint32_t height);
void whirlpool_skia_clear(WhirlpoolSkia *renderer, float r, float g, float b, float a);
void whirlpool_skia_draw_rect(WhirlpoolSkia *renderer, float x, float y, float width,
                              float height, float r, float g, float b, float a);
void whirlpool_skia_draw_text(WhirlpoolSkia *renderer, const char *text, size_t length,
                              float x, float baseline, float size,
                              float r, float g, float b, float a);
const uint8_t *whirlpool_skia_end(WhirlpoolSkia *renderer, size_t *row_bytes);

#ifdef __cplusplus
}
#endif

#endif
