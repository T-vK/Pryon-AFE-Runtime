#!/usr/bin/env python3
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(sys.argv[1])


def wait_for(path):
    for _ in range(200):
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def test_control(tmp):
    socket_path = tmp / "control.sock"
    restart = tmp / "restart"
    stop = tmp / "stop"
    received = []

    def server():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            listener.listen(1)
            connection, _ = listener.accept()
            with connection:
                received.append(connection.recv(8))
                received.append(connection.recv(8))

    thread = threading.Thread(target=server)
    thread.start()
    wait_for(socket_path)
    process = subprocess.Popen([
        sys.executable,
        str(ROOT / "tools/internal/watch-emulator-control.py"),
        str(socket_path), str(restart), str(stop),
    ])
    restart.touch()
    for _ in range(200):
        if received:
            break
        time.sleep(0.01)
    stop.touch()
    assert process.wait(timeout=5) == 0
    thread.join(timeout=5)
    assert b"".join(received) == b"restart\nstop\n"


def test_audio_bridge(tmp):
    socket_path = tmp / "audio.sock"
    fifo = tmp / "audio.pcm"
    start = tmp / "start"
    connected = tmp / "connected"
    activity = tmp / "activity"
    os.mkfifo(fifo)
    received = bytearray()

    def server():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            listener.listen(1)
            connection, _ = listener.accept()
            with connection:
                received.extend(connection.recv(16))

    thread = threading.Thread(target=server)
    thread.start()
    wait_for(socket_path)
    process = subprocess.Popen([
        sys.executable,
        str(ROOT / "tools/internal/write-unix-socket.py"),
        str(socket_path), str(fifo), str(start), str(connected),
        "--activity-file", str(activity),
    ])
    wait_for(connected)
    start.touch()
    with fifo.open("wb") as stream:
        stream.write(b"audio")
    assert process.wait(timeout=5) == 0
    thread.join(timeout=5)
    wait_for(activity)
    assert received == b"audio"


with tempfile.TemporaryDirectory() as directory:
    test_control(Path(directory))
with tempfile.TemporaryDirectory() as directory:
    test_audio_bridge(Path(directory))
