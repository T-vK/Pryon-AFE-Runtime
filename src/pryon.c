#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <signal.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>

#define PERIOD_FRAMES 320

/* This is the profile exercised by the firmware's small /system/app/echod/pryon
 * process. It is intentionally kept separate from the Spotter constructor:
 * the two APIs have different ABI and lifecycle contracts. */
typedef void (*decode_callback_fn)(const char *, const void *);
typedef int (*callback_version_fn)(void);
typedef int (*set_decode_callback_fn)(decode_callback_fn, int);
typedef int (*set_enumerated_callback_fn)(decode_callback_fn);
typedef int (*json_callback_fn)(const char *, const char *, const char *,
                                const char *, int, int);
typedef int (*set_json_callback_fn)(json_callback_fn);
typedef int (*model_set_new_fn)(const char *, const char *, const char *);
typedef int (*model_set_delete_fn)(const char *);
typedef int (*decoder_new_pcm_fn)(const char *, const char *, const char *);
typedef int (*decoder_push_fn)(const char *, int64_t, const int16_t *, int,
                               const void *);
typedef int (*decoder_wait_fn)(const char *, int);
typedef int (*decoder_session_end_fn)(const char *);
typedef int (*decoder_delete_fn)(const char *);

static char g_id[96];
static char g_format[8] = "json";
static int g_dump_events;
static int g_trace;
static int g_enumerated;
static int g_emit_events;
static int g_json_trace;
static int g_include_near_misses;
static int g_json_registered;
static sigjmp_buf g_probe_jump;
static volatile sig_atomic_t g_probe_active;

static void probe_fault(int signal_number) {
  (void)signal_number;
  if (g_probe_active) siglongjmp(g_probe_jump, 1);
  _exit(128 + SIGSEGV);
}

/* Diagnostic-only memory inspection. The callback payload is proprietary and
 * may contain invalid, tagged, or short-lived pointers. Keep the read bounded
 * and recover from SIGSEGV/SIGBUS so tracing cannot kill the decode process. */
static int guarded_copy(void *dst, const void *src, size_t size) {
  struct sigaction old_segv, old_bus, action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = probe_fault;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGSEGV, &action, &old_segv) != 0) return -1;
  if (sigaction(SIGBUS, &action, &old_bus) != 0) {
    sigaction(SIGSEGV, &old_segv, NULL);
    return -1;
  }
  int result = -1;
  g_probe_active = 1;
  if (sigsetjmp(g_probe_jump, 1) == 0) {
    memcpy(dst, src, size);
    result = 0;
  }
  g_probe_active = 0;
  sigaction(SIGBUS, &old_bus, NULL);
  sigaction(SIGSEGV, &old_segv, NULL);
  return result;
}

static int read_full(int fd, void *buffer, size_t size) {
  unsigned char *p = buffer;
  size_t done = 0;
  while (done < size) {
    ssize_t n = read(fd, p + done, size - done);
    if (n == 0) return done == 0 ? 1 : 2;
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    done += (size_t)n;
  }
  return 0;
}

static void lower_copy(char *out, size_t size, const char *in) {
  size_t i = 0;
  for (; in[i] && i + 1 < size; ++i)
    out[i] = (char)tolower((unsigned char)in[i]);
  out[i] = 0;
}

static int join_path(char *out, size_t size, const char *left,
                     const char *right) {
  int n = snprintf(out, size, "%s/%s", left, right);
  return n >= 0 && (size_t)n < size ? 0 : -1;
}

static int is_model_dir(const char *path) {
  char manifest[1024];
  if (join_path(manifest, sizeof(manifest), path, "pryon.manifest") != 0)
    return 0;
  int fd = open(manifest, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  close(fd);
  return 1;
}

static int list_models(const char *root, const char *locale) {
  char path[512];
  if (snprintf(path, sizeof(path), "%s/%s", root, locale) >=
      (int)sizeof(path))
    return 1;
  DIR *dir = opendir(path);
  if (!dir) {
    dir = opendir(root);
    if (!dir) return 1;
    if (snprintf(path, sizeof(path), "%s", root) >= (int)sizeof(path)) {
      closedir(dir);
      return 1;
    }
  }
  struct dirent *entry;
  while ((entry = readdir(dir))) {
    if (entry->d_name[0] == '.') continue;
    char candidate[1024];
    if (join_path(candidate, sizeof(candidate), path, entry->d_name) != 0)
      continue;
    if (!is_model_dir(candidate)) continue;
    char name[96];
    lower_copy(name, sizeof(name), entry->d_name);
    printf("pryon_%s\t%s\n", name, entry->d_name);
  }
  closedir(dir);
  return 0;
}

static int find_model(const char *root, const char *locale, const char *wanted,
                      char *out, size_t size) {
  char name[96];
  lower_copy(name, sizeof(name), wanted);
  if (!strncmp(name, "pryon_", 6))
    memmove(name, name + 6, strlen(name + 6) + 1);

  char path[512];
  if (snprintf(path, sizeof(path), "%s/%s", root, locale) >=
      (int)sizeof(path))
    return -1;
  DIR *dir = opendir(path);
  if (!dir) {
    dir = opendir(root);
    if (!dir) return -1;
    if (snprintf(path, sizeof(path), "%s", root) >= (int)sizeof(path)) {
      closedir(dir);
      return -1;
    }
  }
  struct dirent *entry;
  int found = -1;
  while ((entry = readdir(dir))) {
    if (entry->d_name[0] == '.') continue;
    char candidate_name[96];
    lower_copy(candidate_name, sizeof(candidate_name), entry->d_name);
    if (!strcmp(candidate_name, name) &&
        join_path(out, size, path, entry->d_name) == 0 && is_model_dir(out)) {
      found = 0;
      break;
    }
  }
  closedir(dir);
  return found;
}

static void dump_event(const char *decoder_id, const void *event) {
  unsigned char bytes[96];
  fprintf(stderr, "pryon: callback decoder=%s event=%p",
          decoder_id ? decoder_id : "(null)", event);
  if (event && guarded_copy(bytes, event, sizeof(bytes)) == 0) {
    fputs(" bytes=", stderr);
    for (size_t i = 0; i < 96; ++i) fprintf(stderr, "%02x", bytes[i]);
    fputs(" candidate-pointers=", stderr);
    for (size_t offset = 0; offset + sizeof(uint32_t) <= sizeof(bytes);
         offset += sizeof(uint32_t)) {
      uint32_t value;
      memcpy(&value, bytes + offset, sizeof(value));
      if (value < 0x10000U) continue;
      unsigned char pointed[32];
      if (guarded_copy(pointed, (const void *)(uintptr_t)value,
                       sizeof(pointed)) != 0)
        continue;
      size_t printable = 0;
      while (printable < sizeof(pointed) &&
             pointed[printable] >= 0x20 && pointed[printable] <= 0x7e)
        ++printable;
      if (printable >= 4)
        fprintf(stderr, "@%zu=0x%08x(\"%.*s\")", offset, value,
                (int)printable, pointed);
    }
  } else if (event) {
    fputs(" unreadable", stderr);
  }
  fputc('\n', stderr);
}

static void emit_event(const char *id) {
  if (!id || !*id) id = g_id;
  if (!strcmp(g_format, "text"))
    printf("%s\n", id);
  else
    printf("{\"type\":\"accepted\",\"id\":\"%s\"}\n", id);
  fflush(stdout);
}

static const char *find_mock_library(char *buffer, size_t size) {
  const char *override = getenv("PRYON_MOCK_LIB");
  if (override && *override) return override;
  char executable[PATH_MAX];
  ssize_t length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (length <= 0 || (size_t)length >= sizeof(executable))
    return "/system/lib/libpryon-mock.so";
  executable[length] = 0;
  char *slash = strrchr(executable, '/');
  if (!slash) return "/system/lib/libpryon-mock.so";
  *slash = 0;
  int written = snprintf(buffer, size, "%s/libpryon-mock.so", executable);
  if (written >= 0 && (size_t)written < size && access(buffer, R_OK) == 0)
    return buffer;
  written = snprintf(buffer, size, "%s/../lib/libpryon-mock.so", executable);
  if (written >= 0 && (size_t)written < size && access(buffer, R_OK) == 0)
    return buffer;
  return "/system/lib/libpryon-mock.so";
}

static void event_id_from_name(char *out, size_t size, const char *name) {
  char lower[96];
  lower_copy(lower, sizeof(lower), name);
  if (!strncmp(lower, "pryon_", 6))
    snprintf(out, size, "%s", lower);
  else
    snprintf(out, size, "pryon_%s", lower);
}

static void on_decode(const char *id, const void *event) {
  if (g_dump_events) dump_event(id, event);
  if (g_emit_events && !g_json_registered) {
    emit_event(id);
  }
}

static int on_json(const char *decoder_id, const char *a, const char *b,
                   const char *c, int d, int e) {
  if (g_json_trace)
    fprintf(stderr, "pryon: json decoder=%s a=%s b=%s c=%s d=%d e=%d\n",
            decoder_id ? decoder_id : "(null)", a ? a : "(null)",
            b ? b : "(null)", c ? c : "(null)", d, e);
  if (!c) return 0;

  const char *type = strstr(c, "\"kwDetectionType\":\"Accept\"");
  const char *near_miss = strstr(c, "\"kwDetectionType\":\"NearMiss\"");
  if (!type && !(g_include_near_misses && near_miss)) return 0;

  const char *name_key = strstr(c, "\"kwName\":\"");
  char name[96];
  if (!name_key) return 0;
  name_key += strlen("\"kwName\":\"");
  size_t name_len = strcspn(name_key, "\"");
  if (name_len == 0 || name_len >= sizeof(name)) return 0;
  memcpy(name, name_key, name_len);
  name[name_len] = 0;

  const char *score_key = strstr(c, "\"kwClassificationScore\":");
  double score = 0.0;
  int have_score = 0;
  if (score_key) {
    char *end = NULL;
    const char *number = score_key + strlen("\"kwClassificationScore\":");
    score = strtod(number, &end);
    have_score = end && end != number;
  }

  const char *start_key = strstr(c, "\"kwSampleStartIndex\":");
  const char *end_key = strstr(c, "\"kwSampleEndIndex\":");
  char *number_end = NULL;
  long long start_index = start_key
                              ? strtoll(start_key + strlen("\"kwSampleStartIndex\":"),
                                       &number_end, 10)
                              : 0;
  int have_start = start_key && number_end != start_key + strlen("\"kwSampleStartIndex\":");
  long long end_index = end_key
                            ? strtoll(end_key + strlen("\"kwSampleEndIndex\":"),
                                     &number_end, 10)
                            : 0;
  int have_end = end_key && number_end != end_key + strlen("\"kwSampleEndIndex\":");
  if (!have_score || !have_start || !have_end) {
    fprintf(stderr,
            "pryon: result omitted because validated JSON fields are missing\n");
    return 0;
  }

  char event_id[128];
  event_id_from_name(event_id, sizeof(event_id), name);

  if (near_miss) {
    if (strcmp(g_format, "text")) {
      if (have_score)
        printf("{\"type\":\"near_miss\",\"id\":\"%s\",\"kwDetectionType\":\"NearMiss\",\"kwName\":\"%s\",\"kwClassificationScore\":%.9g,\"kwSampleStartIndex\":%lld,\"kwSampleEndIndex\":%lld}\n",
               event_id, name, score, start_index, end_index);
      fflush(stdout);
    } else {
      printf("%s\n", event_id);
      fflush(stdout);
    }
  } else {
    if (!strcmp(g_format, "text")) {
      printf("%s\n", event_id);
      fflush(stdout);
    } else {
      printf("{\"type\":\"accepted\",\"id\":\"%s\",\"kwDetectionType\":\"Accept\",\"kwName\":\"%s\",\"kwClassificationScore\":%.9g,\"kwSampleStartIndex\":%lld,\"kwSampleEndIndex\":%lld}\n",
             event_id, name, score, start_index, end_index);
      fflush(stdout);
    }
  }
  return 0;
}

static int required_symbol(void *lib, const char *name, void **out) {
  dlerror();
  *out = dlsym(lib, name);
  const char *error = dlerror();
  if (error || !*out) {
    fprintf(stderr, "pryon: required symbol %s is missing%s%s\n", name,
            error ? ": " : "", error ? error : "");
    return -1;
  }
  return 0;
}

static void usage(FILE *out) {
  fprintf(out, "usage: pryon [options]\n");
  fprintf(out, "  --list                         list available models\n");
  fprintf(out, "  --wakeword NAME                model name (default: ALEXA)\n");
  fprintf(out, "  --model-base-path PATH         model base (default: /system/local/models/keyword)\n");
  fprintf(out, "  --model-language LOCALE        model language (default: en-US)\n");
  fprintf(out, "  --model-dir PATH               select one exact model directory\n");
  fprintf(out, "  --format json|text             output format (default: json)\n");
  fprintf(out, "  --lib PATH                     libpryon.so or libpryon-mock.so\n");
  fprintf(out, "  --include-near-misses          include diagnostic NearMiss events\n");
  fprintf(out, "  --mock                         select libpryon-mock.so\n");
  fprintf(out, "  --models-dir/--root PATH       compatibility aliases for --model-base-path\n");
  fprintf(out, "  --locale/--keyword NAME        compatibility aliases\n");
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const char *root = getenv("PRYON_MODELS_DIR");
  if (!root) root = getenv("PRYON_MODEL_ROOT");
  if (!root) root = "/system/local/models/keyword";
  const char *locale = getenv("PRYON_LOCALE");
  if (!locale) locale = "en-US";
  const char *keyword = NULL;
  const char *model_dir = NULL;
  const char *lib_path = NULL;
  int do_list = 0;
  int force_mock = 0;
  int diagnostic_option = 0;

  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--list"))
      do_list = 1;
    else if ((!strcmp(argv[i], "--wakeword") ||
              !strcmp(argv[i], "--keyword") || !strcmp(argv[i], "--id")) &&
             i + 1 < argc)
      keyword = argv[++i];
    else if ((!strcmp(argv[i], "--model-base-path") ||
              !strcmp(argv[i], "--models-dir") || !strcmp(argv[i], "--root")) &&
             i + 1 < argc)
      root = argv[++i];
    else if (!strcmp(argv[i], "--model-dir") && i + 1 < argc)
      model_dir = argv[++i];
    else if ((!strcmp(argv[i], "--model-language") ||
              !strcmp(argv[i], "--locale")) && i + 1 < argc)
      locale = argv[++i];
    else if (!strcmp(argv[i], "--lib") && i + 1 < argc)
      lib_path = argv[++i];
    else if (!strcmp(argv[i], "--format") && i + 1 < argc) {
      snprintf(g_format, sizeof(g_format), "%s", argv[++i]);
      if (strcmp(g_format, "json") && strcmp(g_format, "text")) return 2;
    } else if (!strcmp(argv[i], "--mock"))
      force_mock = 1;
    else if (!strcmp(argv[i], "--include-certainty"))
      diagnostic_option = 1;
    else if (!strcmp(argv[i], "--include-near-misses"))
      g_include_near_misses = 1;
    else if (!strcmp(argv[i], "--help")) {
      usage(stdout);
      return 0;
    } else {
      usage(stderr);
      return 2;
    }
  }
  if (diagnostic_option) {
    fprintf(stderr, "pryon: certainty is not a public field; the validated score and sample fields are always included\n");
    return 2;
  }
  if (do_list) return list_models(root, locale);
  if (!keyword && !model_dir) keyword = "ALEXA";
  if (!keyword) {
    const char *slash = strrchr(model_dir, '/');
    keyword = slash ? slash + 1 : model_dir;
  }
  lower_copy(g_id, sizeof(g_id), keyword);
  if (strncmp(g_id, "pryon_", 6)) {
    char temp[96] = "pryon_";
    size_t prefix = strlen(temp);
    size_t copy = strlen(g_id);
    if (copy > sizeof(temp) - prefix - 1) copy = sizeof(temp) - prefix - 1;
    memcpy(temp + prefix, g_id, copy);
    temp[prefix + copy] = 0;
    memcpy(g_id, temp, strlen(temp) + 1);
  }

  char model[512];
  if (model_dir) {
    if (snprintf(model, sizeof(model), "%s", model_dir) >=
            (int)sizeof(model) ||
        !is_model_dir(model)) {
      fprintf(stderr, "pryon: model directory is invalid: %s\n", model_dir);
      return 1;
    }
  } else if (find_model(root, locale, g_id, model, sizeof(model)) != 0) {
    fprintf(stderr, "pryon: model %s not found below %s/%s\n", keyword, root,
            locale);
    return 1;
  }

  char manifest[512];
  if (join_path(manifest, sizeof(manifest), model, "pryon.manifest") != 0) {
    fprintf(stderr, "pryon: model manifest path is too long: %s\n", model);
    return 1;
  }
  if (chdir(model) != 0)
    fprintf(stderr, "pryon: warning: chdir %s failed: %s\n", model,
            strerror(errno));

  const char *selected = lib_path ? lib_path : getenv("PRYON_LIB");
  char mock_path[PATH_MAX];
  if (force_mock && !lib_path)
    selected = find_mock_library(mock_path, sizeof(mock_path));
  g_emit_events = force_mock || (selected && strstr(selected, "-mock.so"));
  void *lib = selected ? dlopen(selected, RTLD_NOW | RTLD_LOCAL)
                       : dlopen("/system/lib/libpryon.so", RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    const char *error = dlerror();
    fprintf(stderr, "pryon: unable to load selected Pryon library: %s\n",
            error ? error : "unknown dynamic-loader error");
    return 1;
  }

  void *symbol = NULL;
  const char *dump_events = getenv("PRYON_DUMP_EVENTS");
  const char *trace = getenv("PRYON_TRACE");
  const char *json_trace = getenv("PRYON_JSON_TRACE");
  g_dump_events = dump_events && *dump_events;
  g_trace = trace && *trace;
  g_json_trace = json_trace && *json_trace;
  void *version_symbol = NULL;
  if (required_symbol(lib, "PryonApi_GetDecodeEventCallbackVersion",
                      &version_symbol) != 0)
    goto fail;
  callback_version_fn get_version = (callback_version_fn)version_symbol;
  int version = get_version();
  if (version != 1) {
    fprintf(stderr, "pryon: unsupported decode callback version %d\n",
            version);
    goto fail;
  }
  if (!required_symbol(lib, "PryonApi_SetDecodeEventCallback", &symbol)) {
    const char *enumerated = getenv("PRYON_ENUMERATED");
    g_enumerated = enumerated && *enumerated;
    int callback_status;
    if (g_enumerated) {
      void *enumerated_symbol = NULL;
      if (required_symbol(lib, "PryonApi_SetEnumeratedResultCallback",
                          &enumerated_symbol) != 0)
        goto fail;
      set_enumerated_callback_fn set_callback =
          (set_enumerated_callback_fn)enumerated_symbol;
      callback_status = set_callback(on_decode);
    } else {
      set_decode_callback_fn set_callback = (set_decode_callback_fn)symbol;
      callback_status = set_callback(on_decode, 1);
    }
    if (g_trace)
      fprintf(stderr, "pryon: decode callback registration status=%d\n",
              callback_status);
    if (callback_status != 0) {
      fprintf(stderr, "pryon: decode callback registration failed (%d)\n",
              callback_status);
      goto fail;
    }
  } else {
    goto fail;
  }
  {
    dlerror();
    symbol = dlsym(lib, "PryonApi_SetJsondataCallback");
    const char *json_error = dlerror();
    if (!json_error && symbol) {
      set_json_callback_fn set_json = (set_json_callback_fn)symbol;
      int json_status = set_json(on_json);
      g_json_registered = json_status == 0;
      if (g_trace)
        fprintf(stderr, "pryon: JSON callback registration status=%d\n",
                json_status);
      if (json_status != 0) {
        fprintf(stderr, "pryon: JSON callback registration failed (%d)\n",
                json_status);
        goto fail;
      }
    } else if (!g_emit_events) {
      fprintf(stderr,
              "pryon: JSON result callback is unavailable; real wake "
              "events cannot be reported\n");
      goto fail;
    }
  }
  if (required_symbol(lib, "PryonModelSet_New", &symbol) != 0) goto fail;
  model_set_new_fn model_new = (model_set_new_fn)symbol;
  if (required_symbol(lib, "PryonModelSet_Delete", &symbol) != 0) goto fail;
  model_set_delete_fn model_delete = (model_set_delete_fn)symbol;
  if (required_symbol(lib, "PryonDecoder_NewPcmInt16", &symbol) != 0)
    goto fail;
  decoder_new_pcm_fn decoder_new = (decoder_new_pcm_fn)symbol;
  if (required_symbol(lib, "PryonDecoder_PushAudioEventSamples", &symbol) != 0)
    goto fail;
  decoder_push_fn push = (decoder_push_fn)symbol;
  if (required_symbol(lib, "PryonDecoder_BacklogWait", &symbol) != 0)
    goto fail;
  decoder_wait_fn backlog_wait = (decoder_wait_fn)symbol;
  if (required_symbol(lib, "PryonDecoder_SessionEnd", &symbol) != 0)
    goto fail;
  decoder_session_end_fn session_end = (decoder_session_end_fn)symbol;
  if (required_symbol(lib, "PryonDecoder_Delete", &symbol) != 0) goto fail;
  decoder_delete_fn decoder_delete = (decoder_delete_fn)symbol;

  if (model_new(g_id, manifest, "") != 0) {
    fprintf(stderr, "pryon: model-set initialization failed\n");
    goto fail;
  }
  int model_created = 1;
  if (decoder_new(g_id, g_id, "pryon") != 0) {
    fprintf(stderr, "pryon: PCM decoder initialization failed\n");
    model_delete(g_id);
    goto fail;
  }
  int decoder_created = 1;

  int status = 0;
  int16_t frame[PERIOD_FRAMES];
  int64_t timestamp = 0;
  for (;;) {
    int rc = read_full(STDIN_FILENO, frame, sizeof(frame));
    if (rc == 1) break;
    if (rc == 2) {
      fprintf(stderr, "pryon: incomplete PCM period at EOF\n");
      status = 1;
      break;
    }
    if (rc < 0) {
      fprintf(stderr, "pryon: read failed: %s\n", strerror(errno));
      status = 1;
      break;
    }
    if (g_trace)
      fprintf(stderr, "pryon: push timestamp=%lld frames=%d\n",
              (long long)timestamp, PERIOD_FRAMES);
    if (push(g_id, timestamp, frame, PERIOD_FRAMES, NULL) != 0) {
      fprintf(stderr, "pryon: audio push failed\n");
      status = 1;
      break;
    }
    timestamp += PERIOD_FRAMES;
  }
  if (decoder_created) {
    if (g_trace) fprintf(stderr, "pryon: waiting for decoder backlog\n");
    if (backlog_wait(g_id, -1) != 0) status = 1;
    if (g_trace) fprintf(stderr, "pryon: ending decoder session\n");
    if (session_end(g_id) != 0) status = 1;
    if (g_trace) fprintf(stderr, "pryon: draining decoder backlog\n");
    if (backlog_wait(g_id, -1) != 0) status = 1;
    if (g_trace) fprintf(stderr, "pryon: deleting decoder\n");
    if (decoder_delete(g_id) != 0) status = 1;
    if (g_trace) fprintf(stderr, "pryon: decoder deleted\n");
  }
  if (model_created) {
    if (g_trace) fprintf(stderr, "pryon: deleting model set\n");
    if (model_delete(g_id) != 0) status = 1;
    if (g_trace) fprintf(stderr, "pryon: model set deleted\n");
  }
  /* The firmware library owns process-lifetime worker state. Its public
   * decoder/model teardown is complete above; unloading it invokes a Bionic
   * fini path that is not safe outside the stock Android process. */
  return status;

fail:
  dlclose(lib);
  return 1;
}
