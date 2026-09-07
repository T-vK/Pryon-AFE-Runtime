#ifndef PRYON_AFE_EXAMPLE_AUDIO_H
#define PRYON_AFE_EXAMPLE_AUDIO_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  int16_t *samples;
  size_t count;
} par_mono_audio;

#ifdef __cplusplus
extern "C" {
#endif
int par_load_wav_mono(const char *path, par_mono_audio *audio);
void par_free_audio(par_mono_audio *audio);
#ifdef __cplusplus
}
#endif

#endif
