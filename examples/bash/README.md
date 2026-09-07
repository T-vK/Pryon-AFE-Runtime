# Bash examples

`pryon_afe.sh` is the minimal example. It reads nine-channel S24_3LE audio at
16 kHz from stdin and pipes it through `afe` and `pryon`:

```sh
cat audio.s24_3le | ./build/afe | ./build/pryon
```

Set `AFE`, `PRYON`, and `PRYON_MODEL_DIR` when the binaries or model directory
are somewhere else.

The equivalent minimal ALSA command is:

```sh
arecord -q -D "${ALSA_DEVICE:-hw:0,24}" -t raw -f S24_3LE -c 9 -r 16000 | ./build/afe | ./build/pryon
```

On stock Echo firmware, `tinycap` writes WAV rather than raw PCM. Capture it,
then skip the 44-byte header before the same two-process pipeline:

```sh
tinycap /data/local/tmp/capture.wav -D 0 -d 24 -c 9 -r 16000 -b 24 -t 5
```

```sh
dd if=/data/local/tmp/capture.wav bs=1 skip=44 2>/dev/null | /data/local/tmp/afe | /data/local/tmp/pryon
```
