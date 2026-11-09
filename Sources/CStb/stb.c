// stb_image (MIT / public domain, by Sean Barrett), from llama.cpp's vendor folder: scripts/build-llama.sh copies the
// header into Vendor/linux/stb.
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#include "stb_image.h"
#include "labelit_stb.h"

unsigned char *labelit_stb_load_rgb(const unsigned char *data, int length, int *width, int *height) {
    int channels = 0;
    return stbi_load_from_memory(data, length, width, height, &channels, 3);
}

void labelit_stb_free(void *pixels) { stbi_image_free(pixels); }

const char *labelit_stb_failure(void) { return stbi_failure_reason(); }
