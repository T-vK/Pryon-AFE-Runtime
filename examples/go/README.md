# Go examples

`main.go` is the minimal stream example. It connects stdin to `afe`, then
connects `afe` to `pryon`. Input must be nine-channel S24_3LE at 16 kHz.

```sh
go run . < audio.s24
```

The example deliberately leaves audio capture outside the program. This keeps
the input format honest and lets the same code run with an Echo capture,
recorded fixture, or another application-produced stream.
