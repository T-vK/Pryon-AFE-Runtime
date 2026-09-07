#!/usr/bin/env python3
import os
import subprocess
import sys


def run(binary, args, payload, expected):
    env = os.environ.copy()
    proc = subprocess.Popen([binary, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
    for at in range(0, len(payload), 17):
        proc.stdin.write(payload[at:at + 17])
        proc.stdin.flush()
    proc.stdin.close()
    output = proc.stdout.read()
    if proc.wait() != 0 or len(output) != expected:
        raise SystemExit(f"partial stream failed: {binary}: {len(output)} != {expected}")


afe, pryon, root = sys.argv[1:]
afe_input = b"\x01\x00\x00" * (320 * 9)
run(afe, ["--cfg", "test.cfg"], afe_input, 320 * 2)
pryon_input = b"\x01\x00" * (320 * 20)
run(pryon, ["--wakeword", "alexa", "--models-dir", root, "--format", "text"], pryon_input, 0)
print("partial reads passed")
