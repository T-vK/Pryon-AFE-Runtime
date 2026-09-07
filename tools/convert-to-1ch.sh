#!/bin/sh
set -eu
command -v ffmpeg >/dev/null 2>&1 || {
  echo 'convert-to-1ch: missing dependency: ffmpeg' >&2
  echo '  Linux: sudo apt install ffmpeg' >&2
  echo '  macOS: brew install ffmpeg' >&2
  exit 1
}

# Decode any FFmpeg-supported audio from stdin and write the stream format
# consumed by pryon: mono, signed 16-bit little-endian PCM at 16 kHz.
exec ffmpeg -hide_banner -loglevel error -i pipe:0 -vn \
  -ac 1 -ar 16000 -f s16le pipe:1
