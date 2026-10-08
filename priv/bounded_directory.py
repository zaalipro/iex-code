"""Invocation-scoped directory names only, with one packet outstanding.

Two-byte network framing. L requests carry name/wire allowances and path bytes.
N names require A acknowledgement before advancing scandir. C/I/E terminal
packets carry yielded count, helper peak RSS bytes and a fixed reason code.
"""
import os
import resource
import signal
import struct
import sys

MAX_PATH = 16384
MAX_NAME = 4096
MAX_WIRE = 2097152
TERMINAL_BYTES = 16


def read_exact(size):
    data = bytearray()
    while len(data) < size:
        chunk = sys.stdin.buffer.read(size - len(data))
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return bytes(data)


def receive():
    size = struct.unpack("!H", read_exact(2))[0]
    if size > MAX_PATH + 9:
        raise ValueError
    return read_exact(size)


def send(data):
    sys.stdout.buffer.write(struct.pack("!H", len(data)) + data)
    sys.stdout.buffer.flush()


def terminal(kind, count, reason=0):
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform != "darwin":
        rss *= 1024
    send(kind + struct.pack("!IQB", count, int(rss), reason))


def listing(request):
    if len(request) < 10 or request[:1] != b"L":
        raise ValueError
    allowance, wire = struct.unpack("!II", request[1:9])
    path = request[9:]
    if not path or len(path) > MAX_PATH or b"\0" in path:
        raise ValueError
    if allowance > 5000 or not TERMINAL_BYTES <= wire <= MAX_WIRE:
        raise ValueError
    count = 0
    used = 0
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        with os.scandir(fd) as names:
            while count < allowance:
                try:
                    entry = next(names)
                except StopIteration:
                    terminal(b"C", count)
                    return
                # Every yielded name costs work, even if it cannot be retained.
                count += 1
                name = os.fsencode(entry.name)
                if len(name) > MAX_NAME:
                    terminal(b"I", count, 3)
                    return
                if used + len(name) + 3 + TERMINAL_BYTES > wire:
                    terminal(b"I", count, 2)
                    return
                send(b"N" + name)
                used += len(name) + 3
                if receive() != b"A":
                    raise ValueError
            # No uncharged next() just to distinguish an exact boundary from EOF.
            terminal(b"I", count, 1)
    except OSError:
        terminal(b"E", count, 4)
    finally:
        if fd is not None:
            os.close(fd)


def main():
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    while True:
        signal.setitimer(signal.ITIMER_REAL, 10)
        request = receive()
        if request == b"Q":
            return
        signal.setitimer(signal.ITIMER_REAL, 5)
        listing(request)


try:
    main()
except (EOFError, BrokenPipeError):
    pass
except (ValueError, OSError):
    sys.exit(1)
