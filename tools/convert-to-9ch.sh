#!/bin/sh
set -eu
command -v ffmpeg >/dev/null 2>&1 || {
  echo 'convert-to-9ch: missing dependency: ffmpeg' >&2
  echo '  Linux: sudo apt install ffmpeg' >&2
  echo '  macOS: brew install ffmpeg' >&2
  exit 1
}

INPUT_ARGS='-i pipe:0'
if [ "${1:-}" = --raw-s16le ]; then
  INPUT_ARGS='-f s16le -ar 16000 -ac 1 -i pipe:0'
  shift
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--raw-s16le]" >&2; exit 2; }

# Decode mono audio from stdin and build the native Echo AFE input layout:
# mic channels 0-6 contain the source and speaker-reference channels 7-8 are
# silent. The output is packed signed 24-bit little-endian PCM at 16 kHz.
exec ffmpeg -hide_banner -loglevel error $INPUT_ARGS -vn \
  -filter_complex '[0:a]aresample=16000,aformat=channel_layouts=mono,asplit=7[m0][m1][m2][m3][m4][m5][m6];anullsrc=r=16000:cl=mono[s0];anullsrc=r=16000:cl=mono[s1];[m0][m1][m2][m3][m4][m5][m6][s0][s1]amerge=inputs=9[out]' \
  -map '[out]' -c:a pcm_s24le -f s24le pipe:1
