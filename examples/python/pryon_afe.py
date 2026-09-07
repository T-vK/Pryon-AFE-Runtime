#!/usr/bin/env python3
"""Connect a nine-channel audio stream to afe and then pryon."""
import os
import subprocess
import sys


afe = subprocess.Popen(
    [os.getenv("AFE", "./build/afe")],
    stdin=sys.stdin.buffer,
    stdout=subprocess.PIPE,
)
pryon_args = [os.getenv("PRYON", "./build/pryon")]
if os.getenv("PRYON_MODEL_DIR"):
    pryon_args += ["--model-dir", os.environ["PRYON_MODEL_DIR"]]
pryon = subprocess.Popen(
    pryon_args,
    stdin=afe.stdout,
    stdout=sys.stdout.buffer,
)

assert afe.stdout is not None
afe.stdout.close()
afe_rc = afe.wait()
pryon_rc = pryon.wait()
raise SystemExit(pryon_rc or afe_rc)
