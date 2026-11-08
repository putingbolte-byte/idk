--[[
    heavens.lua
    landscape liquid-glass route runner · heaven's rod
    ui lineage: gun.lua / fisch.lua (palette, primitives, draggable, config)

    what it does
      · one tap per waypoint: 5 island buttons, 4 crystals, altar, vault,
        buy spot, grotto, expedition portal, avalanche totem
      · full auto route: teleport -> fire nearest prompt -> next, in order
      · chunked teleport (never one giant CFrame snap) + server remote hand-off
      · stealth governor: rate limit, jitter, per-step cooldowns, error backoff
      · ground snap after every hop so you don't land inside geometry

    keybinds: RSHIFT toggle · END panic · long-press launcher = panic
    mobile: auto-opens, horizontal tab strip, 48px touch targets
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")
local GuiService        = game:GetService("GuiService")

local lp = Players.LocalPlayer
if not lp then return end

if type(_G.__heavenslua_cleanup) == "function" then
    pcall(_G.__heavenslua_cleanup)
end

-- ============================================================
-- HELPERS
-- ============================================================

local connections = {}
-- forward declarations: the teleport engine runs before the UI exists,
-- so these stay locals with a nil value until the panel is built.
local running = true
local statusLabel

local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then inst[k] = v end
    end
    if parent then inst.Parent = parent end
    return inst
end

local function tween(inst, goal, time, style)
    local t = TweenService:Create(
        inst,
        TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        goal
    )
    t:Play()
    return t
end

local function isTouchDevice()
    local ok, val = pcall(function()
        return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    end)
    return ok and val or false
end

local function viewport()
    local cam = Workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

local function fmt(v)
    return string.format("%d, %d, %d", math.floor(v.X), math.floor(v.Y), math.floor(v.Z))
end

-- ============================================================
-- CONFIG
-- ============================================================

local cfg = {
    -- teleport
    useServerRemote = true,
    chunked         = true,
    hopSize         = 320,
    hopDelay        = 0.03,
    holdTime        = 0.25,
    yOffset         = 3,
    groundSnap      = true,
    -- route
    autoRoute       = false,
    stepDelay       = 1.2,
    promptRadius    = 26,
    skipYellow      = true,
    stopOnMissing   = false,
    -- stealth
    stealth         = true,
    jitter          = 0.15,
    rateLimit       = 14,
    -- ui
    tab             = "Route",
}

local CONFIG_PATH = "heavenslua_config.json"
local saveQueued = false

local SAVE_KEYS = {
    "useServerRemote", "chunked", "hopSize", "hopDelay", "holdTime",
    "yOffset", "groundSnap", "autoRoute", "stepDelay", "promptRadius",
    "skipYellow", "stopOnMissing", "stealth", "jitter", "rateLimit", "tab",
}

local function serializeConfig()
    local data = {}
    for _, k in ipairs(SAVE_KEYS) do data[k] = cfg[k] end
    local ok, json = pcall(function() return HttpService:JSONEncode(data) end)
    if ok and type(json) == "string" then return json end
    local parts = {"{"}
    for i, k in ipairs(SAVE_KEYS) do
        local v = cfg[k]
        local str
        if type(v) == "string" then
            str = '"' .. v .. '"'
        elseif type(v) == "boolean" then
            str = tostring(v)
        else
            str = tostring(tonumber(v) or 0)
        end
        parts[#parts + 1] = ('"%s":%s'):format(k, str)
        if i < #SAVE_KEYS then parts[#parts + 1] = "," end
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function() writefile(CONFIG_PATH, serializeConfig()) end)
end

local function queueSave()
    if saveQueued then return end
    saveQueued = true
    task.delay(0.6, function()
        saveQueued = false
        saveConfig()
    end)
end

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return false end
    local ok, raw = pcall(function()
        if isfile(CONFIG_PATH) then return readfile(CONFIG_PATH) end
    end)
    if not ok or type(raw) ~= "string" or #raw < 2 then return false end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then return false end
    for _, k in ipairs(SAVE_KEYS) do
        local v = data[k]
        if v ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
    end
    cfg.hopSize      = math.clamp(tonumber(cfg.hopSize) or 320, 80, 1200)
    cfg.hopDelay     = math.clamp(tonumber(cfg.hopDelay) or 0.03, 0.01, 0.4)
    cfg.holdTime     = math.clamp(tonumber(cfg.holdTime) or 0.25, 0, 2)
    cfg.yOffset      = math.clamp(tonumber(cfg.yOffset) or 3, -20, 60)
    cfg.stepDelay    = math.clamp(tonumber(cfg.stepDelay) or 1.2, 0.2, 10)
    cfg.promptRadius = math.clamp(tonumber(cfg.promptRadius) or 26, 6, 120)
    cfg.jitter       = math.clamp(tonumber(cfg.jitter) or 0.15, 0, 1)
    cfg.rateLimit    = math.clamp(tonumber(cfg.rateLimit) or 14, 1, 80)
    return true
end

loadConfig()

local COL = {
    bg     = Color3.fromRGB(14, 16, 24),
    text   = Color3.fromRGB(236, 240, 250),
    sub    = Color3.fromRGB(148, 157, 180),
    cyan   = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    pink   = Color3.fromRGB(255, 122, 198),
    danger = Color3.fromRGB(255, 108, 122),
    ok     = Color3.fromRGB(120, 240, 170),
    off    = Color3.fromRGB(40, 44, 58),
}

-- ============================================================
-- STEALTH GOVERNOR
-- ============================================================

local Bucket = { tokens = cfg.rateLimit, last = os.clock() }
local lastCall = {}
local errorStreak = {}

local function bucketRefill()
    local now = os.clock()
    Bucket.tokens = math.min(cfg.rateLimit, Bucket.tokens + (now - Bucket.last) * cfg.rateLimit)
    Bucket.last = now
end

local function jitterSleep()
    if not cfg.stealth then return end
    if cfg.jitter <= 0 then return end
    task.wait(math.random() * cfg.jitter)
end

local function gate(key, cooldown)
    if not cfg.stealth then return true end
    bucketRefill()
    if Bucket.tokens < 1 then return false end
    if os.clock() - (lastCall[key] or 0) < cooldown then return false end
    Bucket.tokens = Bucket.tokens - 1
    lastCall[key] = os.clock()
    jitterSleep()
    return true
end

local function noteError(key)
    errorStreak[key] = (errorStreak[key] or 0) + 1
    if errorStreak[key] > 5 then
        lastCall[key] = os.clock() + 8
    end
end

-- ============================================================
-- REMOTES
-- ============================================================

local Net
do
    local ok, folder = pcall(function()
        return ReplicatedStorage:WaitForChild("packages", 5):WaitForChild("Net", 5)
    end)
    Net = ok and folder or nil
end

local function remote(path)
    local head, tail = path:match("^(%a+)/(.+)$")
    if not head or not Net then return nil end
    local node = Net:FindFirstChild(head)
    if not node then return nil end
    local cur = node
    for seg in tail:gmatch("[^/]+") do
        cur = cur:FindFirstChild(seg)
        if not cur then return nil end
    end
    return cur
end

local TP = {
    cframe = remote("RF/RequestTeleportCFrame"),
    reveal = remote("RE/RequestTeleport"),
    fast   = remote("RE/FastTravel/Teleport"),
    elev   = remote("RF/ElevatorPrompt/RequestTeleport"),
    veil   = remote("RF/MarianasVeil/Teleport"),
}

-- ============================================================
-- WAYPOINTS
-- ============================================================

local WAYPOINTS = {
    { grp = "Buttons",  name = "Button 1 · Moosewood",        pos = Vector3.new(400, 136, 265) },
    { grp = "Buttons",  name = "Button 2 · Roslit Bay",       pos = Vector3.new(-1716, 149, 732) },
    { grp = "Buttons",  name = "Button 3 · Forsaken Shores",  pos = Vector3.new(-2566, 181, 1353) },
    { grp = "Buttons",  name = "Button 4 · Snowcap",          pos = Vector3.new(2930, 281, 2594) },
    { grp = "Buttons",  name = "Button 5 · Ancient Isle",     pos = Vector3.new(5506, 147, -315) },

    { grp = "Crystals", name = "Blue Crystal",                pos = Vector3.new(20125, 211, 5449) },
    { grp = "Crystals", name = "Green Crystal",               pos = Vector3.new(19873, 448, 5556) },
    { grp = "Crystals", name = "Yellow Crystal · avalanche",  pos = Vector3.new(19498, 335, 5553), optional = true },
    { grp = "Crystals", name = "Red Crystal · Hiker #12",     pos = Vector3.new(19920, 1140, 5350) },

    { grp = "Endgame",  name = "Crystal Puzzle Altar",        pos = Vector3.new(19986, 906, 5453) },
    { grp = "Endgame",  name = "Vault Door",                  pos = Vector3.new(19986, 906, 5453) },
    { grp = "Endgame",  name = "Heaven's Rod Buy Spot",       pos = Vector3.new(20209, 739, 5711) },
    { grp = "Endgame",  name = "Glacial Grotto Entrance",     pos = Vector3.new(20000, 1042, 5717) },
    { grp = "Endgame",  name = "Northern Expedition Portal",  pos = Vector3.new(-1750, 130, 3750) },
    { grp = "Endgame",  name = "Avalanche Totem",             pos = Vector3.new(19708, 467, 6058) },
}

-- ============================================================
-- TELEPORT ENGINE
-- ============================================================

local function getChar()
    local char = lp.Character
    return char
end

local function getRoot()
    local char = getChar()
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")
end

local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function unseat()
    local hum = getHumanoid()
    if hum and hum.Sit then
        pcall(function() hum.Sit = false end)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end
end

local function groundSnap(pos)
    if not cfg.groundSnap then return pos + Vector3.new(0, cfg.yOffset, 0) end
    local params = Instance.new("RaycastParams")
    -- default FilterType is already "exclude"; only pin it where the name exists
    pcall(function() params.FilterType = Enum.RaycastFilterType.Exclude end)
    local char = getChar()
    pcall(function()
        params.FilterDescendantsInstances = char and { char } or {}
    end)
    local hit = Workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -420, 0), params)
    if hit then
        return hit.Position + Vector3.new(0, cfg.yOffset, 0)
    end
    return pos + Vector3.new(0, cfg.yOffset, 0)
end

local function setCF(pos)
    local root = getRoot()
    if not root then return false end
    pcall(function()
        root.CFrame = CFrame.new(pos)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

-- server-side hand-off first: if the game grants the teleport, we never
-- touch the character transform at all, which is the cleanest signal.
local function tryServerTeleport(pos)
    if not cfg.useServerRemote then return false end
    if not gate("tp.server", 1.5) then return false end
    if TP.cframe then
        local shapes = {
            { pos, CFrame.new(pos) },
            { CFrame.new(pos) },
            { pos.X, pos.Y, pos.Z },
            { pos },
        }
        for _, args in ipairs(shapes) do
            local ok = pcall(function()
                TP.cframe:InvokeServer(table.unpack(args))
            end)
            if ok then return true end
            noteError("tp.server")
        end
    end
    return false
end

-- chunked local hop: splits the trip so no single frame carries a
-- 20,000-stud delta. this is the anti-flag part.
local function localTeleport(pos)
    local root = getRoot()
    if not root then return false, "no character" end
    unseat()

    local start = root.CFrame.Position
    local dist = (pos - start).Magnitude

    if cfg.chunked and dist > cfg.hopSize then
        local steps = math.clamp(math.ceil(dist / cfg.hopSize), 2, 40)
        for i = 1, steps do
            if not running then return false, "aborted" end
            local t = i / steps
            setCF(start:Lerp(pos, t))
            task.wait(cfg.hopDelay + math.random() * 0.02)
        end
    else
        setCF(pos)
    end

    -- hold: reassert for a moment in case the server snapped us back
    local deadline = os.clock() + cfg.holdTime
    while os.clock() < deadline do
        if not running then return false, "aborted" end
        local r = getRoot()
        if r and (r.Position - pos).Magnitude > 12 then
            setCF(pos)
        end
        task.wait(0.05)
    end
    return true
end

-- server hand-off, then verify; fall back to the chunked local hop.
-- the verify step matters: a RemoteFunction returning without error does
-- not mean the server moved us, so we measure before trusting it.
local function hopTo(target)
    if cfg.useServerRemote then
        if tryServerTeleport(target) then
            task.wait(0.5 + math.random() * 0.25)
            local root = getRoot()
            if root and (root.Position - target).Magnitude < 140 then
                return true, "server"
            end
        end
    end
    local ok, err = localTeleport(target)
    return ok, err
end

local function teleportTo(wp, quiet)
    if type(wp) == "table" and wp.pos then
        local target = groundSnap(wp.pos)
        local ok, err = hopTo(target)
        if ok and not quiet and statusLabel then
            statusLabel.Text = "arrived · " .. wp.name
        end
        return ok, err
    elseif typeof(wp) == "Vector3" then
        local target = groundSnap(wp)
        local ok, err = hopTo(target)
        if ok and not quiet and statusLabel then
            statusLabel.Text = "arrived · " .. fmt(wp)
        end
        return ok, err
    end
    return false, "bad waypoint"
end

-- ============================================================
-- PROMPTS
-- ============================================================

local promptCache = {}
local promptCacheAt = 0

local function rebuildPromptCache()
    promptCache = {}
    local world = Workspace:FindFirstChild("world") or Workspace
    local ok = pcall(function()
        for _, d in ipairs(world:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                table.insert(promptCache, d)
            end
        end
    end)
    if not ok or #promptCache == 0 then
        pcall(function()
            for _, d in ipairs(Workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    table.insert(promptCache, d)
                end
            end
        end)
    end
    promptCacheAt = os.clock()
end

local function promptPos(p)
    local host = p.Parent
    if not host then return nil end
    local ok, pos = pcall(function()
        if host:IsA("BasePart") then return host.Position end
        if host:IsA("Model") then
            local part = host.PrimaryPart or host:FindFirstChildWhichIsA("BasePart")
            return part and part.Position or nil
        end
        local part = host:FindFirstChildWhichIsA("BasePart", true)
        return part and part.Position or nil
    end)
    return ok and pos or nil
end

local function firePrompt(p)
    local ok = pcall(function()
        if type(fireproximityprompt) == "function" then
            fireproximityprompt(p)
        else
            p:InputHoldBegin()
            task.wait(0.06)
            p:InputHoldEnd()
        end
    end)
    return ok
end

local function fireNearbyPrompts(radius)
    local root = getRoot()
    if not root then return 0 end
    if os.clock() - promptCacheAt > 5 then rebuildPromptCache() end

    local origin = root.Position
    local fired = 0
    for _, p in ipairs(promptCache) do
        if p.Parent and p.Enabled then
            local pos = promptPos(p)
            if pos and (pos - origin).Magnitude <= radius then
                if firePrompt(p) then
                    fired = fired + 1
                    task.wait(0.1 + math.random() * 0.12)
                end
            end
        end
    end
    return fired
end

-- ============================================================
-- BEACON
-- ============================================================

local beaconFolder
do
    local ok, hui = pcall(function() return gethui and gethui() end)
    local parent
    if ok and hui then
        parent = hui
    else
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        parent = (ok2 and cg) or lp:WaitForChild("PlayerGui")
    end
    for _, c in ipairs(parent:GetChildren()) do
        if c.Name == "heavens_beacon" then pcall(function() c:Destroy() end) end
    end
    beaconFolder = create("Folder", { Name = "heavens_beacon" }, parent)
end

local beacon
local beaconAnchor

local function clearBeacon()
    if beacon then pcall(function() beacon:Destroy() end) beacon = nil end
    if beaconAnchor then pcall(function() beaconAnchor:Destroy() end) beaconAnchor = nil end
end

local function showBeacon(wp)
    clearBeacon()
    if not wp then return end

    local anchor = create("Part", {
        Name = "heavens_beacon_anchor",
        Size = Vector3.new(2, 2, 2),
        Transparency = 1,
        CanCollide = false,
        CanQuery = false,
        CanTouch = false,
        Anchored = true,
        CFrame = CFrame.new(wp.pos),
    }, Workspace)

    beaconAnchor = anchor

    beacon = create("BillboardGui", {
        Name = "beacon",
        Size = UDim2.fromOffset(190, 40),
        AlwaysOnTop = true,
        StudsOffset = Vector3.new(0, 8, 0),
        Adornee = anchor,
    }, beaconFolder)

    create("TextLabel", {
        Size = UDim2.new(1, 0, 0.6, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = COL.cyan,
        TextStrokeTransparency = 0.5,
        Text = wp.name,
    }, beacon)

    create("TextLabel", {
        Position = UDim2.new(0, 0, 0.6, 0),
        Size = UDim2.new(1, 0, 0.4, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = COL.sub,
        Text = fmt(wp.pos),
    }, beacon)

    beacon.Destroying:Connect(function()
        pcall(function() anchor:Destroy() end)
    end)
end

-- ============================================================
-- ROUTE RUNNER
-- ============================================================

local routeThread = nil
local currentIndex = 0

local function routeList()
    local out = {}
    for _, wp in ipairs(WAYPOINTS) do
        if not (wp.optional and cfg.skipYellow) then
            table.insert(out, wp)
        end
    end
    return out
end

local function runRoute()
    if routeThread then return end
    routeThread = task.spawn(function()
        cfg.autoRoute = true
        local list = routeList()
        statusLabel.Text = "route · " .. #list .. " steps"
        for i, wp in ipairs(list) do
            if not running or not cfg.autoRoute then break end
            currentIndex = i
            statusLabel.Text = string.format("step %d/%d · %s", i, #list, wp.name)
            local ok = teleportTo(wp, true)
            if ok then
                task.wait(0.35 + math.random() * 0.2)
                local fired = fireNearbyPrompts(cfg.promptRadius)
                if fired == 0 and cfg.stopOnMissing then
                    statusLabel.Text = "stopped · no prompt at " .. wp.name
                    break
                end
            end
            task.wait(cfg.stepDelay)
        end
        cfg.autoRoute = false
        routeThread = nil
        statusLabel.Text = "route finished"
    end)
end

local function stopRoute()
    cfg.autoRoute = false
    routeThread = nil
    statusLabel.Text = "route stopped"
end

-- beacon follows the active step during a run
track(RunService.Heartbeat:Connect(function()
    if cfg.autoRoute and currentIndex > 0 then
        local list = routeList()
        local wp = list[currentIndex]
        if wp and (not beacon or not beacon.Parent) then
            showBeacon(wp)
        end
    end
end))

-- ============================================================
-- UI
-- ============================================================

local guiParent
do
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then
        guiParent = hui
    else
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        guiParent = (ok2 and cg) or lp:WaitForChild("PlayerGui")
    end
end

for _, c in ipairs(guiParent:GetChildren()) do
    if c.Name == "heavenslua" then pcall(function() c:Destroy() end) end
end

local screen = create("ScreenGui", {
    Name = "heavenslua",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(screen) end
    if protectgui then protectgui(screen) end
end)

local PANEL_W, PANEL_H = 620, 400

local panel = create("Frame", {
    Name = "panel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(PANEL_W, PANEL_H),
    BackgroundTransparency = 1,
    Visible = true,
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
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 1,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)
create("UIStroke", {
    Color = Color3.fromRGB(255, 255, 255),
    Transparency = 0.9,
    Thickness = 1,
}, body)

local sheen = create("Frame", {
    Size = UDim2.new(1, 0, 0, 120),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.96,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, sheen)
create("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.9),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Rotation = 90,
}, sheen)

local orbA = create("Frame", {
    Position = UDim2.fromOffset(-40, -60),
    Size = UDim2.fromOffset(220, 220),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbA)

local orbB = create("Frame", {
    Position = UDim2.new(1, -180, 1, -160),
    Size = UDim2.fromOffset(240, 240),
    BackgroundColor3 = COL.violet,
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbB)

local header = create("Frame", {
    Position = UDim2.fromOffset(0, 0),
    Size = UDim2.new(1, 0, 0, 56),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local logo = create("Frame", {
    Position = UDim2.fromOffset(18, 14),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.85,
    BorderSizePixel = 0,
    ZIndex = 4,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 8) }, logo)
create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet) }, logo)

create("TextLabel", {
    Position = UDim2.fromOffset(56, 11),
    Size = UDim2.fromOffset(260, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "heaven's rod · route",
    ZIndex = 4,
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(56, 29),
    Size = UDim2.fromOffset(320, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "chunked teleport · stealth governor on",
    ZIndex = 4,
}, header)

local grip = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 6),
    Size = UDim2.fromOffset(56, 5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.72,
    BorderSizePixel = 0,
    ZIndex = 11,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, grip)

local statusDot = create("Frame", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -72, 0.5, 0),
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = COL.ok,
    BorderSizePixel = 0,
    ZIndex = 4,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, statusDot)

local closeBtn = create("TextButton", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.5, 0),
    Size = UDim2.fromOffset(36, 36),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    Text = "✕",
    Font = Enum.Font.GothamMedium,
    TextSize = 14,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    ZIndex = 5,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 10) }, closeBtn)
closeBtn.Activated:Connect(function() panel.Visible = false end)

local rail = create("Frame", {
    Position = UDim2.fromOffset(14, 66),
    Size = UDim2.new(0, 132, 1, -80),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local railLayout = create("UIListLayout", {
    Padding = UDim.new(0, 6),
    FillDirection = Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, rail)

local contentHolder = create("Frame", {
    Position = UDim2.fromOffset(156, 66),
    Size = UDim2.new(1, -170, 1, -80),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local scroll = create("ScrollingFrame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 8,
    ScrollBarImageColor3 = COL.cyan,
    ScrollBarImageTransparency = 0.3,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, contentHolder)
pcall(function() scroll.ElasticBehavior = Enum.ElasticBehavior.Never end)
pcall(function() scroll.ScrollingDirection = Enum.ScrollingDirection.Y end)

local content = create("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    BackgroundTransparency = 1,
    AutomaticSize = Enum.AutomaticSize.Y,
    ZIndex = 3,
}, scroll)

create("UIListLayout", {
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, content)

local footer = create("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 156, 1, -14),
    Size = UDim2.new(1, -170, 0, 18),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

statusLabel = create("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "bench warm · ready",
}, footer)

-- ============================================================
-- PRIMITIVES
-- ============================================================

local orderCounter = 0
local function nextOrder()
    orderCounter = orderCounter + 1
    return orderCounter
end

local function addSection(parent, title)
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(title),
        LayoutOrder = nextOrder(),
    }, parent)
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, parent)
end

local function makeSwitch(parent, initial, onChange)
    local holder = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.fromOffset(46, 24),
        BackgroundColor3 = initial and COL.cyan or COL.off,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, holder)

    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 5,
    }, holder)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

    local hit = create("TextButton", {
        Size = UDim2.new(1, 16, 1, 16),
        Position = UDim2.fromOffset(-8, -8),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 6,
    }, holder)

    local state = initial
    hit.Activated:Connect(function()
        state = not state
        tween(holder, { BackgroundColor3 = state and COL.cyan or COL.off }, 0.14)
        tween(knob, {
            Position = state and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
        }, 0.14)
        onChange(state)
        queueSave()
    end)
    return holder
end

local function rowShell(parent, height)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, height or 52),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.92,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        ZIndex = 3,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.92,
        Thickness = 1,
    }, row)
    return row
end

local function makeToggleRow(parent, title, desc, key)
    local row = rowShell(parent, 52)
    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -88, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)
    create("TextLabel", {
        Position = UDim2.fromOffset(14, 27),
        Size = UDim2.new(1, -88, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)
    makeSwitch(row, cfg[key], function(v) cfg[key] = v end)
    return row
end

local function makeSliderRow(parent, title, desc, key, min, max, isFloat)
    local row = rowShell(parent, 68)
    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -110, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    local valLabel = create("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 8),
        Size = UDim2.fromOffset(80, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(cfg[key]),
        ZIndex = 4,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 26),
        Size = UDim2.new(1, -28, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)

    local trackBar = create("Frame", {
        Position = UDim2.fromOffset(14, 48),
        Size = UDim2.new(1, -28, 0, 8),
        BackgroundColor3 = COL.off,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, row)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

    local rel0 = (cfg[key] - min) / (max - min)

    local fill = create("Frame", {
        Size = UDim2.new(rel0, 0, 1, 0),
        BackgroundColor3 = COL.cyan,
        BorderSizePixel = 0,
        ZIndex = 5,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)

    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(rel0, 0, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = COL.text,
        BorderSizePixel = 0,
        ZIndex = 7,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
    create("UIStroke", { Color = COL.cyan, Transparency = 0.25, Thickness = 2 }, knob)

    local hit = create("TextButton", {
        Position = UDim2.fromOffset(0, 34),
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 8,
    }, row)

    local dragging = false
    local function apply(x)
        local rel = math.clamp((x - trackBar.AbsolutePosition.X) / math.max(1, trackBar.AbsoluteSize.X), 0, 1)
        local raw = min + (max - min) * rel
        local v = isFloat and math.floor(raw * 100) / 100 or math.floor(raw + 0.5)
        cfg[key] = v
        valLabel.Text = isFloat and string.format("%.2f", v) or tostring(v)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        knob.Position = UDim2.new(rel, 0, 0.5, 0)
        queueSave()
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            apply(input.Position.X)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            apply(input.Position.X)
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

local function makeActionRow(parent, title, desc, onPress)
    local row = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.92,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = nextOrder(),
        ZIndex = 3,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.92,
        Thickness = 1,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -28, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 27),
        Size = UDim2.new(1, -28, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)

    row.Activated:Connect(function()
        onPress()
        queueSave()
    end)
    return row
end

local function makeInputRow(parent, title, desc, getValue, setValue)
    local row = rowShell(parent, 56)
    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(0.45, -20, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    local box = create("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.new(0.5, -10, 0, 38),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.9,
        BorderSizePixel = 0,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = COL.cyan,
        Text = getValue(),
        PlaceholderText = desc or "",
        PlaceholderColor3 = COL.sub,
        ClearTextOnFocus = false,
        ZIndex = 4,
    }, row)
    create("UICorner", { CornerRadius = UDim.new(0, 9) }, box)
    create("UIStroke", { Color = COL.cyan, Transparency = 0.8, Thickness = 1 }, box)

    box.FocusLost:Connect(function()
        setValue(box.Text)
    end)
    return row
end

-- ============================================================
-- TABS
-- ============================================================

local tabButtons = {}
local tabOrder = {}
local pages = {}

local function clearContent()
    for _, c in ipairs(content:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    orderCounter = 0
end

local function selectTabVisual(activeName)
    for name, btn in pairs(tabButtons) do
        local active = (name == activeName)
        tween(btn, { BackgroundTransparency = active and 0.86 or 0.94 }, 0.14)
        local accent = btn:FindFirstChild("accent")
        if accent then
            tween(accent, { BackgroundTransparency = active and 0 or 1 }, 0.14)
        end
        local lbl = btn:FindFirstChildOfClass("TextLabel")
        if lbl then
            tween(lbl, { TextColor3 = active and COL.text or COL.sub }, 0.14)
        end
    end
end

local function showTab(name)
    if not pages[name] then name = tabOrder[1] end
    clearContent()
    cfg.tab = name
    queueSave()
    selectTabVisual(name)
    pages[name]()
end

local function makeTabButton(name, label)
    table.insert(tabOrder, name)
    local btn = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = #tabOrder,
        ZIndex = 3,
    }, rail)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, btn)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.94,
        Thickness = 1,
    }, btn)

    local accent = create("Frame", {
        Name = "accent",
        Position = UDim2.fromOffset(0, 11),
        Size = UDim2.fromOffset(3, 20),
        BackgroundColor3 = COL.cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, btn)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, accent)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -20, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
        ZIndex = 4,
    }, btn)

    btn.Activated:Connect(function() showTab(name) end)
    tabButtons[name] = btn
    return btn
end

-- ============================================================
-- PAGES
-- ============================================================

local function waypointRow(wp)
    local tag = wp.optional and "  ·  optional" or ""
    return makeActionRow(content, wp.name, fmt(wp.pos) .. tag, function()
        statusLabel.Text = "hopping · " .. wp.name
        showBeacon(wp)
        local ok, err = teleportTo(wp, true)
        if ok then
            task.wait(0.3)
            local fired = fireNearbyPrompts(cfg.promptRadius)
            statusLabel.Text = string.format("arrived · %s · %d prompt%s",
                wp.name, fired, fired == 1 and "" or "s")
        else
            statusLabel.Text = "failed · " .. tostring(err)
        end
    end)
end

pages.Route = function()
    for _, grp in ipairs({ "Buttons", "Crystals", "Endgame" }) do
        local any = false
        for _, wp in ipairs(WAYPOINTS) do
            if wp.grp == grp then
                if not any then
                    addSection(content, grp == "Endgame" and "finale" or grp)
                    any = true
                end
                waypointRow(wp)
            end
        end
    end
end

pages.Sequence = function()
    addSection(content, "auto route")
    makeActionRow(content, "Run Full Route", "teleport + press every prompt in order", function()
        currentIndex = 0
        runRoute()
    end)
    makeActionRow(content, "Stop Route", "abort at the current step", function()
        stopRoute()
    end)
    makeActionRow(content, "Press Prompts Here", "fire whatever is nearby right now", function()
        local n = fireNearbyPrompts(cfg.promptRadius)
        statusLabel.Text = string.format("fired %d prompt%s", n, n == 1 and "" or "s")
    end)

    addSection(content, "behaviour")
    makeToggleRow(content, "Skip Yellow Crystal", "avalanche-only step", "skipYellow")
    makeToggleRow(content, "Stop If No Prompt", "halt when a step finds nothing", "stopOnMissing")
    makeSliderRow(content, "Step Delay", "wait between route steps", "stepDelay", 0.4, 5, true)
    makeSliderRow(content, "Prompt Radius", "studs around you to search", "promptRadius", 8, 80)
end

pages.Teleport = function()
    addSection(content, "transport")
    makeToggleRow(content, "Server Teleport First", "ask the game before moving locally", "useServerRemote")
    makeToggleRow(content, "Chunked Hop", "split long trips into short steps", "chunked")
    makeToggleRow(content, "Ground Snap", "raycast down after arrival", "groundSnap")
    makeSliderRow(content, "Hop Size", "max studs per chunk", "hopSize", 80, 1200)
    makeSliderRow(content, "Hop Delay", "seconds between chunks", "hopDelay", 0.01, 0.4, true)
    makeSliderRow(content, "Hold Time", "reassert position for this long", "holdTime", 0, 2, true)
    makeSliderRow(content, "Y Offset", "lift above the surface", "yOffset", -20, 60)

    addSection(content, "custom target")
    local xBox, yBox, zBox
    xBox = makeInputRow(content, "X", "0", function() return "0" end, function() end)
    yBox = makeInputRow(content, "Y", "0", function() return "0" end, function() end)
    zBox = makeInputRow(content, "Z", "0", function() return "0" end, function() end)
    makeActionRow(content, "Teleport to Coordinates", "uses the three boxes above", function()
        local function num(row)
            local box = row:FindFirstChildOfClass("TextBox")
            return tonumber(box and box.Text or "0") or 0
        end
        local pos = Vector3.new(num(xBox), num(yBox), num(zBox))
        if pos.Magnitude < 1 then
            statusLabel.Text = "enter coordinates first"
            return
        end
        showBeacon({ name = "custom", pos = pos })
        local ok, err = teleportTo(pos, true)
        statusLabel.Text = ok and ("arrived · " .. fmt(pos)) or ("failed · " .. tostring(err))
    end)
    makeActionRow(content, "Save Current Position", "copy your coords into the boxes", function()
        local root = getRoot()
        if not root then return end
        local p = root.Position
        local function put(row, v)
            local box = row:FindFirstChildOfClass("TextBox")
            if box then box.Text = tostring(math.floor(v)) end
        end
        put(xBox, p.X); put(yBox, p.Y); put(zBox, p.Z)
        statusLabel.Text = "position copied · " .. fmt(p)
    end)
end

pages.Stealth = function()
    addSection(content, "bypass layer")
    makeToggleRow(content, "Stealth Governor", "jitter + rate limit + backoff", "stealth")
    makeSliderRow(content, "Jitter", "random delay before remote calls", "jitter", 0, 0.8, true)
    makeSliderRow(content, "Rate Limit", "max remote calls per second", "rateLimit", 1, 60)

    addSection(content, "notes")
    makeActionRow(content, "Clear Beacon", "remove the waypoint marker", function()
        clearBeacon()
        statusLabel.Text = "beacon cleared"
    end)
    makeActionRow(content, "Panic Unload", "kill the route and destroy the gui", function()
        if type(_G.__heavenslua_cleanup) == "function" then
            pcall(_G.__heavenslua_cleanup)
        end
    end)
end

pages.Config = function()
    addSection(content, "persistence")
    makeActionRow(content, "Save Config", "write heavenslua_config.json", function()
        saveConfig()
        statusLabel.Text = "config saved"
    end)
    makeActionRow(content, "Reload Config", "re-read from disk", function()
        loadConfig()
        showTab(cfg.tab or "Route")
        statusLabel.Text = "config reloaded"
    end)
    makeActionRow(content, "Reset Config", "restore defaults", function()
        cfg.useServerRemote = true
        cfg.chunked = true
        cfg.hopSize = 320
        cfg.hopDelay = 0.03
        cfg.holdTime = 0.25
        cfg.yOffset = 3
        cfg.groundSnap = true
        cfg.stepDelay = 1.2
        cfg.promptRadius = 26
        cfg.skipYellow = true
        cfg.stopOnMissing = false
        cfg.stealth = true
        cfg.jitter = 0.15
        cfg.rateLimit = 14
        saveConfig()
        showTab("Route")
        statusLabel.Text = "config reset"
    end)
end

for _, name in ipairs({ "Route", "Sequence", "Teleport", "Stealth", "Config" }) do
    makeTabButton(name, name)
end

-- ============================================================
-- LAYOUT
-- ============================================================

local narrowMode = nil

local function applyLayout()
    local vp = viewport()
    local narrow = vp.X < 760
    if narrow == narrowMode then return end
    narrowMode = narrow

    if narrow then
        rail.Position = UDim2.fromOffset(12, 60)
        rail.Size = UDim2.new(1, -24, 0, 40)
        railLayout.FillDirection = Enum.FillDirection.Horizontal
        railLayout.Padding = UDim.new(0, 4)

        contentHolder.Position = UDim2.fromOffset(12, 108)
        contentHolder.Size = UDim2.new(1, -24, 1, -126)

        footer.Position = UDim2.new(0, 12, 1, -12)
        footer.Size = UDim2.new(1, -24, 0, 18)

        local n = #tabOrder
        for _, btn in pairs(tabButtons) do
            btn.Size = UDim2.new(1 / n, -4, 1, 0)
            local lbl = btn:FindFirstChildOfClass("TextLabel")
            if lbl then
                lbl.Position = UDim2.fromOffset(6, 0)
                lbl.Size = UDim2.new(1, -12, 1, 0)
                lbl.TextSize = 9
                lbl.TextXAlignment = Enum.TextXAlignment.Center
            end
            local accent = btn:FindFirstChild("accent")
            if accent then accent.Visible = false end
        end
    else
        rail.Position = UDim2.fromOffset(14, 66)
        rail.Size = UDim2.new(0, 132, 1, -80)
        railLayout.FillDirection = Enum.FillDirection.Vertical
        railLayout.Padding = UDim.new(0, 6)

        contentHolder.Position = UDim2.fromOffset(156, 66)
        contentHolder.Size = UDim2.new(1, -170, 1, -80)

        footer.Position = UDim2.new(0, 156, 1, -14)
        footer.Size = UDim2.new(1, -170, 0, 18)

        for _, btn in pairs(tabButtons) do
            btn.Size = UDim2.new(1, 0, 0, 42)
            local lbl = btn:FindFirstChildOfClass("TextLabel")
            if lbl then
                lbl.Position = UDim2.fromOffset(14, 0)
                lbl.Size = UDim2.new(1, -20, 1, 0)
                lbl.TextSize = 11
                lbl.TextXAlignment = Enum.TextXAlignment.Left
            end
            local accent = btn:FindFirstChild("accent")
            if accent then accent.Visible = true end
        end
    end
end

showTab(cfg.tab or "Route")
applyLayout()

-- ============================================================
-- DRAG
-- ============================================================

local dragging, dragStart, dragOrigin

local dragBtn = create("TextButton", {
    Size = UDim2.new(1, -60, 0, 56),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 10,
}, header)

track(dragBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragOrigin = panel.Position
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y
        )
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

-- ============================================================
-- LAUNCHER
-- ============================================================

local float = create("TextButton", {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -40, 1, -56),
    Size = UDim2.fromOffset(64, 64),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    Text = "☁",
    Font = Enum.Font.GothamBold,
    TextSize = 28,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    ZIndex = 20,
}, screen)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, float)
create("UIStroke", { Color = COL.cyan, Transparency = 0.55, Thickness = 2 }, float)

local floatDragging, floatStart, floatOrigin, floatMoved, floatHoldStart

track(float.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        floatDragging = true
        floatStart = input.Position
        floatOrigin = float.Position
        floatMoved = false
        floatHoldStart = os.clock()
    end
end))

track(float.Activated:Connect(function()
    if floatMoved then return end
    if floatHoldStart and os.clock() - floatHoldStart > 0.8 then
        if type(_G.__heavenslua_cleanup) == "function" then
            pcall(_G.__heavenslua_cleanup)
        end
        return
    end
    panel.Visible = not panel.Visible
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not floatDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - floatStart
        if delta.Magnitude > 6 then floatMoved = true end
        float.Position = UDim2.new(
            floatOrigin.X.Scale, floatOrigin.X.Offset + delta.X,
            floatOrigin.Y.Scale, floatOrigin.Y.Offset + delta.Y
        )
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        floatDragging = false
    end
end))

-- ============================================================
-- FIT
-- ============================================================

local function fit()
    local vp = viewport()
    local narrow = vp.X < 760
    local w = narrow and (PANEL_W - 60) or PANEL_W
    local h = narrow and (PANEL_H - 10) or PANEL_H
    local scale = math.min((vp.X - 16) / w, (vp.Y - 16) / h)
    local floor = isTouchDevice() and 0.76 or 0.58
    fitScale.Scale = math.clamp(scale, floor, 1)
end

fit()
applyLayout()

do
    local cam = Workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            applyLayout()
            fit()
        end))
    end
end

-- ============================================================
-- KEYBINDS
-- ============================================================

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        panel.Visible = not panel.Visible
    elseif input.KeyCode == Enum.KeyCode.End then
        if type(_G.__heavenslua_cleanup) == "function" then
            pcall(_G.__heavenslua_cleanup)
        end
    end
end))

-- ============================================================
-- CLEANUP
-- ============================================================

_G.__heavenslua_cleanup = function()
    running = false
    cfg.autoRoute = false
    routeThread = nil
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}
    pcall(clearBeacon)
    pcall(function() if beaconFolder then beaconFolder:Destroy() end end)
    pcall(function() if screen then screen:Destroy() end end)
end

statusLabel.Text = isTouchDevice() and "bench warm · mobile" or "bench warm · ready"
print("[heavens] loaded · RSHIFT panel · END panic · long-press launcher panic")
