#!/usr/bin/env python3
import socket
import sys
import os
import time

socket_path = sys.argv[1]
keep_open = "--keep-open" in sys.argv
activity_path = None
args = []
index = 1
while index < len(sys.argv):
    if sys.argv[index] == "--keep-open":
        index += 1
    elif sys.argv[index] == "--activity-file":
        activity_path = sys.argv[index + 1]
        index += 2
    else:
        args.append(sys.argv[index])
        index += 1
if len(args) == 4:
    socket_path, input_path, start_path, connected_path = args
    input_stream = None
else:
    socket_path = args[0]
    input_path = start_path = connected_path = None
    input_stream = sys.stdin.buffer

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
    channel.connect(socket_path)
    if connected_path:
        open(connected_path, "wb").close()
        while not os.path.exists(start_path):
            time.sleep(0.05)
        input_stream = open(input_path, "rb")
    try:
        while True:
            data = input_stream.read(8192)
            if not data:
                if not keep_open or not input_path:
                    break
                input_stream.close()
                input_stream = open(input_path, "rb")
                continue
            channel.sendall(data)
            if activity_path:
                open(activity_path, "wb").close()
                activity_path = None
    except BrokenPipeError:
        pass
    finally:
        if input_path and input_stream:
            input_stream.close()
