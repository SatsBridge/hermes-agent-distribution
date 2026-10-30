import ipaddress
import pathlib
import socket
import struct
import sys
import time

interface, source, target = sys.argv[1:]
ifindex = socket.if_nametoindex(interface)
source = ipaddress.IPv6Address(source)
target = ipaddress.IPv6Address(target)
if not source.is_link_local or target.is_multicast or target.is_unspecified:
    raise ValueError("DAD advertisement requires a link-local source and unicast target")
mac = bytes.fromhex(pathlib.Path(f"/sys/class/net/{interface}/address").read_text().strip().replace(":", ""))
destination = ipaddress.IPv6Address("ff02::1")
packet = struct.pack("!BBHI16s", 136, 0, 0, 0x20000000, target.packed) + bytes((2, 1)) + mac
pseudo = source.packed + destination.packed + struct.pack("!I3xB", len(packet), socket.IPPROTO_ICMPV6)
data = pseudo + packet + (b"\0" if len(pseudo + packet) % 2 else b"")
words = struct.unpack("!" + "H" * (len(data) // 2), data)
checksum = sum(words)
while checksum >> 16:
    checksum = (checksum & 0xffff) + (checksum >> 16)
packet = packet[:2] + struct.pack("!H", (~checksum) & 0xffff) + packet[4:]
print(f"VM_DAD_NA_SENDING interface={interface} target={target}", flush=True)
with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as sock:
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, ifindex)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    sock.bind((str(source), 0, 0, ifindex))
    sent = 0
    for _ in range(40):
        sock.sendto(packet, (str(destination), 0, 0, ifindex))
        sent += 1
        if sent == 1:
            print("VM_DAD_NA_SENT first=1", flush=True)
        time.sleep(0.05)
print(f"VM_DAD_NA_SENT interface={interface} target={target} count={sent}", flush=True)
