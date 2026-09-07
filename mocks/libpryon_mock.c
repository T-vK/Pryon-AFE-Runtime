#define _GNU_SOURCE

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*par_logging_callback_fn)(int, const char *, const char *);
typedef void (*par_enumerated_callback_fn)(const char *, const void *);
typedef void (*par_decode_callback_fn)(const char *, const void *);
typedef int (*par_json_callback_fn)(const char *, const char *, const char *,
                                    const char *, int, int);

static par_logging_callback_fn logging_callback;
static par_enumerated_callback_fn enumerated_callback;
static par_decode_callback_fn decode_callback;
static par_json_callback_fn json_callback;
static int callbacks_ready;
static int decoder_created;
static int detected;
static unsigned backlog_waits;

static int truthy(const char *name) {
  const char *value = getenv(name);
  return value && (!strcmp(value, "1") || !strcasecmp(value, "true"));
}

int PryonApi_SetLoggingCallback(par_logging_callback_fn callback) {
  logging_callback = callback;
  callbacks_ready = decode_callback || (logging_callback && enumerated_callback);
  return 0;
}

int PryonApi_SetEnumeratedResultCallback(par_enumerated_callback_fn callback) {
  enumerated_callback = callback;
  callbacks_ready = decode_callback || (logging_callback && enumerated_callback);
  return 0;
}

int PryonApi_GetDecodeEventCallbackVersion(void) {
  const char *version = getenv("PRYON_MOCK_CALLBACK_VERSION");
  return version ? atoi(version) : 1;
}

int PryonApi_SetDecodeEventCallback(par_decode_callback_fn callback, int enabled) {
  decode_callback = enabled ? callback : NULL;
  callbacks_ready = decode_callback || (logging_callback && enumerated_callback);
  return 0;
}

int PryonApi_SetJsondataCallback(par_json_callback_fn callback) {
  json_callback = callback;
  return 0;
}

int PryonModelSet_New(const char *id, const char *manifest, const char *options) {
  (void)id;
  (void)manifest;
  (void)options;
  if (truthy("PRYON_MOCK_REQUIRE_CALLBACKS") && !callbacks_ready) return 1;
  return 0;
}

int PryonModelSet_Delete(const char *id) {
  (void)id;
  return 0;
}

int PryonDecoder_NewPcmInt16(const char *id, const char *model_set,
                             const char *name) {
  (void)id;
  (void)model_set;
  (void)name;
  if (truthy("PRYON_MOCK_REQUIRE_CALLBACKS") && !callbacks_ready) return 1;
  decoder_created = 1;
  detected = 0;
  backlog_waits = 0;
  return 0;
}

int PryonDecoder_PushAudioEventSamples(const char *id, int64_t timestamp,
                                       const int16_t *samples, int count,
                                       const void *metadata) {
  (void)metadata;
  if (!decoder_created || !samples || count == 0) return 1;
  double energy = 0.0;
  for (int i = 0; i < count; ++i)
    energy += (double)samples[i] * samples[i];
  double threshold = 1000.0;
  const char *threshold_env = getenv("PRYON_MOCK_RMS_THRESHOLD");
  if (threshold_env) threshold = strtod(threshold_env, NULL);
  int forced = truthy("PRYON_MOCK_FORCE_DETECT");
  int wait_required = truthy("PRYON_MOCK_REQUIRE_BACKLOG");
  if (!detected && callbacks_ready && (!wait_required || backlog_waits > 0) &&
      timestamp >= 320U * 15U &&
      (forced || sqrt(energy / count) >= threshold)) {
    detected = 1;
    if (logging_callback) logging_callback(1, "mock", "accepted detection");
    if (json_callback)
      json_callback(id, id, "pryon_enumerated_result_metadata",
                    "{\"kwDetectionType\":\"Accept\",\"kwName\":\"ALEXA\",\"kwClassificationScore\":0.990000,\"kwSampleStartIndex\":4800,\"kwSampleEndIndex\":5120}",
                    0, 0);
    if (decode_callback) decode_callback(id, NULL);
    if (enumerated_callback) enumerated_callback(id, NULL);
  }
  return 0;
}

int PryonDecoder_BacklogWait(const char *id, int timeout) {
  (void)id;
  (void)timeout;
  ++backlog_waits;
  return 0;
}

int PryonDecoder_SessionEnd(const char *id) {
  (void)id;
  return 0;
}

int PryonDecoder_Delete(const char *id) {
  (void)id;
  decoder_created = 0;
  return 0;
}
