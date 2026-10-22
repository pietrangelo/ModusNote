"""End to end against `wrangler dev`: the real Worker, Durable Objects and R2
(local), called the way the app will call them. Run by `server/e2e/run.sh`.

Devices sign with Ed25519 (the `cryptography` package) and hash with
BLAKE2b-256 (hashlib, the same as libsodium's crypto_generichash); records
and requests have the bytes the Dart domain writes.
"""

import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
ENCRYPTION_KEY_LENGTH = 1216
OWNER, EDITOR, VIEWER = 1, 2, 3


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
    expect(call("POST", f"{w}/blobs/delete", bob, {"ids": ["note-audio_1"]}), 200, "delete a blob")
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
    revoke_carol = record(ws, 3, alice, invite_carol[-64:], ("revoke", carol.key))
    expect(call("POST", f"{w}/membership", alice, {"record": b64(revoke_carol)}), 201, "remove the viewer")
    expect(call("GET", f"{w}/heads", carol), 403, "a removed member reads nothing else")
    told = expect(call("GET", f"{w}/membership?from=3", carol), 200, "but learns from the log why")
    assert [base64.b64decode(r) for r in told["records"]] == [revoke_carol], told
    expect(call("DELETE", w, bob), 403, "an editor cannot delete the workspace")
    expect(call("DELETE", w, alice), 200, "an owner deletes the workspace")
    expect(call("GET", f"{w}/heads", alice), 404, "the workspace is gone")
    expect(call("POST", w, alice, {"records": [b64(genesis)], "pow": pow_nonce(1, ws, bits)}), 201, "the id can be founded again")
    expect(call("GET", target, alice), 404, "and its old blobs are gone")
    print("all good")


if __name__ == "__main__":
    main()
