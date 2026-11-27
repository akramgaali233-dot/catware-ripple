"""Local Ripple v1.1 ONNX inference service for the external Luau adapter."""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import onnxruntime as ort


INPUT_SHAPES = {
    "main": (1, 32),
    "others": (1, 5, 21),
    "ball": (1, 6, 9),
    "actions": (1, 6, 8),
    "boosts": (1, 34, 5),
}


class RippleHandler(BaseHTTPRequestHandler):
    server_version = "RippleInference/1.0"

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self.send_json(200, {"ok": True, "model": self.server.model_path.name})
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/ripple":
            self.send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2_000_000:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length))
            inputs = {}
            for name, shape in INPUT_SHAPES.items():
                values = np.asarray(payload[name], dtype=np.float32)
                inputs[name] = values.reshape(shape)
            started = time.perf_counter()
            logits = self.server.session.run(["logits"], inputs)[0]
            action = int(np.argmax(logits[0])) + 1
            elapsed_ms = (time.perf_counter() - started) * 1000
            self.send_json(200, {"action": action, "latency_ms": round(elapsed_ms, 3)})
        except Exception as exc:  # keep failures as JSON so the client can fail closed
            self.send_json(400, {"error": str(exc)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    server = ThreadingHTTPServer((args.host, args.port), RippleHandler)
    server.session = session
    server.model_path = args.model
    print(f"Ripple v1.1 ONNX service listening at http://{args.host}:{args.port}")
    print(f"Health check: http://{args.host}:{args.port}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping Ripple inference service")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
