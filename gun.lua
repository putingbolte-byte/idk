--[[
    gun.lua
    liquid glass panel · mobile ready
    features: aim assist, triggerbot, esp (players + npcs), fov ring
    keybinds: RSHIFT toggle panel · RMB / C hold aim (PC) · touch always-aim (mobile)
    close: X button uses Activated so it works on mouse and touch
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
if not lp then return end

-- re-exec safety
if type(_G.__gunlua_cleanup) == "function" then
    pcall(_G.__gunlua_cleanup)
end

local connections = {}
local espEntries = {}
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

-- config

local cfg = {
    aim = false,
    trigger = false,
    esp = false,
    targetPlayers = true,
    targetNpcs = true,
    teamCheck = true,
    showFov = true,
    autoEquip = true,
    fov = 150,
    smooth = 10,
    triggerDelay = 120,
    triggerFov = 0,
    fireMode = "auto",
    ignoreList = {},
}

-- keys persisted to disk (ignoreList is serialized separately)
local SAVE_KEYS = {
    "aim", "trigger", "esp", "targetPlayers", "targetNpcs", "teamCheck",
    "showFov", "autoEquip", "fov", "smooth", "triggerDelay", "triggerFov",
    "fireMode",
}

local CONFIG_PATH = "gunlua_config.json"
local saveQueued = false

local function serializeConfig()
    local data = {}
    for _, key in ipairs(SAVE_KEYS) do
        data[key] = cfg[key]
    end
    local names = {}
    for name in pairs(cfg.ignoreList) do
        table.insert(names, name)
    end
    data.ignoreList = names

    local ok, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode(data)
    end)
    if ok and type(json) == "string" then
        return json
    end

    -- fallback: flat lua literal, same shape the loader accepts
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

-- debounced: sliders fire on every pixel of drag
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

    cfg.ignoreList = {}
    if type(data.ignoreList) == "table" then
        for _, name in ipairs(data.ignoreList) do
            if type(name) == "string" then
                cfg.ignoreList[name] = true
            end
        end
    end

    -- clamp anything a hand-edited file could have poisoned
    cfg.fov = math.clamp(tonumber(cfg.fov) or 150, 40, 420)
    cfg.smooth = math.clamp(tonumber(cfg.smooth) or 10, 1, 40)
    cfg.triggerDelay = math.clamp(tonumber(cfg.triggerDelay) or 120, 30, 400)
    cfg.triggerFov = math.clamp(tonumber(cfg.triggerFov) or 0, 0, 300)
    return true
end

-- restore before any UI is built, so sliders open on saved values
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

local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- resolver helpers

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- name of every player we must never touch (self + teammates)
local function isFriendly(plr)
    if not plr then
        return false
    end
    if plr == lp then
        return true
    end
    if cfg.ignoreList[plr.Name] then
        return true
    end
    if cfg.teamCheck then
        -- Team can be nil (FFA servers); only compare when both sides have one
        if lp.Team and plr.Team and plr.Team == lp.Team then
            return true
        end
    end
    return false
end

local function isValidTarget(model)
    if not model or model == lp.Character then
        return false
    end
    if not model:IsA("Model") then
        return false
    end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then
        return false
    end
    local plr = Players:GetPlayerFromCharacter(model)
    if plr then
        if isFriendly(plr) then
            return false
        end
        return cfg.targetPlayers
    end
    return cfg.targetNpcs
end

local npcCache = {}
local npcClock = 0

local function refreshNpcCache(dt)
    npcClock = npcClock + (dt or 0)
    if npcClock < 2 then
        return
    end
    npcClock = 0
    local list = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") then
            local hum = obj:FindFirstChildOfClass("Humanoid")
            if hum and not Players:GetPlayerFromCharacter(obj) then
                table.insert(list, obj)
            end
        end
    end
    npcCache = list
end

local function getTargets()
    local list = {}
    if cfg.targetPlayers then
        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr.Character
            if char and isValidTarget(char) then
                table.insert(list, char)
            end
        end
    end
    if cfg.targetNpcs then
        for _, model in ipairs(npcCache) do
            if model.Parent and isValidTarget(model) then
                table.insert(list, model)
            end
        end
    end
    return list
end

local function characterFromPart(part)
    local node = part
    while node and node ~= workspace do
        if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
            return node
        end
        node = node.Parent
    end
    return nil
end

local function isVisible(head, model)
    local cam = workspace.CurrentCamera
    if not cam then
        return false
    end
    local origin = cam.CFrame.Position
    local filter = { model }
    if lp.Character then
        table.insert(filter, lp.Character)
    end
    rayParams.FilterDescendantsInstances = filter
    local result = workspace:Raycast(origin, head.Position - origin, rayParams)
    return result == nil or result.Instance:IsDescendantOf(model)
end

local function getBestTarget(radius)
    local cam = workspace.CurrentCamera
    if not cam then
        return nil
    end
    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local best = nil
    local bestScore = radius or cfg.fov

    for _, model in ipairs(getTargets()) do
        local head = model:FindFirstChild("Head")
        if head and head:IsA("BasePart") then
            local screenPos, onScreen = cam:WorldToViewportPoint(head.Position)
            if onScreen and screenPos.Z > 0 then
                local dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                if dist <= bestScore and isVisible(head, model) then
                    best = head
                    bestScore = dist
                end
            end
        end
    end
    return best
end

-- firing
-- Strategy chain, because "the remote exists" does not mean bare
-- :FireServer() is what the game listens for. Most Roblox gun systems
-- fire on Tool:Activate() and never touch a remote at all.
--
-- order: equipped tool -> known remotes -> mouse fallback
-- mouse1click re-enters the input stack and crashes when spammed from a
-- Heartbeat loop, so it only ever runs as a detached one-shot.

local mouse = lp:GetMouse()
local fireAttempts = 0

local fireRemotes = {}
do
    local gunRemotes = ReplicatedStorage:FindFirstChild("GunRemotes")
    if gunRemotes then
        for _, child in ipairs(gunRemotes:GetChildren()) do
            if child:IsA("RemoteEvent")
                and string.find(string.lower(child.Name), "fire") then
                table.insert(fireRemotes, child)
            end
        end
    end
    -- common alternates in case the folder name differs
    if #fireRemotes == 0 then
        for _, child in ipairs(ReplicatedStorage:GetChildren()) do
            if child:IsA("RemoteEvent") then
                local lower = string.lower(child.Name)
                if lower == "fire" or lower == "shoot"
                    or lower == "fireweapon" or lower == "mouseclick" then
                    table.insert(fireRemotes, child)
                end
            end
        end
    end
end

local function equippedTool()
    local char = lp.Character
    if not char then
        return nil
    end
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then
        return tool
    end
    -- some builds parent the tool elsewhere
    return char:FindFirstChild("Tool")
end

local function backpackGun()
    local backpack = lp:FindFirstChildOfClass("Backpack")
    if not backpack then
        return nil
    end
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local lower = string.lower(tool.Name)
            if string.find(lower, "gun") or string.find(lower, "weapon")
                or string.find(lower, "rifle") or string.find(lower, "pistol")
                or string.find(lower, "sword") or string.find(lower, "blade") then
                return tool
            end
        end
    end
    return nil
end

local function tryEquip()
    if equippedTool() then
        return true
    end
    local gun = backpackGun()
    if not gun then
        return false
    end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if not hum then
        return false
    end
    pcall(function()
        hum:EquipTool(gun)
    end)
    return equippedTool() ~= nil
end

local firing = false
local lastFire = 0

-- argument shapes different servers expect; tried in rotation so one of
-- them lands without needing a settings menu for it
local function buildArgVariants(hitPos)
    local cam = workspace.CurrentCamera
    local camCFrame = cam and cam.CFrame or CFrame.new()
    local look = hitPos or (mouse and mouse.Hit and mouse.Hit.Position) or camCFrame.Position + camCFrame.LookVector * 100
    local aimCFrame = CFrame.lookAt(camCFrame.Position, look)
    return {
        {},
        { aimCFrame },
        { look },
        { camCFrame },
        { aimCFrame, look },
        { mouse and mouse.Hit or aimCFrame },
    }
end

local argIndex = 1

local function fireGun(hitPos)
    if firing then
        return false
    end

    local now = os.clock()
    if now - lastFire < 0.02 then
        return false
    end
    lastFire = now
    firing = true
    fireAttempts = fireAttempts + 1

    if cfg.autoEquip then
        tryEquip()
    end

    local tool = equippedTool()
    local mode = cfg.fireMode

    if tool and (mode == "auto" or mode == "tool") then
        pcall(function()
            tool:Activate()
        end)
    end

    if #fireRemotes > 0 and mode ~= "tool" then
        local variants = buildArgVariants(hitPos)
        local args = variants[((argIndex - 1) % #variants) + 1]
        argIndex = argIndex + 1
        local remote = fireRemotes[1]
        for _, candidate in ipairs(fireRemotes) do
            if string.lower(candidate.Name) == "fire" then
                remote = candidate
                break
            end
        end
        pcall(function()
            remote:FireServer(unpack(args))
        end)
    end

    if mode == "mouse" or (not tool and #fireRemotes == 0) then
        if type(mouse1click) == "function" then
            task.spawn(function()
                pcall(mouse1click)
            end)
        elseif type(VirtualInputManager) ~= "nil" then
            task.spawn(function()
                pcall(function()
                    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 1)
                    task.wait(0.02)
                    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 1)
                end)
            end)
        end
    end

    task.delay(0.03, function()
        firing = false
    end)
    return true
end

-- esp

local function buildEspEntry(char)
    local head = char:FindFirstChild("Head")
    if not head then
        return nil
    end
    local isPlayer = Players:GetPlayerFromCharacter(char) ~= nil
    local accent = isPlayer and COL.cyan or COL.danger

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "gunlua_esp"
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 600
    billboard.Size = UDim2.fromOffset(170, 42)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
    billboard.Adornee = head
    billboard.Parent = head

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Size = UDim2.new(1, 0, 0, 16)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 13
    nameLabel.TextColor3 = Color3.fromRGB(240, 244, 255)
    nameLabel.TextStrokeTransparency = 0.4
    nameLabel.Text = ""
    nameLabel.Parent = billboard

    local distLabel = Instance.new("TextLabel")
    distLabel.BackgroundTransparency = 1
    distLabel.Position = UDim2.fromOffset(0, 15)
    distLabel.Size = UDim2.new(1, 0, 0, 12)
    distLabel.Font = Enum.Font.GothamMedium
    distLabel.TextSize = 10
    distLabel.TextColor3 = accent
    distLabel.TextStrokeTransparency = 0.5
    distLabel.Text = ""
    distLabel.Parent = billboard

    local barBack = Instance.new("Frame")
    barBack.AnchorPoint = Vector2.new(0.5, 1)
    barBack.Position = UDim2.new(0.5, 0, 1, 0)
    barBack.Size = UDim2.fromOffset(96, 4)
    barBack.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    barBack.BackgroundTransparency = 0.35
    barBack.BorderSizePixel = 0
    barBack.Parent = billboard
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, barBack)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.fromScale(1, 1)
    barFill.BackgroundColor3 = accent
    barFill.BorderSizePixel = 0
    barFill.Parent = barBack
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, barFill)
    create("UIGradient", { Color = ColorSequence.new(accent, COL.violet) }, barFill)

    local highlight = Instance.new("Highlight")
    highlight.Name = "gunlua_hl"
    highlight.Adornee = char
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = accent
    highlight.FillTransparency = 0.75
    highlight.OutlineColor = accent
    highlight.OutlineTransparency = 0.25
    highlight.Parent = char

    return {
        billboard = billboard,
        nameLabel = nameLabel,
        distLabel = distLabel,
        barFill = barFill,
        highlight = highlight,
    }
end

local function destroyEspEntry(char)
    local entry = espEntries[char]
    if not entry then
        return
    end
    espEntries[char] = nil
    for _, obj in pairs(entry) do
        pcall(function()
            obj:Destroy()
        end)
    end
end

-- gui parent

local guiParent
do
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    if ok and hui then
        guiParent = hui
    else
        local ok2, coreGui = pcall(function()
            return game:GetService("CoreGui")
        end)
        guiParent = (ok2 and coreGui) or lp:WaitForChild("PlayerGui")
    end
end

for _, child in ipairs(guiParent:GetChildren()) do
    if child.Name == "gunlua" then
        pcall(function()
            child:Destroy()
        end)
    end
end

screen = Instance.new("ScreenGui")
screen.Name = "gunlua"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9999
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = guiParent

-- fov ring

local fovRing = create("Frame", {
    Name = "fov",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(300, 300),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

create("UICorner", { CornerRadius = UDim.new(1, 0) }, fovRing)
local fovStroke = create("UIStroke", {
    Thickness = 1.5,
    Color = COL.cyan,
    Transparency = 0.55,
}, fovRing)
create("UIGradient", {
    Color = ColorSequence.new(COL.cyan, COL.violet),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 0.8),
    }),
    Rotation = 45,
}, fovStroke)

local function refreshFov()
    fovRing.Visible = cfg.showFov
    local size = math.floor(cfg.fov * 2)
    fovRing.Size = UDim2.fromOffset(size, size)
end

-- ui helpers

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

-- layout order

local layoutIndex = 0
local function nextOrder()
    layoutIndex = layoutIndex + 1
    return layoutIndex
end

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
    create("UIPadding", { PaddingLeft = UDim.new(0, 6) }, label)
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
    row.Activated:Connect(function()
        cfg[key] = not cfg[key]
        render()
        queueSave()
        if onChange then
            onChange(cfg[key])
        end
    end)

    track(row.MouseEnter:Connect(function()
        tween(row, { BackgroundTransparency = 0.88 }, 0.12)
    end))
    track(row.MouseLeave:Connect(function()
        tween(row, { BackgroundTransparency = 0.94 }, 0.12)
    end))

    addRipple(row, COL.cyan)
    render()
    return row
end

local function makeSliderRow(parent, title, key, min, max, initial, suffix, onChange)
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

    local valueLabel = create("TextLabel", {
        Position = UDim2.new(1, -72, 0, 4),
        Size = UDim2.fromOffset(58, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(initial) .. suffix,
    }, row)

    local trackBar = create("Frame", {
        Position = UDim2.fromOffset(14, 40),
        Size = UDim2.new(1, -28, 0, 4),
        BackgroundColor3 = Color3.fromRGB(64, 70, 92),
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
    }, row)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

    local fraction = (initial - min) / (max - min)
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

    local function setValue(value, fire)
        value = math.clamp(math.floor(value + 0.5), min, max)
        cfg[key] = value
        local f = (value - min) / (max - min)
        fill.Size = UDim2.fromScale(f, 1)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valueLabel.Text = tostring(value) .. suffix
        if fire and onChange then
            onChange(value)
        end
        if fire then
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

    return row
end

-- panel

local panel = create("Frame", {
    Name = "panel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(292, 470),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

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

local header = create("TextButton", {
    Size = UDim2.new(1, 0, 0, 50),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
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
    Text = "gun.lua",
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
    Text = "RSHIFT · drag",
}, footer)

local function refreshStatus()
    local parts = {}
    if cfg.aim then table.insert(parts, "AIM") end
    if cfg.trigger then table.insert(parts, "TRIGGER") end
    if cfg.esp then table.insert(parts, "ESP") end
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

addSection(content, "COMBAT")
makeToggleRow(content, "Aim assist", "Smooth camera lock on closest target", "aim", refreshStatus)
makeToggleRow(content, "Triggerbot", "Fires when the crosshair is on a target", "trigger", refreshStatus)
makeToggleRow(content, "Team check", "Never target you or your teammates", "teamCheck", nil)
makeToggleRow(content, "Auto-equip gun", "Equips a gun tool before firing", "autoEquip", nil)
makeSliderRow(content, "Trigger delay", "triggerDelay", 30, 400, cfg.triggerDelay, "ms", nil)
makeSliderRow(content, "Trigger radius", "triggerFov", 0, 300, cfg.triggerFov, "px", nil)

addSection(content, "VISION")
makeToggleRow(content, "ESP", "Names, health and distance", "esp", refreshStatus)
makeToggleRow(content, "Target players", "Include players in aim and esp", "targetPlayers", nil)
makeToggleRow(content, "Target NPCs", "Include range dummies and enemies", "targetNpcs", nil)

addSection(content, "TUNING")
makeSliderRow(content, "FOV radius", "fov", 40, 420, cfg.fov, "px", function()
    refreshFov()
end)
makeSliderRow(content, "Aim smoothing", "smooth", 1, 40, cfg.smooth, "", nil)
makeToggleRow(content, "FOV ring", "Draw the aim radius on screen", "showFov", function()
    refreshFov()
end)

addSection(content, "CONFIG")

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

    create("TextLabel", {
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

    local descLabel = row:FindFirstChildOfClass("TextLabel")

    row.Activated:Connect(function()
        onPress(row, descLabel)
    end)
    addRipple(row, COL.violet)
    return row, descLabel
end

local _, saveDesc = makeActionRow(
    content,
    "Save config now",
    configLoaded and "Loaded from gunlua_config.json" or "No saved config found",
    function(_, desc)
        local ok = saveConfig()
        if desc then
            desc.Text = ok and "Saved to gunlua_config.json" or "writefile unavailable here"
            desc.TextColor3 = ok and COL.cyan or COL.danger
        end
    end
)

makeActionRow(content, "Reset config", "Back to defaults, then save", function(_, desc)
    cfg.aim = false
    cfg.trigger = false
    cfg.esp = false
    cfg.targetPlayers = true
    cfg.targetNpcs = true
    cfg.teamCheck = true
    cfg.showFov = true
    cfg.autoEquip = true
    cfg.fov = 150
    cfg.smooth = 10
    cfg.triggerDelay = 120
    cfg.triggerFov = 0
    cfg.fireMode = "auto"
    saveConfig()
    if desc then
        desc.Text = "Defaults saved — re-exec to apply"
        desc.TextColor3 = COL.cyan
    end
end)

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
closeButton.Activated:Connect(function()
    setOpen(false)
end)

-- floating launcher

local float = create("Frame", {
    Name = "float",
    Size = UDim2.fromOffset(52, 52),
    Position = UDim2.fromOffset(20, 220),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, screen)
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

        track(input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End and floatDragging then
                floatDragging = false
                if not floatMoved then
                    setOpen(not uiOpen)
                end
            end
        end))
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
        float.Position = UDim2.new(
            floatOrigin.X.Scale, floatOrigin.X.Offset + delta.X,
            floatOrigin.Y.Scale, floatOrigin.Y.Offset + delta.Y
        )
    end
end))

-- fit

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 28) / 292, (vp.Y - 28) / 470), 0.62, 1)
end

fit()
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
    end
end

-- aim state

local aimHeld = false

track(UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.RightShift then
        setOpen(not uiOpen)
    elseif input.UserInputType == Enum.UserInputType.MouseButton2
        or input.KeyCode == Enum.KeyCode.C then
        aimHeld = true
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2
        or input.KeyCode == Enum.KeyCode.C then
        aimHeld = false
    end
end))

-- aim loop

track(RunService.RenderStepped:Connect(function(dt)
    if not cfg.aim then
        return
    end
    if not isMobile and not aimHeld then
        return
    end
    local cam = workspace.CurrentCamera
    if not cam then
        return
    end
    local head = getBestTarget()
    if not head then
        return
    end

    local goal = CFrame.lookAt(cam.CFrame.Position, head.Position)
    local alpha = 1 - math.exp(-dt * cfg.smooth)
    cam.CFrame = cam.CFrame:Lerp(goal, math.clamp(alpha, 0, 1))
end))

-- triggerbot loop

local nextShot = 0
local trigFilter = {}
local trigCenter = Vector2.zero

track(RunService.Heartbeat:Connect(function()
    if not cfg.trigger then
        return
    end

    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum or hum.Health <= 0 then
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then
        return
    end

    local now = os.clock()
    local delay = math.max(cfg.triggerDelay, 30) / 1000
    if now < nextShot then
        return
    end

    -- reuse the filter table; rebuilding it every frame churns the GC
    if trigFilter[1] ~= char then
        table.clear(trigFilter)
        table.insert(trigFilter, char)
        rayParams.FilterDescendantsInstances = trigFilter
    end

    local vp = cam.ViewportSize
    trigCenter = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local ray = cam:ViewportPointToRay(trigCenter.X, trigCenter.Y)

    local hit = workspace:Raycast(ray.Origin, ray.Direction * 900, rayParams)

    -- crosshair-on-target path
    if hit then
        local target = characterFromPart(hit.Instance)
        if target and isValidTarget(target) then
            local head = target:FindFirstChild("Head")
            nextShot = now + delay
            fireGun(head and head.Position or hit.Position)
            return
        end
    end

    -- fallback: nearest valid target inside the trigger radius, so the
    -- trigger still works when the crosshair sits beside the hitbox
    if cfg.triggerFov > 0 then
        local head = getBestTarget(cfg.triggerFov)
        if head then
            nextShot = now + delay
            fireGun(head.Position)
        end
    end
end))

-- esp loop

local espClock = 0

track(RunService.Heartbeat:Connect(function(dt)
    refreshNpcCache(dt)

    if not cfg.esp then
        if next(espEntries) then
            for char in pairs(espEntries) do
                destroyEspEntry(char)
            end
        end
        return
    end

    espClock = espClock + dt
    if espClock < 0.1 then
        return
    end
    espClock = 0

    local cam = workspace.CurrentCamera
    if not cam then
        return
    end
    local camPos = cam.CFrame.Position

    local alive = {}
    for _, char in ipairs(getTargets()) do
        local head = char:FindFirstChild("Head")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if head and hum and hum.Health > 0 then
            alive[char] = true

            local entry = espEntries[char]
            if entry and not entry.billboard.Parent then
                destroyEspEntry(char)
                entry = nil
            end
            if not entry then
                entry = buildEspEntry(char)
                if entry then
                    espEntries[char] = entry
                end
            end

            if entry then
                local plr = Players:GetPlayerFromCharacter(char)
                entry.nameLabel.Text = plr and plr.DisplayName or char.Name
                entry.distLabel.Text = string.format("%dm", math.floor((head.Position - camPos).Magnitude))
                local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                entry.barFill.Size = UDim2.fromScale(frac, 1)
            end
        end
    end

    local stale = {}
    for char in pairs(espEntries) do
        if not alive[char] then
            table.insert(stale, char)
        end
    end
    for _, char in ipairs(stale) do
        destroyEspEntry(char)
    end
end))

-- boot

refreshNpcCache(3)
refreshFov()
refreshStatus()
setOpen(true)
fit()

-- first run writes a baseline so the file exists to hand-edit
if not configLoaded then
    saveConfig()
end

local function cleanup()
    pcall(saveConfig)
    for _, conn in ipairs(connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(connections)
    for char in pairs(espEntries) do
        destroyEspEntry(char)
    end
    if screen then
        pcall(function()
            screen:Destroy()
        end)
        screen = nil
    end
end

_G.__gunlua_cleanup = cleanup
