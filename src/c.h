#ifndef DEAD10SEC_C_H
#define DEAD10SEC_C_H

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include "stb_image.h"
#include "stb_truetype.h"

int decode_mp3_memory(const unsigned char *data, size_t size, short **pcm_out, int *channels, int *hz, size_t *sample_count);
void free_mp3_memory(short *pcm);

#endif
