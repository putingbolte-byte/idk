--!nonstrict
-- olltaterfx :: liquid glass mobile shell · v2
-- place 125848858933944 | executor: delta (android)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")

local LP = Players.LocalPlayer
if not LP then
	warn("[olltaterfx] no LocalPlayer")
	return
end

local CONFIG = {
	mobileOnly = false,   -- non-blocking: warns only, never kills the build
	scale      = 0.84,
	blurSize   = 18,
	place      = "125848858933944",
	title      = "olltaterfx",
}

local PAL = {
	bg     = Color3.fromRGB(13, 15, 23),
	panel  = Color3.fromRGB(28, 31, 43),
	panel2 = Color3.fromRGB(44, 49, 67),
	stroke = Color3.fromRGB(120, 130, 158),
	text   = Color3.fromRGB(244, 246, 252),
	muted  = Color3.fromRGB(148, 155, 178),
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

-- ── diagnostics ─────────────────────────────────────────────────────────────

local function stage(msg)
	print("[olltaterfx] " .. msg)
end

-- ── scaffolding ─────────────────────────────────────────────────────────────

local function new(cls, props, parent)
	local inst = Instance.new(cls)
	for k, v in pairs(props or {}) do
		pcall(function() inst[k] = v end)
	end
	if parent then
		local ok = pcall(function() inst.Parent = parent end)
		if not ok then
			warn("[olltaterfx] parent failed for " .. cls)
		end
	end
	return inst
end

local function round(parent, px)
	new("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function edge(parent, color, alpha, thick)
	new("UIStroke", {
		Color = color or PAL.stroke,
		Transparency = alpha or 0.4,
		Thickness = thick or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function shade(c, f)
	return Color3.new(
		math.clamp(c.R + f, 0, 1),
		math.clamp(c.G + f, 0, 1),
		math.clamp(c.B + f, 0, 1)
	)
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

-- ── mount ───────────────────────────────────────────────────────────────────

local function mount(gui)
	local attempts = {}

	attempts[#attempts+1] = function()
		if type(gethui) == "function" then
			local ok, c = pcall(gethui)
			if ok and c then return c, "gethui" end
		end
		return nil
	end

	attempts[#attempts+1] = function()
		local ok, c = pcall(function() return game:GetService("CoreGui") end)
		if ok and c then return c, "coregui" end
		return nil
	end

	attempts[#attempts+1] = function()
		local ok, c = pcall(function() return LP:WaitForChild("PlayerGui", 8) end)
		if ok and c then return c, "playergui" end
		return nil
	end

	for _, fn in ipairs(attempts) do
		local ok, parent, label = pcall(fn)
		if ok and parent then
			if type(syn) == "table" and type(syn.protect_gui) == "function" then
				pcall(function() syn.protect_gui(gui) end)
			end
			local placed = pcall(function() gui.Parent = parent end)
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
	local parent = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui", 8)
	if not parent then
		warn("[olltaterfx] no gui parent at all")
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "fx_error"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100000
	gui.Parent = parent

	local card = new("Frame", {
		Size = UDim2.fromOffset(520, 200),
		Position = UDim2.new(0.5, -260, 0.5, -100),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BorderSizePixel = 0,
		Parent = gui,
	})
	round(card, 16)
	edge(card, PAL.red, 0.4, 2)

	new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, 10),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = PAL.red,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "olltaterfx shell failed to build",
		Parent = card,
	})

	new("TextLabel", {
		Size = UDim2.new(1, -24, 1, -48),
		Position = UDim2.fromOffset(12, 36),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = PAL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = tostring(err),
		Parent = card,
	})
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

-- ── hitbox state ────────────────────────────────────────────────────────────

local originals = setmetatable({}, { __mode = "k" })
local boxes = {}
local boxRoot
local boxParentRef

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

local function boxContainer()
	if boxRoot and boxRoot.Parent then return boxRoot end
	if not boxParentRef then return nil end
	local ok, folder = pcall(function()
		local f = Instance.new("Folder")
		f.Name = rname(10)
		f.Parent = boxParentRef
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
	local parent = boxContainer()
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

-- ── build ───────────────────────────────────────────────────────────────────

local unload

local function lockLandscape()
	pcall(function() setorientation("LandscapeLeft") end)
	pcall(function() setorientation("LandscapeSensor") end)
	pcall(function()
		local gs = game:GetService("UserSettings"):GetService("UserGameSettings")
		gs.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
end

local function build()
	-- gate: warn only, never block the shell
	if CONFIG.mobileOnly and not UserInputService.TouchEnabled then
		warn("[olltaterfx] desktop client detected :: running anyway")
	end

	local gui = new("ScreenGui", {
		Name = S.randomNames and rname() or "fx_shell",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 100000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = true,
	})
	if not gui then
		error("ScreenGui creation failed")
	end

	local mounted = mount(gui)
	if not mounted then
		error("could not mount ScreenGui on gethui / CoreGui / PlayerGui")
	end

	-- container used by adornments
	boxParentRef = gui.Parent

	local blur = new("BlurEffect", { Name = rname(8), Size = CONFIG.blurSize, Enabled = S.blur }, Lighting)

	local shell = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = gui,
	})
	local uiScale = new("UIScale", { Scale = S.scale }, shell)

	local vp = workspace.CurrentViewportSize
	local winW = math.clamp(math.floor((vp.X > 0 and vp.X or 900) * 0.70), 520, 820)
	local winH = math.clamp(math.floor((vp.Y > 0 and vp.Y or 420) * 0.80), 280, 430)

	-- soft shadow
	local shadow = new("Frame", {
		Size = UDim2.fromOffset(winW, winH),
		Position = UDim2.new(0.5, -winW / 2, 0.5, -winH / 2 + 8),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Parent = shell,
	})
	round(shadow, 30)

	local win = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(winW, winH),
		BackgroundColor3 = PAL.bg,
		BackgroundTransparency = 0.10,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Parent = shell,
	})
	round(win, 30)
	edge(win, Color3.fromRGB(255, 255, 255), 0.72, 1.4)

	-- liquid glass body: static sheen + drifting highlight
	local sheenBody = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Parent = win,
	})
	round(sheenBody, 30)
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.74),
			NumberSequenceKeypoint.new(0.24, 1.0),
			NumberSequenceKeypoint.new(0.62, 0.97),
			NumberSequenceKeypoint.new(1, 0.90),
		}),
	}, sheenBody)

	local liquid = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Parent = win,
	})
	round(liquid, 30)
	local liquidGrad = new("UIGradient", {
		Rotation = 22,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 0.88),
			NumberSequenceKeypoint.new(0.50, 0.93),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, liquid)
	pcall(function()
		TweenService:Create(liquidGrad, TweenInfo.new(26, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), {
			Rotation = 382,
		}):Play()
	end)

	-- top hairline
	local hair = new("Frame", {
		Size = UDim2.new(1, -48, 0, 1),
		Position = UDim2.new(0, 24, 0, 46),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Parent = win,
	})

	-- header
	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
		Parent = win,
	})

	local grab = new("Frame", {
		Size = UDim2.fromOffset(40, 5),
		Position = UDim2.new(0.5, -20, 0, 8),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Parent = bar,
	})
	round(grab, 3)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 16),
		Position = UDim2.fromOffset(18, 17),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = PAL.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = CONFIG.title,
		Parent = bar,
	})

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 12),
		Position = UDim2.fromOffset(18, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 9,
		TextColor3 = PAL.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "place " .. CONFIG.place,
		Parent = bar,
	})

	local close = new("TextButton", {
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(1, -40, 0, 9),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.88,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	})
	round(close, 14)
	edge(close, Color3.fromRGB(255, 255, 255), 0.78, 1)
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
		Size = UDim2.fromOffset(90, winH - 62),
		Position = UDim2.fromOffset(10, 52),
		BackgroundTransparency = 1,
		Parent = win,
	})
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, side)

	-- content
	local contentHolder = new("Frame", {
		Size = UDim2.new(1, -122, 1, -62),
		Position = UDim2.fromOffset(110, 52),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = win,
	})

	-- ── components ──────────────────────────────────────────────────────────

	local function card(parent, height)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, height or 50),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.94,
			BorderSizePixel = 0,
			Parent = parent,
		})
		round(r, 16)
		edge(r, Color3.fromRGB(255, 255, 255), 0.86, 1)
		return r
	end

	local function page()
		local p = new("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255),
			ScrollBarImageTransparency = 0.6,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Visible = false,
			Parent = contentHolder,
		})
		new("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder }, p)
		new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 12) }, p)
		return p
	end

	local function section(parent, text)
		return new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			TextColor3 = PAL.yellow,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = string.upper(text),
			Parent = parent,
		})
	end

	local function caption(parent, label, sub)
		new("TextLabel", {
			Size = UDim2.new(1, -96, 0, sub and 15 or 18),
			Position = UDim2.fromOffset(16, sub and 10 or 0),
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
				Position = UDim2.fromOffset(16, 26),
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
			Size = UDim2.fromOffset(48, 28),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			BackgroundColor3 = initial and PAL.blue or Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = initial and 0.18 or 0.86,
			BorderSizePixel = 0,
			Parent = parent,
		})
		round(track, 14)
		edge(track, Color3.fromRGB(255, 255, 255), initial and 0.6 or 0.86, 1)

		local knob = new("Frame", {
			Size = UDim2.fromOffset(24, 24),
			AnchorPoint = Vector2.new(0, 0.5),
			Position = initial and UDim2.new(1, -26, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Parent = track,
		})
		round(knob, 12)
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(212, 218, 232)),
		}, knob)
		edge(knob, Color3.fromRGB(0, 0, 0), 0.82, 1)

		local on = initial

		local function set(v, silent)
			on = v
			TweenService:Create(track, TweenInfo.new(0.16), {
				BackgroundColor3 = on and PAL.blue or Color3.fromRGB(255, 255, 255),
				BackgroundTransparency = on and 0.18 or 0.86,
			}):Play()
			TweenService:Create(knob, TweenInfo.new(0.16), {
				Position = on and UDim2.new(1, -26, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
			}):Play()
			if not silent and callback then callback(on) end
		end

		local hit = new("TextButton", {
			Size = UDim2.fromScale(1.45, 1.7),
			Position = UDim2.new(-0.22, 0, -0.35, 0),
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
		local r = card(parent, sub and 50 or 44)
		caption(r, label, sub)
		switch(r, initial, callback)
		return r
	end

	local function sliderRow(parent, label, min, max, value, fmt, callback)
		fmt = fmt or function(v) return tostring(math.floor(v * 10 + 0.5) / 10) end

		local r = card(parent, 66)
		caption(r, label)

		local val = new("TextLabel", {
			Size = UDim2.new(0, 86, 0, 16),
			Position = UDim2.new(1, -102, 0, 9),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = PAL.blue,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = fmt(value),
			Parent = r,
		})

		local holder = new("Frame", {
			Size = UDim2.new(1, -32, 0, 28),
			Position = UDim2.fromOffset(16, 34),
			BackgroundTransparency = 1,
			Parent = r,
		})

		local rail = new("Frame", {
			Size = UDim2.new(1, 0, 0, 7),
			Position = UDim2.new(0, 0, 0.5, -3),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.84,
			BorderSizePixel = 0,
			Parent = holder,
		})
		round(rail, 4)
		edge(rail, Color3.fromRGB(255, 255, 255), 0.88, 1)

		local alpha0 = math.clamp((value - min) / (max - min), 0, 1)

		local fill = new("Frame", {
			Size = UDim2.new(alpha0, 0, 1, 0),
			BackgroundColor3 = PAL.blue,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
			Parent = rail,
		})
		round(fill, 4)
		new("UIGradient", {
			Rotation = 0,
			Color = ColorSequence.new(shade(PAL.blue, 0.16), PAL.blue),
		}, fill)
		edge(fill, PAL.blue, 0.45, 1.5)

		local halo = new("Frame", {
			Size = UDim2.fromOffset(26, 26),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(alpha0, 0, 0.5, 0),
			BackgroundColor3 = PAL.blue,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
			Parent = holder,
		})
		round(halo, 13)

		local knob = new("Frame", {
			Size = UDim2.fromOffset(18, 18),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(alpha0, 0, 0.5, 0),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Parent = holder,
		})
		round(knob, 9)
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(206, 213, 230)),
		}, knob)
		edge(knob, Color3.fromRGB(0, 0, 0), 0.78, 1)

		local dragging = false

		local function paint(v)
			local alpha = math.clamp((v - min) / (max - min), 0, 1)
			fill.Size = UDim2.new(alpha, 0, 1, 0)
			knob.Position = UDim2.new(alpha, 0, 0.5, 0)
			halo.Position = UDim2.new(alpha, 0, 0.5, 0)
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
		local r = card(parent, 54)
		caption(r, label, sub)
		local b = new("TextButton", {
			Size = UDim2.fromOffset(100, 32),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			BackgroundColor3 = color or PAL.blue,
			BackgroundTransparency = 0.15,
			Text = text,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			AutoButtonColor = false,
			Parent = r,
		})
		round(b, 16)
		new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(shade(color or PAL.blue, 0.14), shade(color or PAL.blue, -0.08)),
		}, b)
		edge(b, Color3.fromRGB(255, 255, 255), 0.72, 1)
		b.MouseButton1Click:Connect(callback)
		return r
	end

	-- ── pages ───────────────────────────────────────────────────────────────

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
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.93,
			Text = def.label,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			TextColor3 = PAL.muted,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = side,
		})
		round(b, 13)
		edge(b, Color3.fromRGB(255, 255, 255), 0.9, 1)
		tabButtons[def.id] = b
		pages[def.id] = page()
	end

	local function selectTab(id)
		for _, def in ipairs(tabDefs) do
			local b = tabButtons[def.id]
			local active = def.id == id
			b.BackgroundColor3 = active and PAL.blue or Color3.fromRGB(255, 255, 255)
			b.BackgroundTransparency = active and 0.16 or 0.93
			b.TextColor3 = active and Color3.fromRGB(255, 255, 255) or PAL.muted
			pages[def.id].Visible = active
		end
	end

	for _, def in ipairs(tabDefs) do
		tabButtons[def.id].MouseButton1Click:Connect(function() selectTab(def.id) end)
	end

	-- hit

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

	-- balls

	local pBall = pages.ball
	section(pBall, "state")
	toggleRow(pBall, "Ball HUD", "read GetBallState", S.ballHud, function(v)
		S.ballHud = v
		if hudFrame then hudFrame.Visible = v end
	end)
	toggleRow(pBall, "Auto hit", "fires HitBall at nearest ball part", S.autoHit, function(v)
		S.autoHit = v
	end)

	section(pBall, "ability")
	sliderRow(pBall, "Index", 1, #ABILITIES, S.abilityIndex, function(v)
		return ABILITIES[math.floor(v + 0.5)] or ABILITIES[1]
	end, function(v) S.abilityIndex = math.floor(v + 0.5) end)
	buttonRow(pBall, "Equip", "fires EquipAbility", "Equip", PAL.blue, equipAbility)

	-- spins

	local pSpin = pages.spin
	section(pSpin, "spin")
	toggleRow(pSpin, "Auto spin", "RequestSpin invoke", S.autoSpin, function(v) S.autoSpin = v end)
	sliderRow(pSpin, "Spin interval", 0.2, 3, S.spinDelay, function(v)
		return string.format("%.1fs", v)
	end, function(v) S.spinDelay = v end)
	toggleRow(pSpin, "Auto reward", "RequestRewardFromSpin", S.autoReward, function(v) S.autoReward = v end)
	sliderRow(pSpin, "Reward delay", 0.3, 5, S.rewardDelay, function(v)
		return string.format("%.1fs", v)
	end, function(v) S.rewardDelay = v end)

	section(pSpin, "claims")
	toggleRow(pSpin, "Daily reward", "ClaimDayReward", S.autoDaily, function(v) S.autoDaily = v end)
	toggleRow(pSpin, "Like reward", "ClaimLikeReward", S.autoLike, function(v) S.autoLike = v end)
	toggleRow(pSpin, "Quests", "ClaimQuest sweep", S.autoQuest, function(v) S.autoQuest = v end)
	toggleRow(pSpin, "Achievements", "ClaimAchievement sweep", S.autoAch, function(v) S.autoAch = v end)

	-- bypass

	local pByp = pages.bypass
	section(pByp, "transport")
	toggleRow(pByp, "Stealth mode", "jittered dispatch, token bucket", S.stealth, function(v) S.stealth = v end)
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
	toggleRow(pByp, "Debug log", "trace remote results", S.log, function(v) S.log = v end)

	-- config

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
		Size = UDim2.new(1, 0, 0, 138),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.93,
		BorderSizePixel = 0,
		Parent = pCfg,
	})
	round(logBox, 14)
	edge(logBox, Color3.fromRGB(255, 255, 255), 0.88, 1)
	logRef = new("TextLabel", {
		Size = UDim2.new(1, -18, 1, -14),
		Position = UDim2.fromOffset(9, 7),
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

	-- ── hud ─────────────────────────────────────────────────────────────────

	hudFrame = new("Frame", {
		Size = UDim2.fromOffset(236, 56),
		Position = UDim2.new(0, 12, 1, -70),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.90,
		BorderSizePixel = 0,
		Visible = S.ballHud,
		Parent = gui,
	})
	round(hudFrame, 16)
	edge(hudFrame, Color3.fromRGB(255, 255, 255), 0.84, 1)

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
		Position = UDim2.fromOffset(10, 24),
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

	-- ── orientation / fab ───────────────────────────────────────────────────

	local rotate = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.35,
		Visible = false,
		Parent = gui,
	})

	local rotCard = new("Frame", {
		Size = UDim2.fromOffset(260, 84),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.90,
		BorderSizePixel = 0,
		Parent = rotate,
	})
	round(rotCard, 18)
	edge(rotCard, Color3.fromRGB(255, 255, 255), 0.76, 1)
	new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = PAL.yellow,
		Text = "rotate to landscape",
		Parent = rotCard,
	})

	local fab = new("TextButton", {
		Size = UDim2.fromOffset(50, 50),
		Position = UDim2.new(1, -64, 1, -64),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.86,
		Text = "fx",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = PAL.text,
		AutoButtonColor = false,
		Visible = false,
		Parent = gui,
	})
	round(fab, 25)
	edge(fab, PAL.blue, 0.35, 2)

	local windowOpen = true

	local function refreshVisibility()
		local now = workspace.CurrentViewportSize
		local portrait = now.Y > now.X
		win.Visible = windowOpen and not portrait
		rotate.Visible = windowOpen and portrait
		fab.Visible = not windowOpen and not portrait
		if win.Visible then
			win.Position = UDim2.fromScale(0.5, 0.5)
		end
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

	-- ── drag ────────────────────────────────────────────────────────────────

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

	-- ── loops ───────────────────────────────────────────────────────────────

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

	-- ── teardown ────────────────────────────────────────────────────────────

	unload = function()
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
	gui.Enabled = true
	pushLog("shell up | " .. tostring(#Players:GetPlayers()) .. " players")

	task.defer(function()
		task.wait(0.25)
		if win.Visible and win.AbsoluteSize.X < 1 then
			local pg = LP:FindFirstChildOfClass("PlayerGui")
			if pg then
				pcall(function() gui.Parent = pg end)
				boxParentRef = pg
				stage("remounted to PlayerGui after empty render")
				if not win.Visible then
					win.Visible = true
				end
			end
		end
	end)

	stage("window built " .. winW .. "x" .. winH)
end

-- ── boot ────────────────────────────────────────────────────────────────────

local ok, err = xpcall(build, debug.traceback)
if not ok then
	warn("[olltaterfx] build failed: " .. tostring(err))
	pcall(fallback, err)
else
	pcall(lockLandscape)
	stage("ready")
end
