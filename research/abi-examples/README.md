# C++ examples

# ABI research examples

These experiments directly load the proprietary libraries through `dlopen` and
`dlsym`, without requiring vendor headers. They are deliberately outside the
product surface: they are not part of the default CMake build, CI artifacts,
installation, or releases.

- `c/direct-library.c`
- `cpp/direct-library.cpp`
- `common/audio.c` and `common/audio.h`

Treat every declaration here as an ABI hypothesis and validate it against the
specific firmware image being investigated.
