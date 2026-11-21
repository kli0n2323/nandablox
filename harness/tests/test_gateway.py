"""Tests for the gateway: NANDA Market's monitor and agent slots.

Outside monitors and agents are played by a little HTTP server on loopback
whose routes behave well, slowly, or badly. The gateway is started with
`allow_localhost`, which is what lets it call them over plain http; the
production default (https, public hosts only) is tested separately.

Run: cd harness && python -m pytest -q
"""

from __future__ import annotations

import json
import os
import pathlib
import stat
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from nanda_harness.brain import Brain  # noqa: E402
from nanda_harness.builtins import GeminiSeller, MarketBrain, rule_verdict, rules_decide  # noqa: E402
from nanda_harness.gateway import Gateway, Registry  # noqa: E402
from nanda_harness.limits import Budget  # noqa: E402
from nanda_harness.metrics import Metrics  # noqa: E402
from nanda_harness.outbound import OutboundError, check_url, post_json  # noqa: E402

from test_harness import OBS, fake_model, settle  # noqa: E402
from test_hosted import ANSWER, TOKEN, Fixture  # noqa: E402

REG_TOKEN = "registration-t0ken"
SLOT_TOKEN = "slot-token-of-team-a"
STARTER = pathlib.Path(__file__).resolve().parents[1] / "starter"
TICK = json.loads((STARTER / "tick.json").read_text())


# ------------------------------------------------------- pretend outside code


class Outside:
    """Routes: /good /slow /broken /junk /huge /liar /agent /badagent.

    Every request is recorded with its headers, so a test can see exactly
    what the gateway sent to outside code.
    """

    def __init__(self):
        self.seen: list[tuple[str, dict, dict]] = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
                route = self.path.rsplit("/decide", 1)[0].strip("/")
                outer.seen.append((self.path, dict(self.headers), body))
                cases = body.get("cases", [])
                if route == "slow":
                    time.sleep(2.0)
                    return self.reply(200, {"verdicts": [{"case": c["id"], "verdict": "allow"} for c in cases]})
                if route == "broken":
                    return self.reply(500, {"error": "kaboom"})
                if route == "junk":
                    return self.reply(200, b"<html>not json</html>")
                if route == "huge":
                    return self.reply(200, {"verdicts": [], "pad": "x" * 200_000})
                if route == "liar":
                    # every way a verdict can be wrong, and one that is right
                    return self.reply(
                        200,
                        {
                            "verdicts": [
                                {"case": "nope", "verdict": "allow"},
                                {"case": cases[0]["id"], "verdict": "maybe"},
                                "not an object",
                                {"case": cases[0]["id"], "verdict": "block", "monitor": "rules", "reason": "bad\nnews\x00" + "!" * 300},
                                {"case": cases[0]["id"], "verdict": "allow"},
                            ]
                        },
                    )
                if route == "agent":
                    return self.reply(200, {"actions": [{"agent": d["agent"], "set_price": d["market"] - 10} for d in body.get("decisions", [])]})
                if route == "badagent":
                    ds = body.get("decisions", [])
                    return self.reply(
                        200,
                        {
                            "actions": [
                                {"agent": "someone-else", "set_price": 100},
                                {"agent": ds[0]["agent"], "set_price": -5},
                                {"agent": ds[0]["agent"], "set_price": 99.5},
                                {"agent": ds[0]["agent"], "set_price": True},
                                {"agent": ds[0]["agent"], "set_price": 250.0},
                            ]
                        },
                    )
                # good: escalate everything, with a reason
                return self.reply(200, {"verdicts": [{"case": c["id"], "verdict": "escalate", "reason": "team-a says look"} for c in cases]})

            def reply(self, code, obj):
                raw = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                try:
                    self.wfile.write(raw)
                except OSError:
                    pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, route):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}/{route}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def make_gateway(path=None, per_minute=600, model_call=None, budget=None, **kw):
    brain = MarketBrain(model_call=model_call, log_path=os.devnull, min_interval=0, metrics=Metrics(), budget=budget or Budget(), max_agents=4)
    seller = GeminiSeller(brain)
    reg = Registry(
        builtins={"rules": ("monitor", rules_decide, None), "gemini-seller": ("agent", seller.decide, ["seller"])},
        path=path,
        per_minute=per_minute,
        allow_localhost=True,
    )
    return Gateway(reg, **kw), brain


class GW(Fixture):
    """The whole service: the town's brain, the gateway, both tokens."""

    def __init__(self, gateway=None, legacy=None, **kw):
        self.gateway = gateway or make_gateway()[0]
        legacy = legacy or Brain(model_call=fake_model(ANSWER), log_path=os.devnull, min_interval=0, metrics=Metrics())
        kw.setdefault("registration_token", REG_TOKEN)
        super().__init__(legacy, gateway=self.gateway, **kw)

    def register(self, kind, name, url, token=SLOT_TOKEN, roles=None, auth=TOKEN):
        body = {"name": name, "url": url, "token": token}
        if roles is not None:
            body["roles"] = roles
        return self.call(f"/v1/{kind}s", body, token=auth)

    def tick(self, body=None, **kw):
        return self.call("/v1/tick", body if body is not None else TICK, **kw)


def ids(verdicts):
    return {v["case"]: v for v in verdicts}


# ---------------------------------------------------------- the rule monitor


def case(**kw):
    c = {"id": "c", "good": "bread", "price": 300, "market": 300, "age_s": 4, "ratings": 0, "twin": False}
    c.update(kw)
    return c


def test_the_built_in_rule_monitor_is_the_four_lines_in_the_design():
    # 1. a twin with signatures off: escalate, whatever its price
    assert rule_verdict(case(twin=True, price=300), signatures=False)[0] == "escalate"
    assert rule_verdict(case(twin=True, price=300), signatures=True)[0] == "allow"
    # 2. near the market, or well rated: allow
    assert rule_verdict(case(price=255), True)[0] == "allow"  # exactly 85%
    assert rule_verdict(case(price=254), True)[0] == "escalate"
    assert rule_verdict(case(price=10, ratings=5), True)[0] == "allow"
    # 3. far below market and new: block
    assert rule_verdict(case(price=149, age_s=59), True)[0] == "block"
    assert rule_verdict(case(price=150, age_s=4), True)[0] == "escalate"  # exactly 50% is not < 50%
    assert rule_verdict(case(price=149, age_s=60), True)[0] == "escalate"
    # 4. everything else: escalate
    assert rule_verdict(case(price=200), True)[0] == "escalate"
    # no market price in the case: the tick's market table is used
    assert rule_verdict(case(market=None, price=100), True, {"bread": 300})[0] == "block"
    assert rule_verdict(case(market=None, price=100), True, {})[0] == "escalate"


def test_the_starter_monitor_is_a_different_rule():
    sys.path.insert(0, str(STARTER))
    import monitor  # noqa: E402

    differ = 0
    for c in TICK["cases"]:
        mine = monitor.judge(c, True)[0]
        builtin = rule_verdict(c, True)[0]
        differ += mine != builtin
    assert differ >= 2  # the sample tick shows the difference


# ------------------------------------------------------------- the contract


def test_a_market_tick_answers_in_the_contract_shape():
    f = GW()
    try:
        code, body, _ = f.tick()
        assert code == 200
        assert set(body) == {"verdicts", "actions", "errors", "served_ms"}
        assert body["errors"] == []
        v = ids(body["verdicts"])
        assert set(v) == {c["id"] for c in TICK["cases"]}  # one verdict per case
        assert v["c-17"] == {"case": "c-17", "verdict": "escalate", "monitor": "rules", "reason": "40% below market: the gray zone"}
        assert v["c-18"]["verdict"] == "block"
        for x in body["verdicts"]:
            assert set(x) <= {"case", "verdict", "monitor", "reason"}
        # no key in this gateway: the gemini-seller has no stance, so no action
        assert body["actions"] == []
    finally:
        f.close()


def test_the_example_in_the_design_doc_round_trips():
    doc = (pathlib.Path(__file__).resolve().parents[2] / "docs/market-design.md").read_text()
    req = json.loads(doc.split("`POST /v1/tick` (bearer token), from the Roblox server:")[1].split("```json")[1].split("```")[0])
    f = GW()
    try:
        code, body, _ = f.tick(req)
        assert code == 200 and body["verdicts"][0]["case"] == "c-17" and body["errors"] == []
    finally:
        f.close()


def test_an_outside_monitor_and_agent_are_called_with_their_subset_and_their_own_token():
    out = Outside()
    f = GW()
    try:
        assert f.register("monitor", "team-a", out.url("good"))[0] == 201
        assert f.register("agent", "team-b", out.url("agent"), roles=["seller"])[0] == 201
        code, body, _ = f.tick(server="JOB-1")
        assert code == 200 and body["errors"] == []
        # the outside monitor outranks the built-in rules
        assert all(v["monitor"] == "team-a" and v["verdict"] == "escalate" for v in body["verdicts"])
        assert {a["agent"]: a["set_price"] for a in body["actions"]} == {"seller-12": 285, "seller-13": 1200}
        assert all(a["by"] == "team-b" for a in body["actions"])
        mon = [s for s in out.seen if s[0] == "/good/decide"][0]
        ag = [s for s in out.seen if s[0] == "/agent/decide"][0]
        # each sees only its part, in the same shapes
        assert "decisions" not in mon[2] and mon[2]["cases"] == TICK["cases"]
        assert "cases" not in ag[2] and ag[2]["decisions"] == TICK["decisions"]
        assert mon[2]["market"] == TICK["market"] and mon[2]["lever"] == TICK["lever"]
        # and the bearer token is the registration's, never the gateway's
        for _, headers, _ in out.seen:
            assert headers.get("Authorization") == f"Bearer {SLOT_TOKEN}"
            assert TOKEN not in json.dumps(headers) and REG_TOKEN not in json.dumps(headers)
    finally:
        f.close()
        out.close()


def test_the_request_can_pick_the_monitor_and_the_driver():
    out = Outside()
    f = GW()
    try:
        f.register("monitor", "team-a", out.url("good"))
        f.register("agent", "team-b", out.url("agent"), roles=["seller"])
        req = dict(TICK, monitor="rules")
        req["decisions"] = [dict(TICK["decisions"][0], driver="gemini-seller"), TICK["decisions"][1]]
        code, body, _ = f.tick(req)
        assert all(v["monitor"] == "rules" for v in body["verdicts"])
        assert not any(s[0] == "/good/decide" for s in out.seen)  # not even asked
        sent = [s[2] for s in out.seen if s[0] == "/agent/decide"][0]
        assert [d["agent"] for d in sent["decisions"]] == ["seller-13"]
        code, body, _ = f.tick(dict(TICK, monitor="nobody"))
        assert body["verdicts"] == [] and "no monitor named" in body["errors"][0]["error"]
        # a role nobody has registered for is simply left to the game
        req = dict(TICK, cases=[], decisions=[{"agent": "buyer-1", "role": "buyer"}])
        body = f.tick(req)[1]
        body.pop("served_ms")
        assert body == {"verdicts": [], "actions": [], "errors": []}
    finally:
        f.close()
        out.close()


# --------------------------------------------------------- fan-out, fallback


def test_a_slow_and_a_broken_monitor_cannot_hold_up_the_tick():
    out = Outside()
    f = GW()
    try:
        f.register("monitor", "slowpoke", out.url("slow"))
        f.register("monitor", "broken", out.url("broken"))
        f.register("monitor", "junk", out.url("junk"))
        f.register("monitor", "huge", out.url("huge"))
        t0 = time.monotonic()
        code, body, _ = f.tick()
        took = time.monotonic() - t0
        assert code == 200 and took < 1.5, took  # the 2 s monitor was not waited for
        # the cases still got verdicts: the built-in rules, last in line
        assert {v["monitor"] for v in body["verdicts"]} == {"rules"}
        errs = {e["from"]: e["error"] for e in body["errors"]}
        assert errs["slowpoke"].startswith("timeout")
        assert errs["broken"] == "http 500"
        assert errs["junk"] == "answer is not JSON"
        assert errs["huge"].startswith("answer larger than")
        # while the slow one is still busy, it is skipped, not piled up
        code, body, _ = f.tick()
        assert any(e["from"] == "slowpoke" and e["error"].startswith(("busy", "timeout")) for e in body["errors"])
        listing = {m["name"]: m for m in f.call("/v1/monitors")[1]["monitors"]}
        assert listing["slowpoke"]["stats"]["timeouts"] >= 1
        assert listing["broken"]["stats"]["failures"] >= 1
    finally:
        f.close()
        out.close()


def test_with_nothing_registered_the_tick_is_empty_and_the_game_decides():
    gw, _ = make_gateway()
    gw.registry.remove("monitor", "rules")
    gw.registry.remove("agent", "gemini-seller")
    out = gw.tick(TICK)
    assert out["verdicts"] == [] and out["actions"] == [] and out["errors"] == []


def test_a_registration_is_rate_limited_on_its_own():
    out = Outside()
    gw, _ = make_gateway(per_minute=2)
    try:
        gw.registry.add("monitor", {"name": "team-a", "url": out.url("good"), "token": SLOT_TOKEN})
        gw.tick(TICK)
        gw.tick(TICK)
        res = gw.tick(TICK)
        assert any(e["from"] == "team-a" and "rate limited" in e["error"] for e in res["errors"])
        assert {v["monitor"] for v in res["verdicts"]} == {"rules"}  # rules has its own window
    finally:
        out.close()


# ------------------------------------------------------- schema validation


def test_malformed_verdicts_are_dropped_and_named():
    out = Outside()
    f = GW()
    try:
        f.register("monitor", "liar", out.url("liar"))
        code, body, _ = f.tick()
        v = ids(body["verdicts"])
        first = TICK["cases"][0]["id"]
        # the one well-formed verdict survives, under its real name, cleaned
        assert v[first]["verdict"] == "block" and v[first]["monitor"] == "liar"
        assert "\n" not in v[first]["reason"] and "\x00" not in v[first]["reason"]
        assert len(v[first]["reason"]) <= 120
        # every other case fell back to the rules
        assert all(v[c["id"]]["monitor"] == "rules" for c in TICK["cases"][1:])
        errs = [e["error"] for e in body["errors"] if e["from"] == "liar"]
        assert any("'nope' was not sent" in e for e in errs)
        assert any("allow, block or escalate" in e for e in errs)
        assert any("not an object" in e for e in errs)
        assert any("second verdict" in e for e in errs)
    finally:
        f.close()
        out.close()


def test_malformed_actions_are_dropped_and_named():
    out = Outside()
    f = GW()
    try:
        f.register("agent", "badagent", out.url("badagent"), roles=["seller"])
        code, body, _ = f.tick()
        # only the last one, 250.0 (an integral float), is a valid set_price
        assert body["actions"] == [{"agent": "seller-12", "set_price": 250, "by": "badagent"}]
        errs = [e["error"] for e in body["errors"] if e["from"] == "badagent"]
        assert any("'someone-else' is not one it drives" in e for e in errs)
        assert sum("set_price must be an integer" in e for e in errs) == 3
    finally:
        f.close()
        out.close()


def test_review_reason_codes_are_only_forwarded_on_escalations():
    gw, _ = make_gateway()
    reg = gw.registry.get("monitor", "rules")
    reply = {"verdicts": [
        {"case": "a", "verdict": "escalate", "reason_code": "prints_displayed"},
        {"case": "b", "verdict": "escalate", "reason_code": "arbitrary remote text"},
        {"case": "c", "verdict": "allow", "reason_code": "empty_counter"},
    ]}
    errors = []
    verdicts = gw._verdicts(reg, reply, {"a", "b", "c"}, errors)
    assert not errors
    assert verdicts["a"]["reason_code"] == "prints_displayed"
    assert "reason_code" not in verdicts["b"]
    assert "reason_code" not in verdicts["c"]


def test_a_malformed_request_is_answered_not_crashed():
    f = GW()
    try:
        code, body, _ = f.tick({"cases": "lots", "decisions": [1, {"agent": "x"}]})
        assert code == 200 and body["verdicts"] == [] and body["actions"] == []
        errs = [e["error"] for e in body["errors"]]
        assert "cases must be a list" in errs
        assert sum("needs a string agent and role" in e for e in errs) == 2
        code, body, _ = f.tick({"cases": [{"id": "a"}, {"id": "a"}, {"no": "id"}]})
        assert len(body["verdicts"]) == 1 and len(body["errors"]) == 2
        assert f.tick([1, 2])[0] == 400
    finally:
        f.close()


def test_registration_is_checked():
    f = GW()
    try:
        bad = [
            ({"name": "a b", "url": "https://x.example", "token": SLOT_TOKEN}, "name"),
            ({"name": "a", "url": "http://x.example", "token": SLOT_TOKEN}, "https"),
            ({"name": "a", "url": "ftp://x.example", "token": SLOT_TOKEN}, "https"),
            ({"name": "a", "url": "https://u:p@x.example", "token": SLOT_TOKEN}, "credentials"),
            ({"name": "a", "url": "https://x.example", "token": "short"}, "token"),
            ({"name": "a", "url": "https://x.example"}, "token"),
            ({"name": "rules", "url": "https://x.example", "token": SLOT_TOKEN}, "built-in"),
            ({"name": "a", "url": "builtin:gemini-seller", "token": SLOT_TOKEN}, "no built-in"),
        ]
        for body, word in bad:
            code, ans, _ = f.call("/v1/monitors", body)
            assert code == 400 and word in ans["error"], (body, ans)
        code, ans, _ = f.call("/v1/agents", {"name": "a", "url": "https://x.example", "token": SLOT_TOKEN})
        assert code == 400 and "roles" in ans["error"]
        # a token is never shown back
        assert f.register("monitor", "team-a", "https://team-a.example/m")[0] == 201
        listing = f.call("/v1/monitors")[1]
        assert SLOT_TOKEN not in json.dumps(listing)
        assert [m["name"] for m in listing["monitors"]] == ["team-a", "rules"]
        assert f.call("/v1/monitors/team-a", method="DELETE")[0] == 200
        assert f.call("/v1/monitors/team-a", method="DELETE")[0] == 404
    finally:
        f.close()


def test_production_urls_are_https_to_public_hosts_only():
    for url in (
        "http://localhost:8801",
        "https://localhost:8801",
        "https://127.0.0.1",
        "https://10.0.0.5/x",
        "https://169.254.169.254/latest",
        "https://[::1]/",
        "https://nanda-harness.railway.internal",
    ):
        assert check_url(url, allow_localhost=False), url
    assert check_url("https://team-a.example.com/monitor") is None
    assert check_url("http://localhost:8801", allow_localhost=True) is None
    assert check_url("http://example.com", allow_localhost=True)  # http stays local-only
    # and at call time, a name that resolves to a private address is refused
    try:
        post_json("https://localtest.me/x", {}, "t", time.monotonic() + 2)
    except OutboundError as e:
        assert "private" in str(e) or "resolve" in str(e) or "connection" in str(e), e
    else:
        raise AssertionError("a private address was called")


# --------------------------------------------------------------------- auth


def test_the_tick_and_the_registry_need_a_token():
    f = GW()
    try:
        assert f.tick(token=None)[0] == 401
        assert f.call("/v1/monitors", token=None)[0] == 401
        assert f.register("monitor", "x", "https://x.example", auth=None)[0] == 401
        assert f.call("/v1/builtin/rules/decide", {"cases": []}, token=None)[0] == 401
        # the registration token opens registration and nothing else
        assert f.register("monitor", "team-a", "https://team-a.example", auth=REG_TOKEN)[0] == 201
        assert f.call("/v1/monitors", token=REG_TOKEN)[0] == 200
        assert f.call("/v1/monitors/team-a", token=REG_TOKEN, method="DELETE")[0] == 200
        assert f.tick(token=REG_TOKEN)[0] == 401
        assert f.call("/v1/tick", OBS, token=REG_TOKEN)[0] == 401
        assert f.call("/v1/health", token=REG_TOKEN)[0] == 401
        # and cannot take a built-in out of the market
        assert f.call("/v1/monitors/rules", token=REG_TOKEN, method="DELETE")[0] == 403
        assert f.call("/v1/monitors/rules", method="DELETE")[0] == 200
        assert f.call("/v1/monitors", {"name": "rules", "url": "builtin:rules"})[0] == 201
    finally:
        f.close()


def test_without_a_registration_token_only_the_operator_registers():
    f = GW(registration_token=None)
    try:
        assert f.register("monitor", "team-a", "https://team-a.example", auth=REG_TOKEN)[0] == 401
        assert f.register("monitor", "team-a", "https://team-a.example")[0] == 201
    finally:
        f.close()


def test_the_built_ins_are_decide_endpoints_too():
    f = GW()
    try:
        code, body, _ = f.call("/v1/builtin/rules/decide", {"lever": {"signatures": False}, "cases": [case(id="c-1", twin=True)]})
        assert code == 200 and body["verdicts"][0]["verdict"] == "escalate"
        code, body, _ = f.call("/v1/builtin/gemini-seller/decide", {"decisions": TICK["decisions"]})
        assert code == 200 and body == {"actions": []}  # no key here, so no stance
        assert f.call("/v1/builtin/nope/decide", {})[0] == 404
    finally:
        f.close()


# ----------------------------------------------------------- gemini-seller


def test_the_gemini_seller_speaks_decide_on_its_own_budget():
    call = fake_model({"quote_pct": 90, "floor_pct": 85, "reason": "undercut_rival"})
    gw_budget = Budget(per_minute=1, per_hour=10, per_day=10, usd_per_day=0, usd_total=0)
    gw, brain = make_gateway(model_call=call, budget=gw_budget)
    legacy_budget = Budget(per_minute=40)
    legacy = Brain(model_call=fake_model(ANSWER), log_path=os.devnull, min_interval=0, budget=legacy_budget, metrics=Metrics())
    f = GW(gateway=gw, legacy=legacy)
    try:
        req = dict(TICK, cases=[], decisions=TICK["decisions"][:1])
        assert f.tick(req)[1]["actions"] == []  # first sight: queued, not waited for
        settle(brain)
        body = f.tick(req)[1]
        assert body["actions"] == [{"agent": "seller-12", "set_price": 266, "by": "gemini-seller"}]  # 90% of 295
        assert "NANDA Market" in call.calls[0] and "bread" in call.calls[0]
        # the stance follows the market price it is handed
        moved = dict(req, decisions=[dict(TICK["decisions"][0], market=400)])
        assert f.tick(moved)[1]["actions"][0]["set_price"] == 360
        # the market's model calls are on the market's budget, not the town's
        assert gw_budget.snapshot()["calls"] == 1 and legacy_budget.snapshot()["calls"] == 0
        f.call("/v1/tick", OBS)
        settle(legacy)
        assert legacy_budget.snapshot()["calls"] == 1
    finally:
        f.close()


def test_the_gemini_seller_gives_an_idle_trader_its_seat_back():
    clock = [0.0]
    call = fake_model({"quote_pct": 100, "floor_pct": 90, "reason": "steady"})
    brain = MarketBrain(model_call=call, log_path=os.devnull, min_interval=0, metrics=Metrics(), max_agents=1, now=lambda: clock[0])
    seller = GeminiSeller(brain, idle_s=60)
    one = {"decisions": [dict(TICK["decisions"][0], agent="old-seller")]}
    two = {"decisions": [dict(TICK["decisions"][0], agent="new-seller")]}
    seller.decide(one)
    settle(brain)
    seller.decide(two)  # the only seat is taken
    assert list(brain.agents) == ["old-seller"]
    clock[0] += 61
    seller.decide(two)  # old-seller has not been asked about for a minute
    settle(brain)
    assert list(brain.agents) == ["new-seller"]
    assert seller.decide(two)["actions"][0]["agent"] == "new-seller"


# -------------------------------------------------- backward compatibility


def test_the_town_tick_is_untouched_by_the_gateway():
    f = GW()
    try:
        code, first, _ = f.call("/v1/tick", OBS)
        assert code == 200
        assert set(first) == {"actions", "llm", "model", "pending", "errors", "budget", "served_ms"}
        settle(f.brain)
        second = f.call("/v1/tick", OBS)[1]
        assert second["actions"][0]["quote_pct"] == 92 and second["actions"][0]["kind"] == "seller_pricing"
        assert f.gateway.ticks == 0  # it never reached the gateway
        # the old junk-body behaviour is unchanged too
        assert f.call("/v1/tick", {"agents": "not a list"})[1]["actions"] == []
        for path in ("/v1/health", "/metrics", "/v1/log?n=1"):
            assert f.call(path)[0] == 200
        assert "gateway" in f.call("/metrics")[1]
        assert "/v1/tick" in f.call("/", token=None)[1]["routes"]
    finally:
        f.close()


# ------------------------------------------------------------ persistence


def test_registrations_survive_a_restart_in_a_private_file(tmp_path):
    path = str(tmp_path / "registry.json")
    gw, _ = make_gateway(path=path)
    gw.registry.add("monitor", {"name": "team-a", "url": "https://team-a.example", "token": SLOT_TOKEN})
    gw.registry.add("agent", {"name": "team-b", "url": "https://team-b.example", "token": SLOT_TOKEN, "roles": ["seller"]})
    gw.registry.remove("monitor", "rules")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    again, _ = make_gateway(path=path)
    assert [r.name for r in again.registry.ordered("monitor")] == ["team-a"]  # rules stays removed
    assert [r.name for r in again.registry.ordered("agent")] == ["team-b", "gemini-seller"]
    assert again.registry.get("agent", "team-b").token == SLOT_TOKEN
