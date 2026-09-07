# Audio front end (AFE)

The Echo audio front end prepares the microphone array for speech and
wake-word recognition. This project does not reimplement those algorithms; the
`afe` executable is a small stream adapter around the firmware's `libasp.so`.

## Input and output

`afe` accepts interleaved 9-channel S24_3LE at 16 kHz:

| Channels | Meaning |
| --- | --- |
| 0-6 | Seven synchronized microphone signals |
| 7-8 | Speaker-reference / playback-loopback signals |

The two reference channels matter even when no music is playing: they allow
the firmware's acoustic echo canceller to distinguish playback from room
sound. The output is mono signed 16-bit little-endian PCM at 16 kHz, emitted
in exact 320-sample (20 ms) periods.

Input may arrive in arbitrary read sizes. The adapter buffers bytes until it
has complete 27-byte frames and complete public periods. It rejects a partial
frame or partial period at EOF. Internally, the firmware API is called in its
128-frame quanta; those quanta continue across public periods, so no silence
is inserted between calls. Only the final incomplete internal quantum may be
zero-padded, and its padded output is discarded.

## Selecting the library

The lookup order is:

1. `--lib PATH`;
2. `ASP_LIB`;
3. `/system/lib/libasp.so`.

`--mock` explicitly selects `libasp-mock.so`. A missing real library is an
error; the executable never silently changes a production run into a mock
run. The current supported firmware profile is the parameterized ASP API:
`asp_parameterized_init`, `asp_create_pipeline`, `asp_process`,
`asp_destroy_pipeline`, and `asp_deinit`.

## Configuration and failures

The default configuration is
`/system/vendor/etc/audio-algorithms/AFE.cfg`; override it with `--cfg` or
`AFE_CFG`. Loader, ABI, initialization, processing, malformed-input, and
broken-pipe errors go to stderr and produce a non-zero exit status. stdout is
reserved for audio bytes.

See [firmware-abi.md](firmware-abi.md) for the observed declarations and
[protocol.md](protocol.md) for the process contract.
