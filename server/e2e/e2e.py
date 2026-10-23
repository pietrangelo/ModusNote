"""End to end against `wrangler dev`: the real Worker, Durable Objects and R2
(local), called the way the app will call them. Run by `server/e2e/run.sh`.

Devices sign with Ed25519 (the `cryptography` package) and hash with
BLAKE2b-256 (hashlib, the same as libsodium's crypto_generichash); records
and requests have the bytes the Dart domain writes.
"""

import base64
import http.client
import hashlib
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
ENCRYPTION_KEY_LENGTH = 1216
OWNER, EDITOR, VIEWER = 1, 2, 3
# `wrangler dev` enforces the Worker's write limit (60 a minute for each
# address) in windows aligned to the wall clock, and every request here,
# then the Dart end-to-end test's, comes from 127.0.0.1. Half of it is
# this script's in any one window, so a run never meets the limit.
WRITE_LIMIT_WINDOW_S = 60
WRITES_PER_WINDOW = 30
writes_in_window = {}


def count_write(method, target):
    """Counts a call the Worker throttles as a write (anything but a read,
    and every live handshake), and fails past this script's share."""
    if method == "GET" and not target.endswith("/live"):
        return
    window = int(time.time()) // WRITE_LIMIT_WINDOW_S
    writes_in_window[window] = writes_in_window.get(window, 0) + 1
    if writes_in_window[window] > WRITES_PER_WINDOW:
        raise SystemExit(
            f"FAIL more than {WRITES_PER_WINDOW} writes in one minute, at {method} {target}: "
            "wait for the next window first (next_window)"
        )


def next_window():
    """Waits for the next window of the write limit."""
    time.sleep(WRITE_LIMIT_WINDOW_S - time.time() % WRITE_LIMIT_WINDOW_S + 0.5)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64(data):
    return base64.b64encode(data).decode()


def blake(data):
    return hashlib.blake2b(data, digest_size=32).digest()


class Device:
    def __init__(self):
        self.private = Ed25519PrivateKey.generate()
        self.key = self.private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.millis_offset = 0

    def identity(self):
        return self.key + os.urandom(ENCRYPTION_KEY_LENGTH)

    def sign(self, message):
        return self.private.sign(message)

    def authorization(self, method, target, body, millis=None, nonce=None):
        millis = int(time.time() * 1000) + self.millis_offset if millis is None else millis
        nonce = os.urandom(16) if nonce is None else nonce
        signable = (
            b"modusnote.request.v1"
            + bytes([len(method)]) + method.encode()
            + len(target).to_bytes(2, "big") + target.encode()
            + millis.to_bytes(8, "big") + nonce + blake(body)
        )
        return f"MN1 {b64url(self.key)}.{millis}.{b64url(nonce)}.{b64url(self.sign(signable))}"


def record(ws, sequence, author, previous, change):
    body = bytes([1]) + ws + sequence.to_bytes(4, "big") + author.key
    body += bytes([0]) if previous is None else bytes([1]) + previous
    kind = change[0]
    if kind == "found":
        body += bytes([0]) + change[1]
    elif kind == "invite":
        body += bytes([1]) + change[1] + bytes([change[2]])
    elif kind == "revoke":
        body += bytes([2]) + change[1]
    return body + author.sign(b"modusnote.membership.v1" + body)


def pow_nonce(purpose, target, bits):
    day = int(time.time() * 1000) // 86_400_000
    prefix = b"modusnote.pow.v1" + bytes([purpose, len(target)]) + target + day.to_bytes(4, "big")
    counter = 0
    while True:
        nonce = counter.to_bytes(16, "big")
        digest = blake(prefix + nonce)
        if int.from_bytes(digest, "big") >> (256 - bits) == 0:
            return {"day": day, "nonce": b64(nonce)}
        counter += 1


def call(method, target, by=None, body=None, raw=None, headers=None, signed_body=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
    count_write(method, target)
    request = urllib.request.Request(BASE + target, data=data if data or method in ("POST", "PUT") else None, method=method)
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    if by is not None:
        request.add_header("Authorization", by.authorization(method, target, data if signed_body is None else signed_body))
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def cut_upload(target, by, declared):
    """A PUT that declares `declared` bytes and hangs up after a few."""
    count_write("PUT", target)
    address = urllib.parse.urlsplit(BASE)
    connection = http.client.HTTPConnection(address.hostname, address.port, timeout=30)
    connection.putrequest("PUT", target)
    connection.putheader("Authorization", by.authorization("PUT", target, b""))
    connection.putheader("Content-Length", str(declared))
    connection.endheaders()
    connection.send(os.urandom(1000))
    connection.close()


LIVE_PROTOCOL = "modusnote.live.v1"


def live_token(by, target):
    """The device's credential for the live channel, as a subprotocol token."""
    return by.authorization("GET", target, b"").replace("MN1 ", "mn1.", 1)


class Live:
    """The live channel as a device opens it: a minimal RFC 6455 client over
    a plain socket (masked frames; text, ping, pong and close), so the test
    needs nothing beyond the standard library and `cryptography`."""

    def __init__(self, target, protocols, headers=None):
        count_write("GET", target)
        address = urllib.parse.urlsplit(BASE)
        self.sock = socket.create_connection((address.hostname, address.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {target} HTTP/1.1",
            f"Host: {address.hostname}:{address.port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if protocols:
            lines.append(f"Sec-WebSocket-Protocol: {', '.join(protocols)}")
        lines += [f"{name}: {value}" for name, value in (headers or {}).items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        self.buffer = b""
        while b"\r\n\r\n" not in self.buffer:
            self._fill()
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        status_line, *fields = head.decode("latin-1").split("\r\n")
        self.status = int(status_line.split()[1])
        self.headers = {name.strip().lower(): value.strip() for name, value in (f.split(":", 1) for f in fields)}
        if self.status != 101:
            length = int(self.headers.get("content-length", "0"))
            while len(self.buffer) < length:
                self._fill()
            self.body = self.buffer[:length]
            self.sock.close()
            return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert self.headers.get("sec-websocket-accept") == accept.decode(), self.headers
        self.body = b""

    def _fill(self):
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError("closed without a close frame")
        self.buffer += data

    def _take(self, n):
        while len(self.buffer) < n:
            self._fill()
        taken, self.buffer = self.buffer[:n], self.buffer[n:]
        return taken

    def send(self, opcode, payload=b""):
        mask = os.urandom(4)
        header = bytes([0x80 | opcode])
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        else:
            header += bytes([0x80 | 126]) + len(payload).to_bytes(2, "big")
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_text(self, text):
        self.send(0x1, text.encode())

    def receive(self, timeout=10):
        """The next text message or close, as ("text", str) or ("close", code);
        None if nothing comes in time. Pings are answered on the way."""
        self.sock.settimeout(timeout)
        try:
            while True:
                first, second = self._take(2)
                length = second & 0x7F
                if length == 126:
                    length = int.from_bytes(self._take(2), "big")
                elif length == 127:
                    length = int.from_bytes(self._take(8), "big")
                assert not second & 0x80, "the server masked a frame"
                payload = self._take(length)
                opcode = first & 0x0F
                if opcode == 0x9:
                    self.send(0xA, payload)
                elif opcode == 0x1:
                    return ("text", payload.decode())
                elif opcode == 0x8:
                    return ("close", int.from_bytes(payload[:2], "big") if len(payload) >= 2 else None)
        except socket.timeout:
            return None

    def close(self):
        try:
            self.send(0x8, (1000).to_bytes(2, "big"))
        except OSError:
            pass
        self.sock.close()


def open_live(w, by, protocols=None, headers=None):
    target = f"{w}/live"
    return Live(target, protocols if protocols is not None else [LIVE_PROTOCOL, live_token(by, target)], headers)


def expect_open(live, what):
    if live.status != 101:
        raise SystemExit(f"FAIL {what}: expected 101, got {live.status} {live.body[:200]!r}")
    if live.headers.get("sec-websocket-protocol") != LIVE_PROTOCOL:
        raise SystemExit(f"FAIL {what}: answered protocol {live.headers.get('sec-websocket-protocol')!r}")
    print(f"ok   {what}")
    return live


def expect_refused(live, status, what):
    expect((live.status, live.body), status, what)


def heads_text(by, w):
    """The heads as the live channel sends them: what GET heads answers."""
    status, body, _ = call("GET", f"{w}/heads", by)
    assert status == 200, (status, body)
    return body.decode()


def expect_message(live, message, what, timeout=10):
    got = live.receive(timeout)
    if got != message:
        raise SystemExit(f"FAIL {what}: expected {message!r}, got {got!r}")
    print(f"ok   {what}")


def expect(outcome, status, what):
    if outcome[0] != status:
        raise SystemExit(f"FAIL {what}: expected {status}, got {outcome[0]} {outcome[1][:200]!r}")
    print(f"ok   {what}")
    return json.loads(outcome[1]) if outcome[1][:1] in (b"{", b"[") else outcome[1]


def main():
    info = expect(call("GET", "/api/info"), 200, "info")
    bits = info["pow"]
    alice, bob, carol, mallory = Device(), Device(), Device(), Device()
    ws = os.urandom(16)
    w = f"/api/w/{ws.hex()}"

    genesis = record(ws, 0, alice, None, ("found", alice.identity()))
    found = {"records": [b64(genesis)], "pow": pow_nonce(1, ws, bits)}
    expect(call("POST", w, alice, {"records": [b64(genesis)], "pow": {"day": found["pow"]["day"], "nonce": b64(bytes(16))}}), 403, "founding without work")
    expect(call("POST", w, alice, found), 201, "founding")
    expect(call("POST", w, alice, found), 200, "founding again is fine")
    expect(call("GET", f"{w}/heads"), 401, "unsigned read")
    expect(call("GET", f"{w}/heads", mallory), 403, "a stranger reads")

    invite_bob = record(ws, 1, alice, genesis[-64:], ("invite", bob.identity(), EDITOR))
    expect(call("POST", f"{w}/membership", bob, {"record": b64(invite_bob)}), 403, "a non member cannot relay a record")
    expect(call("POST", f"{w}/membership", alice, {"record": b64(invite_bob)}), 201, "invite an editor")
    invite_carol = record(ws, 2, alice, invite_bob[-64:], ("invite", carol.identity(), VIEWER))
    expect(call("POST", f"{w}/membership", alice, {"record": b64(invite_carol)}), 201, "invite a viewer")
    forged = record(ws, 3, bob, invite_carol[-64:], ("invite", mallory.identity(), OWNER))
    expect(call("POST", f"{w}/membership", bob, {"record": b64(forged)}), 422, "an editor cannot invite")
    log = expect(call("GET", f"{w}/membership?from=0", carol), 200, "the viewer reads the log")
    assert len(log["records"]) == 3

    record_id = os.urandom(16).hex()
    rows = {"rows": [{"record": record_id, "ciphertext": b64(b"sealed one"), "supersedes": 0}]}
    expect(call("POST", f"{w}/rows", carol, rows), 403, "a viewer cannot write")
    pushed = expect(call("POST", f"{w}/rows", bob, rows), 201, "the editor pushes")
    second = {"rows": [{"record": record_id, "ciphertext": b64(b"sealed two"), "supersedes": pushed["positions"][0]}]}
    expect(call("POST", f"{w}/rows", bob, second), 201, "a newer revision supersedes")
    pulled = expect(call("GET", f"{w}/rows?after=0", alice), 200, "pull")
    assert [base64.b64decode(r["ciphertext"]) for r in pulled["rows"]] == [b"sealed two"], pulled

    header = bob.authorization("GET", f"{w}/heads", b"")
    expect(call("GET", f"{w}/heads", headers={"Authorization": header}), 200, "a signed read")
    replay = bob.authorization("POST", f"{w}/rows", json.dumps(rows).encode())
    expect(call("POST", f"{w}/rows", body=rows, headers={"Authorization": replay}), 201, "a signed write")
    expect(call("POST", f"{w}/rows", body=rows, headers={"Authorization": replay}), 401, "the same write again")
    stale = bob.authorization("GET", f"{w}/heads", b"", millis=int(time.time() * 1000) - 600_000)
    clock = expect(call("GET", f"{w}/heads", headers={"Authorization": stale}), 401, "a clock ten minutes off")
    assert clock["error"] == "clock" and abs(clock["now"] - time.time() * 1000) < 60_000
    expect(call("GET", f"{w}/heads", bob, headers={"Origin": "https://evil.example"}), 403, "another origin")

    # The live channel: a member's socket hears of the others' writes.
    alice_live = expect_open(open_live(w, alice), "a member opens the live channel")
    bob_live = expect_open(open_live(w, bob), "another member opens it too")
    third = {"rows": [{"record": record_id, "ciphertext": b64(b"sealed three"), "supersedes": 0}]}
    expect(call("POST", f"{w}/rows", bob, third), 201, "a push while both are open")
    expect_message(alice_live, ("text", heads_text(alice, w)), "the other member hears the heads")
    expect_message(bob_live, None, "the author's own socket hears nothing", timeout=2)
    target_live = f"{w}/live"
    expect_refused(open_live(w, alice, headers={"Origin": "https://evil.example"}), 403, "a live socket from another origin")
    expect_refused(open_live(w, alice, protocols=[LIVE_PROTOCOL]), 401, "an unsigned live socket")
    expect_refused(open_live(w, mallory), 403, "a stranger's live socket")
    token = live_token(alice, target_live)
    expect_open(open_live(w, alice, protocols=[LIVE_PROTOCOL, token]), "a signed handshake").close()
    expect_refused(open_live(w, alice, protocols=[LIVE_PROTOCOL, token]), 401, "the same handshake again")
    beside = {"Authorization": alice.authorization("GET", target_live, b"")}
    expect_refused(open_live(w, alice, headers=beside), 401, "a header beside the token")
    expect_refused(open_live(w, alice, protocols=[live_token(alice, target_live)]), 426, "a token without our protocol")
    expect(call("GET", target_live, alice), 426, "the live route without an upgrade")
    alice_live.send_text("ping")
    expect_message(alice_live, ("text", "pong"), "ping gets pong")
    alice_live.send_text("hello")
    expect_message(alice_live, ("close", 1008), "anything else closes the socket")
    alice_live.close()
    alice_live = expect_open(open_live(w, alice), "and a new handshake still works")
    others = []
    for i in range(3):
        time.sleep(0.01)
        others.append(expect_open(open_live(w, bob), f"the same key's socket {i + 2}"))
    time.sleep(0.01)
    fifth = expect_open(open_live(w, bob), "a fifth socket of the same key")
    expect_message(bob_live, ("close", 4409), "pushes out the oldest")
    others[0].send(0x8, (1000).to_bytes(2, "big"))
    expect_message(others[0], ("close", 1000), "a device's close is answered")
    for live in others:
        live.close()
    bob_live = fifth

    # Blobs, codes and removal in a window of their own; the two sockets
    # wait, idle, as a device's would.
    next_window()
    blob = os.urandom(70_000)
    target = f"{w}/blobs/note-audio_1"
    expect(call("PUT", target, carol, raw=blob, signed_body=b""), 403, "a viewer cannot upload")
    expect(call("PUT", target, bob, raw=blob, signed_body=b""), 201, "upload a blob (signed over an empty body)")
    expect(call("PUT", target, bob, raw=blob, signed_body=b""), 200, "the same blob again")
    expect(call("PUT", target, bob, raw=blob + b"x", signed_body=b""), 409, "the same id with another size")
    got = expect(call("GET", target, carol), 200, "the viewer downloads")
    assert got == blob
    part = call("GET", target, carol, headers={"Range": "bytes=100-199"})
    assert part[0] == 206 and part[1] == blob[100:200] and part[2]["Content-Range"] == "bytes 100-199/70000", part[:1]
    print("ok   a range")
    expect(call("GET", target, carol, headers={"Range": "bytes=70000-"}), 416, "a range past the end")
    listed = expect(call("GET", f"{w}/blobs", carol), 200, "list blobs")
    assert [b["id"] for b in listed["blobs"]] == ["note-audio_1"] and listed["blobs"][0]["size"] == 70_000
    # run.sh sets the service's daily ceiling to 1 MB: uploads that never
    # arrive must not spend it, or one address could stop everyone's.
    for _ in range(3):
        cut_upload(f"{w}/blobs/note-cut_1", bob, 900_000)
    print("ok   three uploads cut short")
    expect(call("GET", f"{w}/blobs/note-cut_1", carol), 404, "a cut upload leaves nothing in R2")
    other = os.urandom(70_000)
    expect(call("PUT", f"{w}/blobs/note-audio_2", bob, raw=other, signed_body=b""), 201, "and spent none of the ceiling")
    expect(call("PUT", f"{w}/blobs/note-big_1", bob, raw=os.urandom(990_000), signed_body=b""), 429, "bytes that reach R2 do")
    expect(call("GET", f"{w}/blobs/note-big_1", carol), 404, "and one past the ceiling is not kept")
    expect(call("POST", f"{w}/blobs/delete", bob, {"ids": ["note-audio_1", "note-audio_2", "note-cut_1", "note-big_1"]}), 200, "delete a blob")
    expect(call("GET", target, carol), 404, "the deleted blob is gone from R2")

    lookup = "".join("0123456789ABCDEFGHJKMNPQRSTVWXYZ"[b % 32] for b in os.urandom(6))
    offer = {"offer": b64(b"sealed invitation")}
    expect(call("POST", f"{w}/codes/{lookup}", bob, offer), 403, "an editor cannot post an offer")
    expect(call("POST", f"{w}/codes/{lookup}", alice, offer), 201, "an owner posts an offer")
    expect(call("POST", f"{w}/codes/{lookup}", alice, offer), 409, "the lookup is taken")
    got = expect(call("GET", f"/api/codes/{lookup}"), 200, "anyone reads the offer")
    assert base64.b64decode(got["offer"]) == b"sealed invitation"
    answer = {"answer": b64(b"sealed answer"), "pow": pow_nonce(2, lookup.encode(), bits)}
    expect(call("POST", f"/api/codes/{lookup}/answers", body=answer), 201, "an answer, with work")
    expect(call("GET", f"/api/codes/{lookup}/answers", bob), 403, "only the poster reads answers")
    answers = expect(call("GET", f"/api/codes/{lookup}/answers", alice), 200, "the poster reads answers")
    assert [base64.b64decode(a) for a in answers["answers"]] == [b"sealed answer"]
    expect(call("DELETE", f"/api/codes/{lookup}", alice), 200, "the poster closes the code")
    expect(call("GET", f"/api/codes/{lookup}"), 404, "the closed code is gone")

    expect(call("PUT", target, bob, raw=blob, signed_body=b""), 201, "upload again before deleting the workspace")
    carol_live = expect_open(open_live(w, carol), "the viewer's live socket")
    revoke_carol = record(ws, 3, alice, invite_carol[-64:], ("revoke", carol.key))
    expect(call("POST", f"{w}/membership", alice, {"record": b64(revoke_carol)}), 201, "remove the viewer")
    expect_message(carol_live, ("close", 4403), "the removed member's socket closes")
    expect_message(bob_live, ("text", heads_text(alice, w)), "the others hear of the removal")
    expect_message(alice_live, None, "but not the owner who removed", timeout=2)
    expect_refused(open_live(w, carol), 403, "a removed member opens no socket")
    expect(call("GET", f"{w}/heads", carol), 403, "a removed member reads nothing else")
    told = expect(call("GET", f"{w}/membership?from=3", carol), 200, "but learns from the log why")
    assert [base64.b64decode(r) for r in told["records"]] == [revoke_carol], told
    expect(call("DELETE", w, bob), 403, "an editor cannot delete the workspace")
    expect(call("DELETE", w, alice), 200, "an owner deletes the workspace")
    expect_message(alice_live, ("close", 4404), "every live socket closes")
    expect_message(bob_live, ("close", 4404), "every live socket closes, the others' too")
    expect(call("GET", f"{w}/heads", alice), 404, "the workspace is gone")
    expect(call("POST", w, alice, {"records": [b64(genesis)], "pow": pow_nonce(1, ws, bits)}), 201, "the id can be founded again")
    expect(call("GET", target, alice), 404, "and its old blobs are gone")
    print("all good")


if __name__ == "__main__":
    main()
