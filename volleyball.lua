--!nonstrict
--[[
    volleyball.lua
    liquid glass panel · mobile ready
    game: 125848858933944 (spin ball)
    features: hitbox expander + visualiser, ball hud, auto hit, ability equip,
              spin / reward, claim sweeps, token-bucket "bypass" layer
    close:  X button uses Activated so it works on mouse and touch
    launcher: drag it anywhere, tap to open
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting          = game:GetService("Lighting")

local lp = Players.LocalPlayer
if not lp then
	warn("[volleyball] no LocalPlayer")
	return
end

-- re-exec safety
if type(_G.__volleyball_cleanup) == "function" then
	pcall(_G.__volleyball_cleanup)
end

local connections = {}
local screen

local function track(conn)
	table.insert(connections, conn)
	return conn
end

local function create(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function tween(inst, goal, time, style)
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		goal
	)
	tw:Play()
	return tw
end

local function stage(msg)
	print("[volleyball] " .. msg)
end

local function rname(len)
	local pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	local out = {}
	for i = 1, (len or 12) do
		local n = math.random(1, #pool)
		out[i] = pool:sub(n, n)
	end
	return table.concat(out)
end

-- ── config ──────────────────────────────────────────────────────────────────

local cfg = {
	-- hitbox
	hb = false,
	hbSize = 8,
	hbBallOnly = true,
	hbTeam = true,
	hbVis = false,
	hbAlpha = 55,
	-- balls
	ballHud = true,
	autoHit = false,
	abilityIndex = 1,
	-- spins
	autoSpin = false,
	spinDelay = 0.8,
	autoReward = true,
	rewardDelay = 1.2,
	-- claims
	autoDaily = false,
	autoLike = false,
	autoQuest = false,
	autoAch = false,
	-- bypass
	stealth = true,
	jitter = 0.35,
	rate = 6,
	maxTokens = 10,
	guiProtect = true,
	randomNames = true,
	-- shell
	uiScale = 1,
	blur = true,
	log = true,
}

local DEFAULTS = {}
for k, v in pairs(cfg) do
	DEFAULTS[k] = v
end

local SAVE_KEYS = {
	"hb", "hbSize", "hbBallOnly", "hbTeam", "hbVis", "hbAlpha",
	"ballHud", "autoHit", "abilityIndex",
	"autoSpin", "spinDelay", "autoReward", "rewardDelay",
	"autoDaily", "autoLike", "autoQuest", "autoAch",
	"stealth", "jitter", "rate", "maxTokens", "guiProtect", "randomNames",
	"uiScale", "blur", "log",
}

local CONFIG_PATH = "volleyball_config.json"
local saveQueued = false

local function serializeConfig()
	local data = {}
	for _, key in ipairs(SAVE_KEYS) do
		data[key] = cfg[key]
	end
	local ok, json = pcall(function()
		return game:GetService("HttpService"):JSONEncode(data)
	end)
	if ok and type(json) == "string" then
		return json
	end
	local parts = {}
	for _, key in ipairs(SAVE_KEYS) do
		local value = cfg[key]
		if type(value) == "string" then
			table.insert(parts, string.format("%s=%q", key, value))
		else
			table.insert(parts, string.format("%s=%s", key, tostring(value)))
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function saveConfig()
	if type(writefile) ~= "function" then
		return false
	end
	local payload = serializeConfig()
	return pcall(writefile, CONFIG_PATH, payload)
end

-- sliders fire on every pixel of the drag
local function queueSave()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.6, function()
		saveQueued = false
		saveConfig()
	end)
end

local function loadConfig()
	if type(readfile) ~= "function" or type(isfile) ~= "function" then
		return false
	end
	local exists = pcall(isfile, CONFIG_PATH)
	if not exists then
		return false
	end
	local ok, raw = pcall(readfile, CONFIG_PATH)
	if not ok or type(raw) ~= "string" or raw == "" then
		return false
	end

	local data
	local decoded = select(2, pcall(function()
		return game:GetService("HttpService"):JSONDecode(raw)
	end))
	if type(decoded) == "table" then
		data = decoded
	else
		local chunk = loadstring or load
		if chunk then
			local fn = chunk("return " .. raw)
			if type(fn) == "function" then
				local good, value = pcall(fn)
				if good and type(value) == "table" then
					data = value
				end
			end
		end
	end

	if type(data) ~= "table" then
		return false
	end

	for _, key in ipairs(SAVE_KEYS) do
		local value = data[key]
		if value ~= nil and type(value) == type(cfg[key]) then
			cfg[key] = value
		end
	end

	-- clamp anything a hand-edited file could have poisoned
	cfg.hbSize = math.clamp(tonumber(cfg.hbSize) or 8, 2, 40)
	cfg.hbAlpha = math.clamp(tonumber(cfg.hbAlpha) or 55, 5, 100)
	cfg.abilityIndex = math.clamp(tonumber(cfg.abilityIndex) or 1, 1, 11)
	cfg.spinDelay = math.clamp(tonumber(cfg.spinDelay) or 0.8, 0.2, 5)
	cfg.rewardDelay = math.clamp(tonumber(cfg.rewardDelay) or 1.2, 0.2, 5)
	cfg.jitter = math.clamp(tonumber(cfg.jitter) or 0.35, 0, 1)
	cfg.rate = math.clamp(tonumber(cfg.rate) or 6, 1, 30)
	cfg.maxTokens = math.clamp(tonumber(cfg.maxTokens) or 10, 1, 40)
	cfg.uiScale = math.clamp(tonumber(cfg.uiScale) or 1, 0.5, 1.2)
	return true
end

local configLoaded = loadConfig()

local COL = {
	bg = Color3.fromRGB(14, 16, 24),
	text = Color3.fromRGB(236, 240, 250),
	sub = Color3.fromRGB(148, 157, 180),
	cyan = Color3.fromRGB(111, 231, 255),
	violet = Color3.fromRGB(167, 139, 250),
	pink = Color3.fromRGB(255, 122, 198),
	danger = Color3.fromRGB(255, 108, 122),
}

local ABILITIES = {
	"Shockwave", "Magnet", "Portal", "Superspike", "TornadoBall", "Forcefield",
	"Guardian", "Moonball", "Curveball", "Adrenaline", "Frozen",
}

-- ── viewport / mount ────────────────────────────────────────────────────────

local function viewport()
	local cam = workspace.CurrentCamera
	if cam then
		local ok, v = pcall(function()
			return cam.ViewportSize
		end)
		if ok and typeof(v) == "Vector2" and v.X > 0 and v.Y > 0 then
			return v
		end
	end
	local ok2, v2 = pcall(function()
		return workspace.CurrentViewportSize
	end)
	if ok2 and typeof(v2) == "Vector2" and v2.X > 0 and v2.Y > 0 then
		return v2
	end
	return Vector2.new(1280, 720)
end

local function mount(gui)
	local attempts = {}

	attempts[#attempts + 1] = function()
		if type(gethui) == "function" then
			local ok, c = pcall(gethui)
			if ok and c then
				return c, "gethui"
			end
		end
		return nil
	end

	attempts[#attempts + 1] = function()
		local ok, c = pcall(function()
			return game:GetService("CoreGui")
		end)
		if ok and c then
			return c, "coregui"
		end
		return nil
	end

	attempts[#attempts + 1] = function()
		local ok, c = pcall(function()
			return lp:WaitForChild("PlayerGui", 8)
		end)
		if ok and c then
			return c, "playergui"
		end
		return nil
	end

	for _, fn in ipairs(attempts) do
		local ok, parent, label = pcall(fn)
		if ok and parent then
			if cfg.guiProtect and type(syn) == "table" and type(syn.protect_gui) == "function" then
				pcall(function()
					syn.protect_gui(gui)
				end)
			end
			local placed = pcall(function()
				gui.Parent = parent
			end)
			if placed and gui.Parent then
				stage("mounted on " .. tostring(label))
				return true, label
			end
			stage("mount rejected on " .. tostring(label))
		end
	end
	return false, nil
end

local function fallback(err)
	local parent = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 8)
	if not parent then
		warn("[volleyball] no gui parent at all")
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "vb_error"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100000
	gui.Parent = parent

	local card = create("Frame", {
		Size = UDim2.fromOffset(520, 200),
		Position = UDim2.new(0.5, -260, 0.5, -100),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BorderSizePixel = 0,
	}, gui)
	create("UICorner", { CornerRadius = UDim.new(0, 16) }, card)
	create("UIStroke", { Color = COL.danger, Transparency = 0.4, Thickness = 2 }, card)

	create("TextLabel", {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, 10),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = COL.danger,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "volleyball shell failed to build",
	}, card)

	create("TextLabel", {
		Size = UDim2.new(1, -24, 1, -48),
		Position = UDim2.fromOffset(12, 36),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = COL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = tostring(err),
	}, card)
	stage("fallback card shown")
end

-- ── remote plumbing ─────────────────────────────────────────────────────────

local remoteCache = {}

local function findRemote(leaf)
	if remoteCache[leaf] ~= nil then
		return remoteCache[leaf] or nil
	end
	local hit
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d.Name == leaf
			and (d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent") or d:IsA("RemoteFunction")) then
			hit = d
			break
		end
	end
	remoteCache[leaf] = hit or false
	return hit
end

local bucket = { tokens = 10, last = os.clock() }

-- token bucket: refills at cfg.rate per second, capped at cfg.maxTokens.
-- invokes cost 2 because they block the calling thread on the server reply.
local function allow(cost)
	local now = os.clock()
	bucket.tokens = math.min(cfg.maxTokens, bucket.tokens + (now - bucket.last) * cfg.rate)
	bucket.last = now
	if bucket.tokens >= cost then
		bucket.tokens -= cost
		return true
	end
	return false
end

local function jitter()
	if cfg.stealth and cfg.jitter > 0 then
		task.wait(math.random() * cfg.jitter)
	end
end

local logRef
local logBuf = {}

local function pushLog(msg)
	table.insert(logBuf, 1, ("%s  %s"):format(os.date("%H:%M:%S"), msg))
	while #logBuf > 60 do
		table.remove(logBuf)
	end
	if cfg.log and logRef then
		logRef.Text = table.concat(logBuf, "\n")
	end
end

local function fire(leaf, ...)
	local r = findRemote(leaf)
	if not r then
		pushLog("missing " .. leaf)
		return false
	end
	if not allow(1) then
		pushLog("throttle " .. leaf)
		return false
	end
	jitter()
	local pack = table.pack(...)
	local ok, err = pcall(function()
		r:FireServer(table.unpack(pack, 1, pack.n))
	end)
	if not ok then
		pushLog(("err %s: %s"):format(leaf, tostring(err)))
	end
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
	if not ok then
		pushLog(("err %s: %s"):format(leaf, tostring(res)))
	end
	return ok, res
end

-- ── hitbox ──────────────────────────────────────────────────────────────────

local originals = setmetatable({}, { __mode = "k" })
local boxes = {}
local boxRoot
local boxParentRef

local function isBall(name)
	return string.find(string.lower(name), "ball", 1, true) ~= nil
end

local function ballParts()
	local out = {}
	local go = workspace:FindFirstChild("GameObjects")
	if not go then
		return out
	end
	for _, d in ipairs(go:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart"
			and (isBall(d.Name) or (d.Parent and isBall(d.Parent.Name))) then
			out[#out + 1] = d
		end
	end
	return out
end

local function enemyParts()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local skip = false
			if cfg.hbTeam and plr.Team and lp.Team and plr.Team == lp.Team then
				skip = true
			end
			local ch = plr.Character
			if ch and not skip then
				for _, d in ipairs(ch:GetDescendants()) do
					if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
						out[#out + 1] = d
					end
				end
			end
		end
	end
	return out
end

local function targets()
	local out = ballParts()
	if not cfg.hbBallOnly then
		for _, p in ipairs(enemyParts()) do
			out[#out + 1] = p
		end
	end
	return out
end

local function apply()
	local k = cfg.hbSize / 4
	for _, part in ipairs(targets()) do
		if part and part.Parent then
			if not originals[part] then
				originals[part] = part.Size
			end
			part.Size = originals[part] * k
		end
	end
end

local function restore()
	for part, size in pairs(originals) do
		if part and part.Parent then
			pcall(function()
				part.Size = size
			end)
		end
	end
	table.clear(originals)
end

local function clearBoxes()
	for i = #boxes, 1, -1 do
		if boxes[i] then
			pcall(function()
				boxes[i]:Destroy()
			end)
		end
		boxes[i] = nil
	end
end

local function boxContainer()
	if boxRoot and boxRoot.Parent then
		return boxRoot
	end
	local roots = {}
	if boxParentRef then
		table.insert(roots, boxParentRef)
	end
	table.insert(roots, workspace)
	for _, root in ipairs(roots) do
		local ok, folder = pcall(function()
			local f = Instance.new("Folder")
			f.Name = rname(10)
			f.Parent = root
			return f
		end)
		if ok and folder and folder.Parent then
			boxRoot = folder
			return folder
		end
	end
	return nil
end

local function draw()
	clearBoxes()
	if not cfg.hbVis then
		return
	end
	local parent = boxContainer()
	if not parent then
		return
	end
	for _, part in ipairs(targets()) do
		if part and part.Parent then
			local ok, box = pcall(function()
				local b = Instance.new("BoxHandleAdornment")
				b.Name = rname(8)
				b.Size = part.Size
				b.Adornee = part
				b.AlwaysOnTop = true
				b.ZIndex = 4
				b.Transparency = cfg.hbAlpha / 100
				b.Color3 = cfg.hbBallOnly and COL.cyan or COL.pink
				b.Parent = parent
				return b
			end)
			if ok and box then
				boxes[#boxes + 1] = box
			end
		end
	end
end

-- ── actions ─────────────────────────────────────────────────────────────────

local function spinOnce()
	local ok, res = invoke("RequestSpin")
	if not ok then
		pushLog("spin transport error")
		return
	end
	pushLog("spin -> " .. tostring(res))
	if cfg.autoReward then
		task.wait(cfg.rewardDelay)
		local idx = type(res) == "number" and res or 1
		local _, reward = invoke("RequestRewardFromSpin", idx)
		pushLog(("reward(%s) -> %s"):format(tostring(idx), tostring(reward)))
	end
end

local function equipAbility()
	local name = ABILITIES[cfg.abilityIndex] or ABILITIES[1]
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
	local ch = lp.Character
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
	if not best then
		return
	end
	local dir = best.pos - myPos
	if dir.Magnitude < 1e-3 then
		dir = Vector3.new(0, 1, 0)
	end
	fire("HitBall", best.part, dir.Unit)
end

local function lockLandscape()
	pcall(function()
		setorientation("LandscapeLeft")
	end)
	pcall(function()
		setorientation("LandscapeSensor")
	end)
	pcall(function()
		local gs = game:GetService("UserSettings"):GetService("UserGameSettings")
		gs.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
end

-- ── ui helpers ──────────────────────────────────────────────────────────────

local function addRipple(button, color)
	button.ClipsDescendants = true
	track(button.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local relX = input.Position.X - button.AbsolutePosition.X
		local relY = input.Position.Y - button.AbsolutePosition.Y
		local dot = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(relX, relY),
			Size = UDim2.fromOffset(0, 0),
			BackgroundColor3 = color or Color3.new(1, 1, 1),
			BackgroundTransparency = 0.75,
			BorderSizePixel = 0,
			ZIndex = 6,
		}, button)
		create("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
		local diameter = math.max(button.AbsoluteSize.X, button.AbsoluteSize.Y) * 1.6
		tween(dot, {
			Size = UDim2.fromOffset(diameter, diameter),
			BackgroundTransparency = 1,
		}, 0.42)
		task.delay(0.45, function()
			if dot and dot.Parent then
				dot:Destroy()
			end
		end)
	end))
end

local function makeDraggable(frame, handle)
	local dragging = false
	local startPos
	local origin

	track(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			startPos = input.Position
			origin = frame.Position
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - startPos
			frame.Position = UDim2.new(
				origin.X.Scale, origin.X.Offset + delta.X,
				origin.Y.Scale, origin.Y.Offset + delta.Y
			)
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local function makeSwitch(parent, initial)
	local trackBar = create("Frame", {
		Size = UDim2.fromOffset(40, 22),
		Position = UDim2.new(1, -14, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(48, 52, 70),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, parent)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

	local fill = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COL.cyan,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, trackBar)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 20 }, fill)

	local knob = create("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = Color3.fromRGB(240, 244, 255),
		BorderSizePixel = 0,
	}, trackBar)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
	create("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.85, Thickness = 1 }, knob)

	local function set(value, animate)
		local on = value and true or false
		local goal = on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
		if animate then
			tween(knob, { Position = goal }, 0.16)
			tween(fill, { BackgroundTransparency = on and 0.05 or 1 }, 0.16)
			tween(trackBar, { BackgroundTransparency = on and 1 or 0.15 }, 0.16)
		else
			knob.Position = goal
			fill.BackgroundTransparency = on and 0.05 or 1
			trackBar.BackgroundTransparency = on and 1 or 0.15
		end
	end

	set(initial, false)
	return set
end

local layoutIndex = 0
local function nextOrder()
	layoutIndex = layoutIndex + 1
	return layoutIndex
end

local syncers = {}

local function addSection(parent, text)
	local label = create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		LayoutOrder = nextOrder(),
	}, parent)
	create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }, label)
	return label
end

local function makeToggleRow(parent, title, desc, key, onChange)
	local row = create("TextButton", {
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = nextOrder(),
	}, parent)
	create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
	create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.92,
		Thickness = 1,
	}, row)

	local accent = create("Frame", {
		Size = UDim2.fromOffset(3, 18),
		Position = UDim2.new(0, 11, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = COL.cyan,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, row)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, accent)
	create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 90 }, accent)

	create("TextLabel", {
		Position = UDim2.fromOffset(22, 6),
		Size = UDim2.fromOffset(180, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = COL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
	}, row)

	create("TextLabel", {
		Position = UDim2.fromOffset(22, 23),
		Size = UDim2.new(1, -110, 0, 13),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = desc,
	}, row)

	local switchSet = makeSwitch(row, cfg[key])

	local function render()
		local on = cfg[key]
		accent.BackgroundTransparency = on and 0.05 or 1
		switchSet(on, true)
	end

	-- Activated is mouse + touch, so mobile toggles work
	track(row.Activated:Connect(function()
		cfg[key] = not cfg[key]
		render()
		queueSave()
		if onChange then
			onChange(cfg[key])
		end
	end))

	track(row.MouseEnter:Connect(function()
		tween(row, { BackgroundTransparency = 0.88 }, 0.12)
	end))
	track(row.MouseLeave:Connect(function()
		tween(row, { BackgroundTransparency = 0.94 }, 0.12)
	end))

	addRipple(row, COL.cyan)
	render()
	syncers[#syncers + 1] = render
	return row
end

local function makeSliderRow(parent, title, key, min, max, opts)
	opts = opts or {}
	local suffix = opts.suffix or ""
	local step = opts.step or 1
	local fmt = opts.fmt

	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 62),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
	}, parent)

	create("TextLabel", {
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(0.6, 0, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = COL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
	}, row)

	local initial = tonumber(cfg[key]) or min

	local valueLabel = create("TextLabel", {
		Position = UDim2.new(1, -110, 0, 4),
		Size = UDim2.fromOffset(96, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = COL.cyan,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = fmt and fmt(initial) or (tostring(initial) .. suffix),
	}, row)

	local trackBar = create("Frame", {
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.new(1, -28, 0, 4),
		BackgroundColor3 = Color3.fromRGB(64, 70, 92),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, row)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

	local fraction = math.clamp((initial - min) / (max - min), 0, 1)
	local fill = create("Frame", {
		Size = UDim2.fromScale(fraction, 1),
		BackgroundColor3 = COL.cyan,
		BorderSizePixel = 0,
	}, trackBar)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet) }, fill)

	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(fraction, 0, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Color3.fromRGB(240, 244, 255),
		BorderSizePixel = 0,
	}, trackBar)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
	create("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.7, Thickness = 1 }, knob)

	local hit = create("Frame", {
		Position = UDim2.fromOffset(4, 30),
		Size = UDim2.new(1, -8, 0, 28),
		BackgroundTransparency = 1,
		Active = true,
	}, row)

	local dragging = false

	local function snap(value)
		local steps = math.floor((value - min) / step + 0.5)
		return math.clamp(min + steps * step, min, max)
	end

	local function setValue(value, fireChange)
		value = snap(value)
		cfg[key] = value
		local f = math.clamp((value - min) / (max - min), 0, 1)
		fill.Size = UDim2.fromScale(f, 1)
		knob.Position = UDim2.new(f, 0, 0.5, 0)
		valueLabel.Text = fmt and fmt(value) or (tostring(value) .. suffix)
		if fireChange then
			if opts.onChange then
				opts.onChange(value)
			end
			queueSave()
		end
	end

	local function updateFromX(x)
		local abs = trackBar.AbsolutePosition.X
		local width = math.max(trackBar.AbsoluteSize.X, 1)
		local frac = math.clamp((x - abs) / width, 0, 1)
		setValue(min + (max - min) * frac, true)
	end

	track(hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFromX(input.Position.X)
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			updateFromX(input.Position.X)
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	setValue(initial, false)
	syncers[#syncers + 1] = function()
		setValue(cfg[key], false)
	end
	return row
end

local function makeActionRow(parent, title, desc, onPress)
	local row = create("TextButton", {
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.92,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = nextOrder(),
	}, parent)
	create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
	create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.92,
		Thickness = 1,
	}, row)

	create("TextLabel", {
		Position = UDim2.fromOffset(22, 5),
		Size = UDim2.new(1, -30, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = COL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
	}, row)

	local descLabel = create("TextLabel", {
		Position = UDim2.fromOffset(22, 21),
		Size = UDim2.new(1, -30, 0, 13),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = desc,
	}, row)

	track(row.Activated:Connect(function()
		onPress(row, descLabel)
	end))
	addRipple(row, COL.violet)
	return row, descLabel
end

-- ── build ───────────────────────────────────────────────────────────────────

local unload
local refreshStatus
local applyFit
local hudLine, hudDetail
local blur

local function build()
	local gui = create("ScreenGui", {
		Name = cfg.randomNames and rname(9) or "volleyball",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 9999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	if not mount(gui) then
		error("could not mount ScreenGui on gethui / CoreGui / PlayerGui")
	end
	screen = gui
	boxParentRef = gui.Parent

	blur = create("BlurEffect", {
		Name = cfg.randomNames and rname(6) or "vb_blur",
		Size = 18,
		Enabled = cfg.blur,
	}, Lighting)

	-- floating launcher
	local float = create("Frame", {
		Name = "float",
		Size = UDim2.fromOffset(52, 52),
		Position = UDim2.fromOffset(20, 220),
		BackgroundColor3 = COL.bg,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, gui)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, float)

	local floatStroke = create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.8,
		Thickness = 1,
	}, float)
	create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 30 }, floatStroke)

	local floatGlow = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.92,
		BorderSizePixel = 0,
	}, float)
	create("UIGradient", {
		Color = ColorSequence.new(COL.violet, COL.cyan),
		Transparency = NumberSequence.new(0.55, 1),
		Rotation = 135,
	}, floatGlow)

	local crossH = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(18, 2),
		BackgroundColor3 = Color3.fromRGB(240, 244, 255),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, float)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, crossH)

	local crossV = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(2, 18),
		BackgroundColor3 = Color3.fromRGB(240, 244, 255),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, float)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, crossV)

	local crossDot = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = COL.cyan,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, float)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, crossDot)

	-- panel
	local panel = create("Frame", {
		Name = "panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(292, 470),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)

	local fitScale = create("UIScale", { Scale = 1 }, panel)

	local shadow = create("Frame", {
		Position = UDim2.fromOffset(0, 9),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.62,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, panel)
	create("UICorner", { CornerRadius = UDim.new(0, 22) }, shadow)

	local shadowSoft = create("Frame", {
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.8,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, panel)
	create("UICorner", { CornerRadius = UDim.new(0, 24) }, shadowSoft)

	local body = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COL.bg,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 1,
	}, panel)
	create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)

	local bodyStroke = create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.84,
		Thickness = 1,
	}, body)
	create("UIGradient", {
		Color = ColorSequence.new(COL.cyan, COL.violet, COL.pink),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.95),
			NumberSequenceKeypoint.new(1, 0.6),
		}),
		Rotation = 35,
	}, bodyStroke)

	local orbA = create("Frame", {
		Position = UDim2.fromOffset(-90, -110),
		Size = UDim2.fromOffset(230, 230),
		BackgroundColor3 = COL.violet,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, body)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbA)
	create("UIGradient", {
		Color = ColorSequence.new(COL.violet, COL.cyan),
		Transparency = NumberSequence.new(0.25, 1),
		Rotation = 140,
	}, orbA)

	local orbB = create("Frame", {
		Position = UDim2.new(1, -80, 1, -70),
		Size = UDim2.fromOffset(170, 170),
		BackgroundColor3 = COL.pink,
		BackgroundTransparency = 0.65,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, body)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbB)
	create("UIGradient", {
		Color = ColorSequence.new(COL.pink, COL.violet),
		Transparency = NumberSequence.new(0.4, 1),
		Rotation = 320,
	}, orbB)

	local sheen = create("Frame", {
		Size = UDim2.new(1, 0, 0, 90),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, body)
	create("UIGradient", {
		Transparency = NumberSequence.new(0.55, 1),
		Rotation = 90,
	}, sheen)

	-- header
	local header = create("Frame", {
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		ZIndex = 3,
	}, body)

	local dragZone = create("Frame", {
		Size = UDim2.new(1, -58, 1, 0),
		BackgroundTransparency = 1,
		Active = true,
		ZIndex = 3,
	}, header)

	local logo = create("Frame", {
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.fromOffset(14, 11),
		BackgroundColor3 = COL.violet,
		BorderSizePixel = 0,
	}, dragZone)
	create("UICorner", { CornerRadius = UDim.new(0, 9) }, logo)
	create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 40 }, logo)

	local logoH = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(12, 1.5),
		BackgroundColor3 = Color3.fromRGB(14, 16, 24),
		BorderSizePixel = 0,
		ZIndex = 5,
	}, logo)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, logoH)

	local logoV = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(1.5, 12),
		BackgroundColor3 = Color3.fromRGB(14, 16, 24),
		BorderSizePixel = 0,
		ZIndex = 5,
	}, logo)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, logoV)

	create("TextLabel", {
		Position = UDim2.fromOffset(52, 10),
		Size = UDim2.fromOffset(150, 17),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor3 = COL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "volleyball.lua",
		ZIndex = 4,
	}, dragZone)

	create("TextLabel", {
		Position = UDim2.fromOffset(52, 27),
		Size = UDim2.fromOffset(170, 13),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "liquid glass · mobile",
		ZIndex = 4,
	}, dragZone)

	-- close button: 34px, Activated handles mouse + touch
	local closeButton = create("TextButton", {
		Name = "close",
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(1, -10, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.9,
		BorderSizePixel = 0,
		Text = "×",
		Font = Enum.Font.Gotham,
		TextSize = 20,
		TextColor3 = COL.text,
		AutoButtonColor = false,
		Active = true,
		ZIndex = 6,
	}, header)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)
	create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Transparency = 0.8,
		Thickness = 1,
	}, closeButton)

	track(closeButton.MouseEnter:Connect(function()
		tween(closeButton, { BackgroundTransparency = 0.78 }, 0.12)
	end))
	track(closeButton.MouseLeave:Connect(function()
		tween(closeButton, { BackgroundTransparency = 0.9 }, 0.12)
	end))

	makeDraggable(panel, dragZone)

	-- content
	local content = create("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 1, -78),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = COL.sub,
		ScrollBarImageTransparency = 0.6,
		ZIndex = 2,
	}, body)

	create("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 10),
	}, content)

	create("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, content)

	-- footer
	local footer = create("Frame", {
		Position = UDim2.new(0, 0, 1, -26),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, body)

	local statusDot = create("Frame", {
		Size = UDim2.fromOffset(6, 6),
		Position = UDim2.fromOffset(16, 10),
		BackgroundColor3 = COL.sub,
		BorderSizePixel = 0,
	}, footer)
	create("UICorner", { CornerRadius = UDim.new(1, 0) }, statusDot)

	local statusLabel = create("TextLabel", {
		Position = UDim2.fromOffset(28, 4),
		Size = UDim2.new(1, -100, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 10,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "idle",
	}, footer)

	create("TextLabel", {
		Position = UDim2.new(1, -86, 0, 4),
		Size = UDim2.fromOffset(74, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 9,
		TextColor3 = Color3.fromRGB(120, 128, 150),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "tap float · drag",
	}, footer)

	refreshStatus = function()
		local parts = {}
		if cfg.hb then
			table.insert(parts, ("HB %.1fx"):format(cfg.hbSize / 4))
		end
		if cfg.autoSpin then
			table.insert(parts, "SPIN")
		end
		if cfg.autoHit then
			table.insert(parts, "HIT")
		end
		if cfg.ballHud then
			table.insert(parts, "HUD")
		end
		if cfg.autoDaily or cfg.autoLike or cfg.autoQuest or cfg.autoAch then
			table.insert(parts, "CLAIM")
		end

		if #parts > 0 then
			statusLabel.Text = table.concat(parts, " · ")
			statusLabel.TextColor3 = COL.cyan
			statusDot.BackgroundColor3 = COL.cyan
		else
			statusLabel.Text = "idle"
			statusLabel.TextColor3 = COL.sub
			statusDot.BackgroundColor3 = COL.sub
		end
	end

	-- rows
	addSection(content, "HITBOX")
	makeToggleRow(content, "Hitbox expander", "Scales ball (or player) parts client-side", "hb", refreshStatus)
	makeSliderRow(content, "Multiplier", "hbSize", 2, 40, {
		fmt = function(v)
			return string.format("%.1fx", v / 4)
		end,
	})
	makeToggleRow(content, "Balls only", "Leave players at normal size", "hbBallOnly", nil)
	makeToggleRow(content, "Team check", "Skip teammates when players included", "hbTeam", nil)
	makeToggleRow(content, "Show boxes", "BoxHandleAdornment overlay", "hbVis", nil)
	makeSliderRow(content, "Box opacity", "hbAlpha", 5, 100, {
		suffix = "%",
	})
	makeActionRow(content, "Restore sizes", "Undo every scaled part now", function(_, desc)
		cfg.hb = false
		pcall(restore)
		clearBoxes()
		for _, fn in ipairs(syncers) do
			pcall(fn)
		end
		refreshStatus()
		desc.Text = "sizes restored"
		desc.TextColor3 = COL.cyan
	end)

	addSection(content, "BALLS")
	makeToggleRow(content, "Ball HUD", "Polls GetBallState every 1.5s", "ballHud", refreshStatus)
	makeToggleRow(content, "Auto hit", "Fires HitBall at the nearest ball", "autoHit", refreshStatus)
	makeSliderRow(content, "Ability", "abilityIndex", 1, #ABILITIES, {
		fmt = function(v)
			return ABILITIES[math.floor(v)] or ABILITIES[1]
		end,
	})
	makeActionRow(content, "Equip ability", "Sends EquipAbility for the slot above", function(_, desc)
		equipAbility()
		desc.Text = "equipped " .. (ABILITIES[cfg.abilityIndex] or ABILITIES[1])
		desc.TextColor3 = COL.cyan
	end)

	addSection(content, "SPINS")
	makeToggleRow(content, "Auto spin", "RequestSpin on a timer", "autoSpin", refreshStatus)
	makeSliderRow(content, "Spin interval", "spinDelay", 0.2, 5, {
		step = 0.1,
		suffix = "s",
		fmt = function(v)
			return string.format("%.1fs", v)
		end,
	})
	makeToggleRow(content, "Auto reward", "RequestRewardFromSpin after each spin", "autoReward", nil)
	makeSliderRow(content, "Reward delay", "rewardDelay", 0.2, 5, {
		step = 0.1,
		fmt = function(v)
			return string.format("%.1fs", v)
		end,
	})

	addSection(content, "CLAIMS")
	makeToggleRow(content, "Daily reward", "ClaimDayReward every 8s", "autoDaily", refreshStatus)
	makeToggleRow(content, "Like reward", "ClaimLikeReward every 8s", "autoLike", refreshStatus)
	makeToggleRow(content, "Quest sweep", "Walks ClaimQuest indices", "autoQuest", refreshStatus)
	makeToggleRow(content, "Achievement sweep", "Walks ClaimAchievement indices", "autoAch", refreshStatus)
	makeActionRow(content, "Claim all once", "One pass across all four claim remotes", function(_, desc)
		task.spawn(function()
			claimDaily()
			task.wait(0.2)
			claimLike()
			task.wait(0.2)
			claimQuest()
			task.wait(0.2)
			claimAch()
		end)
		desc.Text = "claim pass sent"
		desc.TextColor3 = COL.cyan
	end)

	addSection(content, "BYPASS")
	makeToggleRow(content, "Stealth jitter", "Random wait before every remote", "stealth", nil)
	makeSliderRow(content, "Jitter", "jitter", 0, 1, {
		step = 0.05,
		fmt = function(v)
			return string.format("%.2fs", v)
		end,
	})
	makeSliderRow(content, "Rate budget", "rate", 1, 30, {
		suffix = "/s",
	})
	makeToggleRow(content, "GUI protection", "gethui / CoreGui parenting", "guiProtect", nil)
	makeToggleRow(content, "Random names", "Scramble gui + folder names", "randomNames", nil)

	addSection(content, "CONFIG")
	makeToggleRow(content, "Backdrop blur", "BlurEffect over the game", "blur", function(on)
		if blur then
			blur.Enabled = on
		end
	end)
	makeToggleRow(content, "Debug log", "Write remote results into the box below", "log", function(on)
		if on and logRef then
			logRef.Text = table.concat(logBuf, "\n")
		end
	end)
	makeSliderRow(content, "UI scale", "uiScale", 0.5, 1.2, {
		step = 0.05,
		fmt = function(v)
			return string.format("%.2fx", v)
		end,
		onChange = function()
			if applyFit then
				applyFit()
			end
		end,
	})
	makeActionRow(content, "Reapply landscape", "Locks orientation again", function(_, desc)
		lockLandscape()
		desc.Text = "landscape requested"
		desc.TextColor3 = COL.cyan
	end)
	makeActionRow(content, "Save config", configLoaded and "Loaded on start" or "No saved config found", function(_, desc)
		local ok = saveConfig()
		desc.Text = ok and "Saved to " .. CONFIG_PATH or "writefile unavailable here"
		desc.TextColor3 = ok and COL.cyan or COL.danger
	end)
	makeActionRow(content, "Reset config", "Defaults, saved, then applied", function(_, desc)
		for k, v in pairs(DEFAULTS) do
			cfg[k] = v
		end
		saveConfig()
		for _, fn in ipairs(syncers) do
			pcall(fn)
		end
		if blur then
			blur.Enabled = cfg.blur
		end
		refreshStatus()
		desc.Text = "defaults applied"
		desc.TextColor3 = COL.cyan
	end)
	makeActionRow(content, "Unload", "Remove gui, restore parts, disconnect", function()
		if unload then
			unload()
		end
	end)

	addSection(content, "LOG")
	local logBox = create("Frame", {
		Size = UDim2.new(1, 0, 0, 110),
		BackgroundColor3 = Color3.fromRGB(8, 10, 16),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = nextOrder(),
	}, content)
	create("UICorner", { CornerRadius = UDim.new(0, 12) }, logBox)
	create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.94 }, logBox)

	logRef = create("TextLabel", {
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.new(1, -16, 1, -12),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 9,
		TextColor3 = Color3.fromRGB(180, 226, 240),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "",
	}, logBox)

	local hudFrame = create("Frame", {
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Color3.fromRGB(8, 10, 16),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		LayoutOrder = nextOrder(),
		Visible = cfg.ballHud,
	}, content)
	create("UICorner", { CornerRadius = UDim.new(0, 12) }, hudFrame)

	hudLine = create("TextLabel", {
		Position = UDim2.fromOffset(10, 5),
		Size = UDim2.new(1, -20, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = COL.cyan,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "ball state —",
	}, hudFrame)

	hudDetail = create("TextLabel", {
		Position = UDim2.fromOffset(10, 20),
		Size = UDim2.new(1, -20, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 9,
		TextColor3 = COL.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "waiting",
	}, hudFrame)

	-- open / close
	local uiOpen = false
	local bodyScale = create("UIScale", { Scale = 1 }, body)

	local function setOpen(open)
		if open == uiOpen then
			return
		end
		uiOpen = open
		if open then
			panel.Visible = true
			bodyScale.Scale = 0.94
			tween(bodyScale, { Scale = 1 }, 0.18)
		else
			tween(bodyScale, { Scale = 0.94 }, 0.12)
			task.delay(0.14, function()
				if not uiOpen then
					panel.Visible = false
				end
			end)
		end
	end

	-- touch + mouse both fire Activated
	track(closeButton.Activated:Connect(function()
		setOpen(false)
	end))

	local floatDragging = false
	local floatMoved = false
	local floatStart
	local floatOrigin

	track(float.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			floatDragging = true
			floatMoved = false
			floatStart = input.Position
			floatOrigin = float.Position
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not floatDragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - floatStart
			if delta.Magnitude > 6 then
				floatMoved = true
			end
			if floatMoved then
				float.Position = UDim2.new(
					floatOrigin.X.Scale, floatOrigin.X.Offset + delta.X,
					floatOrigin.Y.Scale, floatOrigin.Y.Offset + delta.Y
				)
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if not floatDragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			floatDragging = false
			if not floatMoved then
				setOpen(not uiOpen)
			end
		end
	end))

	-- fit
	local function fit()
		local vp = viewport()
		local base = math.min((vp.X - 28) / 292, (vp.Y - 28) / 470)
		fitScale.Scale = math.clamp(base, 0.55, 1) * (cfg.uiScale or 1)
	end

	applyFit = fit
	fit()

	-- loops
	local t = { hb = 0, spin = 0, daily = 0, like = 0, quest = 0, ach = 0, hit = 0, hud = 0 }
	local lastViewport = viewport()

	local function think(dt)
		local vp = viewport()
		if vp.X ~= lastViewport.X or vp.Y ~= lastViewport.Y then
			lastViewport = vp
			fit()
		end

		t.hb += dt
		if t.hb >= 0.35 then
			t.hb = 0
			if cfg.hb then
				pcall(apply)
			else
				pcall(restore)
			end
			pcall(draw)
		end

		if cfg.autoSpin then
			t.spin += dt
			if t.spin >= cfg.spinDelay then
				t.spin = 0
				task.spawn(spinOnce)
			end
		end

		if cfg.autoDaily then
			t.daily += dt
			if t.daily >= 8 then
				t.daily = 0
				task.spawn(claimDaily)
			end
		end

		if cfg.autoLike then
			t.like += dt
			if t.like >= 8 then
				t.like = 0
				task.spawn(claimLike)
			end
		end

		if cfg.autoQuest then
			t.quest += dt
			if t.quest >= 6 then
				t.quest = 0
				task.spawn(claimQuest)
			end
		end

		if cfg.autoAch then
			t.ach += dt
			if t.ach >= 6 then
				t.ach = 0
				task.spawn(claimAch)
			end
		end

		if cfg.autoHit then
			t.hit += dt
			if t.hit >= 0.25 then
				t.hit = 0
				task.spawn(autoHitTick)
			end
		end

		if cfg.ballHud then
			t.hud += dt
			if t.hud >= 1.5 then
				t.hud = 0
				task.spawn(function()
					local ok, st = invoke("GetBallState")
					if not ok or type(st) ~= "table" then
						return
					end
					local main = type(st.Main) == "table" and st.Main or {}
					local practice = type(st.Practice) == "table" and st.Practice or {}
					if hudLine then
						hudLine.Text = ("dead %s | skin %s"):format(
							tostring(main.Dead), tostring(practice.Skin)
						)
					end
					if hudDetail then
						local vel = practice.Velocity
						if typeof(vel) == "Vector3" then
							hudDetail.Text = ("v %.1f %.1f %.1f"):format(vel.X, vel.Y, vel.Z)
						else
							hudDetail.Text = "main " .. tostring(main.Skin or "-")
						end
					end
				end)
			end
		end

		if hudFrame then
			hudFrame.Visible = cfg.ballHud
		end
	end

	track(RunService.Heartbeat:Connect(think))

	-- teardown
	unload = function()
		pcall(saveConfig)
		for _, conn in ipairs(connections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		table.clear(connections)
		pcall(restore)
		clearBoxes()
		if boxRoot then
			pcall(function()
				boxRoot:Destroy()
			end)
			boxRoot = nil
		end
		if blur then
			pcall(function()
				blur:Destroy()
			end)
			blur = nil
		end
		if screen then
			pcall(function()
				screen:Destroy()
			end)
			screen = nil
		end
		stage("unloaded")
	end

	refreshStatus()
	setOpen(true)
	fit()
	pushLog("shell up | " .. tostring(#Players:GetPlayers()) .. " players")
	stage("panel built 292x470")

	-- if the panel rendered at zero width, remount somewhere it will draw
	task.defer(function()
		task.wait(0.25)
		if panel.Visible and panel.AbsoluteSize.X < 1 then
			local pg = lp:FindFirstChildOfClass("PlayerGui")
			if pg then
				pcall(function()
					gui.Parent = pg
				end)
				boxParentRef = pg
				stage("remounted to PlayerGui after empty render")
			end
		end
	end)
end

-- ── boot ────────────────────────────────────────────────────────────────────

local ok, err = xpcall(build, debug.traceback)
if not ok then
	warn("[volleyball] build failed: " .. tostring(err))
	pcall(fallback, err)
else
	pcall(lockLandscape)
	if not configLoaded then
		saveConfig()
	end
	stage("ready")
end

_G.__volleyball_cleanup = function()
	if unload then
		pcall(unload)
	end
end
