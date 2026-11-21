"""Local NANDA Market monitor and its price-only comparator."""

from __future__ import annotations

import argparse
import hmac
import json
import math
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import NamedTuple

import numpy as np

DEFAULT_MODEL = Path(__file__).with_name("output") / "model.json"
NEIGHBORS = 5
MIN_REFERENCE = 30
CALIBRATION_QUANTILE = 0.95
MAX_REQUEST = 256 * 1024
MAX_RESPONSE = 64 * 1024
SIGNAL_DESCRIPTIONS = {
    "stocked": ("empty counter", "stocked counter"),
    "displays_prints": ("no prints on counter", "prints on counter"),
    "vouched": ("no voucher", "voucher present"),
    "listing_note": ("no listing note", "listing note present"),
    "pitch_present": ("no sales pitch", "sales pitch present"),
}
EVIDENCE_CODES = {("stocked", 0): "empty_counter", ("displays_prints", 1): "prints_displayed"}


class Assessment(NamedTuple):
    verdict: str
    reason: str
    reason_code: str | None = None


def number(value):
    if type(value) in (int, float) and abs(value) <= 1e12 and math.isfinite(value):
        return float(value)
    return None


def log_ratio(case):
    price, market = number(case.get("price")), number(case.get("market"))
    if price is None or market is None or min(price, market) <= 0:
        return None
    return math.log(price / market)


def features(case, signal_names=()):
    ratio = log_ratio(case)
    age, ratings = number(case.get("age_s")), number(case.get("ratings"))
    if ratio is None or age is None or ratings is None or min(age, ratings) < 0:
        return None
    values = [ratio, math.log1p(age), math.log1p(ratings)]
    if ratings:
        average = number(case.get("rating_avg"))
        if average is None or not 0 <= average <= 5:
            return None
        values.append(average)
    if signal_names:
        signals = case.get("signals")
        if not isinstance(signals, dict) or any(type(signals.get(name)) is not bool for name in signal_names):
            return None
        values.extend(float(signals[name]) for name in signal_names)
    return ("rated" if ratings else "unrated"), values


def protocol_verdict(case, signatures):
    if signatures and case.get("signature") == "invalid":
        return "block", "invalid signature"
    if case.get("twin"):
        return "escalate", "duplicate stall identity needs review"
    return None


class HonestSpace:
    def __init__(self, center, scale, components, reference, cutoff=None):
        self.center = np.asarray(center)
        self.scale = np.asarray(scale)
        self.components = np.asarray(components)
        self.reference = np.asarray(reference)
        self.cutoff = cutoff

    @classmethod
    def fit(cls, examples):
        if len(examples) < MIN_REFERENCE:
            return None
        data = np.asarray(examples)
        center = data.mean(axis=0)
        scale = data.std(axis=0)
        scale[scale < 1e-9] = 1.0
        normalized = (data - center) / scale
        _, singular_values, directions = np.linalg.svd(normalized, full_matrices=False)
        rank = min(2, int(np.count_nonzero(singular_values > 1e-8)))
        if rank == 0:
            return None
        components = directions[:rank]
        for axis in components:
            if axis[np.argmax(np.abs(axis))] < 0:
                axis *= -1
        return cls(center, scale, components, normalized @ components.T)

    def measure(self, values):
        normalized = (np.asarray(values) - self.center) / self.scale
        point = self.components @ normalized
        distances = np.linalg.norm(self.reference - point, axis=1)
        neighbors = np.partition(distances, NEIGHBORS - 1)[:NEIGHBORS]
        # A feature absent or constant during training can still be novel at inference.
        residual = np.linalg.norm(normalized - point @ self.components)
        return point, float(math.hypot(neighbors.mean(), residual))

    def to_json(self):
        return {
            "center": self.center.tolist(),
            "scale": self.scale.tolist(),
            "components": self.components.tolist(),
            "reference": self.reference.tolist(),
            "cutoff": self.cutoff,
        }


class Monitor:
    def __init__(self, spaces, price_cutoff, signal_names=(), fallback_spaces=None):
        self.spaces = spaces
        self.price_cutoff = price_cutoff
        self.signal_names = tuple(signal_names)
        self.fallback_spaces = fallback_spaces if fallback_spaces is not None else {}

    @classmethod
    def load(cls, path):
        model = json.loads(path.read_text())
        return cls(
            {key: HonestSpace(**space) for key, space in model["spaces"].items()},
            model["price_cutoff"],
            model.get("signal_names", ()),
            {key: HonestSpace(**space) for key, space in model.get("fallback_spaces", {}).items()},
        )

    def to_json(self):
        return {
            "spaces": {key: space.to_json() for key, space in self.spaces.items()},
            "price_cutoff": self.price_cutoff,
            "signal_names": list(self.signal_names),
            "fallback_spaces": {key: space.to_json() for key, space in self.fallback_spaces.items()},
        }

    def judge(self, case, signatures, price_only=False):
        assessment = self.assess(case, signatures, price_only)
        return assessment.verdict, assessment.reason

    def assess(self, case, signatures, price_only=False):
        verdict = protocol_verdict(case, signatures)
        if verdict is not None:
            return Assessment(*verdict)
        if price_only:
            ratio = log_ratio(case)
            if ratio is None:
                return Assessment("escalate", "no usable price-to-market ratio")
            verdict = "allow" if -ratio <= self.price_cutoff else "escalate"
            return Assessment(verdict, f"price is {math.exp(ratio):.1%} of market")
        names, spaces = self.signal_names, self.spaces
        profile = features(case, names)
        if profile is None and names:
            names, spaces = (), self.fallback_spaces
            profile = features(case)
        if profile is None:
            return Assessment("escalate", "incomplete price or seller history")
        cohort, values = profile
        space = spaces.get(cohort)
        if space is None:
            return Assessment("escalate", "too few comparable honest stalls")
        _, score = space.measure(values)
        verdict = "allow" if score <= space.cutoff else "escalate"
        if verdict == "escalate" and names:
            unusual = [
                (name, int(value))
                for name, value, center in zip(names, values[-len(names):], space.center[-len(names):])
                if abs(value - center) > 0.5
            ]
            if unusual:
                reason = "unusual: " + ", ".join(SIGNAL_DESCRIPTIONS[name][value] for name, value in unusual)
                codes = (EVIDENCE_CODES[signal] for signal in unusual if signal in EVIDENCE_CODES)
                return Assessment(verdict, reason[:120], next(codes, "unusual_listing"))
        reason = f"distance {score:.3f} vs {space.cutoff:.3f} cutoff; {cohort} seller"
        return Assessment(verdict, reason, "unusual_listing" if verdict == "escalate" else None)

    def decide(self, tick, price_only=False):
        lever = tick.get("lever")
        signatures = not isinstance(lever, dict) or lever.get("signatures") is not False
        verdicts = []
        for case in tick.get("cases") or []:
            if not isinstance(case, dict) or not isinstance(case.get("id"), str):
                continue
            verdict, reason, code = self.assess(case, signatures, price_only)
            item = {"case": case["id"], "verdict": verdict, "reason": reason}
            if code is not None:
                item["reason_code"] = code
            verdicts.append(item)
        return {"verdicts": verdicts}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        path = self.path.rstrip("/")
        if path not in ("/decide", "/price-only/decide"):
            return self.reply(404, {"error": "unknown endpoint"})
        offered = self.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(offered, self.server.authorization):
            return self.reply(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= MAX_REQUEST:
                raise ValueError("invalid length")
            tick = json.loads(self.rfile.read(length))
            if not isinstance(tick, dict) or not isinstance(tick.get("cases"), list):
                raise ValueError("invalid tick")
        except (ValueError, UnicodeError):
            return self.reply(400, {"error": "invalid tick"})
        return self.reply(200, self.server.monitor.decide(tick, price_only=path == "/price-only/decide"))

    def reply(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        if len(body) > MAX_RESPONSE:
            for verdict in payload["verdicts"]:
                del verdict["reason"]
            body = json.dumps(payload, separators=(",", ":")).encode()
        if len(body) > MAX_RESPONSE:
            status, body = 413, b'{"error":"response too large"}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--port", type=int, default=8803)
    args = parser.parse_args()
    token = os.environ.get("SLOT_TOKEN")
    if not token:
        parser.error("SLOT_TOKEN must be set")
    monitor = Monitor.load(args.model)
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
        server.monitor = monitor
        server.authorization = f"Bearer {token}".encode()
        print(f"NANDA Supervisor listening on port {server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
