#include "audio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t u32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

int par_load_wav_mono(const char *path, par_mono_audio *audio) {
  if (!path || !audio) return -1;
  memset(audio, 0, sizeof(*audio));
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  unsigned char header[12];
  if (fread(header, 1, sizeof(header), f) != sizeof(header) ||
      memcmp(header, "RIFF", 4) || memcmp(header + 8, "WAVE", 4)) {
    fclose(f); return -1;
  }
  int fmt_ok = 0, data_ok = 0;
  uint16_t format = 0, channels = 0, bits = 0;
  uint32_t rate = 0, data_size = 0;
  long data_offset = 0;
  while (!data_ok) {
    unsigned char chunk[8];
    if (fread(chunk, 1, sizeof(chunk), f) != sizeof(chunk)) break;
    uint32_t size = u32(chunk + 4);
    if (!memcmp(chunk, "fmt ", 4)) {
      unsigned char fmt[16];
      if (size < 16 || fread(fmt, 1, 16, f) != 16) break;
      if (size > 16 && fseek(f, (long)(size - 16), SEEK_CUR)) break;
      format = u16(fmt); channels = u16(fmt + 2); rate = u32(fmt + 4); bits = u16(fmt + 14);
      fmt_ok = 1;
    } else if (!memcmp(chunk, "data", 4)) {
      data_size = size; data_offset = ftell(f); data_ok = 1;
    } else if (fseek(f, (long)size, SEEK_CUR)) break;
    if (size & 1) fseek(f, 1, SEEK_CUR);
  }
  if (!fmt_ok || !data_ok || format != 1 || channels != 1 || rate != 16000 || bits != 16 || data_size % 2) {
    fclose(f); return -1;
  }
  audio->count = data_size / 2;
  audio->samples = malloc(data_size);
  if (!audio->samples || fseek(f, data_offset, SEEK_SET) || fread(audio->samples, 1, data_size, f) != data_size) {
    par_free_audio(audio); fclose(f); return -1;
  }
  fclose(f); return 0;
}

void par_free_audio(par_mono_audio *audio) {
  if (!audio) return;
  free(audio->samples); audio->samples = NULL; audio->count = 0;
}
