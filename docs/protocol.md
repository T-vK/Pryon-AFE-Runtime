# Process protocol

The public API is deliberately a pair of byte streams. This keeps callers in
Go, Python, Bash, C, and other languages independent of proprietary headers.

The normal use is an audio source piped into `afe`, with its mono output piped
into `pryon`.

## `afe`

stdin is interleaved 9-channel signed 24-bit little-endian PCM at 16 kHz.
Each frame is 27 bytes. Channels 0-6 are microphones; channels 7-8 are
speaker-reference inputs. stdout is mono signed 16-bit little-endian PCM at
16 kHz in exact 320-sample / 640-byte periods.

The process accepts arbitrary OS read boundaries and does its own buffering.
It does not accept WAV headers, channel conversion, resampling, or a short
final public period. A partial 27-byte frame or partial 320-frame period at
EOF is an error. Diagnostics and failures go to stderr; stdout contains audio
only.

## `pryon`

stdin is mono signed 16-bit little-endian PCM at 16 kHz. The process buffers
arbitrary byte boundaries and submits complete 320-sample periods to the
decoder. EOF after a complete period is clean; an incomplete two-byte sample
is an error.

stdout contains one complete JSON object per accepted detection:

```json
{"type":"accepted","id":"pryon_alexa","kwDetectionType":"Accept","kwName":"ALEXA","kwClassificationScore":0.999401,"kwSampleStartIndex":9760,"kwSampleEndIndex":24480}
```

Internal decode/activity callbacks are not emitted as wake events. The real
JSON callback is used when it reports the validated `kwDetectionType=Accept`
result. `certainty` and timestamps are not emitted because their callback
fields have not been validated. `--include-near-misses` is diagnostic and
currently experimental; no real-firmware near-miss event has been validated
yet. `--format text` emits only the id followed by a newline.

`--list` prints `id<TAB>display-name` and does not load the proprietary
library. Defaults are model base `/system/local/models/keyword`, language
`en-US`, and wake word `ALEXA`. Use `--model-base-path`,
`--model-language`, and `--wakeword` to override them. `--model-dir` selects
one exact model directory. `--models-dir`/`--root` and `--locale`/`--keyword`
remain compatibility aliases.

## Library selection

`--lib PATH` takes precedence over the corresponding environment variable
(`ASP_LIB` or `PRYON_LIB`). If neither is provided, the real library at
`/system/lib` is loaded. `--mock` explicitly selects the `-mock.so` library;
there is no automatic fallback from a missing real library.
