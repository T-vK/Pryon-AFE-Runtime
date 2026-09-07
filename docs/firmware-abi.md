# Observed firmware ABI

The firmware libraries are stripped ARMv7 Android/Bionic shared objects. These
declarations are hand-maintained observations used through `dlopen` and
`dlsym`; they are not vendor headers.

## Validation status

Static inspection confirms the exports, call sites, model paths, and dependency
tree. Host mocks validate the adapter's ordering, buffering, and cleanup. The
parameterized AFE profile and the simple PCM Pryon profile have been executed
with the supplied Biscuit firmware under ARMv7 system QEMU. QEMU validation
includes real model creation, finite PCM submission, and decoder/model teardown.
The real decode callback is known to run, and guarded runtime inspection has
now confirmed that it contains a readable JSON pointer for utterance lifecycle
events. Observed values include `StartOfUtt`, `StartOfSpeech`, `EndOfSpeech`,
and `EndOfUtt`. These are decoder activity events, not accepted wake results;
the adapter therefore does not expose them as public events. A separate QEMU
probe also called the
preserved `libPryonDetector.so` helper used by
`libAmazonKWD.so`; it created the model set and the stock multichannel decoder
with the firmware's default format and returned successfully from both
decoder and model-set deletion. The default format begins with the observed
values `0, 16000, 16, 1`; the remaining words are intentionally not assigned
names without a header or stronger evidence. Scores, certainty, timestamps,
and near-miss meanings are still not exposed by the decode callback itself.

The separately registered `PryonApi_SetJsondataCallback` is different from
that activity callback. Runtime QEMU testing confirmed JSON containing
`kwDetectionType=Accept`, `kwName=ALEXA`, a varying
`kwClassificationScore`, and sample start/end indices for multiple human
recordings. The adapter exposes those five firmware result fields. Certainty,
timestamps, and real near-miss semantics remain unvalidated.

## `libasp.so`

Observed symbols include:

- `asp_parameterized_init`
- `asp_create_pipeline`
- `asp_process`
- `asp_destroy_pipeline`
- `asp_deinit`
- `_Z9CreateAFEPKc`

The parameterized API is the profile used by this project. The AFE config
describes seven microphones, two speaker references, and a 16 kHz mono ASR
output. The input is nine-channel packed S24_3LE. The lower-level
`AAModuleASP_*` family is also present in the image, but its configuration
object is not safely reconstructable and is not called speculatively.

## `libpryon.so`

The small stock `/system/app/echod/pryon` consumer uses the PCM profile below.
The larger stock consumers also expose a multichannel/enumerated-result
profile, but that profile is not used by this adapter. The adapter keeps the
validated PCM path separate from those calls because the multichannel
constructor carries large by-value structures and the public event contract
is different.
`PryonApi_GetDecodeEventCallbackVersion` returns version 1 in the examined
image.

The validated construction sequence is:

1. `PryonApi_SetDecodeEventCallback(callback, 1)`
2. `PryonModelSet_New(decoder_id, model_manifest, "")`
3. `PryonDecoder_NewPcmInt16(decoder_id, decoder_id, "pryon")`

The adapter then calls
`PryonDecoder_PushAudioEventSamples(decoder_id, timestamp, samples, count,
metadata)` with an `int64_t` timestamp, S16LE samples, a sample count, and a
null metadata pointer. It passes 320-sample periods. This simple profile is
the one that has produced the real callback used by the runtime.

The adapter calls `PryonDecoder_Delete(decoder_id)` and then
`PryonModelSet_Delete(decoder_id)` on normal and error exits after creation.
The public decoder/model teardown is intentionally followed by process exit;
unloading this firmware library with `dlclose` invokes a destructor path that
is safe in the stock Android process but crashes in the minimal QEMU guest.

The decode callback's decoder id is validated. In the examined image, the
opaque event has a pointer at offset `0x04` that resolves to JSON such as
`{"event_name":"StartOfSpeech",...}` and another pointer observed at offset
`0x38` resolves to the string `recognition_id`. The surrounding fields and
their exact ABI are not yet established. Set `PRYON_DUMP_EVENTS=1` to record
bounded raw callback bytes and safely readable candidate strings to stderr.
Those diagnostics are not a public ABI.

## Stock enumerated-result consumer

The extracted `system/lib/libWakeWordManager.so` contains one stock Pryon
adapter. A second, more useful consumer is `system/lib/libAmazonKWD.so`, which
depends on `libPryonDetector.so`. That detector library preserves the helper
symbols and makes the stock constructor sequence easier to inspect:

```text
PryonKeyWordDetector::init()
  PryonApi_SetEnumeratedResultCallback(resultsCallback)
  PryonDetector::createPryonModelAndDecoder(model_path, "pryon", decoder_id, format)
    PryonModelSet_New(model_path, model_path, "pryon")
    PryonDetector::createPryonDecoder(model_path, "pryon", decoder_id, format)
      PryonDecoder_NewMultichannelAudioDecoder(decoder_id, model_path, "pryon", ...)
```

The `PryonMultichannelAudioFormat` passed by the stock code is 144 bytes and
is passed by value on ARM. `libPryonDetector.so` copies that structure before
calling the lower-level decoder constructor. This confirms that the stock
multichannel path is real, but it does not make it safe to substitute into the
small PCM adapter without reproducing all of its arguments and dependent
types.

The preserved callback in both stock consumers is registered after logging
setup and before model/decoder creation. The relevant symbols include:

```text
wwm::Pryon::resultsCallback(const char *, _PryonEnumeratedResult *)
wwm::Pryon::localResultsCallback(const char *, _PryonEnumeratedResult *)
```

Both handlers pass the result to
`wwm::PryonDecoder::setKeywordDetectionInfo(_PryonEnumeratedResult *)`.
The ARM disassembly shows these accesses on the enumerated result object:

| Offset | Access observed | Safe interpretation |
| --- | --- | --- |
| `0x08` | 64-bit copy | Unidentified; copied into stock detection metadata |
| `0x1c` | pointer passed to `strlen` | String, likely the reported keyword name |
| `0x24` | 32-bit value used in a four-way switch | Event-kind value; exact enum names are not confirmed |
| `0x28` | pointer | Auxiliary result data pointer |
| `0x2c` | 32-bit length | Length for the auxiliary result data |
| `0x40` | 64-bit copy | Unidentified; copied into stock detection metadata |

`libAmazonKWD.so` then calls the stock
`notifyKeyWordObservers(..., unsigned long long, unsigned long long, ...,
KWDEventType)` method with the two 64-bit values at offsets `0x08` and
`0x10`. They are carried into stock detection metadata, but the available
symbols and traces do not establish their units or whether they are start/end
times. They are therefore not exposed by this project.

The consumer does not load a floating-point score, certainty, or confidence
value from the enumerated result while building its `KeywordDetected` object.
The stock code does contain logging and metrics strings such as `confidence`,
`kwClassificationScore`, and `NearMiss`; those belong to other internal result
or metrics paths and are not proof that the version-1 decode callback exposes
such a field.

`PryonApi_SetStructuredResultCallback` and `PryonApi_SetJsondataCallback` are
also exported, and `libWakeWordManager.so` contains code for an optional JSON
callback. Their C++ callback objects and complete event contract are separate
from the simple decode callback used here and have not been reconstructed
safely. The runtime therefore does not parse any of these opaque structures.
The `libAmazonKWD.so` callback also reads the result's auxiliary pointer and
length at `0x28`/`0x2c`; those bytes are copied as stock metadata rather than
interpreted as a confidence value.

## Compatibility rules

Do not mix the simple PCM profile with the unvalidated Spotter profile. Unknown
callback versions, missing required symbols, failed callback registration, and
failed lifecycle calls are errors. Run
`tools/internal/validate-firmware.sh` for static checks before invoking a real
library.
