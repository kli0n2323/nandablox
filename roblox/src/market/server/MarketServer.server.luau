-- NANDA Market server (docs/market-design.md, "Architecture").
--
-- Runs MarketSim at a fixed tick, streams its events to every client in one
-- batch per tick, takes verdicts, settings and lever votes over a RemoteEvent,
-- and (only if switched on) calls the gateway once per tick. No Humanoids, no
-- server-side parts: the clients draw everything.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Market = ReplicatedStorage:WaitForChild("Market")
local Config = require(Market.Config)
local MarketSim = require(Market.MarketSim)
local Gateway = require(Market.Gateway)
local Round = require(Market.Round)
local Layout = require(Market.Layout)
local Score = require(Market.Score)
local Ghost = require(Market.Ghost)

local TICK = 0.25 -- seconds of simulated (and real) time per step
local METER_EVERY = 0.5

------------------------------------------------------------------ remotes

local net = Instance.new("Folder")
net.Name = "MarketNet"
local batchEv = Instance.new("RemoteEvent")
batchEv.Name = "Batch"
batchEv.Parent = net
local cmdEv = Instance.new("RemoteEvent")
cmdEv.Name = "Cmd"
cmdEv.Parent = net
local hello = Instance.new("RemoteFunction")
hello.Name = "Hello"
hello.Parent = net
net.Parent = ReplicatedStorage

------------------------------------------------------------------ the crowd's rigs

-- One R15 template per outfit, made once from a HumanoidDescription, then
-- stripped to parts + Motor6Ds + an AnimationController (no Humanoid: no
-- physics, no state machine). Clients clone these into their pools.
task.spawn(function()
	local Outfits = require(Market.Outfits)
	local folder = Instance.new("Folder")
	folder.Name = "MarketRigs"
	local made = 0
	for i, o in Outfits.LIST do
		local ok, err = pcall(function()
			local d = Instance.new("HumanoidDescription")
			local skin = Outfits.SKIN[o.skin]
			d.HeadColor = skin
			d.LeftArmColor = skin
			d.RightArmColor = skin
			d.TorsoColor = o.top
			d.LeftLegColor = o.legs
			d.RightLegColor = o.legs
			local m = Players:CreateHumanoidModelFromDescriptionAsync(d, Enum.HumanoidRigType.R15)
			-- sleeves: colour the upper arms like the shirt
			for _, name in { "LeftUpperArm", "RightUpperArm" } do
				local p = m:FindFirstChild(name)
				if p and p:IsA("BasePart") then
					p.Color = o.top
				end
			end
			-- a face, so the nearest people read as people at eye level
			local head = m:FindFirstChild("Head")
			if head and not head:FindFirstChildOfClass("Decal") then
				local face = Instance.new("Decal")
				face.Name = "face"
				face.Face = Enum.NormalId.Front
				face.Texture = "rbxasset://textures/face.png"
				face.Parent = head
			end
			local hum = m:FindFirstChildOfClass("Humanoid")
			if hum then
				hum:Destroy()
			end
			for _, x in m:GetDescendants() do
				if x:IsA("Script") or x:IsA("LocalScript") or x:IsA("Sound") then
					x:Destroy()
				elseif x:IsA("BasePart") then
					x.Anchored = false
					x.CanCollide = false
					x.CanQuery = false
					x.CanTouch = false
					x.CastShadow = false
					x.Massless = true
				end
			end
			m.PrimaryPart.Anchored = true
			local ac = Instance.new("AnimationController")
			Instance.new("Animator").Parent = ac
			ac.Parent = m
			m.Name = "Outfit" .. i
			m.Parent = folder
			made += 1
		end)
		if not ok then
			warn("[market] outfit " .. i .. ": " .. tostring(err))
		end
	end
	folder:SetAttribute("Count", made)
	folder.Parent = ReplicatedStorage
	print(string.format("[market] %d R15 outfit templates ready", made))
end)

------------------------------------------------------------------ players' own avatars

-- Each player's real avatar as one more rig template (Avatars.luau): fetched
-- and built here, cloned and posed by every client like the crowd. Anything
-- that fails or times out leaves no template, and the clients keep the stock
-- outfit in the team shirt.
local Avatars = require(Market.Avatars)
local avatarFolder = Instance.new("Folder")
avatarFolder.Name = Avatars.FOLDER
avatarFolder.Parent = ReplicatedStorage
local avatarDeps = {
	spawn = task.spawn,
	wait = task.wait,
	now = os.clock,
	get = function(userId: number)
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end,
}
local avatarBuilding: { [number]: boolean } = {}

-- the model's head top above its feet (body only: hats don't count)
local function headTop(m: Model, hum: Humanoid): number?
	local root = m.PrimaryPart
	local head = m:FindFirstChild("Head")
	if not (root and head and head:IsA("BasePart")) then
		return nil
	end
	local feet = root.Position.Y - root.Size.Y / 2 - hum.HipHeight
	return head.Position.Y + head.Size.Y / 2 - feet
end

local function buildAvatar(p: Player)
	local userId = p.UserId
	if avatarBuilding[userId] or avatarFolder:FindFirstChild(Avatars.templateName(userId)) then
		return
	end
	avatarBuilding[userId] = true
	local t0 = os.clock()
	local desc, why = Avatars.fetch(userId, avatarDeps)
	if not desc then
		warn(string.format("[market] avatar %d: %s; stock outfit", userId, tostring(why)))
		avatarBuilding[userId] = nil
		return
	end
	local ok, m = Avatars.withDeadline(avatarDeps, Avatars.TIMEOUT, function()
		return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or typeof(m) ~= "Instance" then
		warn(string.format("[market] avatar %d: build %s; stock outfit", userId, tostring(m)))
		avatarBuilding[userId] = nil
		return
	end
	local built, err = pcall(function()
		local hum = m:FindFirstChildOfClass("Humanoid") :: Humanoid
		-- the Humanoid stays (layered clothing and accessories hang off it)
		-- but does nothing: no states, no name, no health bar
		hum.EvaluateStateMachine = false
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.RequiresNeck = false
		hum.BreakJointsOnDeath = false
		if not hum:FindFirstChildOfClass("Animator") then
			Instance.new("Animator").Parent = hum
		end
		-- root height above the feet, before any fitting (ScaleTo scales the
		-- parts; whether it scales HipHeight too is not ours to rely on)
		local hip = hum.HipHeight + m.PrimaryPart.Size.Y / 2
		local k = Avatars.fitScale(headTop(m, hum))
		if k < 1 then
			m:ScaleTo(m:GetScale() * k)
			hip *= k
		end
		for _, x in m:GetDescendants() do
			if x:IsA("Script") or x:IsA("LocalScript") or x:IsA("Sound") then
				x:Destroy()
			elseif x:IsA("BasePart") then
				x.Anchored = false
				x.CanCollide = false
				x.CanQuery = false
				x.CanTouch = false
				x.Massless = true
			end
		end
		m.PrimaryPart.Anchored = true
		m:SetAttribute("Hip", hip) -- for the clients' placing
		m:SetAttribute("UserId", userId)
		m.Name = Avatars.templateName(userId)
		m.Parent = avatarFolder
	end)
	avatarBuilding[userId] = nil
	if not built then
		warn(string.format("[market] avatar %d: %s; stock outfit", userId, tostring(err)))
		m:Destroy()
		return
	end
	print(string.format("[market] avatar %d (%s) ready in %.1f s", userId, p.Name, os.clock() - t0))
end

Players.PlayerAdded:Connect(function(p)
	task.spawn(buildAvatar, p)
end)
for _, p in Players:GetPlayers() do
	task.spawn(buildAvatar, p)
end
Players.PlayerRemoving:Connect(function(p)
	local m = avatarFolder:FindFirstChild(Avatars.templateName(p.UserId))
	if m then
		m:Destroy()
	end
end)

------------------------------------------------------------------ the sim

local seed = tonumber(workspace:GetAttribute("MarketSeed")) or 20261106
local sim = MarketSim.new({ seed = seed, n = 5 })
sim:setMonitor("off")
sim:setSignatures(true)
sim:drain()

local function watcherId(p: Player): string
	return "p" .. tostring(p.UserId)
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- state the whole room shares, beside the sim's own
local room = {
	caption = nil :: string?,
	beat = 0,
	cam = nil :: string?,
	votes = {} :: { [string]: boolean }, -- watcher id -> wants signatures on
	auto = {} :: { [string]: boolean },
	paused = false,
	crew = false,
	botRate = Config.BOT.perMin,
}

-- the timed round (Config.ROUND_PHASES) and the last scoreboard it produced
local round = Round.new(Config)
local lastScore: any = nil
local scoreSeq = 0
-- when a round ends, the round bar and the meter hold the scoreboard's
-- numbers until the next round or a free-play setting
local frozen: any = nil
-- the two extreme Blues (no checks, every check) on this round's seed,
-- played headless a slice per frame so the scoreboard can mark them
local ghosts: any = nil

------------------------------------------------------------------ gateway

local auth: any = nil
local function authHeader()
	if auth ~= nil then
		return auth
	end
	auth = false
	local ok, secret = pcall(function()
		return (HttpService :: any):GetSecret(Config.GATEWAY_SECRET):AddPrefix("Bearer ")
	end)
	if ok and secret then
		auth = secret
		return auth
	end
	local box = ServerStorage:FindFirstChild("NandaSecrets")
	local mod = box and box:FindFirstChild("LlmToken")
	if mod and mod:IsA("ModuleScript") then
		local ok2, token = pcall(require, mod)
		if ok2 and type(token) == "string" and #token > 0 then
			auth = "Bearer " .. token
		end
	end
	return auth
end

local gateway = Gateway.new({
	config = Config,
	encode = function(t)
		return HttpService:JSONEncode(t)
	end,
	decode = function(s)
		return HttpService:JSONDecode(s)
	end,
	clock = os.clock,
	post = function(url, body, headers)
		local h = table.clone(headers)
		local a = authHeader()
		if a then
			h["Authorization"] = a
		end
		local res = HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = h,
			Body = body,
			Timeout = math.max(1, math.ceil(Config.GATEWAY_TIMEOUT_S)),
		} :: any)
		local retry = tonumber(res.Headers and (res.Headers["retry-after"] or res.Headers["Retry-After"]))
		return res.Success, res.StatusCode, res.Body, retry
	end,
})

------------------------------------------------------------------ settings

local function majorityLever()
	local on, off = 0, 0
	for _, p in Players:GetPlayers() do
		local v = room.votes[watcherId(p)]
		if v == true then
			on += 1
		elseif v == false then
			off += 1
		end
	end
	-- the council's vote and the loadout's ID check toggle are one flag; like
	-- any loadout change it lands LOADOUT_DELAY_S later
	if on > off then
		sim:requestCheck("idCheck", true)
	elseif off > on then
		sim:requestCheck("idCheck", false)
	end
end

local function setMonitor(mode: string, keep: boolean?)
	if mode == "external" then
		gateway:setEnabled(true)
		sim:setMonitor("external", Config.GATEWAY_MONITOR)
	else
		if sim.monitor == "external" then
			gateway:setEnabled(#(sim:gatewayRequest().decisions) > 0)
		end
		-- (keep: the loadout as it is, no preset)
		sim:setMonitor(mode, nil, keep)
	end
	sim:mark("monitor " .. mode)
end

-- the agent slot: hand one honest open stall to an outside agent (or back)
local agentSeller: string? = nil
local function setOutsideAgent(on: boolean)
	agentSeller = nil
	for _, s in sim.sellers do
		if s.policy == "external" then
			sim:setPolicy(s.id, "scripted")
		end
		-- re-entering the beat starts the badge over: "waiting" until the next real price
		s.labelled = nil
		s.extCount = nil
	end
	if on then
		local best
		for _, s in sim.sellers do
			if s.kind == "honest" and s.state == "open" and s.ratings >= 5 then
				if not best or s.slot < best.slot then
					best = s
				end
			end
		end
		if best then
			-- the gateway's gemini-seller prices it. Until its first action
			-- arrives the badge says it is waiting; with no token it says the
			-- slot fell back to the scripted seller
			local live = authHeader() ~= false and workspace:GetAttribute("MarketGateway") ~= false
			sim:setPolicy(best.id, "external", live and "Gemini (waiting for its first price)" or "the agent slot (scripted fallback)", "gemini-seller")
			gateway:setEnabled(live)
			agentSeller = best.id
			return best.id
		end
	elseif sim.monitor ~= "external" then
		gateway:setEnabled(false)
	end
	return nil
end

------------------------------------------------------------------ demo beats

-- The five beats (docs/market-design.md, "The demo"), plus the outside agent.
local BEATS = {
	{ caption = "Five traders. You can decide every case, and you keep up.  (biking)", n = 5, monitor = "off", sig = true, scam = true, quiet = true, cam = "street" },
	{ caption = "Now 300. The inbox overflows, the meter goes red, and frauds escape while their cases wait.", n = 300, monitor = "off", sig = true, cam = "street", thenCam = "overview" },
	{ caption = "Monitor on: four rules settle the obvious. Only the gray zone reaches you.  (paragliding)", n = 300, monitor = "rules", sig = true },
	{ caption = "Signatures off: trade speeds up, twins appear, the inbox floods again. The rule was doing oversight work.", n = 300, monitor = "rules", sig = false, burst = 8 },
	{ caption = "A second watcher joins, and the inbox splits between you.  (crewed sailing)", n = 300, monitor = "rules", sig = false, second = true, cam = "balcony" },
	{ caption = "An outside agent runs one stall through the agent slot: the seat your agents will fill.", n = 300, monitor = "rules", sig = true, agent = true, cam = "street" },
}

local SECOND = "helper"
-- a player's team: "blue" (watchers: the inbox, monitors, council) or "red"
-- (con artists). A player picks on join; until then the default below is
-- only the pre-selected card in their picker.
local playerRole: { [Player]: string } = {}

-- Blue's crew roles (docs/market-game.md, "Why a human, and why a crew"):
-- lookout (inbox, escapes), trim (loadout), skipper (council votes). One
-- Blue holds all three; two split them lookout + skipper / trim; three take
-- one each. In join order.
local function crewRoles(p: Player): { string }
	local blues = {}
	for _, q in Players:GetPlayers() do
		if (playerRole[q] or "blue") == "blue" then
			table.insert(blues, q)
		end
	end
	local i = table.find(blues, p) or 1
	if #blues <= 1 then
		return { "lookout", "trim", "skipper" }
	elseif #blues == 2 then
		return i == 1 and { "lookout", "skipper" } or { "trim" }
	end
	return ({ { "lookout" }, { "trim" }, { "skipper" } })[((i - 1) % 3) + 1]
end

local playerChosen: { [Player]: boolean } = {}
local playerPose: { [Player]: { x: number, z: number, yaw: number, moving: boolean, mind: number? } } = {}
-- the frauds a red player opened (seller ids, newest last)
local playerStalls: { [Player]: { string } } = {}

local function defaultRole(p: Player): string
	for _, o in Players:GetPlayers() do
		if o ~= p and playerRole[o] == "blue" then
			return "red"
		end
	end
	return "blue"
end

-- The watchers are the Blue players. The round's Crew phase (or beat 5, or
-- the panel's "2") wants two: a second Blue human if there is one, else the
-- modelled helper. With no Blue player at all the helper watches alone, so a
-- Red player always has someone to beat.
local function syncWatchers()
	local plist = Players:GetPlayers()
	for _, p in plist do
		if not playerRole[p] then
			playerRole[p] = defaultRole(p)
		end
	end
	local blues = 0
	for _, p in plist do
		local wid = watcherId(p)
		if playerRole[p] == "blue" then
			sim:addWatcher(wid, { auto = room.auto[wid] == true, label = "watcher" })
			blues += 1
		else
			sim:removeWatcher(wid)
		end
	end
	local want = room.crew and 2 or 1
	if blues < want then
		sim:addWatcher(SECOND, { auto = true, label = blues == 0 and "auto watcher" or "second watcher" })
	else
		sim:removeWatcher(SECOND)
	end
end

-- The bot Red plays during a round when no human plays Red.
local function humanRed(): boolean
	for _, p in Players:GetPlayers() do
		if playerRole[p] == "red" then
			return true
		end
	end
	return false
end

local function syncBot()
	if round.active and not humanRed() then
		sim:setRedBot(true, room.botRate)
	else
		sim:setRedBot(false)
	end
end

-- after a round: the market as it was (scripted fraud agents, every attack open)
local function afterRound()
	sim:setRedBot(false)
	sim:setUnlocked(nil)
	sim:setLlmShoppers(false)
	sim.fraudsPaused = false
end

local function stopRound(why: string?)
	ghosts = nil
	if round.active then
		round:stop()
		afterRound()
		sim:mark(why or "round stopped")
	end
end

local function applyBeat(i: number)
	-- a beat is a manual stage cue: it ends a running round
	stopRound("beat " .. i)
	sim:setCounterfeitShare(0)
	local b = BEATS[i]
	if not b then
		room.caption = nil
		room.beat = 0
		return
	end
	room.beat = i
	room.caption = b.caption
	-- the shot: some beats start close and cut wide after a few seconds
	room.cam = b.cam or "auto"
	if b.thenCam then
		task.delay(10, function()
			if room.beat == i then
				room.cam = b.thenCam
			end
		end)
	end
	if sim.n ~= b.n then
		sim:setSize(b.n)
	end
	if sim.monitor ~= b.monitor then
		setMonitor(b.monitor)
	end
	if sim.signatures ~= b.sig then
		sim:setSignatures(b.sig)
	end
	room.votes = {}
	room.crew = b.second == true
	syncWatchers()
	setOutsideAgent(b.agent == true)
	-- beat 1 is the presenter's: the scripted fraud agents rest, so the only
	-- fraud is the one seeded case, which no buyer reaches for 30 s
	sim.fraudsPaused = b.quiet == true
	if b.quiet then
		-- and any fraud already on its way to a buyer packs up: beat 1 starts clean
		for _, s in sim.sellers do
			if s.kind ~= "honest" and (s.state == "setup" or s.state == "open" or s.state == "restock") then
				s.leaveAt = sim.now
			end
		end
	end
	sim:mark(b.caption)
	if b.scam then
		task.delay(3, function()
			if room.beat == i then
				sim:injectFraud("scam", { price = 0.45, window = 30 })
			end
		end)
	end
	if b.burst then
		-- the twins arrive together: the inbox fills within seconds
		task.delay(2, function()
			if room.beat == i then
				sim:fraudBurst(b.burst)
			end
		end)
	end
end

------------------------------------------------------------------ the round

local function applyPhase(ph)
	Round.apply(sim, ph.set, {
		monitor = setMonitor,
		watchers = function(k: number)
			room.crew = k >= 2
			syncWatchers()
		end,
		botRate = function(rate: number)
			room.botRate = rate
			syncBot()
		end,
	})
	if ph.prompt and ph.prompt.ask == "vote" then
		room.votes = {} -- a fresh council vote
	end
	print(string.format("[market] round %s: %s", ph.name, ph.banner or ""))
end

local function startRound()
	-- the round overrides the beats: no caption, no outside agent, frauds on
	room.beat = 0
	room.caption = nil
	room.votes = {}
	setOutsideAgent(false)
	sim.fraudsPaused = false
	sim:setCounterfeitShare(0)
	-- a fresh ledger for every Red player, and a bot Red that knows nothing yet
	sim.red = {}
	sim.stolenBy = {}
	sim.bot = nil
	for _, p in Players:GetPlayers() do
		playerStalls[p] = nil
	end
	frozen = nil
	local gseed = (math.floor(os.time()) % 100000) + 1
	ghosts = { seed = gseed, none = Ghost.new(gseed, Ghost.NONE, Config), all = Ghost.new(gseed, Ghost.ALL, Config) }
	round:start(sim.now, sim:getTotals())
	for _, ph in round:update(sim.now, sim:getTotals(), #sim.watchers, sim:gameState()) do
		applyPhase(ph.phase)
	end
	sim:mark("round")
end

-- the ghosts' finishing lines (finishing them now if they are behind)
local function ghostLines()
	if not ghosts then
		return nil
	end
	for _, k in { "none", "all" } do
		local g = ghosts[k]
		while not g.done do
			g:advance(30)
		end
	end
	local n, a = ghosts.none:result(), ghosts.all:result()
	return {
		seed = ghosts.seed,
		none = { blue = n.blue, red = n.red, winner = n.winner, ended = n.ended, endedAt = n.endedAt },
		all = { blue = a.blue, red = a.red, winner = a.winner, ended = a.ended, endedAt = a.endedAt },
	}
end

-- each Red's line for the scoreboard: the humans by number, and the bot
local function redLines()
	local out = {}
	local nums = {}
	for i, p in Players:GetPlayers() do
		nums[watcherId(p)] = i
	end
	for owner, l in sim.red do
		local sc = Score.ledger(l)
		table.insert(out, {
			id = owner,
			bot = owner == "bot",
			label = owner == "bot" and "bot Red" or ("Red player " .. tostring(nums[owner] or "?")),
			stolen = sc.stolen,
			score = sc.score,
			purse = sc.purse,
			stalls = l.stalls,
		})
	end
	table.sort(out, function(a, b)
		if a.bot ~= b.bot then
			return not a.bot
		end
		return a.score > b.score
	end)
	return out
end

------------------------------------------------------------------ red's stalls

local function fmtMoney(c: number): string
	c = math.floor(c + 0.5)
	return string.format("%d.%02d", c // 100, c % 100)
end

-- what a red player's stall is doing, in a few words
local function stallStatus(s): string
	local st = s.state
	-- Red sees one coarse outcome, never which check (docs/market-game.md)
	if s.outcome == "rejected" then
		return "rejected at listing"
	elseif s.outcome == "blocked" then
		return "blocked by a person"
	elseif s.outcome == "inspected" then
		return "shut down by an inspector"
	elseif s.outcome == "refunded" then
		return "refunded at delivery"
	end
	if st == "rejected" then
		return "rejected at listing"
	elseif st == "blocked" then
		return "blocked"
	elseif st == "shuttered" then
		return string.format("took %s · closed", fmtMoney(s.stolen or 0))
	elseif st == "gone" then
		if (s.stolen or 0) > 0 then
			return string.format("took %s · gone", fmtMoney(s.stolen))
		end
		return s.blockedBy and "was blocked · gone" or "packed up"
	end
	if round.active then
		-- in the game Red learns nothing about Blue's checks until the outcome
		if st == "open" and (s.stolen or 0) > 0 then
			return string.format("open · took %s so far", fmtMoney(s.stolen))
		end
		return st == "setup" and "opening" or (st == "open" and "open · trading" or st)
	end
	local c = s.case and sim.cases[s.case]
	local by = s.allowedBy == "monitor" and "allowed by the monitor"
		or (s.allowedBy == "watcher" and "allowed by a watcher")
		or (s.allowedBy == "expired" and "nobody decided in time")
		or nil
	if c and c.stage == "inbox" then
		return "waiting in Blue's inbox"
	elseif c and c.stage == "monitor" then
		return "with the monitor"
	elseif st == "setup" then
		return (by or "setting up") .. " · opening"
	elseif st == "open" then
		if (s.stolen or 0) > 0 then
			return string.format("open · took %s so far", fmtMoney(s.stolen))
		end
		return "open · " .. (by or "trading")
	end
	return st
end

local function redInfo()
	local out = {}
	for _, p in Players:GetPlayers() do
		local ids = playerStalls[p]
		if ids or playerRole[p] == "red" then
			local stalls = {}
			for _, sid in ids or {} do
				local s = sim.byId[sid]
				if s then
					table.insert(stalls, {
						id = s.id,
						name = s.name,
						kind = s.kind,
						good = s.good,
						slot = s.slot,
						state = s.state,
						status = stallStatus(s),
						stolen = math.floor((s.stolen or 0) + 0.5),
						live = s.state == "setup" or s.state == "open" or s.state == "restock",
					})
				end
			end
			out[watcherId(p)] = { stolen = math.floor(sim:stolenFor(watcherId(p)) + 0.5), stalls = stalls }
		end
	end
	return out
end

-- the live stall a red player is minding at `slot`, if they own one there
local function mindedStall(p: Player, slot: number?)
	if not slot then
		return nil
	end
	for _, sid in playerStalls[p] or {} do
		local s = sim.byId[sid]
		if s and s.slot == slot and s.state ~= "gone" and s.state ~= "rejected" then
			return s
		end
	end
	return nil
end

------------------------------------------------------------------ commands

local SIZES = {}
for _, n in Config.SIZES do
	SIZES[n] = true
end

local lastCmd: { [Player]: number } = {}

cmdEv.OnServerEvent:Connect(function(player: Player, msg: any)
	if type(msg) ~= "table" or type(msg.op) ~= "string" then
		return
	end
	local id = watcherId(player)
	local op = msg.op
	if op == "verdict" then
		if type(msg.case) == "string" and (msg.v == "allow" or msg.v == "block") then
			local ok = sim:verdict(id, msg.case, msg.v)
			if not ok then
				-- another watcher's case? let anyone answer a case they can see
				local c = sim.cases[msg.case]
				if c and c.stage == "inbox" and c.watcher ~= id then
					sim:verdict(c.watcher or id, msg.case, msg.v)
				end
			end
		end
		return
	elseif op == "pose" then
		if type(msg.x) == "number" and type(msg.z) == "number" and type(msg.yaw) == "number" then
			playerPose[player] = {
				x = math.clamp(msg.x, -260, 260),
				z = math.clamp(msg.z, -260, 260),
				yaw = msg.yaw,
				moving = msg.moving == true,
				mind = type(msg.mind) == "number" and math.floor(msg.mind) or nil,
			}
		end
		return
	end
	-- everything else is a setting: at most a few a second per player
	local t = os.clock()
	if lastCmd[player] and t - lastCmd[player] < 0.2 then
		return
	end
	lastCmd[player] = t
	-- a free-play setting lets go of the last round's frozen numbers
	if op == "size" or op == "monitor" or op == "beat" or op == "second" or op == "agent" then
		if not round.active then
			frozen = nil
		end
	end
	if op == "size" and round.active then
		-- the phase table sets the traders while a round runs
		sim:emit({ k = "locked", by = id, what = "traders", why = "the round sets the traders" })
	elseif op == "size" and SIZES[msg.n] then
		sim:setSize(msg.n)
		sim:mark(msg.n .. " traders")
	elseif op == "monitor" and (msg.mode == "off" or msg.mode == "rules" or msg.mode == "external") then
		setMonitor(msg.mode, msg.keep == true)
	elseif op == "vote" and type(msg.on) == "boolean" then
		room.votes[id] = msg.on
		majorityLever()
	elseif op == "auto" and type(msg.on) == "boolean" then
		room.auto[id] = msg.on
		sim:setAuto(id, msg.on)
	elseif (op == "fraud" or op == "attack") and type(msg.kind) == "string" then
		-- Red opens an attack (a stall it pays rent on), with what it bought for
		-- it; in a round only what the phase has unlocked
		local opts: any = { vouch = msg.vouch == true, stolenId = msg.stolenId == true }
		if msg.kind == "scam" and type(msg.price) == "number" then
			opts.price = math.clamp(msg.price, 0.2, 1)
		end
		if type(msg.good) == "string" and sim.goods[msg.good] then
			opts.good = msg.good
		end
		if type(msg.victim) == "string" then
			opts.victim = msg.victim
		end
		local s, why = sim:redAttack(id, msg.kind, opts)
		if not s then
			sim:emit({ k = "attackFailed", by = id, kind = msg.kind, why = why })
		end
		if s then
			local list = playerStalls[player] or {}
			table.insert(list, s.id)
			while #list > 4 do
				table.remove(list, 1)
			end
			playerStalls[player] = list
			sim:emit({
				k = "manualFraud",
				kind = msg.kind,
				seller = s.id,
				slot = s.slot,
				stall = s.name,
				good = s.good,
				state = s.state,
				signatures = sim.signatures,
				by = id,
				vouch = opts.vouch or nil,
				stolenId = opts.stolenId or nil,
			})
		end
	elseif op == "check" and type(msg.id) == "string" and type(msg.on) == "boolean" then
		-- Blue's trim changes the loadout: it lands LOADOUT_DELAY_S later
		if playerRole[player] ~= "red" and table.find(crewRoles(player), "trim") then
			sim:requestCheck(msg.id, msg.on)
		end
	elseif op == "sign" and type(msg.id) == "string" and type(msg.on) == "boolean" then
		-- Blue's trim posts (or takes down) a sign at the gate: free, true or not
		if playerRole[player] ~= "red" and table.find(crewRoles(player), "trim") then
			sim:setSign(msg.id, msg.on)
		end
	elseif op == "preset" and msg.name == "rules" then
		if playerRole[player] ~= "red" then
			for _, cid in Config.PRESET_RULES do
				sim:requestCheck(cid, true)
			end
		end
	elseif op == "beat" and type(msg.i) == "number" then
		applyBeat(math.floor(msg.i))
	elseif op == "agent" and type(msg.on) == "boolean" then
		setOutsideAgent(msg.on)
	elseif op == "role" and (msg.role == "blue" or msg.role == "red") then
		playerRole[player] = msg.role
		playerChosen[player] = true
		syncWatchers()
		syncBot()
	elseif op == "second" and type(msg.on) == "boolean" then
		room.crew = msg.on
		syncWatchers()
		sim:mark(msg.on and "2 watchers" or "1 watcher")
	elseif op == "round" and type(msg.on) == "boolean" then
		if msg.on then
			startRound()
		else
			stopRound()
		end
	elseif op == "reset" then
		sim:mark("reset")
	end
end)

------------------------------------------------------------------ untrusted text

-- A `reason` written by outside code (an external monitor) is untrusted
-- (gateway decision 7). The inbox renders known evidence codes separately.
local function sanitize(events)
	for _, e in events do
		if e.untrusted then
			e.reason = nil
		end
		if e.c and e.c.untrusted then
			e.c.why = nil
		end
	end
	return events
end

------------------------------------------------------------------ players

local function state()
	return {
		t = sim.now,
		st = serverNow(),
		caption = room.caption,
		beat = room.beat,
		cam = room.cam,
		-- the stall the outside agent runs (the beat-6 camera looks at it)
		agentSlot = agentSeller and sim.byId[agentSeller] and sim.byId[agentSeller].slot or nil,
		agentOn = agentSeller ~= nil,
		secondOn = room.crew == true or #sim.watchers >= 2,
		beats = #BEATS,
		round = round:public(sim.now, sim.monitor),
		-- the score line both teams see: since the round began (or the market opened)
		score = frozen and frozen.score or (function()
			local t = sim:getTotals()
			local b = round.base or {}
			local function d(k)
				return (t[k] or 0) - (b[k] or 0)
			end
			return {
				caught = d("caught"),
				escaped = d("escaped"),
				falseAlarms = d("falseAlarms"),
				stolen = math.floor(d("stolen") + 0.5),
				honestDeals = d("honestDeals"),
			}
		end)(),
		scoreSeq = scoreSeq,
		red = redInfo(),
		gateway = gateway:status(),
		watchers = (function()
			local w = {}
			for _, x in sim.watchers do
				table.insert(w, { id = x.id, label = x.label, auto = x.auto, queue = #x.queue, decided = x.decided })
			end
			return w
		end)(),
		players = (function()
			local out = {}
			for idx, p in Players:GetPlayers() do
				local wid = watcherId(p)
				local r = playerRole[p] or "blue"
				local pose = playerPose[p] or { x = (idx - 1) * 6, z = 34, yaw = 0, moving = false }
				local x, z, yaw, moving = pose.x, pose.z, pose.yaw, pose.moving
				-- a red player minding their own stall stands behind its counter
				local minded = r == "red" and mindedStall(p, pose.mind) or nil
				if minded then
					local L = Layout.SLOTS[minded.slot]
					x, z = L.back.x, L.back.z
					yaw = math.atan2(-L.facing.x, -L.facing.z)
					moving = false
				end
				table.insert(out, {
					id = wid,
					num = idx,
					role = r,
					chosen = playerChosen[p] == true,
					x = x,
					z = z,
					yaw = yaw,
					moving = moving,
					stall = minded and minded.name or nil,
					stallSlot = minded and minded.slot or nil,
				})
			end
			return out
		end)(),
	}
end

------------------------------------------------------------------ the game, per team

-- What one player's panels need (docs/market-game.md, "What each side
-- sees"). Everyone: trade speed, Blue's signs, what Red has unlocked, both
-- scores. Blue: its loadout, changes on their way, friction, compute, the
-- escapes with their type and the catches. Red: its own ledger and its
-- frauds' coarse outcomes. Neither sees the other's choices.
local function lastN(list, n: number)
	local out = {}
	for i = math.max(1, #list - n + 1), #list do
		table.insert(out, list[i])
	end
	return out
end

local function gameFor(p: Player)
	local g = sim:gameState()
	local role = playerRole[p] or "blue"
	local out: any = {
		role = role,
		health = g.health,
		dealsPerMin = g.dealsPerMin,
		baseline = g.baseline,
		signs = g.signs,
		unlocked = g.unlocked,
		llmShoppers = g.llmShoppers,
		roundOn = round.active,
	}
	if role == "red" then
		local l = sim.red[watcherId(p)]
		out.red = {
			score = Score.ledger(l),
			stalls = l and l.stalls or 0,
			outcomes = l and l.outcomes or nil,
			log = l and lastN(l.log, 12) or {},
		}
	else
		out.loadout = g.loadout
		out.pending = g.pending
		out.friction = g.friction
		out.band = g.band
		out.compute = g.compute
		out.monitor = g.monitor
		out.crew = crewRoles(p)
		out.escapes = lastN(sim.escapeLog, 10)
		out.catches = lastN(sim.catchLog, 10)
		out.bot = g.bot
	end
	return out
end

-- the static menus (sent once)
local function gameConfig()
	local checks = {}
	for _, c in Config.CHECKS do
		table.insert(checks, { id = c.id, label = c.label, short = c.short, friction = c.friction, when = c.when, act = c.act, what = c.what, compute = c.compute })
	end
	local attacks = {}
	for _, a in Config.ATTACKS do
		table.insert(attacks, { id = a.id, label = a.label, cost = a.cost, costLabel = a.costLabel, what = a.what })
	end
	local mods = {}
	for _, m in Config.MODS do
		table.insert(mods, { id = m.id, label = m.label, cost = m.cost, what = m.what })
	end
	return {
		checks = checks,
		attacks = attacks,
		mods = mods,
		outcomes = Config.OUTCOMES,
		rent = Config.RENT_PER_MIN,
		deposit = Config.STALL_DEPOSIT,
		stake = Config.RED_STAKE,
		fee = Config.FEE_SHARE,
		delay = Config.LOADOUT_DELAY_S,
		healthy = Config.FRICTION_HEALTHY,
		seized = Config.FRICTION_SEIZED,
	}
end

hello.OnServerInvoke = function(player: Player)
	return {
		you = watcherId(player),
		snapshot = (function()
			local snap = sim:snapshot()
			for _, c in snap.cases do
				if c.untrusted then
					c.why = nil
				end
			end
			return snap
		end)(),
		meter = sim:meter(),
		state = state(),
		config = { budget = Config.BUDGET, sizes = Config.SIZES, game = gameConfig() },
		game = gameFor(player),
		score = lastScore,
	}
end

Players.PlayerAdded:Connect(function(_p)
	syncWatchers()
end)
syncWatchers()
Players.PlayerRemoving:Connect(function(p)
	sim:removeWatcher(watcherId(p))
	room.votes[watcherId(p)] = nil
	lastCmd[p] = nil
	playerRole[p] = nil
	playerChosen[p] = nil
	playerPose[p] = nil
	playerStalls[p] = nil
	syncWatchers()
	syncBot()
end)

------------------------------------------------------------------ the loop

local acc = 0
local meterAt = 0
local jobId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false):sub(1, 8))

RunService.Heartbeat:Connect(function(dt)
	acc += math.min(dt, 0.5)
	if acc < TICK then
		return
	end
	acc -= TICK
	if room.paused then
		return
	end
	sim:step(TICK)
	if ghosts and round.active then
		for _, k in { "none", "all" } do
			if not ghosts[k].done then
				ghosts[k]:advance(0.5)
			end
		end
	end
	local scoreNow = nil
	if round.active then
		for _, ph in round:update(sim.now, sim:getTotals(), #sim.watchers, sim:gameState()) do
			applyPhase(ph.phase)
		end
		-- money runs out: Blue bankrupt (Red wins) or every Red broke (Blue wins)
		if round.active then
			local reds = {}
			for _, p in Players:GetPlayers() do
				if playerRole[p] == "red" then
					table.insert(reds, watcherId(p))
				end
			end
			if #reds == 0 and sim.bot then
				reds = { "bot" }
			end
			local ending = round:checkMoney(sim, reds)
			if ending then
				print(string.format("[market] round ended early at %ds: %s", round.score.endedAt or 0, ending.text))
				sim:mark(ending.text)
			end
		end
		if round.done and round.score then
			afterRound()
			scoreSeq += 1
			lastScore = round.score
			-- the game's lines: each Red, and where the extreme Blues finished
			lastScore.reds = redLines()
			lastScore.ghosts = ghostLines()
			lastScore.winner = lastScore.ended and lastScore.ended.winner
				or (lastScore.blue and lastScore.red and Score.winner(lastScore.blue.score, lastScore.red.score) or nil)
			ghosts = nil
			frozen = {
				score = {
					caught = lastScore.caught,
					escaped = lastScore.escaped,
					falseAlarms = lastScore.falseAlarms,
					stolen = math.floor((lastScore.stolen or 0) + 0.5),
					honestDeals = lastScore.honestDeals,
				},
				-- the meter shows the round's numbers too
				meter = (function()
					local m = sim:meter()
					m.caught = lastScore.caught
					m.escaped = lastScore.escaped
					m.falseAlarms = lastScore.falseAlarms
					return m
				end)(),
			}
			lastScore.seq = scoreSeq
			scoreNow = lastScore
			print(string.format("[market] round over: %d honest deals (%s), stolen %s, caught %d, escaped %d, false alarms %d, peak %.1f calls/min",
				lastScore.honestDeals, fmtMoney(lastScore.honestValue), fmtMoney(lastScore.stolen), lastScore.caught, lastScore.escaped, lastScore.falseAlarms, lastScore.peak))
		end
	end
	if gateway.enabled and not gateway.inflight then
		task.spawn(function()
			gateway:tick(sim, sim.now, jobId)
			-- once the outside agent has actually set a price, the badge says who
			local sel = agentSeller and sim.byId[agentSeller]
			if sel and sel.policy == "external" and (sel.extCount or 0) > 0 and not sel.labelled then
				sel.labelled = true
				local by = sel.extBy or "gemini-seller"
				sim:setPolicy(sel.id, "external", Config.AGENT_MODEL_LABEL .. " (" .. by .. ")", "gemini-seller")
				print(string.format("[market] agent slot: %s set %s's price to %d (by %s)", "gemini-seller", sel.name, math.floor(sel.price + 0.5), by))
			end
		end)
	end
	local events = sanitize(sim:drain())
	local out: any = { t = sim.now, st = serverNow(), ev = events, sb = scoreNow }
	if sim.now >= meterAt or scoreNow then
		meterAt = sim.now + METER_EVERY
		out.m = frozen and frozen.meter or sim:meter()
		out.s = state()
		-- each player's own team view rides on the state ticks
		for _, p in Players:GetPlayers() do
			local o = table.clone(out)
			o.g = gameFor(p)
			batchEv:FireClient(p, o)
		end
	else
		batchEv:FireAllClients(out)
	end
end)

print(string.format("[market] server up: seed %d, %d traders, gateway %s", seed, sim.n, gateway.enabled and "on" or "off"))
