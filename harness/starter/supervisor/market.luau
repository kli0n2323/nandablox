-- Capture the real gateway payload with private labels, or play through HTTP.
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Config = require("../../../roblox/src/market/shared/Market/Config")
local Gateway = require("../../../roblox/src/market/shared/Market/Gateway")
local MarketSim = require("../../../roblox/src/market/shared/Market/MarketSim")

local function encode(value)
	return serde.encode("json", value)
end

local function decode(value)
	return serde.decode("json", value)
end

local function encodeTick(tick)
	-- Lune encodes an empty Luau table as a JSON object. These fields are optional.
	if #tick.decisions == 0 then
		tick.decisions = nil
	end
	return encode(tick)
end

local function post(url, body, headers)
	local response = net.request({ url = url, method = "POST", body = body, headers = headers })
	return response.ok, response.statusCode, response.body
end

local function run(seed, seconds, policy, gatewayUrl, reviewOrder, signalCondition)
	local sim = MarketSim.new({
		seed = seed,
		n = 300,
		signatures = seed % 2 == 0,
		reviewOrder = reviewOrder,
	})
	sim:setMonitor("external", policy)
	sim:setCounterfeitShare(0.15)
	local redBot = seed >= 37
	if redBot then
		sim:setRedBot(true, 10)
	end
	sim:addWatcher("demo-watcher", { auto = true })
	local headers = { ["Content-Type"] = "application/json" }
	local token = process.env.NANDA_HARNESS_TOKEN
	if token and token ~= "" then
		headers.Authorization = "Bearer " .. token
	end
	local function capture(_, body)
		local tick = decode(body)
		local truth, verdicts = {}, {}
		for _, case in tick.cases do
			truth[case.id] = sim.cases[case.id].truth
			local verdict = MarketSim.ruleMonitor(case, tick.lever.signatures, Config)
			table.insert(verdicts, { case = case.id, verdict = verdict, monitor = "rules" })
		end
		print(encode({ seed = seed, tick = tick, truth = truth }))
		return true, 200, encode({ verdicts = verdicts })
	end
	local affected = 0
	local function encodeRequest(tick)
		if signalCondition == "missing" then
			for _, c in tick.cases do
				local index = tonumber(string.sub(c.id, 3)) + seed
				if index % 5 == 0 then
					local cue = if index % 2 == 0 then "stocked" else "displays_prints"
					c.signals[cue] = nil
					affected += 1
				end
			end
		end
		return encodeTick(tick)
	end
	local gw = Gateway.new({
		config = Config,
		enabled = true,
		url = gatewayUrl,
		headers = headers,
		encode = encodeRequest,
		decode = decode,
		post = if gatewayUrl then post else capture,
	})
	local server = string.format("%s-%d-%s-%s", policy, seed, reviewOrder or "priority", signalCondition or "normal")
	local gatewayMs = {}
	for _ = 1, seconds * 4 do
		sim:step(0.25)
		if signalCondition == "empty-honest" then
			for _, c in sim.caseList do
				-- Change the observation during review while keeping the honest sale behavior.
				if c.stage == "monitor" and c.truth == "honest" and not c.twin and c.hasStock
					and (tonumber(string.sub(c.id, 3)) + seed) % 10 == 0 then
					c.hasStock = false
					affected += 1
				end
			end
		end
		if gw:tick(sim, sim.now, server) == "ok" and gw.servedMs then
			table.insert(gatewayMs, gw.servedMs)
		end
		sim:drain()
	end
	if gatewayUrl then
		local totals = sim:getTotals()
		table.sort(gatewayMs)
		local summary = {
			policy = policy,
			seed = seed,
			seconds = seconds,
			signatures = sim.signatures,
			redBot = redBot,
			reviewOrder = reviewOrder,
			signalCondition = signalCondition,
			affectedCases = affected,
			watcherCallsPerMinute = totals.decided * 60 / seconds,
			watcherRequestsPerMinute = totals.asked * 60 / seconds,
			fraudEscapes = totals.escaped,
			fraudsCaught = totals.caught,
			honestBlocked = totals.falseAlarms,
			expiredWaiting = totals.expiredWaiting,
			honestDeals = totals.honestDeals,
			gateway = gw:status(),
			gatewayP95Ms = gatewayMs[math.ceil(#gatewayMs * 0.95)],
			fallbacks = sim.gatewayStats.fallbacks,
		}
		print(encode(summary))
		if gw.stats.verdicts == 0 or gw.stats.errors > 0 or gw.lastRemoteError or summary.fallbacks > 0 then
			process.exit(1)
		end
	end
end

local args = process.args
if args[1] == "collect" then
	local lastSeed = assert(tonumber(args[2]), "collect requires the last seed")
	for seed = 1, lastSeed do
		run(seed, 300, "rules", nil, "arrival")
	end
elseif args[1] == "play" then
	local seed = assert(tonumber(args[2]), "play requires a seed")
	local policy = args[3] or "supervisor"
	local gateway = (args[4] or "http://127.0.0.1:8790") .. Config.GATEWAY_PATH
	local order, condition = args[6] or "priority", args[7] or "normal"
	assert(order == "deadline" or order == "priority", "review order must be deadline or priority")
	assert(condition == "normal" or condition == "missing" or condition == "empty-honest", "unknown signal condition")
	run(seed, tonumber(args[5]) or 300, policy, gateway, order, condition)
else
	error("usage: market.luau collect LAST_SEED | play SEED [POLICY] [GATEWAY] [SECONDS] [ORDER] [SIGNAL_CONDITION]")
end
