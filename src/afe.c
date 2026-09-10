#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_RATE 16000
#define PERIOD_FRAMES 320
#define CHANNELS 9
#define QUANTUM_FRAMES 128
#define INPUT_FRAME_BYTES (CHANNELS * 3)
#define INPUT_PERIOD_BYTES (PERIOD_FRAMES * INPUT_FRAME_BYTES)
#define OUTPUT_PERIOD_BYTES (PERIOD_FRAMES * sizeof(int16_t))
#define PIPELINE_ASR 0
#define PCM_S16 1
#define QUEUE_FRAMES (PERIOD_FRAMES * 2 + QUANTUM_FRAMES)
#define PCM_IN 0x10000000U
#define PCM_FORMAT_S24_3LE 4
#define PCM_PERIOD_FRAMES 256

struct pcm;
struct pcm_config {
  unsigned int channels, rate, period_size, period_count;
  int format;
  unsigned long start_threshold, stop_threshold, silence_threshold;
  unsigned long silence_size, avail_min;
};

typedef struct pcm *(*pcm_open_fn)(unsigned int, unsigned int, unsigned int,
                                   const struct pcm_config *);
typedef int (*pcm_ready_fn)(const struct pcm *);
typedef const char *(*pcm_error_fn)(const struct pcm *);
typedef int (*pcm_read_fn)(struct pcm *, void *, unsigned int);
typedef int (*pcm_prepare_fn)(struct pcm *);
typedef int (*pcm_close_fn)(struct pcm *);

typedef int (*asp_init_fn)(const char *);
typedef void *(*asp_create_fn)(int, int, int, int, int, int, int);
typedef int (*asp_process_fn)(void *, const void *, int *, void *, int *, void *, void *, void *);
typedef int (*asp_destroy_fn)(void *);
typedef int (*asp_deinit_fn)(void);

static struct pcm *g_pcm;
static pcm_read_fn g_pcm_read;
static pcm_error_fn g_pcm_error;
static pcm_prepare_fn g_pcm_prepare;

static ssize_t source_read(void *buffer, size_t size) {
  if (!g_pcm) {
    ssize_t n;
    do n = read(STDIN_FILENO, buffer, size);
    while (n < 0 && errno == EINTR);
    return n;
  }
  if (size > PCM_PERIOD_FRAMES * INPUT_FRAME_BYTES)
    size = PCM_PERIOD_FRAMES * INPUT_FRAME_BYTES;
  int rc = g_pcm_read(g_pcm, buffer, (unsigned int)size);
  if (rc != 0) {
    const char *error = g_pcm_error ? g_pcm_error(g_pcm) : "unknown error";
    if (g_pcm_prepare && g_pcm_prepare(g_pcm) == 0 &&
        g_pcm_read(g_pcm, buffer, (unsigned int)size) == 0)
      return (ssize_t)size;
    fprintf(stderr, "afe: ALSA capture failed: %s\n", error);
    return -1;
  }
  return (ssize_t)size;
}

static const char *find_mock_library(char *buffer, size_t size) {
  const char *override = getenv("ASP_MOCK_LIB");
  if (override && *override) return override;
  char executable[PATH_MAX];
  ssize_t length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (length <= 0 || (size_t)length >= sizeof(executable))
    return "/system/lib/libasp-mock.so";
  executable[length] = 0;
  char *slash = strrchr(executable, '/');
  if (!slash) return "/system/lib/libasp-mock.so";
  *slash = 0;
  int written = snprintf(buffer, size, "%s/libasp-mock.so", executable);
  if (written >= 0 && (size_t)written < size && access(buffer, R_OK) == 0)
    return buffer;
  written = snprintf(buffer, size, "%s/../lib/libasp-mock.so", executable);
  if (written >= 0 && (size_t)written < size && access(buffer, R_OK) == 0)
    return buffer;
  return "/system/lib/libasp-mock.so";
}

static void *open_library(const char *explicit_path, const char *env_name,
                          const char *real_path, const char *mock_path,
                          int force_mock) {
  const char *path = explicit_path;
  if (!path) path = force_mock ? mock_path : getenv(env_name);
  if (path) return dlopen(path, RTLD_NOW | RTLD_LOCAL);
  return dlopen(real_path, RTLD_NOW | RTLD_LOCAL);
}

static const char *loader_error(void) {
  const char *error = dlerror();
  return error ? error : "unknown dynamic-loader error";
}

static int write_full(const void *buffer, size_t size) {
  const unsigned char *p = buffer;
  while (size) {
    ssize_t n = write(STDOUT_FILENO, p, size);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    p += (size_t)n;
    size -= (size_t)n;
  }
  return 0;
}

static void signal_ready(void) {
  const char *path = getenv("AFE_READY_FILE");
  if (!path || !*path) return;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd >= 0) close(fd);
}

static int16_t s24_to_s16(const unsigned char *p) {
  int32_t value = (int32_t)p[0] | ((int32_t)p[1] << 8) | ((int32_t)p[2] << 16);
  if (value & 0x800000) value |= (int32_t)0xff000000;
  return (int16_t)(value >> 8);
}

static void usage(FILE *out) {
  fprintf(out, "usage: afe [--alsa [--card N] [--device N]] [--cfg PATH] [--lib PATH] [--mock]\n");
  fprintf(out, "  --alsa  capture from ALSA instead of stdin (default card 0, device 24)\n");
  fprintf(out, "  --card N                      ALSA card (default: 0)\n");
  fprintf(out, "  --device N                    ALSA device (default: 24)\n");
  fprintf(out, "  --cfg PATH                    AFE.cfg path (default: /system/vendor/etc/audio-algorithms/AFE.cfg)\n");
  fprintf(out, "  --lib PATH                    libasp.so or libasp-mock.so\n");
  fprintf(out, "  --mock                        explicitly use libasp-mock.so\n");
  fprintf(out, "  stdin:  9-channel S24_3LE, 16 kHz\n");
  fprintf(out, "  stdout: mono S16LE, 16 kHz, 320-sample periods\n");
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const char *cfg = getenv("AFE_CFG");
  if (!cfg) cfg = "/system/vendor/etc/audio-algorithms/AFE.cfg";
  const char *lib_path = NULL;
  int force_mock = 0;
  int use_alsa = 0;
  int card_specified = 0, device_specified = 0;
  unsigned int alsa_card = 0, alsa_device = 24;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--cfg") && i + 1 < argc) cfg = argv[++i];
    else if (!strcmp(argv[i], "--lib") && i + 1 < argc) lib_path = argv[++i];
    else if (!strcmp(argv[i], "--mock")) force_mock = 1;
    else if (!strcmp(argv[i], "--alsa")) use_alsa = 1;
    else if (!strcmp(argv[i], "--card") && i + 1 < argc) {
      char *end = NULL;
      unsigned long value = strtoul(argv[++i], &end, 10);
      if (!end || *end || value > UINT_MAX) { usage(stderr); return 2; }
      alsa_card = (unsigned int)value;
      card_specified = 1;
    } else if (!strcmp(argv[i], "--device") && i + 1 < argc) {
      char *end = NULL;
      unsigned long value = strtoul(argv[++i], &end, 10);
      if (!end || *end || value > UINT_MAX) { usage(stderr); return 2; }
      alsa_device = (unsigned int)value;
      device_specified = 1;
    }
    else if (!strcmp(argv[i], "--help")) { usage(stdout); return 0; }
    else { usage(stderr); return 2; }
  }
  if ((card_specified || device_specified) && !use_alsa) {
    fprintf(stderr, "afe: --card and --device require --alsa\n");
    return 2;
  }

  char mock_path[PATH_MAX];
  const char *selected_mock = find_mock_library(mock_path, sizeof(mock_path));
  void *lib = open_library(lib_path, "ASP_LIB", "/system/lib/libasp.so",
                           selected_mock, force_mock);
  if (!lib) {
    fprintf(stderr, "afe: unable to load %s: %s\n",
            force_mock ? "libasp-mock.so" : "libasp.so", loader_error());
    return 1;
  }
  asp_init_fn init = (asp_init_fn)dlsym(lib, "asp_parameterized_init");
  asp_create_fn create = (asp_create_fn)dlsym(lib, "asp_create_pipeline");
  asp_process_fn process = (asp_process_fn)dlsym(lib, "asp_process");
  asp_destroy_fn destroy = (asp_destroy_fn)dlsym(lib, "asp_destroy_pipeline");
  asp_deinit_fn deinit = (asp_deinit_fn)dlsym(lib, "asp_deinit");
  if (!init || !create || !process || !destroy) {
    fprintf(stderr, "afe: unsupported parameterized ASP ABI (required symbols missing)\n");
    dlclose(lib);
    return 1;
  }

  int status = 1;
  void *pipeline = NULL;
  int initialized = 0;
  unsigned char input[INPUT_PERIOD_BYTES * 2];
  size_t input_bytes = 0;
  int16_t input_queue[QUEUE_FRAMES * CHANNELS];
  int16_t output_queue[QUEUE_FRAMES];
  int16_t quantum_in[QUANTUM_FRAMES * CHANNELS];
  int16_t quantum_out[QUANTUM_FRAMES];
  size_t input_frames = 0, output_frames = 0;

  void *tinyalsa = NULL;
  pcm_close_fn pcm_close = NULL;

  int rc = init(cfg);
  if (rc != 0) {
    fprintf(stderr, "afe: asp_parameterized_init(%s) = %d\n", cfg, rc);
    goto cleanup;
  }
  initialized = 1;
  pipeline = create(PIPELINE_ASR, PCM_S16, CHANNELS, SAMPLE_RATE,
                    PCM_S16, 1, SAMPLE_RATE);
  if (!pipeline) {
    fprintf(stderr, "afe: ASP pipeline creation failed\n");
    goto cleanup;
  }
  if (use_alsa) {
    const char *tinyalsa_path = getenv("TINYALSA_LIB");
    if (!tinyalsa_path || !*tinyalsa_path) tinyalsa_path = "/system/lib/libtinyalsa.so";
    tinyalsa = dlopen(tinyalsa_path, RTLD_NOW | RTLD_LOCAL);
    if (!tinyalsa) {
      fprintf(stderr, "afe: --alsa requires libtinyalsa.so (%s): %s\n",
              tinyalsa_path, loader_error());
      goto cleanup;
    }
    pcm_open_fn pcm_open = (pcm_open_fn)dlsym(tinyalsa, "pcm_open");
    pcm_ready_fn pcm_ready = (pcm_ready_fn)dlsym(tinyalsa, "pcm_is_ready");
    g_pcm_error = (pcm_error_fn)dlsym(tinyalsa, "pcm_get_error");
    g_pcm_read = (pcm_read_fn)dlsym(tinyalsa, "pcm_read");
    g_pcm_prepare = (pcm_prepare_fn)dlsym(tinyalsa, "pcm_prepare");
    pcm_close = (pcm_close_fn)dlsym(tinyalsa, "pcm_close");
    if (!pcm_open || !pcm_ready || !g_pcm_error || !g_pcm_read || !pcm_close) {
      fprintf(stderr, "afe: libtinyalsa.so is missing required PCM symbols\n");
      goto cleanup;
    }
    struct pcm_config pcm_config = {
        CHANNELS, SAMPLE_RATE, PCM_PERIOD_FRAMES, 4, PCM_FORMAT_S24_3LE,
        0, 0, 0, 0, 0};
    g_pcm = pcm_open(alsa_card, alsa_device, PCM_IN, &pcm_config);
    if (!g_pcm || !pcm_ready(g_pcm)) {
      fprintf(stderr, "afe: cannot open ALSA card %u device %u: %s\n",
              alsa_card, alsa_device,
              g_pcm && g_pcm_error ? g_pcm_error(g_pcm) : "device unavailable");
      goto cleanup;
    }
  }
  signal_ready();

  for (;;) {
    ssize_t n = source_read(input + input_bytes, sizeof(input) - input_bytes);
    if (n < 0) { fprintf(stderr, "afe: read: %s\n", strerror(errno)); goto cleanup; }
    if (n == 0) break;
    input_bytes += (size_t)n;
    while (input_bytes >= INPUT_PERIOD_BYTES) {
      for (int frame = 0; frame < PERIOD_FRAMES; ++frame)
        for (int channel = 0; channel < CHANNELS; ++channel)
          input_queue[(input_frames + (size_t)frame) * CHANNELS + channel] =
              s24_to_s16(input + (frame * CHANNELS + channel) * 3);
      input_frames += PERIOD_FRAMES;
      input_bytes -= INPUT_PERIOD_BYTES;
      if (input_bytes) memmove(input, input + INPUT_PERIOD_BYTES, input_bytes);

      while (input_frames >= QUANTUM_FRAMES) {
        memcpy(quantum_in, input_queue, sizeof(quantum_in));
        memmove(input_queue, input_queue + QUANTUM_FRAMES * CHANNELS,
                (input_frames - QUANTUM_FRAMES) * CHANNELS * sizeof(int16_t));
        input_frames -= QUANTUM_FRAMES;
        int in_frames = QUANTUM_FRAMES, out_frames = QUANTUM_FRAMES;
        if (process(pipeline, quantum_in, &in_frames, quantum_out, &out_frames,
                    NULL, NULL, NULL) != 0 || out_frames < 0 || out_frames > QUANTUM_FRAMES ||
            output_frames + (size_t)out_frames > QUEUE_FRAMES) {
          fprintf(stderr, "afe: asp_process failed or returned invalid frame count\n");
          goto cleanup;
        }
        memcpy(output_queue + output_frames, quantum_out,
               (size_t)out_frames * sizeof(int16_t));
        output_frames += (size_t)out_frames;
        while (output_frames >= PERIOD_FRAMES) {
          if (write_full(output_queue, OUTPUT_PERIOD_BYTES) != 0) goto cleanup;
          output_frames -= PERIOD_FRAMES;
          if (output_frames) memmove(output_queue, output_queue + PERIOD_FRAMES,
                                     output_frames * sizeof(int16_t));
        }
      }
    }
  }

  if (input_bytes != 0) {
    fprintf(stderr, "afe: incomplete input frame or public period at EOF\n");
    goto cleanup;
  }
  if (input_frames != 0) {
    size_t valid = input_frames;
    memset(input_queue + input_frames * CHANNELS, 0,
           (QUANTUM_FRAMES - valid) * CHANNELS * sizeof(int16_t));
    int in_frames = QUANTUM_FRAMES, out_frames = QUANTUM_FRAMES;
    if (process(pipeline, input_queue, &in_frames, quantum_out, &out_frames,
                NULL, NULL, NULL) != 0 || out_frames < 0 || out_frames > QUANTUM_FRAMES) {
      fprintf(stderr, "afe: final asp_process failed or returned invalid frame count\n");
      goto cleanup;
    }
    if ((size_t)out_frames > valid) out_frames = (int)valid;
    memcpy(output_queue + output_frames, quantum_out, (size_t)out_frames * sizeof(int16_t));
    output_frames += (size_t)out_frames;
    while (output_frames >= PERIOD_FRAMES) {
      if (write_full(output_queue, OUTPUT_PERIOD_BYTES) != 0) goto cleanup;
      output_frames -= PERIOD_FRAMES;
      if (output_frames) memmove(output_queue, output_queue + PERIOD_FRAMES,
                                 output_frames * sizeof(int16_t));
    }
  }
  if (output_frames != 0) {
    fprintf(stderr, "afe: ASP produced a partial public period (%zu samples)\n", output_frames);
    goto cleanup;
  }
  status = 0;

cleanup:
  if (g_pcm && pcm_close) (void)pcm_close(g_pcm);
  g_pcm = NULL;
  g_pcm_read = NULL;
  g_pcm_error = NULL;
  g_pcm_prepare = NULL;
  if (tinyalsa) dlclose(tinyalsa);
  if (pipeline) (void)destroy(pipeline);
  if (initialized && deinit) (void)deinit();
  dlclose(lib);
  return status;
}
