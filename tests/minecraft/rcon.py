"""Minimal Minecraft RCON client:  python3 rcon.py 'say hi'  (or import and call cmd())."""
import socket
import struct
import sys


def cmd(command, host="127.0.0.1", port=25575, password="shulker"):
    s = socket.create_connection((host, port), timeout=10)

    def send(req_id, kind, body):
        data = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
        s.sendall(struct.pack("<i", len(data)) + data)

    def recv():
        n = struct.unpack("<i", s.recv(4))[0]
        data = b""
        while len(data) < n:
            data += s.recv(n - len(data))
        return struct.unpack("<ii", data[:8])[0], data[8:-2].decode(errors="replace")

    send(1, 3, password)
    if recv()[0] == -1:
        raise RuntimeError("rcon login failed")
    send(2, 2, command)
    out = recv()[1]
    s.close()
    return out


if __name__ == "__main__":
    print(cmd(" ".join(sys.argv[1:])))
