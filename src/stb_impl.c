#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
#define MINIMP3_EXT_IMPLEMENTATION
#include "minimp3_ex.h"

int decode_mp3_memory(const unsigned char *data, size_t size, short **pcm_out, int *channels, int *hz, size_t *sample_count) {
    mp3dec_t mp3d;
    mp3dec_file_info_t info;
    int res = mp3dec_load_buf(&mp3d, data, size, &info, NULL, NULL);
    if (res != 0 || info.buffer == NULL) return -1;
    *pcm_out = info.buffer;
    *channels = info.channels;
    *hz = info.hz;
    *sample_count = info.samples;
    return 0;
}

void free_mp3_memory(short *pcm) {
    free(pcm);
}
