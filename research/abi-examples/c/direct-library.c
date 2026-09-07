#define _GNU_SOURCE
#include "../common/audio.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAR_AFE_CHANNELS 9
#define PAR_AFE_QUANTUM 128
typedef void *(*par_create_afe_fn)(const char *);
typedef int (*par_asp_process_fn)(void *, const void *, int *, void *, int *, void *, void *, void *);
typedef int (*par_model_set_new_fn)(const char *, const char *, const char *);
typedef int (*par_decoder_new_fn)(const char *, const char *, const char *);
typedef int (*par_decoder_push_fn)(const char *, int64_t, const int16_t *, int, const void *);
typedef void (*par_decode_callback_fn)(const char *, void *);
typedef int (*par_set_decode_callback_fn)(par_decode_callback_fn, int);

static int detected;
static void on_detect(const char *id, void *event) {
  (void)event; detected = 1; printf("DETECTED %s\n", id ? id : "unknown");
}

static void *load(const char *env, const char *real, const char *mock) {
  const char *path = getenv(env);
  if (path) return dlopen(path, RTLD_NOW);
  void *h = dlopen(real, RTLD_NOW);
  return h ? h : dlopen(mock, RTLD_NOW);
}

int main(int argc, char **argv) {
  const char *file = NULL;
  int stdin_mode = 0, mic_mode = 0;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--file") && i + 1 < argc) file = argv[++i];
    else if (!strcmp(argv[i], "--stdin")) stdin_mode = 1;
    else if (!strcmp(argv[i], "--mic")) mic_mode = 1;
    else { fprintf(stderr, "usage: %s [--file 16k-mono.wav|--stdin]\n", argv[0]); return 2; }
  }
  if ((file != NULL) + stdin_mode + mic_mode != 1) { fprintf(stderr, "direct-c: choose exactly one of --file, --stdin, or --mic\n"); return 2; }
  void *asp = load("ASP_LIB", "/system/lib/libasp.so", "libasp-mock.so");
  void *pryon = load("PRYON_LIB", "/system/lib/libpryon.so", "libpryon-mock.so");
  if (!asp || !pryon) { fprintf(stderr, "direct-c: set ASP_LIB and PRYON_LIB or provide firmware\n"); return 1; }
  par_asp_process_fn process = (par_asp_process_fn)dlsym(asp, "asp_process");
  par_create_afe_fn create = (par_create_afe_fn)dlsym(asp, "CreateAFE");
  par_model_set_new_fn model_new = (par_model_set_new_fn)dlsym(pryon, "PryonModelSet_New");
  par_decoder_new_fn decoder_new = (par_decoder_new_fn)dlsym(pryon, "PryonDecoder_NewSimple");
  par_decoder_push_fn push = (par_decoder_push_fn)dlsym(pryon, "PryonDecoder_PushAudioEventSamples");
  par_set_decode_callback_fn set_cb = (par_set_decode_callback_fn)dlsym(pryon, "PryonApi_SetDecodeEventCallback");
  if (!process || !create || !model_new || !decoder_new || !push || !set_cb) { fprintf(stderr, "direct-c: ABI symbol missing\n"); return 1; }
  void *afe = create("AFE.cfg");
  model_new("pryon_alexa", "pryon.manifest", ""); decoder_new("pryon_alexa", "pryon_alexa", "pryon"); set_cb(on_detect, 1);
  par_mono_audio audio = {0};
  if (file && par_load_wav_mono(file, &audio) != 0) { fprintf(stderr, "direct-c: invalid WAV\n"); return 1; }
  size_t count = file ? ((audio.count + PAR_AFE_QUANTUM - 1) / PAR_AFE_QUANTUM) * PAR_AFE_QUANTUM : 320 * 20;
  int16_t *mono = calloc(count, sizeof(*mono));
  if (!mono) return 1;
  if (file) memcpy(mono, audio.samples, audio.count * sizeof(*mono));
  FILE *mic = NULL;
  if (mic_mode) mic = popen("(command -v pw-record >/dev/null 2>&1 && exec pw-record --raw --rate 16000 --channels 1 --format s16 -) || (command -v parec >/dev/null 2>&1 && exec parec --raw --format=s16le --rate=16000 --channels=1) || (command -v arecord >/dev/null 2>&1 && exec arecord -q -D default -f S16_LE -r 16000 -c 1 -t raw)", "r");
  if (stdin_mode || mic_mode) {
    size_t got = fread(mono, sizeof(*mono), count, mic ? mic : stdin);
    if (got < count) memset(mono + got, 0, (count - got) * sizeof(*mono));
  }
  int16_t in[PAR_AFE_QUANTUM * PAR_AFE_CHANNELS], out[PAR_AFE_QUANTUM];
  uint64_t ts = 0;
  for (size_t at = 0; at < count; at += PAR_AFE_QUANTUM) {
    int n = (int)((count - at) > PAR_AFE_QUANTUM ? PAR_AFE_QUANTUM : count - at);
    if (n < PAR_AFE_QUANTUM) memset(mono + at + n, 0, (PAR_AFE_QUANTUM - n) * 2);
    for (int i = 0; i < PAR_AFE_QUANTUM; ++i) for (int c = 0; c < PAR_AFE_CHANNELS; ++c) in[i * PAR_AFE_CHANNELS + c] = mono[at + i];
    int out_n = PAR_AFE_QUANTUM;
    if (process(afe, in, &n, out, &out_n, NULL, NULL, NULL) != 0) return 1;
    push("pryon_alexa", (int64_t)ts, out, out_n, NULL); ts += out_n;
  }
  free(mono); par_free_audio(&audio);
  if (mic) pclose(mic);
  return detected ? 0 : 3;
}
