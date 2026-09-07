#include <stdint.h>
#include <stdlib.h>

#define PAR_AFE_CHANNELS 9

typedef struct { int channels; } mock_afe;

void *CreateAFE(const char *config_path) {
  (void)config_path;
  mock_afe *afe = calloc(1, sizeof(*afe));
  if (afe) afe->channels = PAR_AFE_CHANNELS;
  return afe;
}

void DestroyAFE(void *afe) { free(afe); }

int asp_parameterized_init(const char *config_path) { (void)config_path; return 0; }

void *asp_create_pipeline(int type, int input_format, int input_channels,
                          int input_rate, int output_format, int output_channels,
                          int output_rate) {
  (void)type; (void)input_format; (void)input_rate;
  (void)output_format; (void)output_channels; (void)output_rate;
  mock_afe *afe = calloc(1, sizeof(*afe));
  if (afe) afe->channels = input_channels;
  return afe;
}

int asp_process(void *pipeline, const void *input, int *input_frames,
                void *output, int *output_frames, void *a, void *b, void *c) {
  (void)a; (void)b; (void)c;
  if (!pipeline || !input || !input_frames || !output || !output_frames ||
      *input_frames < 0 || *output_frames < 0) return 1;
  mock_afe *afe = pipeline;
  int count = *input_frames < *output_frames ? *input_frames : *output_frames;
  const int16_t *in = input;
  int16_t *out = output;
  for (int frame = 0; frame < count; ++frame) {
    int64_t sum = 0;
    for (int channel = 0; channel < afe->channels; ++channel)
      sum += in[frame * afe->channels + channel];
    out[frame] = (int16_t)(sum / afe->channels);
  }
  *input_frames = count;
  *output_frames = count;
  return 0;
}

int asp_destroy_pipeline(void *pipeline) { free(pipeline); return 0; }
int asp_deinit(void) { return 0; }
