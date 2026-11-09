// stb_image behind LabelIt's own names. The implementation is compiled with STB_IMAGE_STATIC (stb.c), so it can't
// clash with the copy inside llama.cpp's mtmd.
#ifndef LABELIT_STB_H
#define LABELIT_STB_H

/// Decodes a JPEG, PNG, GIF or BMP in memory to packed 8-bit RGB. Free the result with labelit_stb_free.
unsigned char *labelit_stb_load_rgb(const unsigned char *data, int length, int *width, int *height);
void labelit_stb_free(void *pixels);
const char *labelit_stb_failure(void);

#endif
