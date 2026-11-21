-- Gateway: one POST /v1/tick per tick, the slot contract's shapes, off by
-- default, and every failure falls back without the market waiting.

local lib = require("./lib")
local serde = require("@lune/serde")

local function enc(t)
	return serde.encode("json", t)
end
local function dec(s)
	return serde.decode("json", s)
end

local function sim()
	local s = lib.MarketSim.new({ seed = 21, n = 300 })
	s:setMonitor("external")
	s:addWatcher("me")
	s:runUntil(10)
	s:injectFraud("scam", { price = 0.7 })
	s:injectFraud("scam", { price = 0.6 })
	s:drain()
	return s
end

return function(t)
	t.case("off by default: no request at all", function(A)
		local calls = 0
		local gw = lib.Gateway.new({ config = lib.Config, encode = enc, decode = dec, post = function()
			calls += 1
			return true, 200, "{}"
		end })
		A.eq(gw.enabled, false)
		A.eq(gw:tick(sim(), 0), "off")
		A.eq(calls, 0)
	end)

	t.case("one call carries every case and decision, in the contract's shapes", function(A)
		local s = sim()
		local seller = s.sellers[1]
		s:setPolicy(seller.id, "external", "gemini")
		local seen
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function(url, body, headers)
			seen = { url = url, body = dec(body), headers = headers }
			local verdicts, actions = {}, {}
			for _, c in seen.body.cases do
				table.insert(verdicts, { case = c.id, verdict = "escalate", monitor = "team-a", reason = "test" })
			end
			for _, d in seen.body.decisions do
				table.insert(actions, { agent = d.agent, set_price = d.market })
			end
			return true, 200, enc({ verdicts = verdicts, actions = actions })
		end })
		A.eq(gw:tick(s, s.now, "job-1"), "ok")
		A.eq(seen.url, lib.Config.GATEWAY_URL .. "/v1/tick")
		local b = seen.body
		A.eq(b.server, "job-1")
		A.eq(seen.headers["X-Nanda-Server"], "job-1", "the per-server rate-limit key")
		A.eq(b.monitor, nil, "no monitor named: ask every registered monitor")
		A.ok(type(b.t) == "number" and type(b.market.bread) == "number", "t, market")
		A.eq(b.lever.signatures, true)
		A.ok(#b.cases > 0, "cases")
		local c = b.cases[1]
		for _, k in { "id", "stall", "good", "price", "market", "age_s", "ratings", "signature", "twin", "deadline_s" } do
			A.ok(c[k] ~= nil, "case field " .. k)
		end
		A.eq(c.truth, nil, "no ground truth on the wire")
		A.ok(c.price == math.floor(c.price), "integer cents")
		A.eq(#b.decisions, 1)
		A.eq(gw.stats.verdicts, #b.cases, "every verdict applied")
		A.eq(gw.stats.actions, 1)
		A.eq(gw:tick(s, s.now + 0.5), "wait", "one call per tick, not more")
	end)

	t.case("a failing gateway backs off and the market carries on with the rules", function(A)
		local s = sim()
		local calls = 0
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function()
			calls += 1
			error("HttpError: ConnectFail")
		end })
		A.eq(gw:tick(s, s.now), "error")
		A.eq(gw.backoff, 3)
		A.eq(gw:tick(s, s.now + 2.5), "wait", "backing off")
		A.eq(gw:tick(s, s.now + 3.1), "error")
		A.eq(gw.backoff, 6, "doubling")
		-- the market didn't wait: cases fell back to the rules
		s:runUntil(s.now + 10)
		A.ok(s.gatewayStats.fallbacks > 0, "rules decided")
		for _, c in s.caseList do
			A.ok(c.stage ~= "monitor" or s.now - c.created <= lib.Config.MONITOR_WAIT_S + 0.01, "nothing stuck in the monitor")
		end
	end)

	t.case("listing signals reflect the watcher view and omit private labels", function(A)
		local s = sim()
		local fraud = s:injectFraud("counterfeit", { vouch = true })
		local talker = s:injectFraud("talker")
		local observed = {}
		for _, c in s:gatewayRequest().cases do
			observed[c.id] = c
		end
		local fake = observed[fraud.case]
		A.eq(fake.signals.stocked, true)
		A.eq(fake.signals.displays_prints, true)
		A.eq(fake.signals.vouched, true)
		A.eq(fake.signals.listing_note, true)
		A.eq(fake.signals.pitch_present, false)
		A.eq(fake.truth, nil)
		A.eq(fake.listing, nil)
		A.eq(fake.vouchedBy, nil)
		local pitch = observed[talker.case]
		A.eq(pitch.signals.stocked, false)
		A.eq(pitch.signals.displays_prints, false)
		A.eq(pitch.signals.pitch_present, true)
		A.eq(pitch.pitch, nil)
	end)

	t.case("only corroborated review evidence moves a case ahead in the queue", function(A)
		for _, prioritize in { false, true } do
			local s = lib.MarketSim.new({ seed = 21, n = 50, reviewOrder = if prioritize then "priority" else "deadline" })
			s.fraudsPaused = true
			s:setMonitor("external")
			local watcher = s:addWatcher("me", { auto = true })
			local earlier = s:injectFraud("counterfeit", { window = 13 })
			local later = s:injectFraud("counterfeit", { window = 16 })
			local expiring = s:injectFraud("counterfeit", { window = 1 })
			local old, new = earlier.case, later.case
			s:applyGateway({ verdicts = {
				{ case = old, verdict = "escalate", monitor = "team", reason_code = "empty_counter" },
				{ case = new, verdict = "escalate", monitor = "team", reason_code = "prints_displayed" },
				{ case = expiring.case, verdict = "escalate", monitor = "team", reason_code = "prints_displayed" },
			} })
			local cards = s:inbox("me")
			A.eq(cards[1].reason_code, nil, "a stocked counter cannot claim the empty-counter label")
			A.eq(cards[2].reason_code, "prints_displayed")
			A.eq(cards[2].review_at, if prioritize then cards[2].deadline_at - lib.Config.WATCHER_SECONDS else nil)
			s:step(0.25)
			A.eq(watcher.working, if prioritize then new else old)
			s:runUntil(1.25)
			A.eq(s:getTotals().expiredWaiting, 1)
		end
	end)

	t.case("HTTP errors and junk JSON are failures, not crashes", function(A)
		local s = sim()
		local replies = { { true, 503, "busy" }, { true, 200, "not json" }, { false, 0, "" } }
		local i = 0
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function()
			i += 1
			return table.unpack(replies[i])
		end })
		local now = s.now
		for _ = 1, 3 do
			A.eq(gw:tick(s, now), "error")
			now += 31
		end
		A.eq(gw.stats.errors, 3)
	end)

	t.case("429 honours Retry-After; a named monitor is asked by name", function(A)
		local s = sim()
		s:setMonitor("external", "team-a")
		local body
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function(_, b)
			body = dec(b)
			return true, 429, "", 20
		end })
		A.eq(gw:tick(s, 100), "error")
		A.eq(body.monitor, "team-a")
		A.eq(gw:tick(s, 110), "wait", "still waiting out Retry-After")
		A.ok(gw.nextAt >= 120, "Retry-After honoured")
	end)

	t.case("the per-minute ceiling holds whatever happens", function(A)
		local s = sim()
		local cfg = lib.config({ GATEWAY_EVERY_S = 0 })
		local gw = lib.Gateway.new({ config = cfg, enabled = true, encode = enc, decode = dec, post = function()
			return true, 200, "{}"
		end })
		local okN = 0
		for k = 1, 200 do
			s:injectFraud("scam")
			if gw:tick(s, k * 0.1) == "ok" then
				okN += 1
			end
		end
		A.eq(okN, cfg.GATEWAY_MAX_PER_MINUTE)
	end)
end
