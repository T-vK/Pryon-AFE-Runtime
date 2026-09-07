# Python examples

`pryon_afe.py` is the minimal example. It connects Python subprocesses and
expects nine-channel S24_3LE audio at 16 kHz on stdin.

```sh
cat audio.s24 | python3 pryon_afe.py
```

Set `AFE`, `PRYON`, and `PRYON_MODEL_DIR` to override defaults.
