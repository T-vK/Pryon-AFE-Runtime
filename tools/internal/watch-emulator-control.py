#!/usr/bin/env python3
"""Keep one emulator control connection open and turn trigger files into commands."""
import os
import socket
import sys
import time

if len(sys.argv) not in (3, 4):
    print(f"usage: {sys.argv[0]} SOCKET RESTART_TRIGGER [STOP_TRIGGER]", file=sys.stderr)
    raise SystemExit(2)

socket_path = sys.argv[1]
restart_trigger = sys.argv[2]
stop_trigger = sys.argv[3] if len(sys.argv) == 4 else None
while True:
    try:
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        channel.connect(socket_path)
        break
    except OSError:
        time.sleep(0.05)

with channel:
    while True:
        if stop_trigger and os.path.exists(stop_trigger):
            try:
                os.unlink(stop_trigger)
            except FileNotFoundError:
                continue
            channel.sendall(b"stop\n")
            break
        if os.path.exists(restart_trigger):
            try:
                os.unlink(restart_trigger)
            except FileNotFoundError:
                continue
            channel.sendall(b"restart\n")
        time.sleep(0.02)
