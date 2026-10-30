import http.server
import select
import socket
import socketserver
import sys
import threading

class HttpHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode() if self.path == "/source" else b"OK"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(128)
            if not data:
                break
            self.request.sendall(data)

class UdpEchoServer:
    def __init__(self, addresses):
        self.sockets = []
        for family, address, port in addresses:
            sock = socket.socket(family, socket.SOCK_DGRAM)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind((address, port))
            self.sockets.append(sock)

    def serve_forever(self):
        while True:
            for sock in select.select(self.sockets, [], [])[0]:
                data, peer = sock.recvfrom(4096)
                sock.sendto(b"hermes-network-policy-udp-ok", peer)

class TcpServer6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()

class EchoServer4(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

mode = sys.argv[1]
if mode == "host":
    tcp_servers = [
        http.server.ThreadingHTTPServer(("0.0.0.0", 18083), HttpHandler),
        TcpServer6(("::", 18083), HttpHandler),
        EchoServer4(("0.0.0.0", 18084), EchoHandler),
    ]
    udp_addresses = [
        (socket.AF_INET, "0.0.0.0", 18083),
        (socket.AF_INET6, "::", 18083),
    ]
elif mode == "endpoint":
    tcp_servers = [
        http.server.ThreadingHTTPServer(("0.0.0.0", 18082), HttpHandler),
        TcpServer6(("::", 18082), HttpHandler),
        http.server.ThreadingHTTPServer(("10.20.0.2", 18083), HttpHandler),
        http.server.ThreadingHTTPServer(("10.20.0.2", 18086), HttpHandler),
        TcpServer6(("fd42:198:20::2", 18086), HttpHandler),
        EchoServer4(("10.20.0.2", 18090), EchoHandler),
    ]
    udp_addresses = [
        (socket.AF_INET, "10.20.0.2", 18082),
        (socket.AF_INET, "10.20.0.2", 18083),
        (socket.AF_INET, "10.20.0.2", 18086),
        (socket.AF_INET, "10.20.0.3", 18082),
        (socket.AF_INET6, "fd42:198:20::2", 18082),
        (socket.AF_INET6, "fd42:198:20::2", 18083),
        (socket.AF_INET6, "fd42:198:20::2", 18086),
        (socket.AF_INET6, "fd42:198:20::3", 18086),
    ]
else:
    ipv4, ipv6 = sys.argv[2:4]
    tcp_servers = [
        http.server.ThreadingHTTPServer((ipv4, 18084), HttpHandler),
        TcpServer6((ipv6, 18085), HttpHandler),
        http.server.ThreadingHTTPServer((ipv4, 18088), HttpHandler),
        http.server.ThreadingHTTPServer((ipv4, 18090), HttpHandler),
        http.server.ThreadingHTTPServer(("127.0.0.1", 18087), HttpHandler),
        http.server.ThreadingHTTPServer(("127.0.0.1", 18089), HttpHandler),
    ]
    udp_addresses = [
        (socket.AF_INET, ipv4, 18086),
        (socket.AF_INET, ipv4, 18088),
        (socket.AF_INET, ipv4, 18090),
        (socket.AF_INET, "127.0.0.1", 18087),
        (socket.AF_INET, "127.0.0.1", 18089),
    ]

for server in tcp_servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()
UdpEchoServer(udp_addresses).serve_forever()
