#!/usr/bin/python3
"""Local test double, never contacts a Boundary controller or reads credentials."""
import json
import os
import signal
import socket
import sys
import threading
import time
import shutil
import subprocess

signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

if sys.argv[1] == "authenticate":
    assert "-format=table" in sys.argv
    if "-auth-method-id=ampw_fail" in sys.argv:
        print("Authentication failed", file=sys.stderr)
        sys.exit(1)
    if sys.argv[2] == "oidc":
        helper = shutil.which("open")
        assert helper and "browser-helper" in helper
        assert subprocess.run([helper, "https://login.example.test/authorize"]).returncode == 0
        assert "BRIDGE_LOGIN_PASSWORD" not in os.environ
        print("Opening returned authentication URL in your browser...", flush=True)
        print("https://login.example.test/authorize?state=fixture", flush=True)
        time.sleep(0.2)
        print("Token: at_sensitive_fixture_secret", flush=True)
        sys.exit(0)
    assert "-password=env://BRIDGE_LOGIN_PASSWORD" in sys.argv
    assert os.environ.get("BRIDGE_LOGIN_PASSWORD") == "test-password-only"
    assert "test-password-only" not in " ".join(sys.argv)
    print("Token: at_sensitive_fixture_secret")
    sys.exit(0)
if sys.argv[1] == "targets":
    assert "-recursive" in sys.argv
    print(json.dumps({"items": [{"id": "ttcp_fixture", "name": "Fixture DB", "type": "tcp",
                                  "scope_id": "p_test", "attributes": {"default_port": 5432}}]}, indent=2))
    sys.exit(0)
if sys.argv[1] == "auth-methods":
    print(json.dumps({"items": [{"id": "ampw_fixture", "name": "Test password", "type": "password"}]}))
    sys.exit(0)
if sys.argv[1] == "logout":
    assert "-token-name=BoundaryBridge" in sys.argv
    sys.exit(0)

assert sys.argv[1] == "connect"
assert "-listen-addr=127.0.0.1" in sys.argv
assert "-listen-port=0" in sys.argv
assert "-format=json" in sys.argv

server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(32)
message = json.dumps({"address": "127.0.0.1", "port": server.getsockname()[1],
                      "protocol": "tcp", "session_id": "s_integration",
                      "credentials": [{"secret": "never-print-this-secret"}]}) + "\n"
# Exercise streaming output split across several reads.
for part in [message[:11], message[11:39], message[39:]]:
    sys.stdout.write(part)
    sys.stdout.flush()
    time.sleep(0.02)


def handle(connection):
    with connection:
        chunks = []
        while True:
            data = connection.recv(65536)
            if not data:
                break
            chunks.append(data)
        payload = b"".join(chunks)
        if payload == b"__DROP__":
            os._exit(23)
        connection.sendall(payload)
        connection.shutdown(socket.SHUT_WR)


while True:
    connection, _ = server.accept()
    threading.Thread(target=handle, args=(connection,), daemon=True).start()
