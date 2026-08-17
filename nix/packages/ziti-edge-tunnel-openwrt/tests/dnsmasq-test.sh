#!/usr/bin/env bash
set -euo pipefail

dnsmasq=${1:?usage: dnsmasq-test.sh DNSMASQ}
[[ -x $dnsmasq ]] || {
  printf 'missing dnsmasq: %s\n' "$dnsmasq" >&2
  exit 1
}

python3 - "$dnsmasq" <<'PY'
import os
import pwd
import random
import socket
import struct
import subprocess
import sys
import threading
import time

DNSMASQ = sys.argv[1]


def free_udp_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def parse_question(packet):
    offset = 12
    labels = []
    while True:
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        labels.append(packet[offset : offset + length].decode("ascii"))
        offset += length
    question_end = offset + 4
    return ".".join(labels), question_end


def response_for(packet, address):
    _, question_end = parse_question(packet)
    if address is None:
        return packet[:2] + struct.pack("!HHHHH", 0x8183, 1, 0, 0, 0) + packet[12:question_end]
    answer = (
        b"\xc0\x0c"
        + struct.pack("!HHIH", 1, 1, 30, 4)
        + socket.inet_aton(address)
    )
    return (
        packet[:2]
        + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
        + packet[12:question_end]
        + answer
    )


class DnsStub:
    def __init__(self, answers):
        self.answers = answers
        self.names = []
        self.stop_event = threading.Event()
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.1)
        self.port = self.socket.getsockname()[1]
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop_event.is_set():
            try:
                packet, peer = self.socket.recvfrom(4096)
            except socket.timeout:
                continue
            name, _ = parse_question(packet)
            self.names.append(name)
            self.socket.sendto(response_for(packet, self.answers.get(name)), peer)

    def close(self):
        self.stop_event.set()
        self.thread.join(timeout=1)
        self.socket.close()


def make_query(name):
    identifier = random.randrange(65536)
    qname = b"".join(
        bytes([len(label)]) + label.encode("ascii") for label in name.split(".")
    ) + b"\0"
    packet = (
        struct.pack("!HHHHHH", identifier, 0x0100, 1, 0, 0, 0)
        + qname
        + struct.pack("!HH", 1, 1)
    )
    return identifier, packet


def query(port, name):
    identifier, packet = make_query(name)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        sock.sendto(packet, ("127.0.0.1", port))
        response, _ = sock.recvfrom(4096)
    finally:
        sock.close()
    response_id, flags, _, answer_count, _, _ = struct.unpack("!HHHHHH", response[:12])
    if response_id != identifier:
        raise AssertionError(f"response ID mismatch for {name}")
    rcode = flags & 0x0F
    address = socket.inet_ntoa(response[-4:]) if rcode == 0 and answer_count == 1 else None
    return rcode, address


ziti = DnsStub({"ha.compaan": "100.64.0.4"})
public = DnsStub({"public.example": "192.0.2.80"})
dnsmasq_port = free_udp_port()
run_user = pwd.getpwuid(os.getuid()).pw_name
command = [
    DNSMASQ,
    "--keep-in-foreground",
    f"--port={dnsmasq_port}",
    "--listen-address=127.0.0.1",
    "--bind-interfaces",
    "--no-hosts",
    "--no-resolv",
    "--log-facility=-",
    "--server=/compaan/",
    f"--server=/ha.compaan/127.0.0.1#{ziti.port}",
    f"--server=127.0.0.1#{public.port}",
    f"--user={run_user}",
]
process = subprocess.Popen(
    command,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
failed = False
try:
    time.sleep(0.3)
    if process.poll() is not None:
        raise AssertionError("dnsmasq exited during startup")

    assert query(dnsmasq_port, "ha.compaan") == (0, "100.64.0.4")
    assert query(dnsmasq_port, "unknown.compaan") == (3, None)
    assert query(dnsmasq_port, "public.example") == (0, "192.0.2.80")
    assert query(dnsmasq_port, "child.ha.compaan") == (3, None)
    time.sleep(0.1)

    assert ziti.names == ["ha.compaan", "child.ha.compaan"], ziti.names
    assert public.names == ["public.example"], public.names
except Exception:
    failed = True
    raise
finally:
    process.terminate()
    try:
        output, _ = process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate(timeout=2)
    ziti.close()
    public.close()
    if failed and output:
        print(output, file=sys.stderr)
PY

printf 'dnsmasq routing tests: 5 passed\n'
