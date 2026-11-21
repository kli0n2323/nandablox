"""The gateway: one market tick in, fanned out to every slot occupant, merged.

A Roblox server may make only ~500 outbound HTTP requests a minute, so it
never calls monitors and agents one by one. Every tick (~2 s) it sends one
`POST /v1/tick` carrying the open cases and the traders awaiting a decision
(docs/market-design.md, "The slot contract"). This module

  1. checks the request and splits it: every case goes to the monitors, each
     decision goes to the one agent registration that drives that trader;
  2. calls them all in parallel, each with a deadline (~800 ms), through
     outbound.post_json (https only, public hosts, size cap, own token);
  3. validates every verdict and action against the schema, dropping what is
     malformed and saying so in `errors`;
  4. merges: at most one verdict per case and one action per trader.

Whatever is missing from the answer, the Roblox server decides with its own
built-ins. The market never waits on the network.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from typing import Callable

from .limits import RateLimiter
from .outbound import OutboundError, check_url, post_json

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
VERDICTS = ("allow", "block", "escalate")
REVIEW_REASONS = ("empty_counter", "prints_displayed", "unusual_listing")
KINDS = ("monitor", "agent")
MAX_CASES = 500
MAX_DECISIONS = 2000
MAX_ERRORS = 50
MAX_REASON = 120
MAX_PRICE = 10_000_000  # cents: $100,000
_UNPRINTABLE = re.compile(r"[^\x20-\x7e\u00a0-\u024f\u2018-\u201d\u2026]")


def clean_reason(v) -> str | None:
    """Free text from outside code: printable, one line, at most 120 chars.

    The game should still pass it through TextService before a player sees
    it; this only guarantees it is short and harmless to log.
    """
    if not isinstance(v, str):
        return None
    s = " ".join(_UNPRINTABLE.sub(" ", v).split())[:MAX_REASON]
    return s or None


def _int_cents(v) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


class Registration:
    def __init__(self, kind: str, name: str, url: str, token: str | None, roles: list[str] | None, builtin: Callable | None):
        self.kind = kind
        self.name = name
        self.url = url
        self.token = token
        self.roles = roles
        self.builtin = builtin
        self.created = time.time()
        self.inflight = False
        self.calls = self.ok = self.timeouts = self.failures = self.rejected = self.rate_limited = 0
        self.last_error: str | None = None
        self.last_ms: int | None = None

    def public(self) -> dict:
        """What GET /v1/monitors|agents shows. Never the token."""
        d = {
            "name": self.name,
            "url": self.url,
            "builtin": self.builtin is not None,
            "created": round(self.created, 1),
            "stats": {
                "calls": self.calls,
                "ok": self.ok,
                "timeouts": self.timeouts,
                "failures": self.failures,
                "rejected_items": self.rejected,
                "rate_limited": self.rate_limited,
                "last_ms": self.last_ms,
                "last_error": self.last_error,
            },
        }
        if self.kind == "agent":
            d["roles"] = list(self.roles or [])
        return d

    def stored(self) -> dict:
        return {"kind": self.kind, "name": self.name, "url": self.url, "token": self.token, "roles": self.roles}


class Registry:
    """Who sits in the monitor and agent slots. In memory, optionally a file.

    Order matters: outside registrations are consulted in the order they were
    registered, the built-ins after them. Re-registering a name replaces it
    (and moves it to the back of the outside queue).
    """

    def __init__(
        self,
        builtins: dict | None = None,
        path: str | None = None,
        max_per_kind: int = 16,
        per_minute: int = 60,
        allow_localhost: bool = False,
        enable_builtins: tuple = ("rules", "gemini-seller"),
    ):
        # name -> (kind, decide function, roles)
        self.builtins = builtins or {}
        self.path = path
        self.max_per_kind = max_per_kind
        self.allow_localhost = allow_localhost
        self.limiter = RateLimiter(per_minute, 60.0)
        self.lock = threading.Lock()
        self.regs: dict[str, dict[str, Registration]] = {k: {} for k in KINDS}
        if path and os.path.isfile(path):
            self._load()
        else:
            for name in enable_builtins:
                if name in self.builtins:
                    kind, _, roles = self.builtins[name]
                    self.add(kind, {"name": name, "url": f"builtin:{name}", "roles": roles}, save=False)

    # ---------------------------------------------------------- changes

    def add(self, kind: str, body, save: bool = True) -> tuple[Registration | None, str | None]:
        if kind not in KINDS:
            return None, "no such kind"
        if not isinstance(body, dict):
            return None, "expected a JSON object {name, url, token}"
        name, url, token = body.get("name"), body.get("url"), body.get("token")
        if not isinstance(name, str) or not NAME.match(name):
            return None, "name must be 1-32 characters: letters, digits, . _ -"
        builtin = None
        roles = None
        if kind == "agent":
            roles = body.get("roles")
            if not isinstance(roles, list) or not roles or not all(isinstance(r, str) and NAME.match(r) for r in roles):
                return None, "roles must be a non-empty list of role names, e.g. [\"seller\"]"
            roles = sorted(set(roles))
        if isinstance(url, str) and url.startswith("builtin:"):
            b = self.builtins.get(url[len("builtin:") :])
            if b is None or b[0] != kind or name != url[len("builtin:") :]:
                return None, f"no built-in {kind} at {url} (built-ins: " + ", ".join(f"{n} ({v[0]})" for n, v in self.builtins.items()) + ")"
            builtin = b[1]
            token = None
            if kind == "agent":
                roles = sorted(set(roles) & set(b[2])) or list(b[2])
        else:
            if name in self.builtins:
                return None, f"{name} is the name of a built-in; choose another"
            why = check_url(url, self.allow_localhost)
            if why:
                return None, why
            if not isinstance(token, str) or not (8 <= len(token) <= 256) or not token.isprintable():
                return None, "token must be 8-256 printable characters: your endpoint checks it, the gateway sends it as a bearer token"
        reg = Registration(kind, name, url, token, roles, builtin)
        with self.lock:
            table = self.regs[kind]
            if name not in table and len(table) >= self.max_per_kind:
                return None, f"at most {self.max_per_kind} {kind}s may be registered"
            table.pop(name, None)
            table[name] = reg
        if save:
            self._save()
        return reg, None

    def remove(self, kind: str, name: str) -> bool:
        with self.lock:
            gone = self.regs.get(kind, {}).pop(name, None) is not None
        if gone:
            self._save()
        return gone

    # ---------------------------------------------------------- reading

    def get(self, kind: str, name: str) -> Registration | None:
        with self.lock:
            return self.regs[kind].get(name)

    def ordered(self, kind: str) -> list[Registration]:
        with self.lock:
            regs = list(self.regs[kind].values())
        return [r for r in regs if r.builtin is None] + [r for r in regs if r.builtin is not None]

    def listing(self, kind: str) -> list[dict]:
        return [r.public() for r in self.ordered(kind)]

    # ---------------------------------------------------------- the file

    def _save(self) -> None:
        if not self.path:
            return
        with self.lock:
            data = [r.stored() for k in KINDS for r in self.regs[k].values()]
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = f"{self.path}.{os.getpid()}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # it holds registrants' tokens
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"registrations": data}, f)
        os.replace(tmp, self.path)

    def _load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as f:  # type: ignore[arg-type]
                data = json.load(f).get("registrations", [])
        except (OSError, ValueError, AttributeError):
            data = []
        for d in data:
            if isinstance(d, dict):
                reg, why = self.add(d.get("kind"), d, save=False)
                if why:
                    print(json.dumps({"ev": "gateway_load_skipped", "name": str(d.get("name"))[:32], "why": why}), flush=True)


class Gateway:
    def __init__(
        self,
        registry: Registry,
        call_timeout_ms: int = 800,
        tick_deadline_ms: int = 900,
        max_bytes: int = 64 * 1024,
        workers: int = 40,
    ):
        self.registry = registry
        self.call_timeout = call_timeout_ms / 1000.0
        self.tick_deadline = tick_deadline_ms / 1000.0
        self.max_bytes = max_bytes
        self.pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="gateway")
        self.lock = threading.Lock()
        self.ticks = 0
        self.verdicts = 0
        self.actions = 0
        self.errors = 0

    # -------------------------------------------------------------- one call

    def _call(self, reg: Registration, body: dict, deadline: float):
        t0 = time.monotonic()
        try:
            if reg.builtin is not None:
                ans = reg.builtin(json.loads(json.dumps(body)))  # a copy: a builtin sees what an outsider would
            else:
                ans = post_json(
                    reg.url,
                    body,
                    reg.token,
                    deadline,
                    max_bytes=self.max_bytes,
                    allow_localhost=self.registry.allow_localhost,
                )
            if time.monotonic() > deadline:
                raise OutboundError("timeout")
            return ans
        finally:
            reg.last_ms = int((time.monotonic() - t0) * 1000)

    def _submit(self, reg: Registration, body: dict, deadline: float, errors: list):
        with self.lock:
            busy = reg.inflight
            if not busy:
                # built-ins cost nothing to call (the gemini-seller has its
                # own budget); the limit is for outside hosts
                ok = reg.builtin is not None or self.registry.limiter.allow(reg.name)[0]
                if ok:
                    reg.inflight = True
                    reg.calls += 1
        if busy:
            # one call per registration at a time, so a slow host cannot pile
            # up threads; it simply misses ticks until it answers
            errors.append({"from": reg.name, "error": "busy: its previous call has not finished"})
            reg.timeouts += 1
            return None
        if not ok:
            reg.rate_limited += 1
            errors.append({"from": reg.name, "error": "rate limited (per-registration calls per minute)"})
            return None
        fut = self.pool.submit(self._call, reg, body, deadline)

        def done(_f, reg=reg):
            reg.inflight = False

        fut.add_done_callback(done)
        return fut

    # -------------------------------------------------------------- the tick

    def tick(self, req: dict) -> dict:
        t0 = time.monotonic()
        call_deadline = t0 + self.call_timeout
        tick_deadline = t0 + self.tick_deadline
        errors: list[dict] = []
        shared = {k: req.get(k) for k in ("server", "t", "market", "lever") if k in req}

        cases = self._cases(req.get("cases"), errors)
        decisions = self._decisions(req.get("decisions"), errors)

        # -- monitors: every candidate sees every case
        monitors: list[Registration] = []
        if cases:
            want = req.get("monitor")
            if want is not None:
                reg = self.registry.get("monitor", want) if isinstance(want, str) else None
                if reg is None:
                    errors.append({"from": "request", "error": f"no monitor named {str(want)[:32]!r}"})
                else:
                    monitors = [reg]
            else:
                monitors = self.registry.ordered("monitor")

        # -- agents: each decision goes to exactly one registration
        agent_regs = self.registry.ordered("agent")
        groups: dict[str, list[dict]] = {}
        owner: dict[str, Registration] = {}
        for d in decisions:
            drv = d.get("driver")
            reg = None
            if drv is not None:
                reg = self.registry.get("agent", drv) if isinstance(drv, str) else None
                if reg is None:
                    errors.append({"from": "request", "error": f"decision {d['agent']}: no agent named {str(drv)[:32]!r}"})
                    continue
            else:
                reg = next((r for r in agent_regs if d["role"] in (r.roles or [])), None)
                if reg is None:
                    continue  # nobody registered for this role: the game's built-in decides
            groups.setdefault(reg.name, []).append(d)
            owner[reg.name] = reg

        jobs = []  # (reg, future)
        case_body = {**shared, "cases": cases}
        for reg in monitors:
            f = self._submit(reg, case_body, call_deadline, errors)
            if f is not None:
                jobs.append((reg, f))
        for name, ds in groups.items():
            reg = owner[name]
            f = self._submit(reg, {**shared, "decisions": ds}, call_deadline, errors)
            if f is not None:
                jobs.append((reg, f))

        if jobs:
            wait([f for _, f in jobs], timeout=max(0.0, tick_deadline - time.monotonic()))

        case_ids = {c["id"] for c in cases}
        verdict_by: dict[str, dict[str, dict]] = {}  # monitor -> case -> verdict
        actions: list[dict] = []
        seen_agents: set[str] = set()
        for reg, f in jobs:
            if not f.done():
                reg.timeouts += 1
                reg.last_error = "timeout"
                errors.append({"from": reg.name, "error": f"timeout (no answer within {int(self.call_timeout * 1000)} ms)"})
                continue
            exc = f.exception()
            if exc is not None:
                msg = str(exc) if isinstance(exc, OutboundError) else f"failed ({type(exc).__name__})"
                if msg.startswith("timeout"):
                    reg.timeouts += 1
                    msg = f"timeout (no answer within {int(self.call_timeout * 1000)} ms)"
                else:
                    reg.failures += 1
                reg.last_error = msg
                errors.append({"from": reg.name, "error": msg})
                continue
            ans = f.result()
            if not isinstance(ans, dict):
                reg.failures += 1
                reg.last_error = "answer is not a JSON object"
                errors.append({"from": reg.name, "error": reg.last_error})
                continue
            before = len(errors)
            if reg.kind == "monitor":
                verdict_by[reg.name] = self._verdicts(reg, ans, case_ids, errors)
            else:
                allowed = {d["agent"] for d in groups.get(reg.name, [])}
                for a in self._actions(reg, ans, allowed, errors):
                    if a["agent"] not in seen_agents:
                        seen_agents.add(a["agent"])
                        actions.append(a)
            reg.rejected += len(errors) - before
            reg.ok += 1
            reg.last_error = errors[-1]["error"] if len(errors) > before else None

        # one verdict per case: the first monitor, in priority order, that gave one
        verdicts = []
        for c in cases:
            for reg in monitors:
                v = verdict_by.get(reg.name, {}).get(c["id"])
                if v is not None:
                    verdicts.append(v)
                    break

        with self.lock:
            self.ticks += 1
            self.verdicts += len(verdicts)
            self.actions += len(actions)
            self.errors += len(errors)
        if len(errors) > MAX_ERRORS:
            n = len(errors) - MAX_ERRORS + 1
            errors = errors[: MAX_ERRORS - 1] + [{"from": "gateway", "error": f"{n} more errors not shown"}]
        return {
            "verdicts": verdicts,
            "actions": actions,
            "errors": errors,
            "served_ms": int((time.monotonic() - t0) * 1000),
        }

    # ------------------------------------------------------------ validation

    @staticmethod
    def _cases(raw, errors) -> list[dict]:
        if raw is None:
            return []
        if not isinstance(raw, list):
            errors.append({"from": "request", "error": "cases must be a list"})
            return []
        out, ids = [], set()
        for i, c in enumerate(raw):
            if len(out) >= MAX_CASES:
                errors.append({"from": "request", "error": f"more than {MAX_CASES} cases; the rest were not sent"})
                break
            if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not c["id"] or len(c["id"]) > 64:
                errors.append({"from": "request", "error": f"case {i}: needs a string id"})
                continue
            if c["id"] in ids:
                errors.append({"from": "request", "error": f"case {c['id']}: duplicate id"})
                continue
            ids.add(c["id"])
            out.append(c)
        return out

    @staticmethod
    def _decisions(raw, errors) -> list[dict]:
        if raw is None:
            return []
        if not isinstance(raw, list):
            errors.append({"from": "request", "error": "decisions must be a list"})
            return []
        out, ids = [], set()
        for i, d in enumerate(raw):
            if len(out) >= MAX_DECISIONS:
                errors.append({"from": "request", "error": f"more than {MAX_DECISIONS} decisions; the rest were not sent"})
                break
            if not isinstance(d, dict) or not isinstance(d.get("agent"), str) or not d["agent"] or len(d["agent"]) > 64 or not isinstance(d.get("role"), str):
                errors.append({"from": "request", "error": f"decision {i}: needs a string agent and role"})
                continue
            if d["agent"] in ids:
                errors.append({"from": "request", "error": f"decision {d['agent']}: duplicate agent"})
                continue
            ids.add(d["agent"])
            out.append(d)
        return out

    @staticmethod
    def _verdicts(reg: Registration, ans: dict, case_ids: set, errors: list) -> dict[str, dict]:
        raw = ans.get("verdicts")
        if not isinstance(raw, list):
            errors.append({"from": reg.name, "error": "answer has no verdicts list"})
            return {}
        out: dict[str, dict] = {}
        for i, v in enumerate(raw[: len(case_ids) + 10]):
            if not isinstance(v, dict):
                errors.append({"from": reg.name, "error": f"verdict {i}: not an object"})
                continue
            cid = v.get("case")
            if not isinstance(cid, str) or cid not in case_ids:
                errors.append({"from": reg.name, "error": f"verdict {i}: case {str(cid)[:64]!r} was not sent to it"})
                continue
            if v.get("verdict") not in VERDICTS:
                errors.append({"from": reg.name, "error": f"verdict {i}: verdict must be allow, block or escalate"})
                continue
            if cid in out:
                errors.append({"from": reg.name, "error": f"verdict {i}: second verdict for case {cid}, ignored"})
                continue
            item = {"case": cid, "verdict": v["verdict"], "monitor": reg.name}
            reason = clean_reason(v.get("reason"))
            if reason:
                item["reason"] = reason
            code = v.get("reason_code")
            if item["verdict"] == "escalate" and isinstance(code, str) and code in REVIEW_REASONS:
                item["reason_code"] = code
            out[cid] = item
        return out

    @staticmethod
    def _actions(reg: Registration, ans: dict, allowed: set, errors: list) -> list[dict]:
        raw = ans.get("actions")
        if not isinstance(raw, list):
            errors.append({"from": reg.name, "error": "answer has no actions list"})
            return []
        out, seen = [], set()
        for i, a in enumerate(raw[: len(allowed) + 10]):
            if not isinstance(a, dict):
                errors.append({"from": reg.name, "error": f"action {i}: not an object"})
                continue
            agent = a.get("agent")
            if not isinstance(agent, str) or agent not in allowed:
                errors.append({"from": reg.name, "error": f"action {i}: agent {str(agent)[:64]!r} is not one it drives this tick"})
                continue
            price = _int_cents(a.get("set_price"))
            if price is None or not (1 <= price <= MAX_PRICE):
                errors.append({"from": reg.name, "error": f"action {i}: set_price must be an integer number of cents, 1 to {MAX_PRICE}"})
                continue
            if agent in seen:
                errors.append({"from": reg.name, "error": f"action {i}: second action for {agent}, ignored"})
                continue
            seen.add(agent)
            out.append({"agent": agent, "set_price": price, "by": reg.name})
        return out

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "ticks": self.ticks,
                "verdicts": self.verdicts,
                "actions": self.actions,
                "errors": self.errors,
                "monitors": len(self.registry.ordered("monitor")),
                "agents": len(self.registry.ordered("agent")),
            }
