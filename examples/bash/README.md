# Bash examples

`pryon_afe.sh` is the minimal example. It reads nine-channel S24_3LE audio at
16 kHz from stdin and pipes it through `afe` and `pryon`:

```sh
cat audio.s24_3le | ./build/afe | ./build/pryon
```

Set `AFE`, `PRYON`, and `PRYON_MODEL_DIR` when the binaries or model directory
are somewhere else.

On the tested Echo, `afe` can capture the native array stream itself:

```sh
afe --alsa | pryon --wakeword alexa
```
