# Mock libraries

The host build produces two deliberately explicit development libraries:

```text
libasp-mock.so
libpryon-mock.so
```

They are not copies of the proprietary libraries and are never installed under
`libasp.so` or `libpryon.so`. This naming prevents a development run from
being mistaken for a real firmware run.

## Selecting mocks

Use an explicit library path or the command-line switch:

```sh
ASP_LIB=build/libasp-mock.so ./build/afe --cfg tests/fixtures/test.cfg
PRYON_LIB=build/libpryon-mock.so \
  PRYON_MODELS_DIR=tests/fixtures/models \
  ./build/pryon --wakeword alexa
```

`--mock` selects the explicitly named mock library. The executable first looks
next to itself, then in a sibling `lib/` directory when installed that way,
and finally at `/system/lib/libasp-mock.so` or
`/system/lib/libpryon-mock.so`. `ASP_MOCK_LIB` and `PRYON_MOCK_LIB` can override
that search. A missing real library never silently selects a mock.

## Deterministic behavior

The ASP mock converts the packed nine-channel input to mono deterministically,
which makes channel order and stream buffering testable. The Pryon mock emits
one deterministic accepted event after enough audio has been submitted when
the RMS threshold is met.

Useful test controls are:

```text
PRYON_MOCK_FORCE_DETECT=1
PRYON_MOCK_RMS_THRESHOLD=1000
PRYON_MOCK_CALLBACK_VERSION=2
```

The last setting intentionally exercises rejection of an unknown callback ABI
version. The mocks are test fixtures, not a promise that arbitrary host audio
will behave like the Echo's proprietary decoder.
