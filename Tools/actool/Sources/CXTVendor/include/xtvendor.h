#ifndef XTVENDOR_H
#define XTVENDOR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A bitmap of premultiplied 8-bit pixels in B, G, R, A byte order (CoreUI's 'ARGB'), rows packed.
typedef struct {
    int width;
    int height;
    unsigned char *pixels;
} xt_bitmap;

/// Decodes PNG, JPEG, GIF, BMP or TGA data. Returns 0 on success.
int xt_image_decode(const void *data, size_t length, xt_bitmap *out);

/// Reads the intrinsic size of an SVG document. Returns 0 on success.
int xt_svg_size(const char *data, size_t length, float *width, float *height);

/// Renders an SVG document into a width x height bitmap, scaled by `scale` (or stretched to fit when scale <= 0).
int xt_svg_render(const char *data, size_t length, int width, int height, float scale, xt_bitmap *out);

/// Resamples a bitmap to width x height. Returns 0 on success.
int xt_resize(const xt_bitmap *in, int width, int height, xt_bitmap *out);

/// Encodes a bitmap as an RGBA PNG. Returns 0 on success; free *out with xt_free.
int xt_png_encode(const xt_bitmap *in, unsigned char **out, size_t *out_length);

/// zlib (RFC 1950) compression and decompression. Free the result with xt_free.
unsigned char *xt_zlib_compress(const unsigned char *data, int length, int *out_length);
unsigned char *xt_zlib_decompress(const unsigned char *data, int length, int *out_length);

void xt_free(void *pointer);
void xt_bitmap_free(xt_bitmap *bitmap);

#ifdef __cplusplus
}
#endif

#endif
