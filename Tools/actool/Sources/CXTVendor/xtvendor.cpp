#include "xtvendor.h"

#include <cstdlib>
#include <cstring>
#include <memory>

#include "lunasvg/lunasvg.h"

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_PSD
#define STBI_NO_PIC
#define STBI_NO_PNM
#include "plutovg/plutovg-stb-image.h"

#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "plutovg/plutovg-stb-image-write.h"

#define STB_IMAGE_RESIZE_STATIC
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb/stb_image_resize2.h"

static unsigned char premultiply(unsigned int c, unsigned int a) {
    return (unsigned char)((c * a + 127) / 255);
}

static int alloc_bitmap(xt_bitmap *out, int width, int height) {
    out->width = width;
    out->height = height;
    out->pixels = (unsigned char *)calloc((size_t)width * (size_t)height, 4);
    return out->pixels ? 0 : -1;
}

extern "C" int xt_image_decode(const void *data, size_t length, xt_bitmap *out) {
    int w = 0, h = 0, n = 0;
    unsigned char *rgba = stbi_load_from_memory((const stbi_uc *)data, (int)length, &w, &h, &n, 4);
    if (!rgba) return -1;
    if (alloc_bitmap(out, w, h) != 0) {
        stbi_image_free(rgba);
        return -1;
    }
    size_t count = (size_t)w * (size_t)h;
    for (size_t i = 0; i < count; i++) {
        unsigned int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2], a = rgba[i * 4 + 3];
        out->pixels[i * 4 + 0] = premultiply(b, a);
        out->pixels[i * 4 + 1] = premultiply(g, a);
        out->pixels[i * 4 + 2] = premultiply(r, a);
        out->pixels[i * 4 + 3] = (unsigned char)a;
    }
    stbi_image_free(rgba);
    return 0;
}

extern "C" int xt_svg_size(const char *data, size_t length, float *width, float *height) {
    auto document = lunasvg::Document::loadFromData(data, length);
    if (!document) return -1;
    *width = document->width();
    *height = document->height();
    return 0;
}

extern "C" int xt_svg_render(const char *data, size_t length, int width, int height, float scale, xt_bitmap *out) {
    auto document = lunasvg::Document::loadFromData(data, length);
    if (!document || width <= 0 || height <= 0) return -1;
    lunasvg::Bitmap bitmap(width, height);
    if (bitmap.isNull()) return -1;
    bitmap.clear(0x00000000);
    if (scale > 0) {
        document->render(bitmap, lunasvg::Matrix::scaled(scale, scale));
    } else {
        document->render(bitmap, lunasvg::Matrix::scaled(width / document->width(), height / document->height()));
    }
    if (alloc_bitmap(out, bitmap.width(), bitmap.height()) != 0) return -1;
    // lunasvg bitmaps are premultiplied ARGB32 in native order, which is B, G, R, A in memory on little-endian hosts.
    for (int y = 0; y < bitmap.height(); y++) {
        const unsigned char *src = bitmap.data() + (size_t)y * (size_t)bitmap.stride();
        memcpy(out->pixels + (size_t)y * (size_t)bitmap.width() * 4, src, (size_t)bitmap.width() * 4);
    }
    return 0;
}

extern "C" int xt_resize(const xt_bitmap *in, int width, int height, xt_bitmap *out) {
    if (alloc_bitmap(out, width, height) != 0) return -1;
    void *result = stbir_resize(in->pixels, in->width, in->height, in->width * 4,
                                out->pixels, width, height, width * 4,
                                STBIR_BGRA_PM, STBIR_TYPE_UINT8_SRGB, STBIR_EDGE_CLAMP, STBIR_FILTER_MITCHELL);
    if (!result) {
        xt_bitmap_free(out);
        return -1;
    }
    return 0;
}

extern "C" int xt_png_encode(const xt_bitmap *in, unsigned char **out, size_t *out_length) {
    size_t count = (size_t)in->width * (size_t)in->height;
    unsigned char *rgba = (unsigned char *)malloc(count * 4);
    if (!rgba) return -1;
    for (size_t i = 0; i < count; i++) {
        unsigned int b = in->pixels[i * 4], g = in->pixels[i * 4 + 1], r = in->pixels[i * 4 + 2], a = in->pixels[i * 4 + 3];
        if (a == 0) {
            rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = rgba[i * 4 + 3] = 0;
            continue;
        }
        rgba[i * 4 + 0] = (unsigned char)((r * 255 + a / 2) / a > 255 ? 255 : (r * 255 + a / 2) / a);
        rgba[i * 4 + 1] = (unsigned char)((g * 255 + a / 2) / a > 255 ? 255 : (g * 255 + a / 2) / a);
        rgba[i * 4 + 2] = (unsigned char)((b * 255 + a / 2) / a > 255 ? 255 : (b * 255 + a / 2) / a);
        rgba[i * 4 + 3] = (unsigned char)a;
    }
    int length = 0;
    stbi_write_png_compression_level = 9;
    unsigned char *png = stbi_write_png_to_mem(rgba, in->width * 4, in->width, in->height, 4, &length);
    free(rgba);
    if (!png) return -1;
    *out = png;
    *out_length = (size_t)length;
    return 0;
}

extern "C" unsigned char *xt_zlib_compress(const unsigned char *data, int length, int *out_length) {
    return stbi_zlib_compress((unsigned char *)data, length, out_length, 9);
}

extern "C" unsigned char *xt_zlib_decompress(const unsigned char *data, int length, int *out_length) {
    return (unsigned char *)stbi_zlib_decode_malloc((const char *)data, length, out_length);
}

extern "C" void xt_free(void *pointer) {
    free(pointer);
}

extern "C" void xt_bitmap_free(xt_bitmap *bitmap) {
    free(bitmap->pixels);
    bitmap->pixels = nullptr;
}
