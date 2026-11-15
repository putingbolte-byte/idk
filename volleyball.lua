--!nonstrict
-- olltaterfx :: landscape mobile shell
-- place 125848858933944 | executor: delta (android)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")

local LP = Players.LocalPlayer
assert(LP, "no local player")

local CONFIG = {
	mobileOnly = true,
	scale      = 0.82,
	blurSize   = 16,
	place      = "125848858933944",
}

local PAL = {
	bg     = Color3.fromRGB(14, 16, 24),
	panel  = Color3.fromRGB(27, 30, 42),
	panel2 = Color3.fromRGB(40, 45, 62),
	stroke = Color3.fromRGB(62, 68, 90),
	text   = Color3.fromRGB(243, 245, 250),
	muted  = Color3.fromRGB(138, 145, 165),
	blue   = Color3.fromRGB(0, 122, 255),
	red    = Color3.fromRGB(255, 59, 48),
	yellow = Color3.fromRGB(255, 204, 0),
	green  = Color3.fromRGB(52, 199, 89),
}

local S = {
	hb = false, hbSize = 8, hbBallOnly = true, hbTeam = true, hbVis = false, hbAlpha = 55,
	ballHud = true, autoHit = false, abilityIndex = 1,
	autoSpin = false, spinDelay = 0.8, autoReward = false, rewardDelay = 1.2,
	autoDaily = false, autoLike = false, autoQuest = false, autoAch = false,
	stealth = true, jitter = 0.35, rate = 6, maxTokens = 10,
	guiProtect = true, randomNames = true,
	scale = CONFIG.scale, blur = true, log = true,
}

local ABILITIES = {
	"Shockwave", "Magnet", "Portal", "Superspike", "TornadoBall", "Forcefield",
	"Guardian", "Moonball", "Curveball", "Adrenaline", "Frozen",
}

-- ── scaffolding ─────────────────────────────────────────────────────────────

local function new(cls, props, parent)
	local inst = Instance.new(cls)
	for k, v in pairs(props or {}) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

local function round(parent, px)
	new("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function edge(parent, color, alpha, thick)
	new("UIStroke", {
		Color = color or PAL.stroke,
		Transparency = alpha or 0.35,
		Thickness = thick or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function rname(len)
	local pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local t = {}
	for i = 1, (len or 14) do
		local n = math.random(1, #pool)
		t[i] = pool:sub(n, n)
	end
	return table.concat(t)
end

if CONFIG.mobileOnly and not UserInputService.TouchEnabled then
	warn("[olltaterfx] mobile-only shell :: flip CONFIG.mobileOnly to false on desktop")
	return
end

local function lockLandscape()
	pcall(function() setorientation("LandscapeLeft") end)
	pcall(function() setorientation("LandscapeSensor") end)
	pcall(function()
		local gs = game:GetService("UserSettings"):GetService("UserGameSettings")
		gs.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
end
lockLandscape()

local function container(protect)
	if protect and type(gethui) == "function" then
		local ok, c = pcall(gethui)
		if ok and c then return c end
	end
	local ok, c = pcall(function() return game:GetService("CoreGui") end)
	if ok and c then return c end
	return LP:WaitForChild("PlayerGui")
end

local root = container(S.guiProtect)

local gui = new("ScreenGui", {
	Name = S.randomNames and rname() or "fx_shell",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 9999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = root,
})

local blur = new("BlurEffect", { Name = rname(8), Size = CONFIG.blurSize, Enabled = S.blur }, Lighting)

-- ── remotes ─────────────────────────────────────────────────────────────────

local remoteCache = {}

local function findRemote(leaf)
	if remoteCache[leaf] ~= nil then
		return remoteCache[leaf] or nil
	end
	local hit
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d.Name == leaf and (d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent") or d:IsA("RemoteFunction")) then
			hit = d
			break
		end
	end
	remoteCache[leaf] = hit or false
	return hit
end

local bucket = { tokens = S.maxTokens, last = os.clock() }

local function allow(cost)
	local now = os.clock()
	bucket.tokens = math.min(S.maxTokens, bucket.tokens + (now - bucket.last) * S.rate)
	bucket.last = now
	if bucket.tokens >= cost then
		bucket.tokens -= cost
		return true
	end
	return false
end

local function jitter()
	if S.stealth and S.jitter > 0 then
		task.wait(math.random() * S.jitter)
	end
end

local logRef
local logBuf = {}

local function pushLog(msg)
	if not S.log then return end
	table.insert(logBuf, 1, ("%s  %s"):format(os.date("%H:%M:%S"), msg))
	while #logBuf > 80 do table.remove(logBuf) end
	if logRef then logRef.Text = table.concat(logBuf, "\n") end
end

local function fire(leaf, ...)
	local r = findRemote(leaf)
	if not r then pushLog("missing " .. leaf) return false end
	if not allow(1) then pushLog("throttle " .. leaf) return false end
	jitter()
	local pack = table.pack(...)
	local ok, err = pcall(function()
		r:FireServer(table.unpack(pack, 1, pack.n))
	end)
	if not ok then pushLog(("err %s: %s"):format(leaf, tostring(err))) end
	return ok
end

local function invoke(leaf, ...)
	local r = findRemote(leaf)
	if not r or not r:IsA("RemoteFunction") then
		pushLog("missing " .. leaf)
		return false, nil
	end
	if not allow(2) then
		pushLog("throttle " .. leaf)
		return false, nil
	end
	jitter()
	local pack = table.pack(...)
	local ok, res = pcall(function()
		return r:InvokeServer(table.unpack(pack, 1, pack.n))
	end)
	if not ok then pushLog(("err %s: %s"):format(leaf, tostring(res))) end
	return ok, res
end

-- ── hitbox ──────────────────────────────────────────────────────────────────

local originals = setmetatable({}, { __mode = "k" })
local boxes = {}
local boxRoot

local function isBall(name)
	return name:lower():find("ball", 1, true) ~= nil
end

local function ballParts()
	local out = {}
	local go = workspace:FindFirstChild("GameObjects")
	if not go then return out end
	for _, d in ipairs(go:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart"
			and (isBall(d.Name) or (d.Parent and isBall(d.Parent.Name))) then
			out[#out+1] = d
		end
	end
	return out
end

local function enemyParts()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP then
			local skip = false
			if S.hbTeam and plr.Team and LP.Team and plr.Team == LP.Team then
				skip = true
			end
			local ch = plr.Character
			if ch and not skip then
				for _, d in ipairs(ch:GetDescendants()) do
					if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
						out[#out+1] = d
					end
				end
			end
		end
	end
	return out
end

local function targets()
	local out = ballParts()
	if not S.hbBallOnly then
		for _, p in ipairs(enemyParts()) do out[#out+1] = p end
	end
	return out
end

local function apply()
	local k = S.hbSize / 4
	for _, part in ipairs(targets()) do
		if part and part.Parent then
			if not originals[part] then originals[part] = part.Size end
			part.Size = originals[part] * k
		end
	end
end

local function restore()
	for part, size in pairs(originals) do
		if part and part.Parent then part.Size = size end
	end
	table.clear(originals)
end

local function clearBoxes()
	for i = #boxes, 1, -1 do
		if boxes[i] then boxes[i]:Destroy() end
		boxes[i] = nil
	end
end

local function boxParent()
	if boxRoot and boxRoot.Parent then return boxRoot end
	local ok, folder = pcall(function()
		local f = Instance.new("Folder")
		f.Name = rname(10)
		f.Parent = root
		return f
	end)
	if ok and folder then
		boxRoot = folder
		return folder
	end
	return nil
end

local function draw()
	clearBoxes()
	if not S.hbVis then return end
	local parent = boxParent()
	if not parent then return end
	for _, part in ipairs(targets()) do
		if part and part.Parent then
			local ok, box = pcall(function()
				local b = Instance.new("BoxHandleAdornment")
				b.Name = rname(8)
				b.Size = part.Size
				b.Adornee = part
				b.AlwaysOnTop = true
				b.ZIndex = 4
				b.Transparency = S.hbAlpha / 100
				b.Color3 = S.hbBallOnly and PAL.blue or PAL.red
				b.Parent = parent
				return b
			end)
			if ok and box then boxes[#boxes+1] = box end
		end
	end
end

-- ── actions ─────────────────────────────────────────────────────────────────

local function spinOnce()
	local ok, res = invoke("RequestSpin")
	if not ok then pushLog("spin transport error") return end
	pushLog("spin -> " .. tostring(res))
	if S.autoReward then
		local idx = type(res) == "number" and res or 1
		local _, reward = invoke("RequestRewardFromSpin", idx)
		pushLog(("reward(%s) -> %s"):format(tostring(idx), tostring(reward)))
	end
end

local function equipAbility()
	local name = ABILITIES[S.abilityIndex] or ABILITIES[1]
	fire("EquipAbility", name)
	pushLog("equip " .. name)
end

local questIndex, achIndex = 1, 1

local function claimDaily()
	fire("ClaimDayReward")
	pushLog("daily claim")
end

local function claimLike()
	fire("ClaimLikeReward")
	pushLog("like claim")
end

local function claimQuest()
	fire("ClaimQuest", questIndex)
	pushLog("quest " .. questIndex)
	questIndex = (questIndex % 12) + 1
end

local function claimAch()
	fire("ClaimAchievement", achIndex)
	pushLog("achievement " .. achIndex)
	achIndex = (achIndex % 24) + 1
end

local function autoHitTick()
	local myPos = Vector3.zero
	local ch = LP.Character
	if ch and ch:FindFirstChild("HumanoidRootPart") then
		myPos = ch.HumanoidRootPart.Position
	end
	local best
	for _, part in ipairs(ballParts()) do
		local d = (part.Position - myPos).Magnitude
		if not best or d < best.d then
			best = { part = part, d = d, pos = part.Position }
		end
	end
	if not best then return end
	local dir = best.pos - myPos
	if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 1, 0) end
	fire("HitBall", best.part, dir.Unit)
end

-- ── shell ───────────────────────────────────────────────────────────────────

local shell = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = gui })
local uiScale = new("UIScale", { Scale = S.scale }, shell)

local vp = workspace.CurrentViewportSize
local winW = math.clamp(math.floor(vp.X * 0.68), 500, 800)
local winH = math.clamp(math.floor(vp.Y * 0.76), 270, 400)

local win = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(winW, winH),
	BackgroundColor3 = PAL.bg,
	BackgroundTransparency = 0.04,
	BorderSizePixel = 0,
	Parent = shell,
})
round(win, 22)
edge(win, PAL.stroke, 0.3)

local bar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundTransparency = 1,
	Parent = win,
})

local grab = new("Frame", {
	Size = UDim2.fromOffset(40, 5),
	Position = UDim2.new(0.5, -20, 0, 9),
	BackgroundColor3 = PAL.stroke,
	BorderSizePixel = 0,
	Parent = bar,
})
round(grab, 3)

new("TextLabel", {
	Size = UDim2.new(1, -100, 0, 18),
	Position = UDim2.fromOffset(16, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = PAL.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = CONFIG.title,
	Parent = bar,
})

new("TextLabel", {
	Size = UDim2.new(1, -100, 0, 12),
	Position = UDim2.fromOffset(16, 31),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	TextSize = 9,
	TextColor3 = PAL.muted,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "place " .. CONFIG.place,
	Parent = bar,
})

local close = new("TextButton", {
	Size = UDim2.fromOffset(26, 26),
	Position = UDim2.new(1, -38, 0, 10),
	BackgroundColor3 = PAL.panel2,
	Text = "",
	AutoButtonColor = false,
	Parent = bar,
})
round(close, 13)
new("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 18,
	TextColor3 = PAL.text,
	Text = "×",
	Parent = close,
})

-- sidebar

local side = new("Frame", {
	Size = UDim2.fromOffset(88, winH - 60),
	Position = UDim2.fromOffset(10, 50),
	BackgroundTransparency = 1,
	Parent = win,
})
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, side)

-- content holder

local contentHolder = new("Frame", {
	Size = UDim2.new(1, -118, 1, -60),
	Position = UDim2.fromOffset(108, 50),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = win,
})

-- ── components ──────────────────────────────────────────────────────────────

local function page()
	local p = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = PAL.stroke,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = contentHolder,
	})
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, p)
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 10) }, p)
	return p
end

local function section(parent, text)
	new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = PAL.yellow,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = string.upper(text),
		Parent = parent,
	})
end

local function row(parent, height)
	local r = new("Frame", {
		Size = UDim2.new(1, 0, 0, height or 50),
		BackgroundColor3 = PAL.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Parent = parent,
	})
	round(r, 14)
	edge(r, PAL.stroke, 0.6)
	return r
end

local function caption(parent, label, sub)
	new("TextLabel", {
		Size = UDim2.new(1, -96, 0, sub and 16 or 18),
		Position = UDim2.fromOffset(14, sub and 9 or 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = PAL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
		Parent = parent,
	})
	if sub then
		new("TextLabel", {
			Size = UDim2.new(1, -96, 0, 12),
			Position = UDim2.fromOffset(14, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 9,
			TextColor3 = PAL.muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = sub,
			Parent = parent,
		})
	end
end

local function switch(parent, initial, callback)
	local track = new("Frame", {
		Size = UDim2.fromOffset(46, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		BackgroundColor3 = initial and PAL.blue or PAL.panel2,
		BorderSizePixel = 0,
		Parent = parent,
	})
	round(track, 14)

	local knob = new("Frame", {
		Size = UDim2.fromOffset(24, 24),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = initial and UDim2.new(1, -26, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = track,
	})
	round(knob, 12)

	local on = initial

	local function set(v, silent)
		on = v
		TweenService:Create(track, TweenInfo.new(0.16), {
			BackgroundColor3 = on and PAL.blue or PAL.panel2,
		}):Play()
		TweenService:Create(knob, TweenInfo.new(0.16), {
			Position = on and UDim2.new(1, -26, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
		}):Play()
		if not silent and callback then callback(on) end
	end

	local hit = new("TextButton", {
		Size = UDim2.fromScale(1.4, 1.6),
		Position = UDim2.new(-0.2, 0, -0.3, 0),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = track,
	})
	hit.MouseButton1Click:Connect(function() set(not on) end)
	set(initial, true)
	return set
end

local function toggleRow(parent, label, sub, initial, callback)
	local r = row(parent, sub and 50 or 44)
	caption(r, label, sub)
	switch(r, initial, callback)
	return r
end

local function sliderRow(parent, label, min, max, value, fmt, callback)
	fmt = fmt or function(v) return tostring(math.floor(v * 10 + 0.5) / 10) end

	local r = row(parent, 64)
	caption(r, label)

	local val = new("TextLabel", {
		Size = UDim2.new(0, 80, 0, 18),
		Position = UDim2.new(1, -94, 0, 9),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = PAL.blue,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = fmt(value),
		Parent = r,
	})

	local holder = new("Frame", {
		Size = UDim2.new(1, -28, 0, 26),
		Position = UDim2.fromOffset(14, 32),
		BackgroundTransparency = 1,
		Parent = r,
	})

	local rail = new("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0.5, -3),
		BackgroundColor3 = PAL.panel2,
		BorderSizePixel = 0,
		Parent = holder,
	})
	round(rail, 3)

	local fill = new("Frame", {
		Size = UDim2.new((value - min) / (max - min), 0, 1, 0),
		BackgroundColor3 = PAL.blue,
		BorderSizePixel = 0,
		Parent = rail,
	})
	round(fill, 3)

	local knob = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new((value - min) / (max - min), 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = rail,
	})
	round(knob, 8)

	local dragging = false

	local function paint(v)
		local alpha = math.clamp((v - min) / (max - min), 0, 1)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		val.Text = fmt(v)
	end

	local function setFromX(x)
		local ax = holder.AbsolutePosition.X
		local aw = math.max(holder.AbsoluteSize.X, 1)
		local alpha = math.clamp((x - ax) / aw, 0, 1)
		local v = min + (max - min) * alpha
		paint(v)
		if callback then callback(v) end
	end

	holder.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			setFromX(input.Position.X)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseMovement) then
			setFromX(input.Position.X)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	return r
end

local function buttonRow(parent, label, sub, text, color, callback)
	local r = row(parent, 52)
	caption(r, label, sub)
	local b = new("TextButton", {
		Size = UDim2.fromOffset(96, 30),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		BackgroundColor3 = color or PAL.blue,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		AutoButtonColor = false,
		Parent = r,
	})
	round(b, 15)
	b.MouseButton1Click:Connect(callback)
	return r
end

-- ── pages ───────────────────────────────────────────────────────────────────

local hudFrame, hudLine, hudDetail

local pages = {}
local tabButtons = {}
local tabDefs = {
	{ id = "hit", label = "Hitbox" },
	{ id = "ball", label = "Balls" },
	{ id = "spin", label = "Spins" },
	{ id = "bypass", label = "Bypass" },
	{ id = "cfg", label = "Config" },
}

for i, def in ipairs(tabDefs) do
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = PAL.panel,
		BackgroundTransparency = 0.45,
		Text = def.label,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
		TextColor3 = PAL.muted,
		AutoButtonColor = false,
		LayoutOrder = i,
		Parent = side,
	})
	round(b, 11)
	tabButtons[def.id] = b
	pages[def.id] = page()
end

local function selectTab(id)
	for _, def in ipairs(tabDefs) do
		local b = tabButtons[def.id]
		local active = def.id == id
		b.BackgroundColor3 = active and PAL.blue or PAL.panel
		b.BackgroundTransparency = active and 0 or 0.45
		b.TextColor3 = active and Color3.fromRGB(255, 255, 255) or PAL.muted
		pages[def.id].Visible = active
	end
end

for _, def in ipairs(tabDefs) do
	tabButtons[def.id].MouseButton1Click:Connect(function() selectTab(def.id) end)
end

-- hit page

local pHit = pages.hit
section(pHit, "hitbox expander")
toggleRow(pHit, "Enabler", "arena ball parts + optional targets", S.hb, function(v)
	S.hb = v
	if not v then
		pcall(restore)
		pcall(draw)
	end
end)
sliderRow(pHit, "Multiplier", 2, 40, S.hbSize, function(v)
	return string.format("%.1fx", v / 4)
end, function(v) S.hbSize = v end)

section(pHit, "targets")
toggleRow(pHit, "Ball only", "ignore characters", S.hbBallOnly, function(v)
	S.hbBallOnly = v
	pcall(restore)
end)
toggleRow(pHit, "Team check", "skip teammates", S.hbTeam, function(v)
	S.hbTeam = v
	pcall(restore)
end)

section(pHit, "visuals")
toggleRow(pHit, "Show boxes", "box adornment overlay", S.hbVis, function(v)
	S.hbVis = v
	pcall(draw)
end)
sliderRow(pHit, "Box opacity", 0, 100, S.hbAlpha, function(v)
	return string.format("%d%%", math.floor(v))
end, function(v) S.hbAlpha = v end)

-- ball page

local pBall = pages.ball
section(pBall, "state")
toggleRow(pBall, "Ball HUD", "read GetBallState", S.ballHud, function(v)
	S.ballHud = v
	hudFrame.Visible = v
end)
toggleRow(pBall, "Auto hit", "fires HitBall at nearest ball part", S.autoHit, function(v)
	S.autoHit = v
end)

section(pBall, "ability")
sliderRow(pBall, "Index", 1, #ABILITIES, S.abilityIndex, function(v)
	return ABILITIES[math.floor(v + 0.5)] or ABILITIES[1]
end, function(v) S.abilityIndex = math.floor(v + 0.5) end)
buttonRow(pBall, "Equip", "fires EquipAbility", "Equip", PAL.blue, equipAbility)

-- spin page

local pSpin = pages.spin
section(pSpin, "spin")
toggleRow(pSpin, "Auto spin", "RequestSpin invoke", S.autoSpin, function(v)
	S.autoSpin = v
end)
sliderRow(pSpin, "Spin interval", 0.2, 3, S.spinDelay, function(v)
	return string.format("%.1fs", v)
end, function(v) S.spinDelay = v end)
toggleRow(pSpin, "Auto reward", "RequestRewardFromSpin", S.autoReward, function(v)
	S.autoReward = v
end)
sliderRow(pSpin, "Reward delay", 0.3, 5, S.rewardDelay, function(v)
	return string.format("%.1fs", v)
end, function(v) S.rewardDelay = v end)

section(pSpin, "claims")
toggleRow(pSpin, "Daily reward", "ClaimDayReward", S.autoDaily, function(v) S.autoDaily = v end)
toggleRow(pSpin, "Like reward", "ClaimLikeReward", S.autoLike, function(v) S.autoLike = v end)
toggleRow(pSpin, "Quests", "ClaimQuest sweep", S.autoQuest, function(v) S.autoQuest = v end)
toggleRow(pSpin, "Achievements", "ClaimAchievement sweep", S.autoAch, function(v) S.autoAch = v end)

-- bypass page

local pByp = pages.bypass
section(pByp, "transport")
toggleRow(pByp, "Stealth mode", "jittered dispatch, token bucket", S.stealth, function(v)
	S.stealth = v
end)
sliderRow(pByp, "Jitter", 0, 150, S.jitter * 100, function(v)
	return string.format("%dms", math.floor(v))
end, function(v) S.jitter = v / 100 end)
sliderRow(pByp, "Rate budget", 1, 15, S.rate, function(v)
	return string.format("%d/s", math.floor(v))
end, function(v)
	S.rate = math.floor(v)
	S.maxTokens = math.max(S.maxTokens, S.rate)
end)

section(pByp, "surface")
toggleRow(pByp, "GUI protection", "gethui / CoreGui parenting", S.guiProtect, function(v)
	S.guiProtect = v
	pushLog(v and "guiProtect on next launch" or "guiProtect off next launch")
end)
toggleRow(pByp, "Randomised names", "instance name noise", S.randomNames, function(v)
	S.randomNames = v
	pushLog(v and "name randomiser on next launch" or "name randomiser off next launch")
end)
toggleRow(pByp, "Debug log", "trace remote results", S.log, function(v)
	S.log = v
end)

-- config page

local pCfg = pages.cfg
section(pCfg, "shell")
sliderRow(pCfg, "UI scale", 60, 120, S.scale * 100, function(v)
	return string.format("%d%%", math.floor(v))
end, function(v)
	S.scale = v / 100
	uiScale.Scale = S.scale
end)
toggleRow(pCfg, "Blur backdrop", "lighting blur while open", S.blur, function(v)
	S.blur = v
	blur.Enabled = v
end)

section(pCfg, "actions")
buttonRow(pCfg, "Reapply landscape", "setorientation retry", "Lock", PAL.yellow, function()
	lockLandscape()
	pushLog("landscape relock")
end)
buttonRow(pCfg, "Restore hitboxes", "write original sizes back", "Restore", PAL.yellow, function()
	pcall(restore)
	pcall(draw)
	pushLog("sizes restored")
end)
buttonRow(pCfg, "Unload", "destroy shell and hooks", "Unload", PAL.red, function()
	unload()
end)

section(pCfg, "log")
local logBox = new("Frame", {
	Size = UDim2.new(1, 0, 0, 132),
	BackgroundColor3 = PAL.panel,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Parent = pCfg,
})
round(logBox, 12)
edge(logBox, PAL.stroke, 0.6)
logRef = new("TextLabel", {
	Size = UDim2.new(1, -16, 1, -12),
	Position = UDim2.fromOffset(8, 6),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 9,
	TextColor3 = PAL.muted,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Text = "",
	Parent = logBox,
})
new("UIPadding", { PaddingTop = UDim.new(0, 2) }, logBox)

-- ── hud ─────────────────────────────────────────────────────────────────────

hudFrame = new("Frame", {
	Size = UDim2.fromOffset(228, 54),
	Position = UDim2.new(0, 12, 1, -66),
	AnchorPoint = Vector2.new(0, 0),
	BackgroundColor3 = PAL.bg,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = S.ballHud,
	Parent = gui,
})
round(hudFrame, 12)
edge(hudFrame, PAL.stroke, 0.35)

hudLine = new("TextLabel", {
	Size = UDim2.new(1, -20, 0, 14),
	Position = UDim2.fromOffset(10, 9),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextColor3 = PAL.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "ball state",
	Parent = hudFrame,
})
hudDetail = new("TextLabel", {
	Size = UDim2.new(1, -20, 0, 26),
	Position = UDim2.fromOffset(10, 23),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 9,
	TextColor3 = PAL.muted,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Text = "awaiting scan",
	Parent = hudFrame,
})

-- ── orientation guard / fab ─────────────────────────────────────────────────

local rotate = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(0, 0, 0),
	BackgroundTransparency = 0.2,
	Visible = false,
	Parent = gui,
})
new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 28),
	Position = UDim2.new(0, 0, 0.5, -14),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = PAL.yellow,
	Text = "rotate to landscape",
	Parent = rotate,
})

local fab = new("TextButton", {
	Size = UDim2.fromOffset(48, 48),
	Position = UDim2.new(1, -62, 1, -62),
	BackgroundColor3 = PAL.blue,
	Text = "fx",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(255, 255, 255),
	AutoButtonColor = false,
	Visible = false,
	Parent = gui,
})
round(fab, 24)

local windowOpen = true

local function refreshVisibility()
	local now = workspace.CurrentViewportSize
	local portrait = now.Y > now.X
	win.Visible = windowOpen and not portrait
	rotate.Visible = windowOpen and portrait
	fab.Visible = not windowOpen and not portrait
end

close.MouseButton1Click:Connect(function()
	windowOpen = false
	refreshVisibility()
end)

fab.MouseButton1Click:Connect(function()
	windowOpen = true
	refreshVisibility()
end)

workspace:GetPropertyChangedSignal("CurrentViewportSize"):Connect(refreshVisibility)

-- ── drag ────────────────────────────────────────────────────────────────────

local dragging, dragStart, startPos

bar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		startPos = win.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseMovement) then
		local delta = input.Position - dragStart
		win.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)

-- ── loops ───────────────────────────────────────────────────────────────────

local t = { hb = 0, spin = 0, daily = 0, like = 0, quest = 0, ach = 0, hit = 0, hud = 0 }
local hbConn

local function think(dt)
	t.hb += dt
	if t.hb >= 0.35 then
		t.hb = 0
		if S.hb then
			pcall(apply)
		else
			pcall(restore)
		end
		pcall(draw)
	end

	if S.autoSpin then
		t.spin += dt
		if t.spin >= S.spinDelay then
			t.spin = 0
			task.spawn(spinOnce)
		end
	end

	if S.autoDaily then
		t.daily += dt
		if t.daily >= 8 then
			t.daily = 0
			task.spawn(claimDaily)
		end
	end

	if S.autoLike then
		t.like += dt
		if t.like >= 8 then
			t.like = 0
			task.spawn(claimLike)
		end
	end

	if S.autoQuest then
		t.quest += dt
		if t.quest >= 6 then
			t.quest = 0
			task.spawn(claimQuest)
		end
	end

	if S.autoAch then
		t.ach += dt
		if t.ach >= 6 then
			t.ach = 0
			task.spawn(claimAch)
		end
	end

	if S.autoHit then
		t.hit += dt
		if t.hit >= 0.25 then
			t.hit = 0
			task.spawn(autoHitTick)
		end
	end

	if S.ballHud then
		t.hud += dt
		if t.hud >= 1.5 then
			t.hud = 0
			task.spawn(function()
				local ok, st = invoke("GetBallState")
				if not ok or type(st) ~= "table" then return end
				local main = type(st.Main) == "table" and st.Main or {}
				local practice = type(st.Practice) == "table" and st.Practice or {}
				hudLine.Text = ("dead %s | skin %s"):format(
					tostring(main.Dead), tostring(practice.Skin)
				)
				local vel = practice.Velocity
				if typeof(vel) == "Vector3" then
					hudDetail.Text = ("v %.1f %.1f %.1f"):format(vel.X, vel.Y, vel.Z)
				end
			end)
		end
	end
end

hbConn = RunService.Heartbeat:Connect(think)

-- ── teardown ────────────────────────────────────────────────────────────────

function unload()
	if hbConn then
		hbConn:Disconnect()
		hbConn = nil
	end
	pcall(restore)
	clearBoxes()
	if blur then blur:Destroy() end
	if gui then gui:Destroy() end
end

selectTab("hit")
refreshVisibility()
pushLog("shell up | " .. tostring(#Players:GetPlayers()) .. " players")
