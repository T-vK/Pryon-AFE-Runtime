#include "../common/audio.h"

#include <algorithm>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>

#define PAR_AFE_CHANNELS 9
#define PAR_AFE_QUANTUM 128
using par_create_afe_fn = void *(*)(const char *);
using par_asp_process_fn = int (*)(void *, const void *, int *, void *, int *, void *, void *, void *);
using par_model_set_new_fn = int (*)(const char *, const char *, const char *);
using par_decoder_new_fn = int (*)(const char *, const char *, const char *);
using par_decoder_push_fn = int (*)(const char *, int64_t, const int16_t *, int, const void *);
using par_decode_callback_fn = void (*)(const char *, void *);
using par_set_decode_callback_fn = int (*)(par_decode_callback_fn, int);

static bool detected;
static void callback(const char *id, void *) { detected = true; std::cout << "DETECTED " << (id ? id : "unknown") << '\n'; }
static void *load(const char *env, const char *real, const char *mock) {
  if (const char *p = std::getenv(env)) return dlopen(p, RTLD_NOW);
  if (void *h = dlopen(real, RTLD_NOW)) return h;
  return dlopen(mock, RTLD_NOW);
}

int main(int argc, char **argv) {
  const char *file = nullptr; bool stdin_mode = false, mic_mode = false;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--file") && i + 1 < argc) file = argv[++i];
    else if (!std::strcmp(argv[i], "--stdin")) stdin_mode = true;
    else if (!std::strcmp(argv[i], "--mic")) mic_mode = true;
    else { std::cerr << "usage: " << argv[0] << " [--file WAV|--stdin]\n"; return 2; }
  }
  if ((file != nullptr) + stdin_mode + mic_mode != 1) { std::cerr << "direct-cpp: choose exactly one of --file, --stdin, or --mic\n"; return 2; }
  void *asp = load("ASP_LIB", "/system/lib/libasp.so", "libasp-mock.so");
  void *pryon = load("PRYON_LIB", "/system/lib/libpryon.so", "libpryon-mock.so");
  auto process = reinterpret_cast<par_asp_process_fn>(dlsym(asp, "asp_process"));
  auto create = reinterpret_cast<par_create_afe_fn>(dlsym(asp, "CreateAFE"));
  auto model = reinterpret_cast<par_model_set_new_fn>(dlsym(pryon, "PryonModelSet_New"));
  auto decoder = reinterpret_cast<par_decoder_new_fn>(dlsym(pryon, "PryonDecoder_NewSimple"));
  auto push = reinterpret_cast<par_decoder_push_fn>(dlsym(pryon, "PryonDecoder_PushAudioEventSamples"));
  auto set_callback = reinterpret_cast<par_set_decode_callback_fn>(dlsym(pryon, "PryonApi_SetDecodeEventCallback"));
  if (!asp || !pryon || !process || !create || !model || !decoder || !push || !set_callback) { std::cerr << "direct-cpp: ABI symbol missing\n"; return 1; }
  par_mono_audio audio{};
  if (file && par_load_wav_mono(file, &audio) != 0) { std::cerr << "direct-cpp: invalid WAV\n"; return 1; }
  const size_t count = file ? ((audio.count + PAR_AFE_QUANTUM - 1) / PAR_AFE_QUANTUM) * PAR_AFE_QUANTUM : 320 * 20;
  int16_t *mono = static_cast<int16_t *>(std::calloc(count, sizeof(int16_t)));
  if (!mono) return 1;
  if (file) std::memcpy(mono, audio.samples, audio.count * sizeof(int16_t));
  FILE *mic = nullptr;
  if (mic_mode) mic = popen("(command -v pw-record >/dev/null 2>&1 && exec pw-record --raw --rate 16000 --channels 1 --format s16 -) || (command -v parec >/dev/null 2>&1 && exec parec --raw --format=s16le --rate=16000 --channels=1) || (command -v arecord >/dev/null 2>&1 && exec arecord -q -D default -f S16_LE -r 16000 -c 1 -t raw)", "r");
  if (stdin_mode || mic_mode) {
    const size_t got = std::fread(mono, sizeof(int16_t), count, mic ? mic : stdin);
    if (got < count) std::memset(mono + got, 0, (count - got) * sizeof(int16_t));
  }
  void *afe = create("AFE.cfg");
  if (!afe || model("pryon_alexa", "pryon.manifest", "") != 0 || decoder("pryon_alexa", "pryon_alexa", "pryon") != 0) return 1;
  set_callback(callback, 1);
  int16_t in[PAR_AFE_QUANTUM * PAR_AFE_CHANNELS], out[PAR_AFE_QUANTUM];
  uint64_t timestamp = 0;
  for (size_t at = 0; at < count; at += PAR_AFE_QUANTUM) {
    int n = static_cast<int>(std::min<size_t>(PAR_AFE_QUANTUM, count - at));
    for (int i = 0; i < PAR_AFE_QUANTUM; ++i) for (int c = 0; c < PAR_AFE_CHANNELS; ++c) in[i * PAR_AFE_CHANNELS + c] = i < n ? mono[at + i] : 0;
    int out_n = PAR_AFE_QUANTUM; if (process(afe, in, &n, out, &out_n, nullptr, nullptr, nullptr) != 0) return 1;
    push("pryon_alexa", static_cast<int64_t>(timestamp), out, out_n, nullptr);
    timestamp += static_cast<uint64_t>(out_n);
  }
  std::free(mono);
  if (mic) pclose(mic);
  par_free_audio(&audio);
  return detected ? 0 : 3;
}
