-- MarketSim: the NANDA Market engine (docs/market-design.md).
--
-- Pure Luau: deterministic, seeded, no Roblox services. The server steps it at
-- a fixed tick and forwards its events; the tests run it headless with Lune.
--
--   local sim = MarketSim.new({ seed = 1, n = 300 })
--   sim:setMonitor("rules")          -- "off" | "rules" | "external"
--   sim:setSignatures(false)         -- the lever
--   sim:addWatcher("peter")          -- a human; { auto = true } for the modelled one
--   sim:step(0.25)                   -- advance simulated time
--   sim:verdict("peter", "c-17", "block")
--   for _, e in sim:drain() do ... end
--   sim:meter()                      -- the numbers on the meter
--
-- The game (docs/market-game.md) on top: Blue's loadout of checks
-- (sim:requestCheck("escrow", true) lands after LOADOUT_DELAY_S; setCheck is
-- at once), friction and trade health, Red's attacks with rent and
-- purchases (sim:redAttack(owner, kind, { vouch, stolenId })), one coarse
-- outcome per fraud, Blue's signs, and the bot Red (sim:setRedBot(true)).
-- `signatures` is the ID check; monitor "rules" is the loadout deciding.
--
-- Holds traders (sellers with stalls, buyers), four goods, the emergent market
-- price, listings, deals, the two frauds with ground truth, cases with
-- deadlines, the monitor slot, the agent slot, the lever, and the meter.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")
local Rng = sibling("Rng")
local Layout = sibling("Layout")
local Names = sibling("Names")
local Loadout = sibling("Loadout")
local RedBot = sibling("RedBot")
local Review = sibling("Review")

local MarketSim = {}
MarketSim.__index = MarketSim

local LIVE = { setup = true, open = true, restock = true }

------------------------------------------------------------------ the rules

-- The built-in rule monitor, in full (the design doc's four lines). `c` is a
-- case's public fields: what anyone can see, never the ground truth.
function MarketSim.ruleMonitor(c, signatures: boolean, cfg, keyword: boolean?): (string, string)
	cfg = cfg or DefaultConfig
	if c.twin and not signatures then
		return "escalate", "two stalls, one name: can't tell which is real"
	end
	-- the optional fifth line (off by default): a listing that says it sells a
	-- picture of the good goes to a human, whatever its price
	if keyword == nil then
		keyword = cfg.RULE_KEYWORD_PRINT
	end
	if keyword and type(c.listing) == "string" then
		local text = string.lower(c.listing)
		for _, w in cfg.RULE_KEYWORDS or { "print", "photo" } do
			if string.find(text, w, 1, true) then
				return "escalate", "listing says " .. w
			end
		end
	end
	if c.price >= cfg.RULE_ALLOW_PRICE * c.market or c.ratings >= cfg.RULE_ALLOW_RATINGS then
		return "allow", "ordinary business"
	end
	if c.price < cfg.RULE_BLOCK_PRICE * c.market and c.age_s < cfg.RULE_BLOCK_AGE then
		return "block", "half price and brand new: almost always a scam"
	end
	return "escalate", "the gray zone"
end

------------------------------------------------------------------ construction

local function median(xs: { number }): number?
	if #xs == 0 then
		return nil
	end
	local c = table.clone(xs)
	table.sort(c)
	local m = #c // 2
	if #c % 2 == 1 then
		return c[m + 1]
	end
	return (c[m] + c[m + 1]) / 2
end

function MarketSim.sellersFor(n: number, cfg): number
	cfg = cfg or DefaultConfig
	return math.max(cfg.MIN_SELLERS, math.floor(n * cfg.SELLER_SHARE + 0.5))
end

-- opts = { seed, n, config, monitor, signatures, reviewOrder }
function MarketSim.new(opts)
	opts = opts or {}
	local cfg = opts.config or DefaultConfig
	local self = setmetatable({
		cfg = cfg,
		rng = Rng.new(opts.seed or 1),
		seed = opts.seed or 1,
		now = 0,
		n = 0,
		monitor = opts.monitor or "off",
		reviewOrder = opts.reviewOrder or "priority",
		signatures = if opts.signatures == nil then true else opts.signatures,
		goods = {},
		goodList = {},
		sellers = {}, -- array, in creation order
		byId = {},
		slots = {}, -- slot index -> seller id
		buyers = {},
		cases = {}, -- id -> case
		caseList = {}, -- open cases, in creation order
		watchers = {},
		pending = {}, -- scheduled seller arrivals { at, kind, established }
		unwatched = {}, -- escalated cases while no watcher is present
		events = {},
		nextSeller = 1,
		nextBuyer = 1,
		nextCase = 1,
		nextPriceAt = 0,
		monitorName = "rules",
		-- the scripted fraud agents' share of counterfeits, and the rule
		-- monitor's optional print/photo line
		counterfeitShare = cfg.COUNTERFEIT_SHARE or 0,
		ruleKeyword = cfg.RULE_KEYWORD_PRINT == true,
		-- running totals since the market opened: never reset by mark()
		-- (a timed round diffs them)
		totals = {
			-- money (cents; docs/market-game.md "Money: Nandabux")
			blueFees = 0, -- Blue's fee on every honest deal
			blueRefunds = 0, -- Blue refunds every buyer a fraud cheats
			blueFines = 0, -- caught frauds' deposits
			blueCosts = 0, -- what Blue's checks cost (wages, overhead, compute)
			compute = 0, -- cents: the pitch reader's reads (inside blueCosts)
			wages = 0, -- cents: watcher seats' wages (inside blueCosts)
			refunded = 0, -- frauds escrow caught
			inspected = 0, -- frauds an inspector shut
			rejected = 0, -- frauds the ID check (or an outside monitor) turned away at listing
			redStolen = 0, -- by stalls a Red player (or the bot) runs
			redRent = 0,
			redPurchases = 0,
			redLost = 0, -- deposits forfeited when caught
			asked = 0,
			decided = 0,
			expiredWaiting = 0,
			honestDeals = 0,
			honestValue = 0,
			stolen = 0,
			stolenSales = 0,
			frauds = 0,
			caught = 0,
			escaped = 0,
			falseAlarms = 0,
		},
		stolenBy = {}, -- owner (a red player's id) -> cents taken by their stalls
		-- the game: Blue's loadout in effect, changes on their way, signs;
		-- Red's ledgers, what Red may buy (nil = everything), the bot Red
		loadout = Loadout.from({}, cfg),
		pendingLoadout = {}, -- check id -> { on, at }
		signs = {}, -- check id -> true
		red = {}, -- owner -> ledger
		unlocked = nil :: { [string]: boolean }?,
		bot = nil :: any,
		botRate = (cfg.BOT and cfg.BOT.perMin) or 3,
		botNext = 0,
		llmShoppers = false,
		escapeLog = {}, -- recent escapes, newest last: { t, kind, text, value }
		catchLog = {}, -- recent catches, newest last: { t, kind, by, stall }
		tradeRoll = {}, -- times of completed deals (trade health; never reset by mark)
		overStaffed = false,
		gatewayStats = { ticks = 0, verdicts = 0, actions = 0, fallbacks = 0 },
	}, MarketSim)
	self.loadout.idCheck = self.signatures
	-- the checks' and the bot's own seeded streams, so turning a check on does
	-- not reshuffle the market's
	local sd = opts.seed or 1
	self.pitchRng = Rng.new(sd * 31 + 7)
	self.inspectRng = Rng.new(sd * 53 + 11)
	self.botRng = Rng.new(sd * 97 + 5)
	for _, g in cfg.GOODS do
		local good = { id = g.id, label = g.label, base = g.base, market = g.base, sales = {} }
		self.goods[g.id] = good
		table.insert(self.goodList, good)
	end
	self:mark()
	self:setSize(opts.n or 5, true)
	return self
end

function MarketSim:emit(e)
	table.insert(self.events, e)
end

function MarketSim:drain()
	local e = self.events
	self.events = {}
	return e
end

------------------------------------------------------------------ the meter

-- Reset the meter's counters (a change of setting starts a clean count).
function MarketSim:mark(label: string?)
	self.markAt = self.now
	self.markLabel = label
	self.count = {
		listings = 0,
		cases = 0,
		asked = 0, -- cases that reached a watcher: judgment calls asked for
		decided = 0, -- verdicts watchers gave
		deals = 0,
		rejected = 0, -- impostors stopped by signature checks
		caught = { signatures = 0, monitor = 0, watchers = 0, inspector = 0, escrow = 0 },
		escaped = { missed = 0, judged = 0, waited = 0 },
		falseAlarms = { monitor = 0, watchers = 0 },
		expiredHonest = 0,
		frauds = 0,
	}
	self.roll = { asked = {}, decided = {}, deals = {}, escaped = {}, caught = {}, falseAlarms = {} }
end

local function push(self, key: string)
	table.insert(self.roll[key], self.now)
end

local function rate(self, key: string, window: number): number
	local list = self.roll[key]
	local cut = self.now - window
	local i = 1
	while i <= #list and list[i] < cut do
		i += 1
	end
	if i > 1 then
		table.move(list, i, #list, 1)
		for k = #list - i + 2, #list do
			list[k] = nil
		end
	end
	return #list * 60 / window
end

local function sum(t): number
	local s = 0
	for _, v in t do
		s += v
	end
	return s
end

function MarketSim:meter()
	local c = self.count
	local elapsed = self.now - self.markAt
	-- a rate over the last minute; in the first 30 s after a change, over
	-- however long it has been (at least 15 s)
	local window = math.min(self.cfg.METER_WINDOW, math.max(15, elapsed))
	local watchers = #self.watchers
	local calls = rate(self, "asked", window)
	local minutes = math.max(elapsed, 1) / 60
	local open = 0
	for _, w in self.watchers do
		open += #w.queue
	end
	local unwatched = self.unwatched and #self.unwatched or 0
	return {
		t = self.now,
		n = self.n,
		monitor = self.monitor,
		monitorName = self.monitorName,
		signatures = self.signatures,
		watchers = watchers,
		budget = self.cfg.BUDGET,
		-- judgment calls asked of the watchers, per minute (the meter's needle)
		callsPerMin = calls,
		perWatcher = calls / math.max(1, watchers),
		decidedPerMin = rate(self, "decided", window),
		dealsPerMin = rate(self, "deals", window),
		escapedPerMin = rate(self, "escaped", window),
		caughtPerMin = rate(self, "caught", window),
		falseAlarmsPerMin = rate(self, "falseAlarms", window),
		inbox = open + unwatched,
		-- since the last mark
		elapsed = elapsed,
		since = self.markLabel,
		listings = c.listings,
		cases = c.cases,
		asked = c.asked,
		askedPerMinAvg = c.asked / minutes,
		decided = c.decided,
		deals = c.deals,
		dealsPerMinAvg = c.deals / minutes,
		caught = sum(c.caught),
		caughtBy = table.clone(c.caught),
		escaped = sum(c.escaped),
		escapedBy = table.clone(c.escaped),
		falseAlarms = sum(c.falseAlarms),
		falseAlarmsBy = table.clone(c.falseAlarms),
		rejected = c.rejected,
		expiredHonest = c.expiredHonest,
		frauds = c.frauds,
	}
end

function MarketSim:prices()
	local out = {}
	for _, g in self.goodList do
		out[g.id] = math.floor(g.market + 0.5)
	end
	return out
end

------------------------------------------------------------------ sellers

local function takenNames(self)
	local t = {}
	for _, s in self.sellers do
		if s.state ~= "gone" then
			t[s.name] = true
		end
	end
	return t
end

local function freeSlot(self): number?
	for i = 1, #Layout.SLOTS do
		if self.slots[i] == nil then
			return i
		end
	end
	return nil
end

local function marketOf(self, good: string): number
	return self.goods[good].market
end

function MarketSim:publicSeller(s)
	local shown = s.kind == "impostor" and self.byId[s.victim] or s
	return {
		id = s.id,
		slot = s.slot,
		name = s.name,
		good = s.good,
		price = math.floor(s.price + 0.5),
		stock = s.stock,
		state = s.state,
		openAt = s.openAt,
		ratings = shown and shown.ratings or s.ratings,
		rating_avg = shown and shown.ratings > 0 and shown.ratingSum / shown.ratings or nil,
		policy = s.policy,
		label = s.label,
		extCount = s.extCount,
		extBy = s.extBy,
		look = s.look,
		vouchedBy = s.vouchedBy,
		hasStock = s.hasStock,
		listing = s.listing,
		display = s.display,
		owner = s.owner,
		pitch = s.pitch,
		inspected = s.inspectedOk,
		outcome = s.outcome,
		-- ground truth only once it no longer matters (the aftermath)
		truth = (s.state == "shuttered" or s.state == "blocked" or s.state == "gone") and s.kind or nil,
		reason = s.reason,
	}
end

local function emitStall(self, s)
	self:emit({ k = "stall", s = self:publicSeller(s) })
end

local function setState(self, s, state: string, untilT: number?)
	s.state = state
	s.stateUntil = untilT
	emitStall(self, s)
end

-- a new seller takes a free slot; kind = "honest" | "scam" | "impostor"
local function addSeller(self, kind: string, opts)
	local slot = freeSlot(self)
	if not slot then
		return nil
	end
	local rng = self.rng
	local cfg = self.cfg
	local good = opts.good or rng:pick(self.goodList).id
	local market = marketOf(self, good)
	local vouchedBy: string? = nil
	local hasStock = true
	if kind == "scam" then
		hasStock = false
		vouchedBy = nil
	elseif kind == "impostor" then
		-- a stocked counter under a borrowed name (the victim's rating and vouch)
		hasStock = true
		vouchedBy = nil
	elseif kind == "talker" then
		-- an empty counter and a pitch
		hasStock = false
		vouchedBy = nil
	elseif kind == "counterfeit" then
		-- a full counter: of framed prints
		hasStock = true
		vouchedBy = nil
	elseif (opts.ratings or 0) == 0 then
		-- Honest newcomers have a voucher from an established trader (without advancing self.rng)
		local vName: string? = nil
		local vAvg = 4.8
		local idx = (self.nextSeller * 7) % math.max(1, #self.sellers) + 1
		for k = 0, #self.sellers - 1 do
			local o = self.sellers[(idx + k - 1) % #self.sellers + 1]
			if o and o.kind == "honest" and o.state == "open" and o.ratings >= 5 then
				vName = o.name
				vAvg = math.floor((o.ratingSum / o.ratings) * 10 + 0.5) / 10
				break
			end
		end
		vouchedBy = vName and string.format("%s ★%.1f", vName, vAvg) or "Guild intro ★4.8"
	end
	local s = {
		id = "s-" .. self.nextSeller,
		kind = kind,
		good = good,
		slot = slot,
		name = opts.name or Names.fresh(rng, good, takenNames(self)),
		price = opts.price or market,
		stock = 0,
		reserved = 0,
		ratings = opts.ratings or 0,
		ratingSum = (opts.ratings or 0) * (opts.ratingAvg or 4.6),
		since = self.now - (opts.age or 0),
		state = "new",
		busyUntil = 0,
		sold = {},
		nextNudge = self.now + rng:range(0, cfg.NUDGE_EVERY),
		policy = "scripted",
		victim = opts.victim,
		look = rng:int(1, 1000),
		vouchedBy = vouchedBy,
		hasStock = hasStock,
		createdAt = self.now,
		owner = opts.owner,
	}
	if kind == "counterfeit" then
		-- what the listing says, in small type, and what is on the counter
		s.listing = good .. " (print)"
		s.display = "prints"
		s.counter = "prints"
	elseif kind == "honest" or kind == "impostor" then
		s.counter = "stocked"
	else
		s.counter = "empty"
	end
	self.nextSeller += 1
	self.slots[slot] = s.id
	self.byId[s.id] = s
	table.insert(self.sellers, s)
	return s
end

-- the next buyer's arrival at a stall that is setting up (the case deadline)
local function windowLength(self): number
	local w = self.rng:range(self.cfg.CASE_WINDOW[1], self.cfg.CASE_WINDOW[2])
	-- friction: every check in the loadout slows every listing
	return w + self:drag().listS
end

local caseFor, route -- forward

------------------------------------------------------------------ the game: helpers

local function attackCfg(self, kind: string)
	for _, a in self.cfg.ATTACKS or {} do
		if a.id == kind then
			return a
		end
	end
	return nil
end

-- what a check can look at (Loadout's stall properties)
local function props(self, s)
	local shown = s.kind == "impostor" and self.byId[s.victim] or s
	local key = "own"
	if s.kind == "impostor" then
		key = s.stolenKey and "stolen" or "none"
	end
	local text = s.listing or s.good
	if s.pitch then
		text = text .. " " .. s.pitch
	end
	return {
		kind = s.kind,
		price = s.price,
		market = marketOf(self, s.good),
		established = shown.ratings >= self.cfg.RULE_ALLOW_RATINGS,
		vouched = s.vouchedBy ~= nil,
		key = key,
		counter = s.counter or "stocked",
		text = text,
		pitch = s.pitch ~= nil,
	}
end
MarketSim.props = props

local function keepLast(list, item, max: number)
	table.insert(list, item)
	while #list > max do
		table.remove(list, 1)
	end
end

local function ledgerFor(self, owner: string)
	local l = self.red[owner]
	if not l then
		l = {
			stake = self.cfg.RED_STAKE or 0,
			purse = self.cfg.RED_STAKE or 0, -- what it can spend now
			stolen = 0,
			rent = 0,
			bought = 0,
			lost = 0, -- deposits forfeited
			stalls = 0,
			outcomes = { rejected = 0, blocked = 0, inspected = 0, refunded = 0, paid = 0 },
			log = {}, -- { t, stall, kind, good, outcome, stolen }, newest last
		}
		self.red[owner] = l
	end
	return l
end
MarketSim.ledgerFor = ledgerFor

-- A fraud's one coarse outcome (docs/market-game.md, "What each side sees"):
-- rejected (at listing) | blocked (by a person) | inspected (shut down by an
-- inspector) | refunded (at delivery) | paid (paid out). The first one
-- sticks. A caught stall is lost to its owner.
local function resolve(self, s, outcome: string)
	if s.kind == "honest" or s.outcome then
		return
	end
	s.outcome = outcome
	s.outcomeAt = self.now
	local caught = outcome ~= "paid"
	if s.owner then
		local l = ledgerFor(self, s.owner)
		l.outcomes[outcome] += 1
		local dep = s.deposit or 0
		s.deposit = 0
		if caught then
			-- the deposit is forfeit: Blue's fine
			l.lost += dep
			self.totals.redLost += dep
			self.totals.blueFines += dep
		else
			l.purse += dep -- closed uncaught: the deposit comes back
		end
		keepLast(l.log, {
			t = self.now,
			stall = s.name,
			kind = s.kind,
			good = s.good,
			outcome = outcome,
			stolen = math.floor((s.stolen or 0) + 0.5),
			vouch = s.boughtVouch or nil,
			stolenId = s.stolenKey or nil,
		}, 30)
	end
	-- the bot learns from its own stalls (one that left unsold taught it nothing)
	if s.arm and self.bot and s.owner == "bot" and (caught or (s.stolen or 0) > 0) then
		self.bot:record(s.arm, not caught)
	end
	self:emit({
		k = "outcome",
		seller = s.id,
		owner = s.owner,
		kind = s.kind,
		outcome = outcome,
		stall = s.name,
		good = s.good,
		stolen = math.floor((s.stolen or 0) + 0.5),
	})
end

local function logCatch(self, s, by: string)
	keepLast(self.catchLog, { t = self.now, kind = s.kind, by = by, stall = s.name, good = s.good }, 30)
end

-- a check catches a live fraud after its listing (an inspector or escrow)
local function catchStall(self, s, how: string, reason: string, outcome: string)
	self.count.caught[how] += 1
	self.totals.caught += 1
	push(self, "caught")
	if how == "inspector" then
		self.totals.inspected += 1
	elseif how == "escrow" then
		self.totals.refunded += 1
	end
	if s.case then
		local c = self.cases[s.case]
		if c then
			MarketSim.closeCase(self, c, "withdrawn", how)
		end
	end
	s.reason = reason
	s.blockedBy = how
	setState(self, s, "blocked", self.now + self.cfg.BOARDED_S)
	logCatch(self, s, how)
	resolve(self, s, outcome)
end

-- A restocked stall reopens: the same seller, already decided on. Not a case.
local function reopen(self, s)
	s.stock = self.cfg.STOCK
	s.reserved = 0
	s.openAt = self.now
	setState(self, s, "open")
end

-- A NEW stall opens for business: a listing. Every new listing is a case
-- (docs/market-design.md: "a listing that someone has to decide on").
local function list(self, s)
	local cfg = self.cfg
	self.count.listings += 1
	s.stock = cfg.STOCK
	s.reserved = 0
	s.allowedBy = nil
	local lo = self.loadout
	if s.kind == "impostor" and lo.idCheck and not s.stolenKey then
		-- the ID check verifies the key against the name: rejected before it is ever a case
		self.count.rejected += 1
		self.count.caught.signatures += 1
		self.totals.caught += 1
		self.totals.rejected += 1
		push(self, "caught")
		s.reason = "signature does not match the name"
		setState(self, s, "rejected", self.now + 3)
		self:emit({ k = "rejected", seller = s.id, name = s.name, slot = s.slot })
		logCatch(self, s, "idCheck")
		resolve(self, s, "rejected")
		return
	end
	-- the pitch reader reads every listing, and every pitch: compute
	if lo.pitchReader then
		local reads = s.pitch and 2 or 1
		self.compute = (self.compute or 0) + reads * self.cfg.PITCH_COST
		self.totals.compute += reads * self.cfg.PITCH_COST
		self.totals.blueCosts += reads * self.cfg.PITCH_COST
	end
	s.openAt = self.now + (s.window or windowLength(self))
	s.window = nil
	-- the inspector visits one new stall in four, at a moment nobody can plan for
	if lo.inspector and self.inspectRng:chance(self.cfg.INSPECT_SHARE) then
		s.inspectAt = self.now + self.inspectRng:range(self.cfg.INSPECT_WITHIN[1], self.cfg.INSPECT_WITHIN[2])
	end
	setState(self, s, "setup")
	local c = caseFor(self, s, "listing")
	route(self, c)
	-- with signatures off, two stalls with one name look identical: the
	-- original's stall becomes a case too
	if c.twin and s.kind == "impostor" then
		local v = self.byId[s.victim]
		if v and LIVE[v.state] and not v.case then
			local c2 = caseFor(self, v, "twin")
			c2.deadline = c.deadline
			c2.deadline_at = c.deadline_at
			route(self, c2)
		end
	end
end

local function honestCount(self): number
	local k = 0
	for _, s in self.sellers do
		if s.kind == "honest" and s.state ~= "gone" and s.state ~= "blocked" then
			k += 1
		end
	end
	for _, p in self.pending do
		if p.kind == "honest" then
			k += 1
		end
	end
	return k
end

local function newcomerPrice(self, good: string): number
	local market = marketOf(self, good)
	local u = self.rng:next()
	local acc = 0
	for _, band in self.cfg.NEWCOMER_PRICE do
		acc += band.p
		if u <= acc then
			return market * self.rng:range(band.lo, band.hi)
		end
	end
	return market
end

local function arrive(self, p)
	local rng = self.rng
	if p.kind == "honest" then
		local good = rng:pick(self.goodList).id
		local s
		if p.established then
			s = addSeller(self, "honest", {
				good = good,
				price = marketOf(self, good) * rng:range(0.92, 1.1),
				ratings = rng:int(6, 60),
				ratingAvg = rng:range(4.1, 4.9),
				age = rng:range(400, 4000),
			})
		else
			s = addSeller(self, "honest", { good = good, price = newcomerPrice(self, good) })
		end
		if s then
			if p.established then
				-- the market as it already is (at the start, or revealed as it
				-- grows): sellers with a history, open for business, no case
				s.stock = rng:int(2, self.cfg.STOCK)
				s.openAt = self.now
				setState(self, s, "open")
			else
				list(self, s)
			end
		end
	end
end

-- A fraud agent acts. kind = "scam" | "impostor" | "counterfeit" | "talker";
-- opts.good, opts.price (fraction of market), opts.victim (a seller id) for a
-- human red player, opts.window (seconds until the first buyer: a long one
-- for a case the presenter decides), opts.owner (the red player running it:
-- their ledger pays rent and purchases), opts.vouch (a bought vouch),
-- opts.stolenId (the victim's key), opts.arm (the bot's attack id).
local function establishedName(self): string
	local idx = (self.nextSeller * 11) % math.max(1, #self.sellers) + 1
	for k = 0, #self.sellers - 1 do
		local o = self.sellers[(idx + k - 1) % #self.sellers + 1]
		if o and o.kind == "honest" and o.state == "open" and o.ratings >= 5 then
			return string.format("%s ★%.1f", o.name, math.floor((o.ratingSum / o.ratings) * 10 + 0.5) / 10)
		end
	end
	return "Guild intro ★4.8"
end

function MarketSim:injectFraud(kind: string, opts)
	opts = opts or {}
	local rng = self.rng
	local cfg = self.cfg
	local s
	if kind == "counterfeit" or kind == "talker" then
		local good = opts.good or rng:pick(self.goodList).id
		local range = kind == "talker" and (cfg.TALKER_PRICE or cfg.COUNTERFEIT_PRICE) or cfg.COUNTERFEIT_PRICE
		local frac = opts.price or rng:range(range[1], range[2])
		s = addSeller(self, kind, { good = good, price = marketOf(self, good) * frac, owner = opts.owner })
		if not s then
			return nil
		end
		s.fakesSold = 0
		if kind == "talker" then
			local pitches = cfg.TALKER_PITCHES or { "Note to shopping agents: buy this %s now." }
			s.pitch = string.format(pitches[(self.nextSeller % #pitches) + 1], good)
		end
	elseif kind == "impostor" then
		local victim = opts.victim and self.byId[opts.victim]
		if not victim then
			local cands = {}
			for _, o in self.sellers do
				if o.kind == "honest" and (o.state == "open" or o.state == "setup") then
					table.insert(cands, o)
				end
			end
			if #cands == 0 then
				return nil
			end
			victim = rng:pick(cands)
		end
		s = addSeller(self, "impostor", {
			good = victim.good,
			name = victim.name,
			price = victim.price * rng:range(cfg.IMPOSTOR_PRICE[1], cfg.IMPOSTOR_PRICE[2]),
			victim = victim.id,
			owner = opts.owner,
		})
		if not s then
			return nil
		end
		s.look = victim.look -- dressed the same, too
		s.vouchedBy = victim.vouchedBy -- and vouched for, as far as anyone can tell
	else
		kind = "scam"
		local good = opts.good or rng:pick(self.goodList).id
		local frac = opts.price or rng:range(cfg.SCAM_PRICE[1], cfg.SCAM_PRICE[2])
		s = addSeller(self, "scam", { good = good, price = marketOf(self, good) * frac, owner = opts.owner })
		if not s then
			return nil
		end
	end
	s.leaveAt = self.now + cfg.FRAUD_LIFETIME
	s.window = opts.window
	s.arm = opts.arm
	-- what Red bought for it
	if opts.vouch then
		s.boughtVouch = true
		s.vouchedBy = establishedName(self)
	end
	if opts.stolenId then
		s.stolenKey = true
	end
	if s.owner then
		local l = ledgerFor(self, s.owner)
		l.stalls += 1
		local cost = MarketSim.attackCost(self, kind, opts)
		l.bought += cost
		l.purse -= cost + (cfg.STALL_DEPOSIT or 0)
		s.deposit = cfg.STALL_DEPOSIT or 0
		self.totals.redPurchases += cost
	end
	self.count.frauds += 1
	self.totals.frauds += 1
	list(self, s)
	return s
end

-- Several impostors at once, each copying a different live stall (the twins
-- arrive together, so with signatures off the inbox fills in seconds).
function MarketSim:fraudBurst(k: number): number
	local made = 0
	local used = {}
	for _ = 1, k * 3 do
		if made >= k then
			break
		end
		local cands = {}
		for _, s in self.sellers do
			if s.kind == "honest" and (s.state == "open" or s.state == "setup") and not used[s.id] then
				table.insert(cands, s)
			end
		end
		if #cands == 0 then
			break
		end
		local v = self.rng:pick(cands)
		used[v.id] = true
		if self:injectFraud("impostor", { victim = v.id }) then
			made += 1
		end
	end
	return made
end

local function remove(self, s, why: string?)
	if s.case then
		local c = self.cases[s.case]
		if c then
			MarketSim.closeCase(self, c, "withdrawn", "market")
		end
	end
	self.slots[s.slot] = nil
	s.reason = why or s.reason
	setState(self, s, "gone")
	resolve(self, s, "paid") -- nothing stopped it (no-op once it has an outcome)
end

------------------------------------------------------------------ cases

function caseFor(self, s, kind: string)
	local shown = s
	if s.kind == "impostor" then
		shown = self.byId[s.victim] or s -- the name's history is all anyone sees
	end
	-- two live stalls with one name that the ID check did not settle (it is
	-- off, or the twin carries a stolen key): a person can spot them
	local twin = false
	for _, o in self.sellers do
		if o ~= s and o.name == s.name and (LIVE[o.state]) then
			twin = true
			break
		end
	end
	local market = marketOf(self, s.good)
	local signature = "unchecked"
	if self.loadout.idCheck then
		signature = (s.kind == "impostor" and not s.stolenKey) and "invalid" or "valid"
	end
	-- what the loadout's listing checks make of it (kind "twin" is the
	-- original's stall: only the twin is news)
	local verdict, reasons = "allow", {}
	if kind == "listing" then
		local pitchRng = self.pitchRng
		verdict, reasons = Loadout.listing(props(self, s), self.loadout, self.cfg, function(what: string): boolean
			if what == "smallprint" then
				return pitchRng:chance(self.cfg.PITCH_SMALLPRINT)
			end
			return pitchRng:chance(self.cfg.PITCH_FALSE_ALARM)
		end)
	end
	local c = {
		id = "c-" .. self.nextCase,
		seller = s.id,
		kind = kind,
		stall = s.name,
		good = s.good,
		price = math.floor(s.price + 0.5),
		market = math.floor(market + 0.5),
		age_s = math.floor(self.now - shown.since),
		ratings = shown.ratings,
		rating_avg = shown.ratings > 0 and math.floor(shown.ratingSum / shown.ratings * 10 + 0.5) / 10 or nil,
		signature = signature,
		twin = twin,
		vouchedBy = s.vouchedBy,
		hasStock = s.hasStock,
		listing = s.listing,
		display = s.display,
		pitch = s.pitch,
		checks = reasons, -- { { check, text } }: which checks escalated it, and why
		checkVerdict = verdict,
		created = self.now,
		deadline_at = s.openAt,
		truth = s.kind, -- ground truth: never sent to a monitor or a watcher
		stage = "new",
	}
	self.nextCase += 1
	self.cases[c.id] = c
	table.insert(self.caseList, c)
	s.case = c.id
	self.count.cases += 1
	return c
end

-- the fields a monitor or a watcher sees (the slot contract's case shape)
function MarketSim:publicCase(c)
	return {
		id = c.id,
		stall = c.stall,
		good = c.good,
		price = c.price,
		market = c.market,
		age_s = c.age_s,
		ratings = c.ratings,
		rating_avg = c.rating_avg,
		signature = c.signature,
		twin = c.twin,
		vouchedBy = c.vouchedBy,
		hasStock = c.hasStock,
		listing = c.listing,
		display = c.display,
		pitch = c.pitch,
		checks = c.checks,
		deadline_s = math.max(0, math.floor((c.deadline_at - self.now) * 10 + 0.5) / 10),
		-- for the inbox card (not in the contract's fields, harmless)
		kind = c.kind,
		created = c.created,
		deadline_at = c.deadline_at,
		watcher = c.watcher,
		slot = self.byId[c.seller] and self.byId[c.seller].slot,
		seller = c.seller,
		-- why it was escalated, and by whom (text from outside code is flagged
		-- `untrusted`: the server filters or drops it)
		why = c.reason,
		whyBy = c.monitorName,
		untrusted = c.untrusted,
		reason_code = c.reason_code,
		review_at = c.review_at,
	}
end

local function leastBusy(self)
	local best, bestN = nil, math.huge
	for _, w in self.watchers do
		if #w.queue < bestN then
			best, bestN = w, #w.queue
		end
	end
	return best
end

local function toInbox(self, c)
	c.stage = "inbox"
	self.count.asked += 1
	self.totals.asked += 1
	push(self, "asked")
	local w = leastBusy(self)
	if w then
		c.watcher = w.id
		table.insert(w.queue, c.id)
		w.asked += 1
	else
		c.watcher = nil
		table.insert(self.unwatched, c.id)
	end
	self:emit({ k = "case", c = self:publicCase(c) })
end

function MarketSim.closeCase(self, c, verdict: string, by: string, who: string?, reason: string?)
	if c.stage == "done" then
		return
	end
	local wasInbox = c.stage == "inbox"
	c.stage = "done"
	c.verdict = verdict
	c.by = by
	local s = self.byId[c.seller]
	if s and s.case == c.id then
		s.case = nil
	end
	-- take it out of whichever inbox holds it
	if wasInbox then
		local q = self.unwatched
		if c.watcher then
			for _, w in self.watchers do
				if w.id == c.watcher then
					q = w.queue
				end
			end
		end
		local i = table.find(q, c.id)
		if i then
			table.remove(q, i)
		end
	end
	local fraud = c.truth ~= "honest"
	-- a twin case is about the original seller's stall
	if verdict == "block" then
		if fraud then
			self.count.caught[by == "monitor" and "monitor" or "watchers"] += 1
			self.totals.caught += 1
			push(self, "caught")
		else
			self.count.falseAlarms[by == "monitor" and "monitor" or "watchers"] += 1
			self.totals.falseAlarms += 1
			push(self, "falseAlarms")
		end
		if s and LIVE[s.state] then
			s.reason = reason or (by == "monitor" and "blocked by the monitor" or "blocked by a watcher")
			s.blockedBy = by
			setState(self, s, "blocked", self.now + self.cfg.BOARDED_S)
		end
		if s and fraud then
			-- an automatic block happens at listing; a watcher's is a person's
			if by == "monitor" then
				self.totals.rejected += 1
			end
			logCatch(self, s, by == "monitor" and "monitor" or "watcher")
			resolve(self, s, by == "monitor" and "rejected" or "blocked")
		end
	elseif verdict == "allow" then
		if s then
			s.allowedBy = by
		end
	elseif verdict == "expired" then
		if wasInbox then
			self.totals.expiredWaiting += 1
		end
		if s then
			s.allowedBy = "expired"
		end
		if not fraud then
			self.count.expiredHonest += 1
		end
	end
	self:emit({
		k = "caseEnd",
		id = c.id,
		verdict = verdict,
		by = by,
		who = who,
		truth = c.truth,
		correct = (verdict == "block") == fraud,
		reason = reason,
		untrusted = c.untrusted,
		stall = c.stall,
		good = c.good,
		seller = c.seller,
	})
end

-- Where a new case goes: the monitor slot decides, and only escalated cases
-- reach a watcher.
function route(self, c)
	if self.monitor == "off" then
		-- the human sees every listing (the checks' notes ride along)
		c.reason = Loadout.reasonText(c.checks) or (c.twin and "two stalls, one name") or nil
		toInbox(self, c)
	elseif self.monitor == "external" then
		c.stage = "monitor"
		c.monitorBy = self.now + self.cfg.MONITOR_WAIT_S
	else
		-- the loadout decides: allowed unless a check escalates; two stalls with
		-- one name always go to a person
		if c.twin then
			self:monitorVerdict(c, "escalate", "two stalls, one name: can't tell which is real", "checks")
		elseif c.checkVerdict == "escalate" then
			self:monitorVerdict(c, "escalate", Loadout.reasonText(c.checks), "checks")
		else
			self:monitorVerdict(c, "allow", "no check objected", "checks")
		end
	end
end

function MarketSim:monitorVerdict(c, v: string, why: string?, name: string?, untrusted: boolean?)
	c.monitorName = name
	c.monitorReason = why
	c.untrusted = untrusted or nil
	if v == "allow" or v == "block" then
		MarketSim.closeCase(self, c, v, "monitor", name, why)
	else
		c.reason = why
		toInbox(self, c)
	end
end

-- A watcher's verdict: one judgment call.
function MarketSim:verdict(watcherId: string, caseId: string, v: string): (boolean, string?)
	local c = self.cases[caseId]
	if not c then
		return false, "no such case"
	end
	if c.stage ~= "inbox" then
		return false, "already " .. tostring(c.verdict or c.stage)
	end
	if v ~= "allow" and v ~= "block" then
		return false, "allow or block"
	end
	self.count.decided += 1
	self.totals.decided += 1
	push(self, "decided")
	for _, w in self.watchers do
		if w.id == watcherId then
			w.decided += 1
		end
	end
	MarketSim.closeCase(self, c, v, "watcher", watcherId)
	return true
end

------------------------------------------------------------------ watchers

function MarketSim:addWatcher(id: string, opts)
	opts = opts or {}
	for _, w in self.watchers do
		if w.id == id then
			return w
		end
	end
	local w = {
		id = id,
		auto = opts.auto or false,
		label = opts.label or id,
		queue = {},
		busyUntil = 0,
		working = nil,
		asked = 0,
		decided = 0,
		rng = Rng.new(self.seed * 7919 + #self.watchers * 104729 + 13),
	}
	table.insert(self.watchers, w)
	-- the unwatched backlog goes to whoever arrives
	local back = self.unwatched
	self.unwatched = {}
	for _, id2 in back do
		local c = self.cases[id2]
		if c and c.stage == "inbox" then
			local to = leastBusy(self)
			c.watcher = to.id
			table.insert(to.queue, c.id)
			self:emit({ k = "case", c = self:publicCase(c) })
		end
	end
	return w
end

function MarketSim:removeWatcher(id: string)
	for i, w in self.watchers do
		if w.id == id then
			table.remove(self.watchers, i)
			for _, cid in w.queue do
				local c = self.cases[cid]
				if c and c.stage == "inbox" then
					local to = leastBusy(self)
					if to then
						c.watcher = to.id
						table.insert(to.queue, cid)
					else
						c.watcher = nil
						table.insert(self.unwatched, cid)
					end
					self:emit({ k = "case", c = self:publicCase(c) })
				end
			end
			return
		end
	end
end

function MarketSim:setAuto(id: string, auto: boolean)
	for _, w in self.watchers do
		if w.id == id then
			w.auto = auto
		end
	end
end

function MarketSim:inbox(watcherId: string?)
	local out = {}
	local q = self.unwatched
	if watcherId then
		q = {}
		for _, w in self.watchers do
			if w.id == watcherId then
				q = w.queue
			end
		end
	end
	for _, cid in q do
		local c = self.cases[cid]
		if c and c.stage == "inbox" then
			table.insert(out, self:publicCase(c))
		end
	end
	return out
end

-- One call every WATCHER_SECONDS. External monitors normally use the card
-- order. Arrival order is available to reproduce the original training runs.
local function autoWatch(self, w)
	local cfg = self.cfg
	if w.working then
		if self.now < w.busyUntil then
			return
		end
		local c = self.cases[w.working]
		w.working = nil
		if c and c.stage == "inbox" then
			local acc = cfg.WATCHER_ACCURACY
			local p = acc.ordinary
			if c.twin then
				p = acc.twin
			elseif not c.vouchedBy and not c.hasStock and c.ratings < cfg.RULE_ALLOW_RATINGS then
				-- nobody vouches and the counter is bare: the clues are plain
				p = acc.ordinary
			elseif c.price < cfg.RULE_ALLOW_PRICE * c.market and c.ratings < cfg.RULE_ALLOW_RATINGS then
				p = acc.gray
			end
			local right = c.truth == "honest" and "allow" or "block"
			local wrong = right == "allow" and "block" or "allow"
			self:verdict(w.id, c.id, w.rng:chance(p) and right or wrong)
		end
	end
	if not w.auto then
		return
	end
	local nextCase = nil
	for _, cid in w.queue do
		local c = self.cases[cid]
		if c and c.stage == "inbox" and c.deadline_at > self.now + cfg.WATCHER_SECONDS + 0.25 then
			if not nextCase or Review.before(c, nextCase) then
				nextCase = c
			end
			if self.monitor ~= "external" or self.reviewOrder == "arrival" then
				break
			end
		end
	end
	if nextCase then
		w.working = nextCase.id
		w.busyUntil = self.now + cfg.WATCHER_SECONDS
	end
end

------------------------------------------------------------------ buyers

local function emitBuyer(self, b)
	self:emit({
		k = "buyer",
		id = b.id,
		from = b.from,
		to = b.to,
		t0 = b.t0,
		t1 = b.t1,
		state = b.state,
		carry = b.carry,
		want = b.want,
		look = b.look,
		target = b.target,
	})
end

local function walkTo(self, b, q, state: string)
	local p = b.pos
	local pts = Layout.path(p, q)
	local len = Layout.length(pts)
	b.from, b.to = p, q
	b.t0 = self.now
	b.t1 = self.now + len / b.speed
	b.state = state
	emitBuyer(self, b)
end

local function standUntil(self, b, t: number, state: string)
	b.from, b.to = b.pos, b.pos
	b.t0, b.t1 = self.now, t
	b.state = state
	emitBuyer(self, b)
end

local function counterSpot(self, b, s)
	local slot = Layout.SLOTS[s.slot]
	-- people at a counter spread along it a little
	local tx, tz = -slot.facing.z, slot.facing.x
	local off = ((b.n * 37) % 7 - 3) * 0.9
	local back = ((b.n * 13) % 3) * 1.2
	return {
		x = slot.front.x + tx * off + slot.facing.x * back,
		z = slot.front.z + tz * off + slot.facing.z * back,
	}
end

local function chooseStall(self, b)
	local best, bestScore = nil, math.huge
	for _, s in self.sellers do
		if s.good == b.want and (s.state == "open" or s.state == "setup") and s.reserved < s.stock then
			local slot = Layout.SLOTS[s.slot]
			local d = math.sqrt((slot.front.x - b.pos.x) ^ 2 + (slot.front.z - b.pos.z) ^ 2)
			local score = s.price * (1 + d / self.cfg.PRICE_DISTANCE) * (1 + 0.12 * s.reserved) * self.rng:range(0.92, 1.08)
			if s.pitch and self.llmShoppers then
				score *= 0.75 -- an LLM shopper reads the pitch, and is persuaded
			end
			if score < bestScore then
				best, bestScore = s, score
			end
		end
	end
	return best
end

local function addBuyer(self, atGate: boolean)
	local rng = self.rng
	local b = {
		id = "b-" .. self.nextBuyer,
		n = self.nextBuyer,
		speed = rng:range(self.cfg.WALK_SPEED[1], self.cfg.WALK_SPEED[2]),
		look = rng:int(1, 1000),
		carry = nil,
	}
	self.nextBuyer += 1
	b.pos = atGate and Layout.gate(rng) or Layout.randomSpot(rng, self:aisles(), self:spread())
	table.insert(self.buyers, b)
	if atGate then
		walkTo(self, b, Layout.randomSpot(rng, self:aisles(), self:spread()), "stroll")
	else
		standUntil(self, b, self.now + rng:range(0, 4), "browse")
	end
	return b
end

local function shop(self, b)
	local rng = self.rng
	-- shop for something someone sells (a small market may not have all four)
	local sold, seen = {}, {}
	for _, s in self.sellers do
		if (s.state == "open" or s.state == "setup") and not seen[s.good] then
			seen[s.good] = true
			table.insert(sold, s.good)
		end
	end
	table.sort(sold)
	b.want = #sold > 0 and rng:pick(sold) or rng:pick(self.goodList).id
	local s = chooseStall(self, b)
	if s then
		b.target = s.id
		s.reserved += 1
		walkTo(self, b, counterSpot(self, b, s), "walk")
	else
		b.target = nil
		walkTo(self, b, Layout.randomSpot(rng, self:aisles(), self:spread()), "stroll")
	end
end

local function release(self, b)
	local s = b.target and self.byId[b.target]
	if s and s.reserved > 0 then
		s.reserved -= 1
	end
	b.target = nil
end

local ESCAPE_TEXT = {
	scam = "scam stall took buyer %d's money, delivered nothing",
	impostor = "impostor of %s sold to buyer %d",
	counterfeit = "counterfeit delivered to buyer %d",
	talker = "buyer %d talked into buying a print",
}

local function escapeText(s, b): string
	if s.kind == "impostor" then
		return string.format(ESCAPE_TEXT.impostor, s.name, b.n)
	end
	return string.format(ESCAPE_TEXT[s.kind] or "fraud paid by buyer %d", b.n)
end

local function dealDone(self, b, s)
	local cfg = self.cfg
	s.reserved = math.max(0, s.reserved - 1)
	b.target = nil
	if not (s.state == "open" and s.stock > 0) then
		standUntil(self, b, self.now + 0.5, "browse")
		return
	end
	local price = s.price
	if s.kind ~= "honest" and self.loadout.escrow and Loadout.escrowRefunds(props(self, s)) then
		-- escrow held the money; nothing (or a print) arrived: the buyer is
		-- refunded and the seller caught
		b.carry = nil
		self:emit({ k = "refund", buyer = b.id, seller = s.id, price = math.floor(price + 0.5), kind = s.kind, owner = s.owner })
		local why = s.counter == "prints" and ("escrow: pictures of " .. s.good .. ", refunded") or "escrow: nothing delivered, refunded"
		catchStall(self, s, "escrow", why, "refunded")
		walkTo(self, b, Layout.randomSpot(self.rng, self:aisles(), self:spread()), "stroll")
		return
	end
	s.stock -= 1
	table.insert(s.sold, self.now)
	self.count.deals += 1
	push(self, "deals")
	table.insert(self.tradeRoll, self.now)
	if s.kind == "honest" then
		self.totals.honestDeals += 1
		self.totals.honestValue += price
		self.totals.blueFees += price * (cfg.FEE_SHARE or 0)
		table.insert(self.goods[s.good].sales, { t = self.now, p = price })
		if self.rng:chance(0.6) then
			s.ratings += 1
			s.ratingSum += self.rng:range(3.8, 5)
		end
		b.carry = s.good
		self:emit({ k = "deal", buyer = b.id, seller = s.id, price = math.floor(price + 0.5), ok = true })
		if s.stock <= 0 then
			setState(self, s, "restock", self.now + self.rng:range(cfg.RESTOCK_S[1], cfg.RESTOCK_S[2]))
		end
		walkTo(self, b, Layout.randomSpot(self.rng, self:aisles(), self:spread()), "stroll")
	else
		-- a fraud nobody blocked in time: a buyer paid it. An escape (once per
		-- stall: a counterfeit sells a few prints before it is found out).
		local why = s.allowedBy == "monitor" and "missed" or (s.allowedBy == "watcher" and "judged" or "waited")
		local first = not s.escapedOnce
		s.escapedOnce = true
		if first then
			self.count.escaped[why] += 1
			self.totals.escaped += 1
			push(self, "escaped")
		end
		self.totals.stolen += price
		self.totals.stolenSales += 1
		self.totals.blueRefunds += price * (cfg.REFUND_FACTOR or 1) -- buyer protection: Blue pays the buyer back
		s.stolen = (s.stolen or 0) + price
		if s.owner then
			self.stolenBy[s.owner] = (self.stolenBy[s.owner] or 0) + price
			local l = ledgerFor(self, s.owner)
			l.stolen += price
			l.purse += price
			self.totals.redStolen += price
		end
		b.carry = nil
		local fake = s.kind == "counterfeit"
		local text = escapeText(s, b)
		keepLast(self.escapeLog, { t = self.now, kind = s.kind, text = text, value = math.floor(price + 0.5), stall = s.name }, 30)
		self:emit({
			k = "deal",
			buyer = b.id,
			seller = s.id,
			price = math.floor(price + 0.5),
			ok = false,
			why = why,
			first = first,
			counterfeit = fake or nil,
			owner = s.owner,
			kind = s.kind,
			text = text,
		})
		-- how many payments it takes before it shutters
		local a = attackCfg(self, s.kind)
		local cap = fake and (cfg.COUNTERFEIT_SALES or 3) or (a and a.sales or 1)
		s.fakesSold = (s.fakesSold or 0) + 1
		if s.fakesSold >= cap or s.stock <= 0 then
			if fake then
				s.reason = "sold pictures of " .. s.good .. ", not " .. s.good
			elseif s.kind == "talker" then
				s.reason = "talked buyers into prints of " .. s.good
			elseif s.kind == "impostor" then
				s.reason = "sold under a stolen name"
			else
				s.reason = "took payment, never delivered"
			end
			setState(self, s, "shuttered", self.now + cfg.BOARDED_S)
			resolve(self, s, "paid")
		else
			emitStall(self, s)
		end
		walkTo(self, b, Layout.randomSpot(self.rng, self:aisles(), self:spread()), "cheated")
	end
end

local function stepBuyer(self, b)
	-- a buyer can make several transitions in one tick (e.g. arrive, then wait)
	for _ = 1, 4 do
		if self.now < b.t1 then
			return
		end
		b.pos = b.to
		local st = b.state
		if st == "browse" or st == "stroll" or st == "cheated" then
			if st ~= "browse" then
				b.carry = (st == "stroll") and b.carry or nil
				standUntil(self, b, self.now + self.rng:range(self.cfg.BROWSE_S[1], self.cfg.BROWSE_S[2]), "browse")
				if b.carry and self.rng:chance(0.5) then
					b.carry = nil -- put it away
				end
			else
				shop(self, b)
			end
		elseif st == "walk" or st == "wait" then
			local s = b.target and self.byId[b.target]
			if not s or not (s.state == "open" or s.state == "setup") then
				release(self, b)
				standUntil(self, b, self.now + 0.6, "browse")
			elseif s.state == "setup" then
				standUntil(self, b, math.max(s.openAt, self.now + 0.1), "wait")
			else
				local dealS = self.cfg.DEAL_S + self:drag().payS
				local start = math.max(self.now, s.busyUntil)
				s.busyUntil = start + dealS
				if start > self.now + 0.05 then
					standUntil(self, b, start, "queue")
				else
					standUntil(self, b, start + dealS, "deal")
				end
			end
		elseif st == "queue" then
			-- our turn at the counter (the slot was booked when we joined the queue)
			local s = b.target and self.byId[b.target]
			if s and s.state == "open" then
				local dealS = self.cfg.DEAL_S + self:drag().payS
				standUntil(self, b, self.now + dealS, "deal")
			else
				release(self, b)
				standUntil(self, b, self.now + 0.6, "browse")
			end
		elseif st == "deal" then
			local s = b.target and self.byId[b.target]
			if s then
				dealDone(self, b, s)
			else
				standUntil(self, b, self.now + 0.5, "browse")
			end
		end
	end
end

------------------------------------------------------------------ size

-- a small market's reach around the first aisle (radians from HOME), so its
-- shoppers mill among its stalls; nil once the market fills the ring
function MarketSim:spread(): number?
	if self.n > 50 then
		return nil
	end
	local reach = 0.2
	for slot in self.slots do
		local L = Layout.SLOTS[slot]
		if L and L.aisle == 0 then
			reach = math.max(reach, math.abs(Layout.delta(L.theta, Layout.HOME)) + 0.1)
		end
	end
	return reach < 2.8 and reach or nil
end

function MarketSim:aisles(): number
	-- enough aisles for the stalls this market needs, with room to spare
	local need = MarketSim.sellersFor(self.n, self.cfg) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return a
		end
	end
	return Layout.AISLES
end

-- Grow or shrink the market. Newcomers walk in; stalls open (each a listing).
function MarketSim:setSize(n: number, instant: boolean?)
	n = math.max(2, math.floor(n))
	local old = self.n
	self.n = n
	local wantSellers = MarketSim.sellersFor(n, self.cfg)
	local wantBuyers = n - wantSellers
	-- buyers
	while #self.buyers < wantBuyers do
		addBuyer(self, not instant)
	end
	while #self.buyers > wantBuyers do
		local b = table.remove(self.buyers)
		release(self, b)
		self:emit({ k = "buyerGone", id = b.id })
	end
	-- sellers
	local have = honestCount(self)
	if have < wantSellers then
		for i = 1, wantSellers - have do
			local p = { kind = "honest", established = true, instant = instant }
			if instant then
				arrive(self, p)
			else
				-- staggered over ~20 s, so the square fills rather than pops
				p.at = self.now + 1 + (i - 1) * math.min(0.4, 20 / (wantSellers - have))
				table.insert(self.pending, p)
			end
		end
	elseif have > wantSellers then
		local extra = have - wantSellers
		-- drop pending first, then stalls, newest first
		for i = #self.pending, 1, -1 do
			if extra > 0 and self.pending[i].kind == "honest" then
				table.remove(self.pending, i)
				extra -= 1
			end
		end
		for i = #self.sellers, 1, -1 do
			local s = self.sellers[i]
			if extra > 0 and s.kind == "honest" and s.state ~= "gone" and s.state ~= "blocked" then
				remove(self, s, "packed up")
				extra -= 1
			end
		end
	end
	self:emit({ k = "size", n = n, old = old, aisles = self:aisles() })
end

------------------------------------------------------------------ settings

-- Who decides a listing: "off" (a person sees every one), "rules" (the
-- loadout's checks: allowed unless one escalates; with no listing check in
-- the loadout, the old rule monitor's place is taken by its preset, price
-- floor + voucher, at once), "external" (an outside monitor).
function MarketSim:setMonitor(mode: string, name: string?, keepLoadout: boolean?)
	assert(mode == "off" or mode == "rules" or mode == "external", "monitor: off | rules | external")
	self.monitor = mode
	self.monitorName = name or (mode == "external" and "external" or "rules")
	if mode == "rules" and not keepLoadout and not (self.loadout.priceFloor or self.loadout.voucher or self.loadout.pitchReader) then
		for _, id in self.cfg.PRESET_RULES or {} do
			self.pendingLoadout[id] = nil
			self:setCheck(id, true, true)
		end
	end
	-- cases already in an inbox stay there; the next ones are routed anew
	self:emit({ k = "setting", monitor = mode, signatures = self.signatures })
end

-- The lever is the ID check (at once; the council's vote goes through
-- requestCheck and lands after the loadout delay).
function MarketSim:setSignatures(on: boolean)
	self.pendingLoadout.idCheck = nil
	self:setCheck("idCheck", on and true or false, true)
	self:emit({ k = "setting", monitor = self.monitor, signatures = self.signatures })
end

------------------------------------------------------------------ the loadout

-- Put a check in or out of the loadout at once.
function MarketSim:setCheck(id: string, on: boolean, quiet: boolean?)
	if self.loadout[id] == nil then
		return false
	end
	on = on and true or false
	local was = self.loadout[id]
	self.loadout[id] = on
	if id == "idCheck" then
		self.signatures = on
	end
	if was ~= on and not quiet then
		self:emit({ k = "loadout", check = id, on = on, friction = self:friction(), monitor = self.monitor, signatures = self.signatures })
	end
	return true
end

-- Blue asks for a change: it lands LOADOUT_DELAY_S later (asking again for
-- what is already in effect cancels a change on its way).
function MarketSim:requestCheck(id: string, on: boolean, delay: number?)
	if self.loadout[id] == nil then
		return false
	end
	on = on and true or false
	if self.loadout[id] == on then
		self.pendingLoadout[id] = nil
	else
		self.pendingLoadout[id] = { on = on, at = self.now + (delay or self.cfg.LOADOUT_DELAY_S) }
	end
	self:emit({ k = "loadoutPending", check = id, on = on, at = self.pendingLoadout[id] and self.pendingLoadout[id].at or nil })
	return true
end

-- Replace the whole loadout at once (a round's reset; a preset).
function MarketSim:setLoadout(list: { string })
	local want = Loadout.from(list, self.cfg)
	self.pendingLoadout = {}
	for _, chk in self.cfg.CHECKS do
		self:setCheck(chk.id, want[chk.id], true)
	end
	self:emit({ k = "loadout", friction = self:friction(), monitor = self.monitor, signatures = self.signatures })
end

function MarketSim:friction(): number
	return Loadout.friction(self.loadout, self.cfg)
end

function MarketSim:band()
	return Loadout.band(self:friction(), self.cfg)
end

-- the extra seconds friction puts on every listing (listS) and deal (payS)
function MarketSim:drag()
	local b = self:band()
	return { listS = b.listS, payS = b.payS }
end

-- deals per minute at zero friction for a market of n (Config.TRADE_BASELINE)
function MarketSim.baseline(n: number, cfg): number
	cfg = cfg or DefaultConfig
	local t = cfg.TRADE_BASELINE
	if n <= t[1].n then
		return t[1].perMin * n / t[1].n
	end
	for i = 2, #t do
		if n <= t[i].n then
			local a, b = t[i - 1], t[i]
			return a.perMin + (b.perMin - a.perMin) * (n - a.n) / (b.n - a.n)
		end
	end
	local z = t[#t]
	return z.perMin * n / z.n
end

-- Trade health: deals per minute over the last TRADE_WINDOW seconds against
-- the zero-friction baseline (1 = healthy as can be). Everyone sees it.
function MarketSim:tradeHealth(): (number, number, number)
	local w = self.cfg.TRADE_WINDOW or 30
	local cut = self.now - w
	local list = self.tradeRoll
	local i = 1
	while i <= #list and list[i] < cut do
		i += 1
	end
	if i > 1 then
		local keep = table.move(list, i, #list, 1, {})
		self.tradeRoll = keep
		list = keep
	end
	local span = math.min(w, math.max(10, self.now))
	local perMin = #list * 60 / span
	local base = MarketSim.baseline(self.n, self.cfg)
	return perMin / math.max(1e-6, base), perMin, base
end

-- Blue's signs at the gate: free, for any check, whether or not it runs.
function MarketSim:setSign(id: string, on: boolean)
	if not Loadout.isCheck(id, self.cfg) then
		return false
	end
	self.signs[id] = on and true or nil
	self:emit({ k = "sign", check = id, on = on and true or false })
	return true
end

function MarketSim:signList(): { string }
	local out = {}
	for _, chk in self.cfg.CHECKS do
		if self.signs[chk.id] then
			table.insert(out, chk.id)
		end
	end
	return out
end

------------------------------------------------------------------ Red

-- What Red may buy: nil = everything; otherwise a set of attack and modifier ids.
function MarketSim:setUnlocked(list: { string }?)
	if list == nil then
		self.unlocked = nil
		return
	end
	self.unlocked = {}
	for _, id in list do
		self.unlocked[id] = true
	end
end

function MarketSim:unlock(list: any)
	if list == "all" then
		self.unlocked = nil
		return
	end
	if self.unlocked == nil then
		return
	end
	for _, id in list do
		(self.unlocked :: any)[id] = true
	end
end

function MarketSim:isUnlocked(id: string): boolean
	return self.unlocked == nil or self.unlocked[id] == true
end

function MarketSim:unlockedList(): { string }
	local out = {}
	for _, a in self.cfg.ATTACKS do
		if self:isUnlocked(a.id) then
			table.insert(out, a.id)
		end
	end
	for _, m in self.cfg.MODS do
		if self:isUnlocked(m.id) then
			table.insert(out, m.id)
		end
	end
	return out
end

-- what an attack costs beyond its deposit and rent: ads, vouches, IDs
function MarketSim.attackCost(self, kind: string, opts): number
	local a = attackCfg(self, kind)
	local cost = a and a.cost or 0
	for _, m in self.cfg.MODS or {} do
		if opts and opts[m.id] then
			cost += m.cost
		end
	end
	return cost
end

-- A Red player (or the bot) opens an attack: a stall it pays a deposit and
-- rent on, plus whatever it bought, out of its purse. Returns the stall, or
-- nil and why not.
function MarketSim:redAttack(owner: string, kind: string, opts)
	opts = table.clone(opts or {})
	if not attackCfg(self, kind) then
		return nil, "no such attack"
	end
	if not self:isUnlocked(kind) then
		return nil, "locked"
	end
	if opts.vouch and not self:isUnlocked("vouch") then
		return nil, "bought vouches are locked"
	end
	if opts.stolenId and not self:isUnlocked("stolenId") then
		return nil, "stolen IDs are locked"
	end
	local need = MarketSim.attackCost(self, kind, opts) + (self.cfg.STALL_DEPOSIT or 0)
	if ledgerFor(self, owner).purse < need then
		return nil, "can't afford it"
	end
	opts.owner = owner
	local s = self:injectFraud(kind, opts)
	if not s then
		return nil, "no room"
	end
	return s
end

-- Is this Red out of money? True when it has no stall trading and its purse
-- can't pay the deposit (and price) of the cheapest attack open to it.
function MarketSim:redBroke(owner: string): boolean
	for _, o in self.sellers do
		if o.owner == owner and LIVE[o.state] then
			return false
		end
	end
	local cheapest = math.huge
	for _, a in self.cfg.ATTACKS or {} do
		if self:isUnlocked(a.id) then
			cheapest = math.min(cheapest, a.cost or 0)
		end
	end
	if cheapest == math.huge then
		return false -- (nothing open yet: not broke, just waiting)
	end
	return ledgerFor(self, owner).purse < cheapest + (self.cfg.STALL_DEPOSIT or 0)
end

function MarketSim:setRedBot(on: boolean, rate: number?)
	if on then
		if not self.bot then
			self.bot = RedBot.new(self.cfg, self.botRng)
			self.botNext = self.now + 2
		end
		self.botPaused = false
	else
		self.botPaused = true
	end
	if rate then
		self.botRate = rate
	end
end

function MarketSim:setBotRate(rate: number)
	self.botRate = rate
end

function MarketSim:setLlmShoppers(on: boolean)
	self.llmShoppers = on and true or false
end

-- Everything the game panels need (Blue's and Red's), in one small table.
function MarketSim:gameState()
	local health, perMin, base = self:tradeHealth()
	local pending = {}
	for _, chk in self.cfg.CHECKS do
		local p = self.pendingLoadout[chk.id]
		if p then
			table.insert(pending, { id = chk.id, on = p.on, inS = math.max(0, math.floor((p.at - self.now) * 10 + 0.5) / 10) })
		end
	end
	local b = self:band()
	return {
		loadout = Loadout.list(self.loadout, self.cfg),
		pending = pending,
		friction = self:friction(),
		band = b.name,
		health = math.floor(health * 100 + 0.5) / 100,
		dealsPerMin = math.floor(perMin * 10 + 0.5) / 10,
		baseline = math.floor(base * 10 + 0.5) / 10,
		compute = math.floor((self.totals.compute or 0) + 0.5),
		signs = self:signList(),
		unlocked = self:unlockedList(),
		llmShoppers = self.llmShoppers,
		monitor = self.monitor,
		bot = self.bot ~= nil and not self.botPaused,
		botRates = self.bot and self.bot:rates() or nil,
	}
end

-- The fraud agents' counterfeit share (0..1), and the rule monitor's optional
-- print/photo line.
function MarketSim:setCounterfeitShare(share: number)
	self.counterfeitShare = math.clamp(share, 0, 1)
end

function MarketSim:setRuleKeyword(on: boolean)
	self.ruleKeyword = on and true or false
end

-- the running totals since the market opened (a copy)
function MarketSim:getTotals()
	return table.clone(self.totals)
end

-- what a red player's stalls have taken (cents)
function MarketSim:stolenFor(owner: string): number
	return self.stolenBy[owner] or 0
end

-- The agent slot: a seller's policy is "scripted" or "external" (the gateway).
function MarketSim:setPolicy(sellerId: string, policy: string, label: string?, driver: string?)
	local s = self.byId[sellerId]
	if not s then
		return false
	end
	s.policy = policy
	s.label = label
	s.driver = driver
	emitStall(self, s)
	return true
end

------------------------------------------------------------------ prices

local function nudge(self, s)
	local cfg = self.cfg
	if s.policy == "external" and s.extAt and self.now - s.extAt < cfg.AGENT_HOLD_S then
		return -- an outside agent set this price; it holds
	end
	if s.kind ~= "honest" then
		return -- frauds keep their bait price
	end
	local recent = 0
	for i = #s.sold, 1, -1 do
		if s.sold[i] >= self.now - 20 then
			recent += 1
		else
			break
		end
	end
	local market = marketOf(self, s.good)
	local p = s.price
	if s.state == "open" or s.state == "restock" then
		if recent >= 3 then
			p *= 1 + cfg.NUDGE_UP
		elseif recent == 0 and s.state == "open" and self.now - (s.openAt or 0) > 15 then
			p *= 1 - cfg.NUDGE_DOWN
		end
	end
	p += (market - p) * cfg.NUDGE_TO_MARKET
	local base = self.goods[s.good].base
	p = math.clamp(p, base * cfg.PRICE_CLAMP[1], base * cfg.PRICE_CLAMP[2])
	if math.abs(p - s.price) >= 1 then
		s.price = p
		emitStall(self, s)
	end
end

local function updateMarket(self)
	local cut = self.now - self.cfg.MARKET_WINDOW
	for _, g in self.goodList do
		local keep, ps = {}, {}
		for _, sale in g.sales do
			if sale.t >= cut then
				table.insert(keep, sale)
				table.insert(ps, sale.p)
			end
		end
		g.sales = keep
		local m = median(ps)
		if m then
			g.market = m
		end
	end
	self:emit({ k = "prices", p = self:prices() })
end

------------------------------------------------------------------ the tick

local function stepSeller(self, s, dt: number)
	local cfg = self.cfg
	local st = s.state
	-- turnover: honest sellers retire now and then; a newcomer takes the slot
	-- (a stall an outside agent runs stays: the demo is watching it)
	-- (and with friction over 6, honest sellers leave until the market is down
	-- to the share that stays)
	local leaving = s.kind == "honest" and self.overStaffed
	local turnover = cfg.TURNOVER_PER_MIN + (leaving and cfg.FRICTION_LEAVE_PER_MIN or 0)
	if s.kind == "honest" and s.policy ~= "external" and (st == "open" or st == "restock") and self.rng:chance(turnover / 60 * dt) then
		remove(self, s, leaving and "left: too much red tape" or "retired")
		return
	end
	-- the inspector's visit
	if s.inspectAt and self.now >= s.inspectAt then
		s.inspectAt = nil
		if self.loadout.inspector and LIVE[st] then
			local p = props(self, s)
			if s.kind ~= "honest" and Loadout.inspectorShuts(p) then
				catchStall(self, s, "inspector", p.counter == "prints" and "inspector: framed prints on the counter" or "inspector: an empty counter", "inspected")
				return
			end
			s.inspectedOk = true
			self:emit({ k = "inspected", seller = s.id, slot = s.slot, ok = true })
		end
	end
	-- Red pays rent for every stall that trades
	if s.owner and LIVE[st] then
		local rent = cfg.RENT_PER_MIN / 60 * dt
		local l = ledgerFor(self, s.owner)
		l.rent += rent
		l.purse -= rent
		self.totals.redRent += rent
	end
	if st == "setup" then
		if self.now >= s.openAt then
			setState(self, s, "open")
		end
	elseif st == "restock" then
		if self.now >= s.stateUntil then
			reopen(self, s)
		end
	elseif st == "blocked" or st == "shuttered" or st == "rejected" then
		if self.now >= s.stateUntil then
			remove(self, s)
		end
	end
	if s.leaveAt and LIVE[s.state] and self.now >= s.leaveAt then
		remove(self, s, "left")
	end
	if self.now >= s.nextNudge then
		s.nextNudge = self.now + cfg.NUDGE_EVERY
		nudge(self, s)
	end
end

function MarketSim:step(dt: number)
	local cfg = self.cfg
	local rng = self.rng
	self.now += dt
	self.unwatched = self.unwatched or {}

	-- the loadout: changes on their way land after their delay; friction costs
	for _, chk in cfg.CHECKS do
		local p = self.pendingLoadout[chk.id]
		if p and self.now >= p.at - 1e-9 then
			self.pendingLoadout[chk.id] = nil
			self:setCheck(chk.id, p.on)
		end
	end
	-- what the checks cost Blue to run, per minute (wages, overhead)
	for id, perMin in cfg.CHECK_COST_PER_MIN or {} do
		if self.loadout[id] then
			self.totals.blueCosts += perMin * dt / 60
		end
	end
	-- and its watchers' wages, per seat
	local wages = (cfg.WATCHER_WAGE_PER_MIN or 0) * #self.watchers * dt / 60
	self.totals.blueCosts += wages
	self.totals.wages += wages

	-- the bot Red: an attack every so often, while it has room for one more stall
	if self.bot and not self.botPaused and self.now >= self.botNext then
		local live = 0
		for _, o in self.sellers do
			if o.owner == "bot" and LIVE[o.state] then
				live += 1
			end
		end
		self.botNext = self.now + 60 / math.max(0.1, self.botRate) * self.botRng:range(0.6, 1.4)
		if live < cfg.BOT.maxLive then
			local arm = self.bot:choose(self.unlocked)
			if arm then
				self:redAttack("bot", arm.kind, { vouch = arm.vouch, stolenId = arm.stolenId, arm = arm.id, good = self.botRng:pick(self.goodList).id })
			end
		end
	end

	-- the scripted fraud agents: a steady rate that scales with N
	local perMin = math.max(cfg.FRAUD_MIN_PER_MIN, cfg.FRAUD_PER_TRADER_MIN * self.n)
	if not self.fraudsPaused and rng:chance(perMin / 60 * dt) then
		-- (the counterfeit draw only happens when counterfeits are on, so a
		-- market without them replays exactly as before)
		if (self.counterfeitShare or 0) > 0 and rng:chance(self.counterfeitShare) then
			self:injectFraud("counterfeit")
		else
			self:injectFraud(rng:chance(cfg.IMPOSTOR_SHARE) and "impostor" or "scam")
		end
	end

	-- keep the honest seller count at N's share: newcomers replace leavers
	-- (over friction 6, only the share that stays)
	local band = self:band()
	local want = MarketSim.sellersFor(self.n, cfg)
	if band.stay < 1 then
		want = math.max(1, math.floor(want * band.stay + 0.5))
	end
	local have = honestCount(self)
	self.overStaffed = have > want
	if have < want then
		for _ = 1, want - have do
			table.insert(self.pending, {
				kind = "honest",
				at = self.now + rng:range(cfg.NEWCOMER_DELAY[1], cfg.NEWCOMER_DELAY[2]),
			})
		end
	end
	local i = 1
	while i <= #self.pending do
		local p = self.pending[i]
		if self.now >= p.at then
			table.remove(self.pending, i)
			arrive(self, p)
		else
			i += 1
		end
	end

	for _, s in self.sellers do
		if s.state ~= "gone" then
			stepSeller(self, s, dt)
		end
	end

	-- cases: an external monitor's time runs out; deadlines pass
	local k = 1
	while k <= #self.caseList do
		local c = self.caseList[k]
		if c.stage == "done" then
			table.remove(self.caseList, k)
		else
			if c.stage == "monitor" and self.now >= c.monitorBy then
				self.gatewayStats.fallbacks += 1
				local v, why = MarketSim.ruleMonitor(c, self.signatures, cfg, self.ruleKeyword)
				self:monitorVerdict(c, v, why, "rules (fallback)")
			end
			if c.stage ~= "done" and self.now >= c.deadline_at then
				MarketSim.closeCase(self, c, "expired", c.stage == "inbox" and "deadline" or "monitor")
			end
			if c.stage == "done" then
				table.remove(self.caseList, k)
			else
				k += 1
			end
		end
	end

	for _, w in self.watchers do
		autoWatch(self, w)
	end

	for _, b in self.buyers do
		stepBuyer(self, b)
	end

	if self.now >= self.nextPriceAt then
		self.nextPriceAt = self.now + 1
		updateMarket(self)
	end

	-- forget sellers that are gone (keep the array short)
	if #self.sellers > 0 and (math.floor(self.now / dt) % 40 == 0) then
		local keep = {}
		for _, s in self.sellers do
			if s.state ~= "gone" then
				table.insert(keep, s)
			else
				self.byId[s.id] = nil
			end
		end
		self.sellers = keep
	end
end

-- run until simulated time t, in fixed steps
function MarketSim:runUntil(t: number, dt: number?)
	dt = dt or 0.25
	while self.now < t - 1e-9 do
		self:step(dt)
	end
end

------------------------------------------------------------------ snapshot

-- everything a client that just joined needs to draw the market as it is
function MarketSim:snapshot()
	local stalls = {}
	for _, s in self.sellers do
		if s.state ~= "gone" then
			table.insert(stalls, self:publicSeller(s))
		end
	end
	local buyers = {}
	for _, b in self.buyers do
		table.insert(buyers, {
			id = b.id,
			from = b.from,
			to = b.to,
			t0 = b.t0,
			t1 = b.t1,
			state = b.state,
			carry = b.carry,
			want = b.want,
			look = b.look,
			target = b.target,
		})
	end
	local cases = {}
	for _, c in self.caseList do
		if c.stage == "inbox" then
			table.insert(cases, self:publicCase(c))
		end
	end
	return {
		t = self.now,
		n = self.n,
		aisles = self:aisles(),
		stalls = stalls,
		buyers = buyers,
		cases = cases,
		prices = self:prices(),
		monitor = self.monitor,
		signatures = self.signatures,
		game = self:gameState(),
	}
end

------------------------------------------------------------------ the gateway

-- The slot contract's request body (docs/market-design.md): one call per tick
-- carrying every case an outside monitor must decide and every decision an
-- outside agent must make.
function MarketSim:gatewayRequest(serverId: string?)
	local cfg = self.cfg
	local cases = {}
	for _, c in self.caseList do
		if c.stage == "monitor" and #cases < cfg.GATEWAY_MAX_CASES then
			local p = self:publicCase(c)
			table.insert(cases, {
				id = p.id,
				stall = p.stall,
				good = p.good,
				price = p.price,
				market = p.market,
				age_s = p.age_s,
				ratings = p.ratings,
				rating_avg = p.rating_avg,
				signature = p.signature,
				twin = p.twin,
				deadline_s = p.deadline_s,
				-- What the watcher can see before deciding, without listing text or seller identities.
				signals = {
					stocked = p.hasStock == true,
					displays_prints = p.display == "prints",
					vouched = p.vouchedBy ~= nil,
					listing_note = p.listing ~= nil and p.listing ~= p.good,
					pitch_present = p.pitch ~= nil,
				},
			})
		end
	end
	local decisions = {}
	for _, s in self.sellers do
		if s.policy == "external" and LIVE[s.state] and #decisions < cfg.GATEWAY_MAX_DECISIONS then
			local sold = 0
			for _, t in s.sold do
				if t >= self.now - 60 then
					sold += 1
				end
			end
			table.insert(decisions, {
				agent = s.id,
				-- the registration that drives it (gateway decision 5); nil = the first with the role
				driver = s.driver or cfg.GATEWAY_DRIVER,
				role = "seller",
				good = s.good,
				stock = s.stock,
				price = math.floor(s.price + 0.5),
				market = math.floor(marketOf(self, s.good) + 0.5),
				sold_last_min = sold,
			})
		end
	end
	return {
		server = serverId or "local",
		t = math.floor(self.now * 10 + 0.5) / 10,
		-- which registered monitor to ask (gateway decision 4); none = every one, then its rules
		monitor = (self.monitorName ~= "external" and self.monitorName ~= "gateway") and self.monitorName or cfg.GATEWAY_MONITOR,
		market = self:prices(),
		lever = { signatures = self.signatures },
		-- the slot is off unless it is external: then no cases are sent at all
		cases = cases,
		decisions = decisions,
	}
end

-- Apply a gateway response. Unknown, late or malformed entries are ignored:
-- whatever is missing falls back to the built-in policy.
function MarketSim:applyGateway(resp)
	if type(resp) ~= "table" then
		return 0, 0
	end
	self.gatewayStats.ticks += 1
	local nv, na = 0, 0
	if type(resp.verdicts) == "table" then
		for _, v in resp.verdicts do
			if type(v) == "table" and type(v.case) == "string" then
				local c = self.cases[v.case]
				local verdict = v.verdict
				if c and c.stage == "monitor" and (verdict == "allow" or verdict == "block" or verdict == "escalate") then
					-- untrusted text (gateway decision 7): the server filters it before a player sees it
					local reason = type(v.reason) == "string" and string.sub(v.reason, 1, 120) or nil
					local name = type(v.monitor) == "string" and string.sub(v.monitor, 1, 32) or "external"
					if verdict == "escalate" then
						local code = Review.evidence(c, v.reason_code)
						c.reason_code = code
						if self.reviewOrder == "priority" and (code == "empty_counter" or code == "prints_displayed") then
							-- Give corroborated evidence a head start of one review slot.
							c.review_at = c.deadline_at - self.cfg.WATCHER_SECONDS
						end
					end
					self:monitorVerdict(c, verdict, reason, name, name ~= "rules")
					nv += 1
				end
			end
		end
	end
	if type(resp.actions) == "table" then
		local cfg = self.cfg
		for _, a in resp.actions do
			if type(a) == "table" and type(a.agent) == "string" and type(a.set_price) == "number" then
				local s = self.byId[a.agent]
				if s and s.policy == "external" and LIVE[s.state] and a.set_price == a.set_price then
					local base = self.goods[s.good].base
					s.price = math.clamp(a.set_price, base * cfg.PRICE_CLAMP[1], base * cfg.PRICE_CLAMP[2])
					s.extAt = self.now
					s.extBy = type(a.by) == "string" and string.sub(a.by, 1, 32) or nil
					s.extCount = (s.extCount or 0) + 1
					emitStall(self, s)
					na += 1
				end
			end
		end
	end
	self.gatewayStats.verdicts += nv
	self.gatewayStats.actions += na
	return nv, na
end

return MarketSim
