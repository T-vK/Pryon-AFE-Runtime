# Pryon wake-word engine

Pryon is the offline wake-word decoder shipped in compatible Echo firmware.
The `pryon` executable adapts its native callback API to a small stdin/stdout
interface. Audio stays local: after `afe`, mono S16LE is submitted directly to
the firmware decoder. Host mocks produce deterministic accepted events, while
the real JSON-data callback supplies validated accepted results.

## Models

A model directory is identified by `pryon.manifest`. The manifest references
the rest of the model set, including the ONNX runtime graph and configuration
files. In the Biscuit firmware, the Alexa model is under:

```text
/system/local/models/keyword/en-US/ALEXA/
```

The model directory contains the manifest and its referenced artifacts. The
main streaming graph in the examined firmware is:

```text
/system/local/models/keyword/en-US/ALEXA/runtime_stateless_standard.streaming.fixed.int16.onnx
```

Other files in the model set include `pryon.config`, `kw.cfg.json`,
`cmvn.6khz.mat`, pronunciation/FST data, and runtime metadata. The manifest is
the entry point; `cmvn.6khz.mat` is one preprocessing artifact, not the whole
model by itself.

By default, `pryon` uses `/system/local/models/keyword` as the model base,
`en-US` as the language, and `ALEXA` as the wake word. Override these with
`--model-base-path`, `--model-language`, and `--wakeword`. Use an exact
directory with `--model-dir` when needed:

```sh
./pryon --model-dir /system/local/models/keyword/en-US/ALEXA
./pryon --wakeword alexa --model-base-path /system/local/models/keyword
./pryon --list
```

`--models-dir` and `--root` remain accepted aliases for
`--model-base-path`; `--locale` and `--keyword` remain accepted aliases for
the newer option names.

## Decoder lifecycle

The adapter loads `libpryon.so` with `dlopen`, queries
`PryonApi_GetDecodeEventCallbackVersion`, and refuses unknown callback
versions. It registers the versioned decode callback, creates the model set
from the selected `pryon.manifest`, and creates the PCM decoder with
`PryonDecoder_NewPcmInt16`. It submits 320-sample periods and deletes the
decoder and model set on normal and error exits.

This is the simple PCM profile used by the stock `/system/app/echod/pryon`
process. The separate multichannel/enumerated-result profile used through
`libPryonDetector.so` and `libAmazonKWD.so` is documented as an ABI finding,
but is not mixed into the runtime. It has a 144-byte by-value audio-format
argument and a different opaque event structure.

The current callback profile supplies the decoder id. Runtime inspection shows
that the decode callback also carries JSON describing utterance lifecycle
events, including `StartOfUtt`, `StartOfSpeech`, `EndOfSpeech`, and `EndOfUtt`.
Those activity events are not emitted as wake results. The separately
registered JSON-data callback supplies the accepted result and the fields
documented below.
`PRYON_DUMP_EVENTS=1` records raw callback bytes and safely readable candidate
strings to stderr for ABI work; this is intentionally not part of the public
event format.

## Output

Default output is JSON Lines. Every wake result is one complete JSON object:

```json
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

The fields are taken from the firmware JSON result callback. The score and
sample indices are not fabricated; they are emitted only when present in that
callback. `--include-near-misses` enables experimental diagnostic `near_miss`
objects with the same fields when the callback reports that type; no real
near-miss event has been validated yet. A callback dump can be enabled with
`PRYON_DUMP_EVENTS=1`.

`--format text` emits only `pryon_alexa`, which is convenient for small shell
programs. Diagnostics always go to stderr. See [protocol.md](protocol.md) for
buffering, EOF, and error behavior.

## Selecting the library

Use `--lib PATH` or `PRYON_LIB` for a specific library. `--mock` explicitly
selects the deterministic development mock. Without an override, only the
real `/system/lib/libpryon.so` is attempted.
