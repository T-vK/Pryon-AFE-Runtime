#!/usr/bin/env python3
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
    channel.connect(sys.argv[1])
    while True:
        data = sys.stdin.buffer.read(64 * 1024)
        if not data:
            break
        try:
            channel.sendall(data)
        except BrokenPipeError:
            break
