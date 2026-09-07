#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "input.wav"
    with wave.open(str(source), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes((b"\x00\x10" * 1600))

    one = subprocess.check_output([str(root / "tools/convert-to-1ch.sh")], input=source.read_bytes())
    if len(one) != 3200:
        raise SystemExit(f"1-channel converter produced {len(one)} bytes")

    nine = subprocess.check_output([str(root / "tools/convert-to-9ch.sh")], input=source.read_bytes())
    if len(nine) != 1600 * 27 or len(nine) % 27:
        raise SystemExit(f"9-channel converter produced {len(nine)} bytes")
    first = [int.from_bytes(nine[offset:offset + 3], "little", signed=True)
             for offset in range(0, 27, 3)]
    if first[:7] != first[0:1] * 7 or first[7:] != [0, 0]:
        raise SystemExit(f"unexpected first 9-channel frame: {first}")
print("converter formats passed")
