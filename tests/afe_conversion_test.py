#!/usr/bin/env python3
import struct
import subprocess
import sys


binary = sys.argv[1]
frame = bytearray()
values = [256, 512, 768, 1024, 1280, 1536, 1792, 2048, 2304]
for _ in range(320):
    for value in values:
        frame.extend(int(value << 8).to_bytes(3, "little", signed=True))
output = subprocess.check_output([binary, "--cfg", "test.cfg"], input=bytes(frame))
samples = struct.unpack("<320h", output)
expected = sum(values) // len(values)
if any(sample != expected for sample in samples):
    raise SystemExit(f"AFE conversion mismatch: expected {expected}, got {samples[0]}")
print("AFE conversion passed")
