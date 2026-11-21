-- The screen: the inbox (case cards with Allow / Block and a deadline bar),
-- the meter (judgment calls per minute against the budget line), the
-- controls (N, monitor, the lever vote, red's buttons), the caption, and the
-- price strip. Presenter view hides everything but the inbox, the meter and
-- the caption.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local GamePanel = require(script.Parent.GamePanel)
local Review = require(ReplicatedStorage:WaitForChild("Market"):WaitForChild("Review"))
local new, label, button = Theme.new, Theme.label, Theme.button

local Hud = {}

local gui: ScreenGui
local send: (any) -> ()
local you = ""
local budget = 12

local cards = {} -- case id -> { frame, bar, c }
local order = {} -- case ids in arrival order
local inboxList: Frame
local inboxTitle: TextLabel
local inboxMore: TextLabel
local inboxPanel: Frame
local inboxSub: TextLabel
local MAX_CARDS = 6

local meter: any = {}
local controls: Frame
local caption: TextLabel
local captionBox: Frame
local priceStrip: Frame
local priceLabels = {}
local toast: TextLabel
local status: TextLabel
local presenter = false
local onFocus: ((any) -> ())?
local onVisit: ((any) -> ())?
local onCamera: ((string) -> ())?
local onRole: ((string) -> ())?
local showControlsBtn: TextButton? = nil
local shortcutsBox: Frame? = nil
local topCard: any = nil

-- teams: Blue (watchers) sees the inbox, the meter and the watcher
-- controls; Red (con artists) sees the red panel instead
local team = "blue"
local blueOnly: { GuiObject } = {}
local teamChip: TextLabel
local onTeam: ((string) -> ())?
local red: any = {} -- the red panel's parts
local rnd: any = {} -- the round bar, the prompt, the banner, the scoreboard
local picker: Frame? = nil
-- the game (a round is on): the loadout strip / attack shop replace the
-- monitor and lever controls
local gameOn = false
local crewText = "watcher"

------------------------------------------------------------------ helpers

local function pct(price: number, market: number): string
	if market <= 0 then
		return ""
	end
	local d = (price - market) / market
	local n = math.floor(math.abs(d) * 100 + 0.5)
	if n <= 2 then
		return "at market"
	end
	return string.format("%d%% %s market", n, d < 0 and "below" or "above")
end

local function ageText(s: number): string
	if s < 60 then
		return "new"
	elseif s < 3600 then
		return string.format("%d min", s // 60)
	end
	return string.format("%d h", s // 3600)
end

local function panel(props)
	local f = new("Frame", {
		BackgroundColor3 = Theme.PANEL,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	})
	for k, v in props do
		(f :: any)[k] = v
	end
	Theme.corner(14).Parent = f
	Theme.stroke(Color3.new(1, 1, 1), 1, 0.9).Parent = f
	return f
end

------------------------------------------------------------------ inbox

local function cardFor(c, now: number)
	local mine = c.watcher == you or c.watcher == nil
	local f = new("Frame", {
		Name = c.id,
		Size = UDim2.new(1, 0, 0, 104),
		BackgroundColor3 = mine and Theme.PAPER or Color3.fromRGB(70, 66, 72),
		BorderSizePixel = 0,
		LayoutOrder = c.created and math.floor(c.created * 10) or 0,
	}, { Theme.corner(10) })
	local ink = mine and Theme.INK or Theme.WHITE
	local muted = mine and Color3.fromRGB(110, 100, 92) or Theme.MUTED
	local below = c.price < c.market * 0.85
	local good = Theme.GOODS[c.good]
	label({
		Text = (good and good.icon or "") .. "  " .. c.stall,
		Font = Theme.HEAVY,
		TextSize = 19,
		TextColor3 = ink,
		Size = UDim2.new(1, -150, 0, 24),
		Position = UDim2.new(0, 12, 0, 8),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	-- what the listing says it sells: the good, and anything after it in small
	-- type (a counterfeit's "(print)")
	local goodText = c.good
	if type(c.listing) == "string" and c.listing ~= c.good then
		local rest = string.sub(c.listing, #c.good + 1)
		if string.sub(c.listing, 1, #c.good) == c.good and rest ~= "" then
			goodText = c.good .. "<font size=\"12\">" .. rest .. "</font>"
		else
			goodText = "<font size=\"12\">" .. c.listing .. "</font>"
		end
	end
	label({
		Text = string.format("%s %s · <b>%s</b>", Theme.money(c.price), goodText, pct(c.price, c.market)),
		RichText = true,
		TextSize = 16,
		TextColor3 = below and (mine and Color3.fromRGB(190, 60, 40) or Theme.WARN) or ink,
		Size = UDim2.new(1, -150, 0, 20),
		Position = UDim2.new(0, 12, 0, 33),
		Parent = f,
	})
	local facts = {}
	if c.vouchedBy then
		table.insert(facts, "✓ vouched: " .. c.vouchedBy)
	elseif (c.ratings or 0) == 0 then
		table.insert(facts, "⚠ unvouched")
	else
		table.insert(facts, string.format("%d ratings ★%.1f", c.ratings, c.rating_avg or 0))
	end
	if c.display == "prints" then
		table.insert(facts, "framed prints on the counter")
	elseif c.hasStock == false then
		table.insert(facts, "no crates")
	else
		table.insert(facts, "stocked")
	end
	if c.signature == "unchecked" then
		table.insert(facts, "unsigned")
	end
	local clueColor = muted
	if c.hasStock == false or c.display == "prints" then
		clueColor = mine and Color3.fromRGB(185, 52, 36) or Theme.WARN
	elseif c.vouchedBy then
		clueColor = mine and Color3.fromRGB(36, 118, 68) or Theme.OK
	end
	label({
		Text = table.concat(facts, " · "),
		Font = Theme.BOLD,
		TextSize = 13,
		TextColor3 = clueColor,
		Size = UDim2.new(1, -150, 0, 18),
		Position = UDim2.new(0, 12, 0, 54),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	local evidence = Review.label(c.reason_code)
	if c.twin then
		label({
			Text = "⚠ TWO STALLS, ONE NAME",
			Font = Theme.HEAVY,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(200, 70, 40),
			Size = UDim2.new(1, -150, 0, 18),
			Position = UDim2.new(0, 12, 0, 72),
			Parent = f,
		})
	elseif evidence or c.why then
		label({
			Text = if evidence then "Flagged · " .. evidence else (c.whyBy and c.whyBy ~= "rules" and (c.whyBy .. ": ") or "monitor: ") .. c.why,
			TextSize = 13,
			Font = evidence and Theme.BOLD or Theme.FONT,
			TextColor3 = evidence and c.review_at and (mine and Color3.fromRGB(185, 52, 36) or Theme.WARN) or muted,
			Size = UDim2.new(1, -150, 0, 18),
			Position = UDim2.new(0, 12, 0, 72),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = f,
		})
	end
	if not mine then
		label({
			Text = "another watcher's",
			TextSize = 13,
			TextColor3 = Theme.MUTED,
			Size = UDim2.new(0, 130, 0, 18),
			Position = UDim2.new(1, -140, 0, 8),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = f,
		})
	end
	local allow = button({
		Text = "Allow",
		BackgroundColor3 = Theme.OK,
		TextColor3 = Theme.INK,
		Size = UDim2.new(0, 64, 0, 40),
		Position = UDim2.new(1, -142, 0, mine and 26 or 32),
		Parent = f,
	}, function()
		send({ op = "verdict", case = c.id, v = "allow" })
		Hud.removeCase(c.id, "allow")
	end)
	local block = button({
		Text = "Block",
		BackgroundColor3 = Theme.BAD,
		Size = UDim2.new(0, 64, 0, 40),
		Position = UDim2.new(1, -72, 0, mine and 26 or 32),
		Parent = f,
	}, function()
		send({ op = "verdict", case = c.id, v = "block" })
		Hud.removeCase(c.id, "block")
	end)
	allow.TextSize = 17
	block.TextSize = 17
	-- the deadline bar
	local track = new("Frame", {
		Size = UDim2.new(1, -24, 0, 6),
		Position = UDim2.new(0, 12, 1, -12),
		BackgroundColor3 = mine and Color3.fromRGB(226, 218, 204) or Color3.fromRGB(50, 48, 54),
		BorderSizePixel = 0,
		Parent = f,
	}, { Theme.corner(3) })
	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.OK,
		BorderSizePixel = 0,
		Parent = track,
	}, { Theme.corner(3) })
	-- hover a card: highlight its stall; click the left side of the card: jump to the stall
	local inspectHit = new("TextButton", {
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -148, 1, -14),
		Position = UDim2.new(0, 0, 0, 0),
		Parent = f,
	})
	inspectHit.MouseEnter:Connect(function()
		if onFocus then
			onFocus(c)
		end
	end)
	inspectHit.Activated:Connect(function()
		if onVisit then
			onVisit(c)
		end
	end)
	f.MouseEnter:Connect(function()
		if onFocus then
			onFocus(c)
		end
	end)
	return { frame = f, bar = bar, c = c, mine = mine }
end

function Hud.addCase(c, now: number)
	if cards[c.id] then
		local old = cards[c.id]
		old.frame:Destroy()
		cards[c.id] = nil
		local i = table.find(order, c.id)
		if i then
			table.remove(order, i)
		end
	end
	local card = cardFor(c, now)
	cards[c.id] = card
	table.insert(order, c.id)
	Hud.layout()
end

function Hud.removeCase(id: string, how: string?)
	local card = cards[id]
	if not card then
		return
	end
	cards[id] = nil
	local i = table.find(order, id)
	if i then
		table.remove(order, i)
	end
	local f = card.frame
	if how == "expired" then
		f.BackgroundColor3 = Color3.fromRGB(120, 60, 56)
	end
	TweenService:Create(f, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	for _, d in f:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			TweenService:Create(d, TweenInfo.new(0.25), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
		end
	end
	task.delay(0.26, function()
		f:Destroy()
		Hud.layout()
	end)
end

function Hud.clearCases()
	for id, card in cards do
		card.frame:Destroy()
		cards[id] = nil
	end
	table.clear(order)
	Hud.layout()
end

-- My reviews first, ordered by the deadline and any corroborated evidence.
function Hud.layout()
	local mine, theirs = {}, {}
	for _, id in order do
		local card = cards[id]
		if card then
			table.insert(card.mine and mine or theirs, card)
		end
	end
	table.sort(mine, function(a, b)
		return Review.before(a.c, b.c)
	end)
	table.sort(theirs, function(a, b)
		return Review.before(a.c, b.c)
	end)
	local shown = 0
	topCard = mine[1] or theirs[1]
	for _, list in { mine, theirs } do
		for _, card in list do
			shown += 1
			if shown <= MAX_CARDS then
				card.frame.LayoutOrder = shown
				card.frame.Parent = inboxList
			else
				card.frame.Parent = nil
			end
		end
	end
	local total = #mine + #theirs
	inboxTitle.Text = string.format("INBOX  <font color=\"#%s\">%d</font>", total > 6 and "F05A48" or "FFFFFF", #mine)
		.. (#theirs > 0 and string.format("  <font size=\"15\" color=\"#A09A96\">+%d for other watchers</font>", #theirs) or "")
	inboxMore.Text = total > MAX_CARDS and string.format("+ %d more waiting", total - MAX_CARDS) or (total == 0 and "nothing to decide" or "")
	inboxMore.TextColor3 = total > MAX_CARDS and Theme.BAD or Theme.MUTED
	-- the panel is as tall as its cards: a slim header when empty, full
	-- height only when the inbox overflows
	local shownN = math.min(total, MAX_CARDS)
	local h = 56 + shownN * 112 + (total > MAX_CARDS and 34 or (total == 0 and 26 or 8)) + 28
	inboxPanel.Size = UDim2.new(0, total == 0 and 300 or 420, 0, h)
	inboxPanel.Position = UDim2.new(1, total == 0 and -316 or -436, 0, 16)
	inboxSub.Visible = total > 0
	inboxMore.Position = UDim2.new(0, 0, 1, -26)
	inboxList.Size = UDim2.new(1, 0, 0, shownN * 112)
end

function Hud.tickCards(now: number)
	for _, card in cards do
		local c = card.c
		local span = math.max(0.1, c.deadline_at - c.created)
		local left = math.clamp((c.deadline_at - now) / span, 0, 1)
		card.bar.Size = UDim2.new(left, 0, 1, 0)
		card.bar.BackgroundColor3 = left > 0.5 and Theme.OK or (left > 0.25 and Theme.WARN or Theme.BAD)
	end
end

function Hud.caseCount(): number
	return #order
end

function Hud.topCase()
	return topCard and topCard.c or nil
end

function Hud.decideTop(verdict: string)
	if not topCard then
		return nil
	end
	local c = topCard.c
	send({ op = "verdict", case = c.id, v = verdict })
	Hud.removeCase(c.id, verdict)
	return c
end

------------------------------------------------------------------ the meter

local function buildMeter(parent)
	local f = panel({
		Name = "Meter",
		Size = UDim2.new(0, 400, 0, 196),
		Position = UDim2.new(0, 16, 1, -212),
		Parent = parent,
	})
	Theme.pad(14, 16).Parent = f
	label({ Text = "JUDGMENT CALLS PER MINUTE", Font = Theme.HEAVY, TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = f })
	meter.big = label({
		Text = "0",
		Font = Theme.HEAVY,
		TextSize = 54,
		Size = UDim2.new(0, 140, 0, 56),
		Position = UDim2.new(0, 0, 0, 18),
		Parent = f,
	})
	meter.sub = label({
		Text = "budget 12 per watcher",
		TextSize = 15,
		TextColor3 = Theme.MUTED,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.new(0, 140, 0, 30),
		Parent = f,
	})
	meter.sub2 = label({
		Text = "",
		TextSize = 15,
		TextColor3 = Theme.MUTED,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.new(0, 140, 0, 50),
		Parent = f,
	})
	-- the bar, with the budget line at 12 (the bar's scale is 0..48)
	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 0, 82),
		BackgroundColor3 = Theme.PANEL2,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = f,
	}, { Theme.corner(8) })
	meter.fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.OK, BorderSizePixel = 0, Parent = track }, { Theme.corner(8) })
	meter.line = new("Frame", { Size = UDim2.new(0, 3, 0, 24), Position = UDim2.new(0.25, -1, 0, -4), BackgroundColor3 = Theme.WHITE, BorderSizePixel = 0, Parent = f })
	meter.line.Position = UDim2.new(0.25, -1, 0, 78)
	label({ Text = "12", Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.WHITE, Size = UDim2.new(0, 30, 0, 14), Position = UDim2.new(0.25, -15, 0, 100), TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
	meter.scale = label({ Text = "48", TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 40, 0, 14), Position = UDim2.new(1, -40, 0, 100), TextXAlignment = Enum.TextXAlignment.Right, Parent = f })
	-- the four numbers
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 52), Position = UDim2.new(0, 0, 0, 118), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 0), Parent = row })
	local function stat(name: string, color: Color3)
		local s = new("Frame", { Size = UDim2.new(0.25, 0, 1, 0), BackgroundTransparency = 1, Parent = row })
		local v = label({ Text = "0", Font = Theme.HEAVY, TextSize = 26, TextColor3 = color, Size = UDim2.new(1, 0, 0, 28), Parent = s })
		label({ Text = name, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 0, 30), Parent = s })
		return v
	end
	meter.caught = stat("caught", Theme.OK)
	meter.escaped = stat("escaped", Theme.BAD)
	meter.falseAlarms = stat("false alarms", Theme.WARN)
	meter.deals = stat("deals / min", Theme.WHITE)
	meter.frame = f
end

function Hud.meter(m)
	local calls = m.perWatcher or 0
	budget = m.budget or 12
	local top = math.max(48, math.ceil(calls / 12) * 12)
	meter.big.Text = string.format("%d", math.floor(calls + 0.5))
	local over = calls > budget * 1.05
	meter.big.TextColor3 = over and Theme.BAD or (calls > budget * 0.8 and Theme.WARN or Theme.OK)
	meter.fill.BackgroundColor3 = meter.big.TextColor3
	TweenService:Create(meter.fill, TweenInfo.new(0.4), { Size = UDim2.new(math.clamp(calls / top, 0, 1), 0, 1, 0) }):Play()
	meter.line.Position = UDim2.new(budget / top, -1, 0, 78)
	meter.scale.Text = tostring(top)
	if m.watchers and m.watchers > 1 then
		meter.sub.Text = string.format("each, %d watchers · budget %d", m.watchers, budget)
	else
		meter.sub.Text = string.format("budget %d per watcher", budget)
	end
	local mon = m.monitor == "off" and "monitor off" or (m.monitor == "rules" and "rule monitor" or ("monitor: " .. tostring(m.monitorName)))
	meter.sub2.Text = string.format("%d traders · %s · ID check %s", m.n, mon, m.signatures and "on" or "off")
	local mins = math.max(m.elapsed or 0, 1) / 60
	meter.caught.Text = tostring(m.caught)
	meter.escaped.Text = tostring(m.escaped)
	meter.falseAlarms.Text = tostring(m.falseAlarms)
	meter.deals.Text = string.format("%d", math.floor((m.dealsPerMin or 0) + 0.5))
	_ = mins
	Hud.settings(m)
end

------------------------------------------------------------------ controls

local seg = {} -- group -> { value -> button }

local function segmented(parent, title: string, group: string, options, onPick)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = parent })
	label({ Text = title, Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = f })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 20), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	seg[group] = {}
	for _, o in options do
		local b = button({
			Text = o.text,
			Size = UDim2.new(1 / #options, -6 + 6 / #options, 1, 0),
			TextSize = 15,
			Parent = row,
		}, function()
			onPick(o.value)
		end)
		seg[group][o.value] = b
	end
	return f
end

local function pick(group: string, value: any)
	for v, b in seg[group] or {} do
		local on = v == value
		b.BackgroundColor3 = on and Theme.WHITE or Theme.PANEL2
		b.TextColor3 = on and Theme.INK or Theme.WHITE
	end
end

function Hud.settings(m)
	pick("n", m.n)
	pick("monitor", m.monitor)
	pick("sig", m.signatures)
end

function Hud.setCameraMode(m: string)
	pick("cam", m)
end

-- "showing the whole market…" while the camera sweeps out after the market grows
local sweepHint: TextLabel? = nil
function Hud.sweeping(secs: number)
	if not sweepHint then
		if secs <= 0 then
			return
		end
		if not gui then
			return
		end
		sweepHint = label({
			Name = "SweepHint",
			Text = "showing the whole market…",
			Font = Theme.HEAVY,
			TextSize = 18,
			TextColor3 = Theme.WHITE,
			TextStrokeTransparency = 0.4,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 170),
			Size = UDim2.new(0, 360, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = gui,
		})
	end
	if sweepHint then
		sweepHint.Visible = secs > 0
	end
end

function Hud.setRole(r: string)
	Hud.setTeam(r)
end

function Hud.toggleShortcuts(on: boolean?)
	if not shortcutsBox then
		return
	end
	if on == nil then
		shortcutsBox.Visible = not shortcutsBox.Visible
	else
		shortcutsBox.Visible = on
	end
end

local function buildControls(parent, sizes)
	controls = panel({
		Name = "Controls",
		Size = UDim2.new(0, 300, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(0, 16, 0, 16),
		Parent = parent,
	})
	Theme.pad(12, 14).Parent = controls
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls })
	label({ Text = "NANDA MARKET", Font = Theme.HEAVY, TextSize = 20, Size = UDim2.new(1, 0, 0, 22), Parent = controls })
	-- your team, and a small button to switch (T does the same)
	local teamRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Parent = controls })
	teamChip = label({
		Text = "TEAM BLUE · watcher",
		Font = Theme.HEAVY,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(28, 92, 196),
		Size = UDim2.new(0.64, -4, 1, 0),
		Parent = teamRow,
	})
	Theme.corner(8).Parent = teamChip
	-- (a long crew name shrinks to fit)
	teamChip.TextScaled = true
	new("UITextSizeConstraint", { MaxTextSize = 15, MinTextSize = 10, Parent = teamChip })
	Theme.pad(2, 6).Parent = teamChip
	button({
		Text = "switch team (T)",
		TextSize = 13,
		Size = UDim2.new(0.36, -2, 1, 0),
		Position = UDim2.new(0.64, 2, 0, 0),
		Parent = teamRow,
	}, function()
		if onTeam then
			onTeam(team == "blue" and "red" or "blue")
		end
	end)
	local opts = {}
	for _, n in sizes do
		table.insert(opts, { text = tostring(n), value = n })
	end
	segmented(controls, "TRADERS", "n", opts, function(v)
		send({ op = "size", n = v })
	end)
	table.insert(blueOnly, segmented(controls, "MONITOR", "monitor", {
		{ text = "off", value = "off" },
		{ text = "rules", value = "rules" },
		{ text = "yours", value = "external" },
	}, function(v)
		send({ op = "monitor", mode = v })
	end))
	table.insert(blueOnly, segmented(controls, "SIGNATURE CHECKS (your vote)", "sig", {
		{ text = "on", value = true },
		{ text = "off", value = false },
	}, function(v)
		send({ op = "vote", on = v })
	end))
	table.insert(blueOnly, segmented(controls, "OUTSIDE AGENT (L)", "agent", {
		{ text = "scripted", value = false },
		{ text = "Gemini", value = true },
	}, function(v)
		send({ op = "agent", on = v })
	end))
	table.insert(blueOnly, segmented(controls, "WATCHERS / CREW", "second", {
		{ text = "1 (you)", value = false },
		{ text = "2 (+helper)", value = true },
	}, function(v)
		send({ op = "second", on = v })
	end))
	segmented(controls, "CAMERA (V)", "cam", {
		{ text = "auto", value = "auto" },
		{ text = "follow", value = "follow" },
		{ text = "walk 3P", value = "walk" },
		{ text = "overview", value = "overview" },
		{ text = "balcony", value = "balcony" },
	}, function(v)
		if onCamera then
			onCamera(v)
		end
	end)
	pick("cam", "auto")
	status = label({ Text = "", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, Parent = controls })
	button({
		Text = "? Keyboard Shortcuts (K)",
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Theme.PANEL2,
		TextColor3 = Theme.WHITE,
		TextSize = 13,
		Parent = controls,
	}, function()
		Hud.toggleShortcuts()
	end)
end

function Hud.status(s)
	if s then
		pick("agent", s.agentOn == true)
		pick("second", s.secondOn == true)
	end
	if not status then
		return
	end
	local bits = {}
	if s.players and #s.players > 0 then
		local pnames = {}
		for _, p in s.players do
			local who = p.id == you and "you" or ("Player " .. tostring(p.num or 2))
			local rtag = (p.role == "red") and "RED" or "BLUE"
			table.insert(pnames, who .. " (" .. rtag .. ")")
		end
		table.insert(bits, "players: " .. table.concat(pnames, ", "))
	end
	if s.gateway and s.gateway.enabled then
		table.insert(bits, string.format("gateway: %s (%d ok, %d errors)", s.gateway.health, s.gateway.ok, s.gateway.errors))
	end
	if s.watchers then
		-- no account names on screen (it is on stage and on video): "you", then numbers
		local names = {}
		local k = 1
		for _, w in s.watchers do
			local name
			if w.id == you then
				name = "you"
			else
				k += 1
				name = w.label == "auto watcher" and "auto watcher" or ("watcher " .. k)
			end
			table.insert(names, name .. (w.auto and " (auto)" or ""))
		end
		table.insert(bits, "watchers: " .. table.concat(names, ", "))
	end
	status.Text = table.concat(bits, "\n")
end

------------------------------------------------------------------ caption, prices, toast

function Hud.caption(text: string?, beat: number?, beats: number?)
	if text and text ~= "" then
		caption.Text = (beat and beat > 0 and string.format("<font color=\"#A09A96\">%d/%d</font>   ", beat, beats or 0) or "") .. text
		captionBox.Visible = true
	else
		captionBox.Visible = false
	end
end

function Hud.prices(p)
	for good, l in priceLabels do
		if p[good] then
			l.Text = Theme.GOODS[good].icon .. " " .. good .. "  " .. Theme.money(p[good])
		end
	end
end

function Hud.toast(text: string, color: Color3?)
	toast.Text = text
	toast.TextColor3 = color or Theme.WHITE
	toast.TextTransparency = 0
	toast.BackgroundTransparency = 0.15
	local mine = {}
	Hud._toast = mine
	task.delay(2.5, function()
		if Hud._toast == mine then
			TweenService:Create(toast, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		end
	end)
end

-- presenter view: the world, the inbox, the meter, the price bar and the
-- caption; the control panel goes
function Hud.presenter(on: boolean)
	presenter = on
	controls.Visible = not on
	if showControlsBtn then
		showControlsBtn.Visible = on
	end
end

function Hud.isPresenter(): boolean
	return presenter
end

-- A round is on: the loadout strip (Blue) or the attack shop (Red) takes
-- over from the monitor, signature, agent and crew controls; the toast
-- moves above the strip.
function Hud.gameMode(on: boolean)
	gameOn = on
	local blue = team == "blue"
	-- the round sets the traders: the buttons dim
	for _, b in seg.n or {} do
		b.TextTransparency = on and 0.6 or 0
		b.AutoButtonColor = not on
	end
	for _, inst in blueOnly do
		inst.Visible = blue and not on
	end
	if toast then
		toast.Position = on and UDim2.new(0.5, -110, 1, -232) or UDim2.new(0.5, -110, 1, -110)
	end
	if red.panel then
		for _, b in red.tools or {} do
			b.Visible = not on
		end
		if red.toolsTitle then
			red.toolsTitle.Visible = not on
		end
		if red.inbox then
			red.inbox.Visible = not on
		end
		if red.outTitle then
			red.outTitle.Visible = on
		end
	end
end

function Hud.isGameMode(): boolean
	return gameOn
end

-- the bottom of the left control panel (the escapes list goes under it)
function Hud.controlsBottom(): number
	if not controls or not controls.Visible then
		return 16
	end
	-- (the panel's own size can lag its contents; the lowest visible child
	-- counts. Absolute positions sit under the top bar's inset; Position
	-- offsets in this IgnoreGuiInset gui do not: convert)
	local bottom = controls.AbsolutePosition.Y + controls.AbsoluteSize.Y
	for _, c in controls:GetChildren() do
		if c:IsA("GuiObject") and c.Visible then
			bottom = math.max(bottom, c.AbsolutePosition.Y + c.AbsoluteSize.Y + 12)
		end
	end
	return bottom + (controls.Position.Y.Offset - controls.AbsolutePosition.Y)
end

function Hud.meterTop(): number
	if not meter.frame or not controls then
		return 600
	end
	return meter.frame.AbsolutePosition.Y + (controls.Position.Y.Offset - controls.AbsolutePosition.Y)
end

-- Blue's crew roles on the team chip
function Hud.setCrew(list: { string }?)
	crewText = list and #list >= 3 and "whole crew" or (list and #list > 0 and table.concat(list, "+") or "watcher")
	if team == "blue" and teamChip then
		teamChip.Text = "TEAM BLUE · " .. crewText
	end
end

function Hud.gui(): ScreenGui
	return gui
end

------------------------------------------------------------------ teams

local RED_DARK = Color3.fromRGB(150, 40, 40)
local BLUE_DARK = Color3.fromRGB(28, 92, 196)

local function fmtClock(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

function Hud.team(): string
	return team
end

-- show the screen for a team: Blue the inbox, meter and watcher controls;
-- Red the red panel (tools, stolen tally, your stalls, Blue's inbox count)
function Hud.setTeam(t: string)
	if t ~= "blue" and t ~= "red" then
		return
	end
	team = t
	local blue = t == "blue"
	for _, inst in blueOnly do
		inst.Visible = blue and not gameOn
	end
	GamePanel.setTeam(t)
	if inboxPanel then
		inboxPanel.Visible = blue
	end
	if meter.frame then
		meter.frame.Visible = blue
	end
	if red.panel then
		red.panel.Visible = not blue
	end
	if teamChip then
		teamChip.Text = blue and ("TEAM BLUE · " .. crewText) or "TEAM RED · con artist"
		teamChip.BackgroundColor3 = blue and BLUE_DARK or RED_DARK
	end
	if rnd.prompts then
		Hud.prompts(rnd.lastPrompts)
	end
end

------------------------------------------------------------------ the red panel

local TOOLS = {
	{ kind = "scam", text = "Scam stall", desc = "too cheap to be true · no goods behind the counter" },
	{ kind = "impostor", text = "Impersonate", desc = "copy a real stall's name (needs signatures off)" },
	{ kind = "counterfeit", text = "Counterfeit", desc = "a fair price · sells framed prints of the good" },
}

local function buildRedPanel(parent)
	local f = panel({
		Name = "RedTeam",
		Size = UDim2.new(0, 380, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(1, -396, 0, 16),
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = parent,
	})
	Theme.stroke(Theme.BAD, 2, 0.35).Parent = f
	Theme.pad(14, 16).Parent = f
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	label({ Text = "RED TEAM · con artists", Font = Theme.HEAVY, TextSize = 20, TextColor3 = Theme.BAD, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 1, Parent = f })
	-- the stolen tally
	local tally = new("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, LayoutOrder = 2, Parent = f })
	label({ Text = "STOLEN BY YOUR STALLS", Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = tally })
	red.stolen = label({ Text = "0.00", Font = Theme.HEAVY, TextSize = 40, TextColor3 = Theme.GOLD, Size = UDim2.new(0.55, 0, 0, 42), Position = UDim2.new(0, 0, 0, 16), Parent = tally })
	red.stolenSub = label({ Text = "", TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(0.45, 0, 0, 40), Position = UDim2.new(0.55, 0, 0, 18), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Right, Parent = tally })
	-- the tools
	red.toolsTitle = label({ Text = "OPEN A STALL", Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 3, Parent = f })
	red.tools = {}
	for i, tool in TOOLS do
		local b = button({
			Text = "",
			BackgroundColor3 = Color3.fromRGB(110, 36, 36),
			Size = UDim2.new(1, 0, 0, 46),
			LayoutOrder = 3 + i,
			Parent = f,
		}, function()
			local msg: any = { op = "fraud", kind = tool.kind }
			if tool.kind == "scam" then
				msg.price = 0.6
			end
			send(msg)
		end)
		table.insert(red.tools, b)
		label({ Text = tool.text, Font = Theme.HEAVY, TextSize = 18, Size = UDim2.new(1, -20, 0, 22), Position = UDim2.new(0, 12, 0, 3), Parent = b })
		label({ Text = tool.desc, TextSize = 13, TextColor3 = Color3.fromRGB(240, 200, 196), Size = UDim2.new(1, -20, 0, 16), Position = UDim2.new(0, 12, 0, 25), TextTruncate = Enum.TextTruncate.AtEnd, Parent = b })
	end
	-- your stalls
	label({ Text = "YOUR STALLS", Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 10, Parent = f })
	red.rows = {}
	for i = 1, 4 do
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = Theme.PANEL2, BorderSizePixel = 0, LayoutOrder = 10 + i, Visible = false, Parent = f }, { Theme.corner(8) })
		local name = label({ Text = "", Font = Theme.HEAVY, TextSize = 15, Size = UDim2.new(1, -96, 0, 18), Position = UDim2.new(0, 10, 0, 3), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local st = label({ Text = "", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, -96, 0, 16), Position = UDim2.new(0, 10, 0, 21), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local go = button({ Text = "stand here", TextSize = 13, Size = UDim2.new(0, 80, 0, 28), Position = UDim2.new(1, -86, 0, 6), BackgroundColor3 = RED_DARK, Parent = row }, function()
			local s = red.rowStall and red.rowStall[i]
			if s and red.onMind then
				red.onMind(s.slot, s.name)
			end
		end)
		red.rows[i] = { frame = row, name = name, status = st, go = go }
	end
	red.none = label({ Text = "none yet: open one above", TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 15, Parent = f })
	-- what Blue is facing, without the cards
	red.inbox = label({ Text = "Blue's inbox: 0 waiting", Font = Theme.BOLD, TextSize = 16, TextColor3 = Theme.BLUE, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 20, Parent = f })
	-- the game: your frauds' coarse outcomes, newest first (no checks named)
	red.outTitle = label({ Text = "YOUR FRAUDS · OUTCOMES", Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 21, Visible = false, Parent = f })
	red.outRows = {}
	for i = 1, 6 do
		red.outRows[i] = label({ Text = "", TextSize = 14, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 21 + i, TextTruncate = Enum.TextTruncate.AtEnd, Visible = false, Parent = f })
	end
	red.panel = f
end

-- refresh the red panel from the room's state and the meter
function Hud.red(s, m, minding: number?, g: any?)
	if not red.panel then
		return
	end
	local info = s and s.red and s.red[you]
	local stolen = info and info.stolen or 0
	red.stolen.Text = Theme.money(stolen)
	-- the game: the outcome log, and the score in the tally's corner
	local rows = gameOn and g and GamePanel.redLog(g) or {}
	for i, row in red.outRows or {} do
		local r = rows[i]
		row.Visible = r ~= nil
		if r then
			row.Text = r.text
			row.TextColor3 = r.color
		end
	end
	local stalls = info and info.stalls or {}
	local sales, live = 0, 0
	red.rowStall = {}
	for i = 1, 4 do
		local row = red.rows[i]
		-- newest first
		local st = stalls[#stalls - i + 1]
		red.rowStall[i] = st
		row.frame.Visible = st ~= nil
		if st then
			local kind = st.kind == "counterfeit" and "counterfeit" or (st.kind == "impostor" and "impostor" or "scam")
			row.name.Text = string.format("%s %s  <font size=\"12\" color=\"#A09A96\">%s · %s</font>", Theme.GOODS[st.good] and Theme.GOODS[st.good].icon or "", st.name, kind, st.good)
			row.name.RichText = true
			row.status.Text = st.status
			local bad = st.state == "blocked" or st.state == "rejected"
			row.status.TextColor3 = bad and Theme.BAD or ((st.stolen or 0) > 0 and Theme.GOLD or Theme.MUTED)
			row.go.Visible = st.live == true
			row.go.Text = minding == st.slot and "here ✓" or "stand here"
			if st.live then
				live += 1
			end
			if (st.stolen or 0) > 0 then
				sales += 1
			end
		end
	end
	red.none.Visible = #stalls == 0
	red.stolenSub.Text = live > 0 and string.format("%d stall%s open", live, live == 1 and "" or "s") or "open a stall to start"
	local sc = gameOn and g and GamePanel.redScore(g)
	if sc then
		red.stolenSub.Text = string.format("profit %s\ncosts %s", GamePanel.nb(sc.score), GamePanel.nb(sc.rent + sc.bought + sc.lost))
	end
	local n = m and m.inbox or 0
	red.inbox.Text = string.format("Blue's inbox: %d waiting", n)
	red.inbox.TextColor3 = n > 6 and Theme.WARN or Theme.BLUE
end

------------------------------------------------------------------ the round

local function buildRound(parent)
	-- the bar, top centre under the prices: timer, phase, progress, score, start/stop
	local f = panel({
		Name = "Round",
		Size = UDim2.new(0, 600, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -110, 0, 64),
		BackgroundTransparency = 0.12,
		Parent = parent,
	})
	Theme.pad(8, 14).Parent = f
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	local top = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 1, Parent = f })
	rnd.clock = label({ Text = "FREE PLAY", Font = Theme.HEAVY, TextSize = 24, Size = UDim2.new(0, 112, 1, 0), Parent = top })
	rnd.phase = label({ Text = "", RichText = true, Font = Theme.BOLD, TextSize = 17, Size = UDim2.new(1, -282, 1, 0), Position = UDim2.new(0, 114, 0, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = top })
	rnd.btn = button({
		Text = "▶ Start 5:00 round",
		Font = Theme.HEAVY,
		TextSize = 15,
		TextColor3 = Theme.INK,
		BackgroundColor3 = Theme.GOLD,
		Size = UDim2.new(0, 160, 0, 28),
		Position = UDim2.new(1, -160, 0, 1),
		Parent = top,
	}, function()
		send({ op = "round", on = not rnd.active })
	end)
	-- progress, with the phase boundaries
	rnd.track = new("Frame", { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = Theme.PANEL2, BorderSizePixel = 0, LayoutOrder = 2, Visible = false, Parent = f }, { Theme.corner(4) })
	rnd.fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.GOLD, BorderSizePixel = 0, Parent = rnd.track }, { Theme.corner(4) })
	rnd.ticks = {}
	-- the phase's banner line, under the progress
	rnd.sub = label({ Text = "", TextSize = 15, TextColor3 = Theme.WHITE, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Visible = false, TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
	rnd.score = label({ Text = "", RichText = true, TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 4, TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
	rnd.bar = f
	-- the prompt (a question for one team), under the bar
	rnd.prompts = new("Frame", {
		Name = "Prompts",
		Size = UDim2.new(0, 600, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -110, 0, 172),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rnd.prompts })
	rnd.promptCards = {}
	rnd.dismissed = {}
	-- the phase banner: big, centre, for a few seconds when a phase begins
	rnd.banner = panel({
		Name = "PhaseBanner",
		Size = UDim2.new(0, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, -60, 0.4, 0),
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = parent,
	})
	Theme.pad(14, 28).Parent = rnd.banner
	new("UIListLayout", { Padding = UDim.new(0, 2), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = rnd.banner })
	rnd.bannerTitle = label({ Text = "", Font = Theme.HEAVY, TextSize = 44, TextColor3 = Theme.GOLD, Size = UDim2.new(0, 0, 0, 48), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = rnd.banner })
	rnd.bannerText = label({ Text = "", Font = Theme.BOLD, TextSize = 22, Size = UDim2.new(0, 0, 0, 28), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = rnd.banner })
end

local function setTicks(marks, length: number)
	if rnd.tickKey == #marks .. ":" .. length then
		return
	end
	rnd.tickKey = #marks .. ":" .. length
	for _, t in rnd.ticks do
		t:Destroy()
	end
	rnd.ticks = {}
	for _, m in marks do
		if m.at > 0 and m.at < length then
			local t = new("Frame", { Size = UDim2.new(0, 2, 1, 4), Position = UDim2.new(m.at / length, -1, 0, -2), BackgroundColor3 = Theme.WHITE, BackgroundTransparency = 0.3, BorderSizePixel = 0, ZIndex = 3, Parent = rnd.track })
			table.insert(rnd.ticks, t)
		end
	end
end

function Hud.banner(title: string, text: string?)
	rnd.bannerTitle.Text = title
	rnd.bannerText.Text = text or ""
	rnd.bannerText.Visible = text ~= nil and text ~= ""
	rnd.banner.Visible = true
	local mine = {}
	rnd.bannerTok = mine
	task.delay(4, function()
		if rnd.bannerTok == mine then
			rnd.banner.Visible = false
		end
	end)
end

-- the round bar, from the room's state (s.round, s.score)
function Hud.round(s)
	local r = s and s.round
	if not r or not rnd.bar then
		return
	end
	rnd.active = r.active == true
	rnd.btn.Text = rnd.active and "■ Stop round" or (r.done and "▶ New 5:00 round" or "▶ Start 5:00 round")
	rnd.btn.BackgroundColor3 = rnd.active and Theme.PANEL2 or Theme.GOLD
	rnd.btn.TextColor3 = rnd.active and Theme.WHITE or Theme.INK
	rnd.track.Visible = rnd.active
	if rnd.active then
		local left = (r.length or 300) - (r.t or 0)
		rnd.clock.Text = fmtClock(left)
		rnd.clock.TextColor3 = left <= 30 and Theme.WARN or Theme.WHITE
		local nextBit = r.nextName and string.format("   <font size=\"14\" color=\"#A09A96\">next: %s in %s</font>", r.nextName == "Scoreboard" and "scoreboard" or r.nextName, fmtClock((r.nextAt or 0) - (r.t or 0))) or ""
		rnd.phase.Text = string.format("<font color=\"#F6C446\">%s</font>%s", string.upper(r.name or ""), nextBit)
		rnd.sub.Text = r.banner or ""
		rnd.sub.Visible = true
		rnd.fill.Size = UDim2.new(math.clamp((r.t or 0) / math.max(1, r.length or 300), 0, 1), 0, 1, 0)
		setTicks(r.marks or {}, r.length or 300)
		-- a new phase: the big banner
		local key = tostring(r.phase)
		if rnd.phaseKey ~= key then
			rnd.phaseKey = key
			if r.name then
				Hud.banner(fmtClock((r.marks and r.marks[r.phase] and r.marks[r.phase].at) or 0) .. "  " .. string.upper(r.name), r.banner)
			end
		end
	else
		rnd.phaseKey = nil
		rnd.sub.Visible = false
		rnd.clock.Text = "FREE PLAY"
		rnd.clock.TextColor3 = Theme.WHITE
		rnd.phase.Text = r.done and "<font color=\"#A09A96\">round over · free play</font>" or "<font color=\"#A09A96\">5 phases, then a scoreboard</font>"
	end
	local sc = s.score
	if sc and rnd.active and r.blue then
		-- the game: both scores, live
		rnd.score.Text = string.format(
			"<font color=\"#5A96F0\"><b>Blue %s</b></font> <font color=\"#A09A96\">(%s left)</font> · <font color=\"#E85448\"><b>Red %s</b></font>   <font color=\"#56C478\">caught %d</font> · <font color=\"#E85448\">escaped %d</font> · stolen %s",
			GamePanel.nb(r.blue),
			GamePanel.nb((r.blueStake or 15000) + r.blue),
			GamePanel.nb(r.red),
			sc.caught or 0, sc.escaped or 0, Theme.money(sc.stolen or 0)
		)
	elseif sc then
		rnd.score.Text = string.format(
			"%s  <font color=\"#56C478\">caught %d</font> · <font color=\"#E85448\">escaped %d</font> · <font color=\"#F0B43C\">false alarms %d</font> · stolen %s · honest deals %d",
			(rnd.active or r.done) and "this round:" or "so far:",
			sc.caught or 0, sc.escaped or 0, sc.falseAlarms or 0, Theme.money(sc.stolen or 0), sc.honestDeals or 0
		)
	end
	Hud.prompts(r.prompts)
end

-- the round's questions: shown to their team until answered here
function Hud.prompts(list)
	rnd.lastPrompts = list
	local want = {}
	for _, p in list or {} do
		-- (the council vote is the skipper's; a solo Blue is skipper too)
		local mine = not (p.ask == "vote" and not GamePanel.roles().skipper)
		if (p.team == "all" or p.team == team) and mine and not rnd.dismissed[p.id] then
			want[p.id] = p
		end
	end
	for id, card in rnd.promptCards do
		if not want[id] then
			card:Destroy()
			rnd.promptCards[id] = nil
		end
	end
	for id, p in want do
		if not rnd.promptCards[id] then
			local c = panel({ Size = UDim2.new(1, 0, 0, 84), BackgroundColor3 = Color3.fromRGB(46, 38, 20), BackgroundTransparency = 0.05, LayoutOrder = id, Parent = rnd.prompts })
			Theme.stroke(Theme.GOLD, 2, 0.1).Parent = c
			label({ Text = "❗ " .. p.text, Font = Theme.HEAVY, TextSize = 18, TextColor3 = Theme.GOLD, Size = UDim2.new(1, -24, 0, 26), Position = UDim2.new(0, 12, 0, 8), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
			local row = new("Frame", { Size = UDim2.new(1, -24, 0, 34), Position = UDim2.new(0, 12, 0, 40), BackgroundTransparency = 1, Parent = c })
			new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), Parent = row })
			local opts
			if p.ask == "monitor" then
				opts = {
					{ "checks: floor + voucher", { op = "monitor", mode = "rules" } },
					{ "my loadout decides", { op = "monitor", mode = "rules", keep = true } },
					{ "your monitor", { op = "monitor", mode = "external" } },
				}
			elseif p.ask == "pitch" then
				opts = {
					{ "turn on the pitch reader (costs NB)", { op = "check", id = "pitchReader", on = true } },
					{ "not worth it", nil },
				}
			else
				opts = {
					{ "keep ID checks ON", { op = "vote", on = true } },
					{ "turn them OFF", { op = "vote", on = false } },
				}
			end
			for _, o in opts do
				button({ Text = o[1], TextSize = 15, Size = UDim2.new(1 / #opts, -8, 1, 0), BackgroundColor3 = o[2] and Theme.PANEL2 or Theme.PANEL, Parent = row }, function()
					if o[2] then
						send(o[2])
					end
					rnd.dismissed[id] = true
					Hud.prompts(rnd.lastPrompts)
				end)
			end
			rnd.promptCards[id] = c
		end
	end
end

-- the scoreboard: the round's numbers and a chart of calls/min with the phases marked
local function chartLine(parent, x0: number, y0: number, x1: number, y1: number, color: Color3, w: number)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	new("Frame", {
		Size = UDim2.new(0, len + 1, 0, w),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, (x0 + x1) / 2, 0, (y0 + y1) / 2),
		Rotation = math.deg(math.atan2(dy, dx)),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	})
end

local function signed(c: number?): string
	return GamePanel.nb(c)
end

function Hud.scoreboard(sb)
	if rnd.sbOverlay then
		rnd.sbOverlay:Destroy()
		rnd.sbOverlay = nil
	end
	if not sb then
		return
	end
	local dim = new("Frame", { Name = "Scoreboard", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, ZIndex = 50, Parent = gui })
	rnd.sbOverlay = dim
	local game_ = sb.series and #sb.series > 0 and sb.blue ~= nil
	-- fit the screen: the game's scoreboard is taller
	local vh = gui.AbsoluteSize.Y
	local W, H = 900, game_ and math.min(700, vh - 40) or 524
	local f = panel({ Size = UDim2.new(0, W, 0, H), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 0.02, Parent = dim })
	local title = "ROUND OVER"
	if game_ and sb.winner then
		title = sb.winner == "blue" and "ROUND OVER · BLUE WINS" or (sb.winner == "red" and "ROUND OVER · RED WINS" or "ROUND OVER · A TIE")
		-- money ran out: say so first
		if sb.ended and sb.ended.why == "bankrupt" then
			title = "MARKET BANKRUPT · RED WINS"
		elseif sb.ended and sb.ended.why == "broke" then
			title = "RED WENT BROKE · BLUE WINS"
		end
	end
	label({ Text = title, Font = Theme.HEAVY, TextSize = 30, TextColor3 = sb.winner == "red" and Theme.BAD or (sb.winner == "blue" and Theme.BLUE or Theme.GOLD), Size = UDim2.new(1, -250, 0, 34), Position = UDim2.new(0, 24, 0, 16), Parent = f })
	local sub = string.format("%s of market · budget %d calls/min per watcher", fmtClock(sb.length or 300), sb.budget or 12)
	if sb.ended then
		sub = string.format("ended early at %s: %s · otherwise it ends at %s", fmtClock(sb.endedAt or 0), sb.ended.text or sb.ended.why, fmtClock(sb.length or 300))
	elseif game_ then
		sub = string.format("ran the full %s: nobody ran out of money · budget %d calls/min per watcher", fmtClock(sb.length or 300), sb.budget or 12)
	end
	label({ Text = sub, TextSize = 15, TextColor3 = Theme.MUTED, Size = UDim2.new(1, -48, 0, 18), Position = UDim2.new(0, 24, 0, 50), Parent = f })
	local y = 78
	if game_ then
		-- both scores, with what they are made of
		local function scoreBox(x: number, title: string, color: Color3, score: number, parts: string)
			local box = new("Frame", { Size = UDim2.new(0, (W - 60) / 2, 0, 74), Position = UDim2.new(0, x, 0, y), BackgroundColor3 = Theme.PANEL2, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = f }, { Theme.corner(10) })
			label({ Text = title, Font = Theme.HEAVY, TextSize = 15, TextColor3 = color, Size = UDim2.new(0, 120, 0, 18), Position = UDim2.new(0, 12, 0, 8), Parent = box })
			label({ Text = signed(score), Font = Theme.HEAVY, TextSize = 34, TextColor3 = color, Size = UDim2.new(0, 170, 0, 38), Position = UDim2.new(0, 12, 0, 28), Parent = box })
			label({ Text = parts, RichText = true, TextSize = 13, TextColor3 = Theme.MUTED, TextWrapped = true, Size = UDim2.new(1, -196, 1, -12), Position = UDim2.new(0, 186, 0, 6), TextYAlignment = Enum.TextYAlignment.Center, Parent = box })
		end
		local bl, rd = sb.blue, sb.red
		scoreBox(24, "BLUE profit", Theme.BLUE, bl.score, string.format("fees %s − refunds %s<br/>+ fines %s<br/>− checks &amp; wages %s", signed(bl.fees), signed(bl.refunds), signed(bl.fines), signed(bl.costs)))
		scoreBox(36 + (W - 60) / 2, "RED profit", Theme.BAD, rd.score, string.format("loot %s − rent %s<br/>− bought %s<br/>− deposits lost %s", signed(rd.stolen), signed(rd.rent), signed(rd.bought), signed(rd.lost)))
		y += 80
		-- where the extreme Blues finished on this seed, and each Red's line
		local gh = sb.ghosts
		local function gend(g): string
			if g.ended == "bankrupt" then
				return " <font color=\"#A09A96\">(bankrupt " .. fmtClock(g.endedAt or 0) .. ")</font>"
			elseif g.ended == "broke" then
				return " <font color=\"#A09A96\">(Red broke " .. fmtClock(g.endedAt or 0) .. ")</font>"
			end
			return ""
		end
		local ghostText = gh and string.format(
			"<font color=\"#A09A96\">same seed, bot Red (NB, Blue vs Red):</font> no checks <font color=\"#5A96F0\">%d</font> vs <font color=\"#E85448\">%d</font>%s · every check <font color=\"#5A96F0\">%d</font> vs <font color=\"#E85448\">%d</font>%s",
			math.floor(gh.none.blue / 100 + 0.5), math.floor(gh.none.red / 100 + 0.5), gend(gh.none), math.floor(gh.all.blue / 100 + 0.5), math.floor(gh.all.red / 100 + 0.5), gend(gh.all)
		) or "<font color=\"#A09A96\">(the extreme Blues were not run)</font>"
		label({ Text = ghostText, RichText = true, TextSize = 14, Size = UDim2.new(0, (W - 60) / 2, 0, 52), Position = UDim2.new(0, 24, 0, y), TextWrapped = true, Parent = f })
		local lines = {}
		for _, rl in sb.reds or {} do
			local who = rl.id == you and "you" or rl.label
			table.insert(lines, string.format("<font color=\"#E85448\">%s</font> stole %s, profit %s", who, signed(rl.stolen), signed(rl.score)))
		end
		label({ Text = #lines > 0 and table.concat(lines, " · ") or "<font color=\"#A09A96\">no Red stalls</font>", RichText = true, TextSize = 14, Size = UDim2.new(0, (W - 60) / 2, 0, 52), Position = UDim2.new(0, 36 + (W - 60) / 2, 0, y), TextWrapped = true, Parent = f })
		y += 56
	end
	-- the numbers: two rows of four
	local stats = {
		{ "honest deals", tostring(sb.honestDeals or 0), Theme.WHITE },
		{ "honest value", game_ and GamePanel.nb(sb.honestValue) or Theme.money(sb.honestValue or 0), Theme.OK },
		{ "stolen", game_ and GamePanel.nb(sb.stolen) or Theme.money(sb.stolen or 0), Theme.BAD },
		{ "peak calls/min", string.format("%.0f", sb.peak or 0), (sb.peak or 0) > (sb.budget or 12) and Theme.WARN or Theme.OK },
		{ "caught", tostring(sb.caught or 0), Theme.OK },
		{ "escaped", tostring(sb.escaped or 0), Theme.BAD },
		{ "false alarms", tostring(sb.falseAlarms or 0), Theme.WARN },
		{ "judgment calls", tostring(sb.asked or 0), Theme.WHITE },
	}
	local cellH = game_ and 48 or 58
	for i, st in stats do
		local col = (i - 1) % 4
		local rowI = (i - 1) // 4
		local cell = new("Frame", { Size = UDim2.new(0, (W - 48) / 4, 0, cellH), Position = UDim2.new(0, 24 + col * (W - 48) / 4, 0, y + rowI * (cellH + 4)), BackgroundTransparency = 1, Parent = f })
		label({ Text = st[2], Font = Theme.HEAVY, TextSize = game_ and 24 or 30, TextColor3 = st[3], Size = UDim2.new(1, 0, 0, game_ and 28 or 34), Parent = cell })
		label({ Text = st[1], TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, game_ and 28 or 34), Parent = cell })
	end
	y += 2 * (cellH + 4) + 10
	-- the chart(s): calls/min (left, or full width), Blue's loadout (right)
	local chartW = game_ and math.floor((W - 48) * 0.42) or (W - 48)
	label({ Text = "JUDGMENT CALLS PER MINUTE", Font = Theme.HEAVY, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(0, chartW, 0, 16), Position = UDim2.new(0, 24, 0, y), Parent = f })
	local cw, ch = chartW - 36, H - (y + 28) - 30
	local chart = new("Frame", { Size = UDim2.new(0, cw, 0, ch), Position = UDim2.new(0, 24 + 36, 0, y + 28), BackgroundColor3 = Theme.PANEL2, BackgroundTransparency = 0.3, BorderSizePixel = 0, ClipsDescendants = false, Parent = f })
	if game_ then
		GamePanel.drawSeries(f, sb, 24 + chartW + 16, y, W - 48 - chartW - 16, H - y - 20)
	end
	local length = sb.length or 300
	local top = math.max(24, (sb.peak or 0) * 1.15, (sb.budget or 12) * 3.2)
	top = math.ceil(top / 12) * 12
	local function X(t: number): number
		return math.clamp(t / length, 0, 1) * cw
	end
	local function Y(v: number): number
		return ch - math.clamp(v / top, 0, 1) * ch
	end
	-- y axis labels and the budget line
	for _, v in { 0, top / 2, top } do
		label({ Text = string.format("%d", v), TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 30, 0, 14), Position = UDim2.new(0, -34, 0, Y(v) - 7), TextXAlignment = Enum.TextXAlignment.Right, Parent = chart })
	end
	local b = sb.budget or 12
	for k = 0, cw, 12 do
		new("Frame", { Size = UDim2.new(0, 6, 0, 2), Position = UDim2.new(0, k, 0, Y(b) - 1), BackgroundColor3 = Theme.OK, BorderSizePixel = 0, Parent = chart })
	end
	label({ Text = "budget " .. b, Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.OK, Size = UDim2.new(0, 70, 0, 14), Position = UDim2.new(1, -72, 0, Y(b) - 16), TextXAlignment = Enum.TextXAlignment.Right, Parent = chart })
	-- phase boundaries
	for _, m in sb.marks or {} do
		local x = X(m.at)
		if m.at > 0 and m.at < length then
			new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(0, x, 0, 0), BackgroundColor3 = Theme.WHITE, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = chart })
		end
		if m.at < length and not game_ then
			label({ Text = m.name, Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.WHITE, Size = UDim2.new(0, 80, 0, 14), Position = UDim2.new(0, x + 4, 0, 3), Parent = chart })
		end
		if not game_ or m.at == 0 or m.at >= length or m.at % 120 == 0 then
			label({ Text = fmtClock(m.at), TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 40, 0, 14), Position = UDim2.new(0, x - 20, 1, 4), TextXAlignment = Enum.TextXAlignment.Center, Parent = chart })
		end
	end
	-- the line
	local pts = sb.chart or {}
	for i = 2, #pts do
		local a, c = pts[i - 1], pts[i]
		chartLine(chart, X(a.t), Y(a.r), X(c.t), Y(c.r), Theme.GOLD, 3)
	end
	button({ Text = "Back to free play", Font = Theme.HEAVY, TextSize = 16, TextColor3 = Theme.INK, BackgroundColor3 = Theme.GOLD, Size = UDim2.new(0, 180, 0, 34), Position = UDim2.new(1, -204, 0, 18), Parent = f }, function()
		Hud.scoreboard(nil)
	end)
	for _, d in dim:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 51
		end
	end
end

function Hud.scoreboardShown(): boolean
	return rnd.sbOverlay ~= nil
end

------------------------------------------------------------------ the team picker

-- "Choose your team": two big cards, the default pre-selected (Enter takes it)
function Hud.pickTeam(default: string, onPick: (string) -> ())
	if picker then
		picker:Destroy()
	end
	local dim = new("Frame", { Name = "TeamPicker", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(10, 10, 14), BackgroundTransparency = 0.25, ZIndex = 60, Parent = gui })
	picker = dim
	rnd.pickDefault = default
	rnd.pickFn = onPick
	local box = new("Frame", { Size = UDim2.new(0, 760, 0, 420), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, Parent = dim })
	label({ Text = "Choose your team", Font = Theme.HEAVY, TextSize = 40, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 48), Parent = box })
	label({ Text = "NANDA Market · one square, two teams", TextSize = 17, TextColor3 = Theme.MUTED, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.new(0, 0, 0, 50), Parent = box })
	local cards = {
		{
			team = "blue",
			title = "BLUE",
			sub = "watchers",
			body = "Work the inbox: allow or block every new stall before its first buyer. Pick the monitors, vote in the council on signature checks.",
			col = BLUE_DARK,
		},
		{
			team = "red",
			title = "RED",
			sub = "con artists",
			body = "Open a scam stall or a counterfeit stall and stand behind the counter. Get past Blue's watchers and take the buyers' money.",
			col = RED_DARK,
		},
	}
	for i, c in cards do
		local card = new("TextButton", {
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = c.col,
			Size = UDim2.new(0, 360, 0, 280),
			Position = UDim2.new(0, (i - 1) * 400, 0, 96),
			Parent = box,
		}, { Theme.corner(18) })
		local chosen = c.team == default
		Theme.stroke(Theme.WHITE, chosen and 4 or 1, chosen and 0 or 0.7).Parent = card
		Theme.pad(20, 22).Parent = card
		label({ Text = c.title, Font = Theme.HEAVY, TextSize = 56, Size = UDim2.new(1, 0, 0, 60), Parent = card })
		label({ Text = c.sub, Font = Theme.BOLD, TextSize = 24, TextColor3 = Color3.fromRGB(235, 235, 240), Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 0, 60), Parent = card })
		label({ Text = c.body, TextSize = 18, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 110), Position = UDim2.new(0, 0, 0, 100), Parent = card })
		if chosen then
			label({ Text = "suggested · Enter", Font = Theme.BOLD, TextSize = 14, TextColor3 = Theme.WHITE, BackgroundTransparency = 0.6, BackgroundColor3 = Color3.new(0, 0, 0), TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(0, 150, 0, 24), Position = UDim2.new(1, -150, 0, 0), Parent = card }, nil)
		end
		card.Activated:Connect(function()
			Hud.closePicker(c.team)
		end)
	end
	label({ Text = "You can switch later: press T, or \"switch team\" on the left panel.", TextSize = 15, TextColor3 = Theme.MUTED, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 392), Parent = box })
	for _, d in dim:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 61
		end
	end
end

function Hud.pickerOpen(): boolean
	return picker ~= nil
end

-- take a team from the picker (nil: the pre-selected one)
function Hud.closePicker(t: string?)
	if not picker then
		return
	end
	picker:Destroy()
	picker = nil
	local fn = rnd.pickFn
	rnd.pickFn = nil
	if fn then
		fn(t or rnd.pickDefault or "blue")
	end
end

------------------------------------------------------------------ build

function Hud.build(opts)
	send = opts.send
	you = opts.you
	onFocus = opts.onFocus
	onVisit = opts.onVisit
	onCamera = opts.onCamera
	onRole = opts.onRole
	onTeam = opts.onTeam
	red.onMind = opts.onMind
	gui = new("ScreenGui", {
		Name = "MarketHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	-- the inbox, right
	inboxPanel = panel({
		Name = "Inbox",
		Size = UDim2.new(0, 420, 1, -32),
		Position = UDim2.new(1, -436, 0, 16),
		BackgroundTransparency = 0.18,
		Parent = gui,
	})
	local inbox = inboxPanel
	Theme.pad(14, 14).Parent = inbox
	inboxTitle = label({ Text = "INBOX", RichText = true, Font = Theme.HEAVY, TextSize = 22, Size = UDim2.new(1, 0, 0, 26), Parent = inbox })
	inboxSub = label({ Text = "Allow or Block before the first buyer arrives", TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, 28), Parent = inbox })
	inboxList = new("Frame", { Size = UDim2.new(1, 0, 1, -90), Position = UDim2.new(0, 0, 0, 56), BackgroundTransparency = 1, Parent = inbox })
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = inboxList })
	inboxMore = label({ Text = "", Font = Theme.HEAVY, TextSize = 18, TextColor3 = Theme.BAD, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(0, 0, 1, -26), TextXAlignment = Enum.TextXAlignment.Center, Parent = inbox })
	buildMeter(gui)
	buildControls(gui, opts.sizes or { 5, 50, 300, 1000 })
	buildRedPanel(gui)
	buildRound(gui)
	showControlsBtn = button({
		Text = "Controls (H)",
		Size = UDim2.new(0, 128, 0, 34),
		Position = UDim2.new(0, 16, 0, 16),
		BackgroundColor3 = Theme.PANEL,
		TextColor3 = Theme.WHITE,
		TextSize = 14,
		Visible = false,
		Parent = gui,
	}, function()
		Hud.presenter(false)
	end)
	-- caption, bottom centre
	captionBox = panel({
		Name = "Caption",
		Size = UDim2.new(0, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		AnchorPoint = Vector2.new(0.5, 1),
		-- bottom centre, clear of the meter (bottom left, 416 px) and the inbox (right)
		Position = UDim2.new(0.5, -10, 1, -18),
		Visible = false,
		Parent = gui,
	})
	Theme.pad(12, 20).Parent = captionBox
	caption = label({
		Text = "",
		RichText = true,
		Font = Theme.BOLD,
		TextSize = 24,
		Size = UDim2.new(0, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = captionBox,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(560, 200), Parent = caption })
	caption.TextWrapped = true
	-- prices, top centre
	priceStrip = panel({
		Name = "Prices",
		Size = UDim2.new(0, 0, 0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -110, 0, 16),
		Parent = gui,
	})
	Theme.pad(8, 16).Parent = priceStrip
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 20), VerticalAlignment = Enum.VerticalAlignment.Center, Parent = priceStrip })
	label({ Text = "MARKET PRICE", Font = Theme.HEAVY, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = priceStrip })
	for _, g in { "bread", "cloth", "lamp", "spice" } do
		priceLabels[g] = label({ Text = g, Font = Theme.BOLD, TextSize = 17, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = priceStrip })
	end
	toast = label({
		Text = "",
		Font = Theme.BOLD,
		TextSize = 18,
		BackgroundColor3 = Theme.PANEL,
		BackgroundTransparency = 1,
		TextTransparency = 1,
		Size = UDim2.new(0, 0, 0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		AnchorPoint = Vector2.new(0.5, 1),
		-- above the caption, clear of the round bar and its prompts
		Position = UDim2.new(0.5, -110, 1, -110),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = gui,
	})
	Theme.corner(10).Parent = toast
	Theme.pad(6, 14).Parent = toast
	-- Keyboard shortcuts overlay card (toggle with K / ? or the button on the panel)
	shortcutsBox = panel({
		Name = "Shortcuts",
		Size = UDim2.new(0, 480, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, -10, 1, -18),
		Visible = false,
		Parent = gui,
	})
	Theme.pad(14, 18).Parent = shortcutsBox
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = shortcutsBox })
	label({
		Text = "KEYBOARD SHORTCUTS   <font size=\"13\" color=\"#A09A96\">(press K or / to close)</font>",
		RichText = true,
		Font = Theme.HEAVY,
		TextSize = 17,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = shortcutsBox,
	})
	local rows = {
		{ "T", "Switch team: Blue watchers (inbox) / Red con artists (stalls)" },
		{ "Z  /  X", "Blue: Allow / Block the top case in your Inbox" },
		{ "R", "Start (or stop) the timed 5:00 round" },
		{ "Click a case card", "Teleport 3rd-person avatar to inspect that stall" },
		{ "V", "V cycles camera: auto → follow → walk 3P → overview → balcony" },
		{ "WASD / Arrows", "Walk the street in 3rd-person (Right-drag or Q/E turns)" },
		{ "1 · 2 · 3 · 4", "Set market size: 5 · 50 · 300 · 1000 traders" },
		{ "M  /  G", "Cycle monitor (off/rules/yours)  /  Vote on the ID check (lands in 30 s)" },
		{ "L  /  A", "Toggle Gemini outside agent  /  Toggle auto-watcher" },
		{ "N  /  B", "Next / previous scripted Demo Beat (1..6)" },
		{ "H  /  K", "Hide/show left control panel  /  Toggle this shortcuts card" },
	}
	for _, r in rows do
		local line = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Parent = shortcutsBox })
		label({ Text = r[1], Font = Theme.HEAVY, TextSize = 14, TextColor3 = Theme.WARN, Size = UDim2.new(0, 145, 1, 0), Parent = line })
		label({ Text = r[2], TextSize = 14, TextColor3 = Theme.WHITE, Size = UDim2.new(1, -150, 1, 0), Position = UDim2.new(0, 150, 0, 0), Parent = line })
	end
	Hud.layout()
	Hud.setTeam(team)
	return gui
end

return Hud
