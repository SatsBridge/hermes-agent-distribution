import ctypes
import errno
import pathlib
import socket

status = dict(line.split(":", 1) for line in pathlib.Path("/proc/self/status").read_text().splitlines())
assert int(status["CapEff"], 16) == 0x1000, status["CapEff"]
assert int(status["CapBnd"], 16) == 0x1000, status["CapBnd"]
assert int(status["CapPrm"], 16) == (1 << 12), status["CapPrm"]
assert int(status["CapAmb"], 16) == (1 << 12)
assert int(status["NoNewPrivs"]) == 1
assert int(status["Seccomp"]) == 2
for family in (socket.AF_UNIX, socket.AF_INET, socket.AF_INET6, socket.AF_PACKET):
    try:
        sock = socket.socket(family, socket.SOCK_DGRAM)
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EAFNOSUPPORT), error
    else:
        sock.close()
        raise AssertionError(f"forbidden socket family {family} succeeded")
libc = ctypes.CDLL(None, use_errno=True)
assert libc.setns(-1, 0) == -1 and ctypes.get_errno() == errno.EPERM
assert libc.unshare(0x40000000) == -1 and ctypes.get_errno() == errno.EPERM
print("LOCAL_NETWORK_BOUNDARY_PASSED caps=NET_ADMIN ambient=NET_ADMIN dynamic-user seccomp=2 forbidden-families/setns/unshare=denied", flush=True)
