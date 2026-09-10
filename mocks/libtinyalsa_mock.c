#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct pcm { unsigned int card, device, reads, prepares; };
struct pcm_config {
  unsigned int channels, rate, period_size, period_count;
  int format;
  unsigned long start_threshold, stop_threshold, silence_threshold;
  unsigned long silence_size, avail_min;
};

static struct pcm instance;
static const char *last_error = "mock capture error";

struct pcm *pcm_open(unsigned int card, unsigned int device,
                     unsigned int flags, const struct pcm_config *config) {
  (void)flags;
  if (!config || config->channels != 9 || config->rate != 16000 ||
      config->format != 4)
    return NULL;
  memset(&instance, 0, sizeof(instance));
  instance.card = card;
  instance.device = device;
  return &instance;
}

int pcm_is_ready(const struct pcm *pcm) { return pcm == &instance; }
const char *pcm_get_error(const struct pcm *pcm) {
  (void)pcm;
  return last_error;
}

int pcm_read(struct pcm *pcm, void *data, unsigned int count) {
  if (getenv("TINYALSA_MOCK_FAIL_FIRST") && pcm->reads++ == 0) return -1;
  unsigned char *bytes = data;
  for (unsigned int offset = 0; offset + 2 < count; offset += 3) {
    bytes[offset] = 0;
    bytes[offset + 1] = 0;
    bytes[offset + 2] = 0x10;
  }
  return 0;
}

int pcm_prepare(struct pcm *pcm) {
  ++pcm->prepares;
  return 0;
}

int pcm_close(struct pcm *pcm) {
  const char *state = getenv("TINYALSA_MOCK_STATE");
  if (state) {
    FILE *file = fopen(state, "w");
    if (file) {
      fprintf(file, "card=%u device=%u prepare=%u close=1\n", pcm->card,
              pcm->device, pcm->prepares);
      fclose(file);
    }
  }
  return 0;
}
