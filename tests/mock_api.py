#!/usr/bin/env python3
"""A scripted stand-in for the Claude Messages API, for testing Shulker OS without an API key.

    python3 tests/mock_api.py --port 8443 --log /tmp/mock.jsonl [--plain]

It speaks HTTPS (self-signed certificate, which Sedna's BusyBox TLS accepts: it verifies nothing),
HTTP/1.1 with chunked transfer encoding, and the Messages API's server-sent events, including thinking
blocks with signatures, tool_use blocks streamed as input_json_delta fragments, and usage.
Every request is checked for the shape the real API needs and appended to --log as JSON.

What it answers depends on the last user message:
  TOOL <name> <json input>   -> a thinking block, a short text and a tool_use call
  ERROR429                   -> 429 with retry-after: 1 the first time, then a normal reply
  ERROR400                   -> a 400 invalid_request_error
  DROP                       -> the first time, the stream is cut off mid-reply
  REFUSE                     -> stop_reason refusal
  anything else              -> "Hello from mock: <text>"
  a tool_result              -> "Tool result was: <the result's first 300 characters>"
"""
import argparse
import json
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"seen": set(), "n": 0}
LOCK = threading.Lock()
ARGS = None


def problems(headers, body):
    out = []
    if not headers.get("x-api-key"):
        out.append("missing x-api-key")
    if headers.get("anthropic-version") != "2023-06-01":
        out.append("bad anthropic-version")
    if "server-side-fallback-2026-07-01" not in (headers.get("anthropic-beta") or ""):
        out.append("missing fallback beta header")
    for k in ("model", "max_tokens", "messages"):
        if k not in body:
            out.append("missing " + k)
    if body.get("model") not in ("claude-opus-5-5", "claude-sonnet-5-5"):
        out.append("unexpected model %r" % body.get("model"))
    if "budget_tokens" in json.dumps(body.get("thinking", {})):
        out.append("budget_tokens is rejected on this model")
    if body.get("thinking", {}).get("type") not in (None, "adaptive"):
        out.append("thinking must be adaptive or omitted")
    if body.get("tool_choice", {}).get("type") in ("any", "tool"):
        out.append("forced tool_choice is rejected")
    msgs = body.get("messages", [])
    if not msgs or msgs[0].get("role") != "user":
        out.append("messages must start with user")
    for a, b in zip(msgs, msgs[1:]):
        if a.get("role") == b.get("role"):
            out.append("two %s messages in a row" % a.get("role"))
    for i, m in enumerate(msgs):
        c = m.get("content")
        if isinstance(c, list):
            if not c:
                out.append("empty content in message %d" % i)
            for blk in c:
                if blk.get("type") == "thinking" and not blk.get("signature"):
                    out.append("thinking block without signature in message %d" % i)
                if any(k.startswith("_") for k in blk):
                    out.append("internal field leaked in message %d" % i)
        # every tool_use must be answered in the next message
        if m.get("role") == "assistant" and isinstance(c, list):
            ids = {b["id"] for b in c if b.get("type") == "tool_use"}
            if ids:
                nxt = msgs[i + 1]["content"] if i + 1 < len(msgs) else []
                got = {b.get("tool_use_id") for b in nxt if isinstance(b, dict) and b.get("type") == "tool_result"}
                if i + 1 < len(msgs) and ids != got:
                    out.append("tool_use ids %s not all answered" % sorted(ids))
    for t in body.get("tools", []):
        if "input_schema" not in t:
            out.append("tool %s without input_schema" % t.get("name"))
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            if self.headers.get("x-api-key") == "sk-ant-bad":
                return self.json(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            return self.json(200, {"data": [{"id": "claude-opus-5-5"}], "has_more": False})
        if self.path.startswith("/files/"):     # a tiny static server for installer tests
            path = os.path.join(ARGS.files or ".", self.path[len("/files/"):].split("?")[0])
            if os.path.isfile(path):
                data = open(path, "rb").read()
                self.send_response(200)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        self.json(404, {"type": "error", "error": {"type": "not_found_error", "message": "not found"}})

    def json(self, status, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def chunk(self, data):
        if isinstance(data, str):
            data = data.encode()
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def event(self, typ, obj):
        obj = dict(obj, type=typ)
        self.chunk("event: %s\ndata: %s\n\n" % (typ, json.dumps(obj)))

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw)
        except Exception as e:
            return self.json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad json: %s" % e}})
        headers = {k.lower(): v for k, v in self.headers.items()}
        bad = problems(headers, body)
        with LOCK:
            STATE["n"] += 1
            reqno = STATE["n"]
        if ARGS.log:
            with LOCK, open(ARGS.log, "a") as f:
                f.write(json.dumps({"n": reqno, "headers": {k: v for k, v in headers.items() if k != "x-api-key"},
                                    "key_tail": headers.get("x-api-key", "")[-4:], "body": body, "problems": bad}) + "\n")
        if bad:
            return self.json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "; ".join(bad)}})

        last = body["messages"][-1]
        content = last["content"]
        text, tool_result = "", None
        if isinstance(content, str):
            text = content
        else:
            for b in content:
                if b.get("type") == "text":
                    text += b["text"]
                elif b.get("type") == "tool_result":
                    tool_result = b
        key = text.strip()

        def once(tag):
            with LOCK:
                if tag in STATE["seen"]:
                    return False
                STATE["seen"].add(tag)
                return True

        if "ERROR429" in key and once("429" + key):
            return self.json(429, {"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}, {"retry-after": "1"})
        if "ERROR400" in key:
            return self.json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "mock says no"}})

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.send_header("connection", "close")
        self.end_headers()
        msg_id = "msg_mock_%d" % reqno
        self.event("message_start", {"message": {"id": msg_id, "type": "message", "role": "assistant", "model": body["model"],
                                                  "content": [], "stop_reason": None, "usage": {"input_tokens": 100, "output_tokens": 1,
                                                  "cache_read_input_tokens": 50, "cache_creation_input_tokens": 10}}})
        self.chunk(": ping\n\n")
        idx = 0

        def text_block(s, pieces=3):
            nonlocal idx
            self.event("content_block_start", {"index": idx, "content_block": {"type": "text", "text": ""}})
            step = max(1, len(s) // pieces)
            for i in range(0, len(s), step):
                self.event("content_block_delta", {"index": idx, "delta": {"type": "text_delta", "text": s[i:i + step]}})
                time.sleep(0.02)
            self.event("content_block_stop", {"index": idx})
            idx += 1

        stop = "end_turn"
        if tool_result is not None:
            res = tool_result.get("content")
            if isinstance(res, list):
                res = "".join(x.get("text", "") for x in res)
            text_block("Tool result was: " + str(res)[:300])
        elif key.startswith("TOOL "):
            parts = key.split(" ", 2)
            name, inp = parts[1], (parts[2] if len(parts) > 2 else "{}")
            self.event("content_block_start", {"index": idx, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
            self.event("content_block_delta", {"index": idx, "delta": {"type": "thinking_delta", "thinking": "Using " + name + "."}})
            self.event("content_block_delta", {"index": idx, "delta": {"type": "signature_delta", "signature": "sig-%d" % reqno}})
            self.event("content_block_stop", {"index": idx})
            idx += 1
            text_block("Let me use %s." % name, 1)
            self.event("content_block_start", {"index": idx, "content_block": {"type": "tool_use", "id": "toolu_%d" % reqno, "name": name, "input": {}}})
            for i in range(0, len(inp), 7):
                self.event("content_block_delta", {"index": idx, "delta": {"type": "input_json_delta", "partial_json": inp[i:i + 7]}})
            self.event("content_block_stop", {"index": idx})
            idx += 1
            stop = "tool_use"
        elif "DROP" in key and once("drop" + key):
            text_block("This reply will be cut o", 2)
            self.wfile.flush()
            self.close_connection = True
            return   # no terminating chunk, no message_stop
        elif "REFUSE" in key:
            stop = "refusal"
        elif "SLOW" in key:
            for _ in range(3):
                time.sleep(1.5)
                self.event("ping", {})
            text_block("Slow hello.")
        else:
            text_block("Hello from mock: " + key)
        self.event("message_delta", {"delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 42}})
        self.event("message_stop", {})
        self.chunk(b"")


def make_cert(d):
    crt, key = os.path.join(d, "mock.crt"), os.path.join(d, "mock.key")
    if not os.path.exists(crt):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=mock-api",
                        "-keyout", key, "-out", crt], check=True, capture_output=True)
    return crt, key


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--log")
    ap.add_argument("--plain", action="store_true", help="plain HTTP instead of HTTPS")
    ap.add_argument("--files", help="serve this directory under /files/")
    ap.add_argument("--certdir", default=tempfile.gettempdir())
    ARGS = ap.parse_args()
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    if not ARGS.plain:
        crt, key = make_cert(ARGS.certdir)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print("mock API on %s:%d (%s)" % (ARGS.host, ARGS.port, "http" if ARGS.plain else "https"), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
