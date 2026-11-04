--[[
    recon2.lua — automated recon suite for Delta

    v1 missed the real surface: it only walked game:GetDescendants(), so
    anything created at runtime, anything behind a framework, and anything
    whose name was built from a string in a script never showed up. that is
    why the report had zero ReplicatedStorage remotes on a live server.

    v2 adds four passes that v1 did not have:

      1. per-service walk      — visits every service explicitly, so a
                                 truncated GetDescendants cannot hide one
      2. script string mining  — pulls every string constant out of every
                                 script it can reach (decompile, else
                                 getscriptbytecode) and matches them against
                                 the instance tree. this finds remotes that
                                 are looked up by name at runtime
      3. runtime capture       — hooks __namecall and records every remote
                                 the game itself invokes. play for a few
                                 seconds and the real remotes name themselves
      4. connection mapping    — getconnections on every remote signal, so a
                                 remote the client listens to is flagged as
                                 a data channel instead of a dead end

    automation: one AUTO button runs the whole pipeline and saves the result.
    stealth: SAFE mode never fires a RemoteEvent and jitters every RemoteFunction
    probe, so the pattern does not look like a scanner.

    layout: single column, full-width rows, resizes on rotation. no crossed
    buttons, portrait or landscape.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__recon2_cleanup) == "function" then
    pcall(_G.__recon2_cleanup)
end

----------------------------------------------------------------------------
-- config
----------------------------------------------------------------------------

local CONFIG = {
    version = "2.0",
    folder = "recon",

    walkCap = 400000,
    yieldEvery = 600,

    decompileCap = 260,
    bytecodeScriptCap = 900,
    bytecodeCap = 220000,

    captureWindow = 8,
    captureCap = 4000,

    probeCap = 40,
    probeTimeout = 0.6,
    probeJitterMin = 0.08,
    probeJitterMax = 0.25,

    safeMode = true,
    autoSave = true,

    maxLogLines = 900,
}

----------------------------------------------------------------------------
-- globals probe
----------------------------------------------------------------------------

-- executor globals are not reliably mirrored into _G, so grab them by
-- identifier at load time. a missing global reads as nil, which is legal.
local G = {
    identifyexecutor = identifyexecutor,
    writefile = writefile,
    readfile = readfile,
    isfile = isfile,
    isfolder = isfolder,
    makefolder = makefolder,
    listfiles = listfiles,
    delfile = delfile,
    setclipboard = setclipboard,

    hookmetamethod = hookmetamethod,
    hookfunction = hookfunction,
    getrawmetatable = getrawmetatable,
    setreadonly = setreadonly,
    getnamecallmethod = getnamecallmethod,

    getconnections = getconnections,
    getnilinstances = getnilinstances,
    getinstances = getinstances,
    getloadedmodules = getloadedmodules,
    getscripts = getscripts,
    getscriptbytecode = getscriptbytecode,
    decompile = decompile,
    getgc = getgc,
    getreg = getreg,

    fireclickdetector = fireclickdetector,
    firetouchinterest = firetouchinterest,
    fireproximityprompt = fireproximityprompt,
    firelplproximityprompt = firelplproximityprompt,

    request = request,
    http_request = http_request,
    queue_on_teleport = queue_on_teleport,
    getcustomasset = getcustomasset,
    setfpscap = setfpscap,
    gethui = gethui,
    setrenderproperty = setrenderproperty,
}

local function has(name)
    if type(G[name]) == "function" then
        return true
    end
    local ok, value = pcall(function()
        return _G[name]
    end)
    return ok and type(value) == "function"
end

local function fetch(name)
    if type(G[name]) == "function" then
        return G[name]
    end
    local ok, value = pcall(function()
        return _G[name]
    end)
    if ok and type(value) == "function" then
        return value
    end
    return nil
end

local function call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

----------------------------------------------------------------------------
-- palette + tiny ui toolkit
----------------------------------------------------------------------------

local COL = {
    bg = Color3.fromRGB(11, 13, 19),
    panel = Color3.fromRGB(16, 19, 27),
    text = Color3.fromRGB(238, 242, 252),
    sub = Color3.fromRGB(150, 159, 182),
    dim = Color3.fromRGB(102, 110, 134),
    cyan = Color3.fromRGB(108, 231, 255),
    blue = Color3.fromRGB(120, 168, 255),
    violet = Color3.fromRGB(172, 146, 255),
    green = Color3.fromRGB(122, 240, 176),
    amber = Color3.fromRGB(255, 198, 110),
    danger = Color3.fromRGB(255, 112, 126),
}

local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props or {}) do
        if key ~= "Parent" then
            pcall(function()
                inst[key] = value
            end)
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

----------------------------------------------------------------------------
-- gui root
----------------------------------------------------------------------------

local guiParent
do
    local ok, playerGui = pcall(function()
        return lp:WaitForChild("PlayerGui", 5)
    end)
    if ok and playerGui then
        guiParent = playerGui
    else
        local ok2, coreGui = pcall(function()
            return game:GetService("CoreGui")
        end)
        guiParent = (ok2 and coreGui) or nil
    end
end

if not guiParent then
    return
end

for _, child in ipairs(guiParent:GetChildren()) do
    if child.Name == "recon2" then
        pcall(function()
            child:Destroy()
        end)
    end
end

local screen = Instance.new("ScreenGui")
screen.Name = "recon2"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9994
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    screen.Parent = guiParent
end)

local panel = create("Frame", {
    AnchorPoint = Vector2.new(0, 0),
    Position = UDim2.new(0, 8, 0, 8),
    Size = UDim2.fromOffset(360, 600),
    BackgroundTransparency = 1,
    Active = true,
}, screen)

local fitScale = create("UIScale", { Scale = 1 }, panel)

local shadow = create("Frame", {
    Position = UDim2.fromOffset(0, 8),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.6,
    BorderSizePixel = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 18) }, shadow)

local shell = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.03,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 18) }, shell)

local shellStroke = create("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.86,
    Thickness = 1,
}, shell)
create("UIGradient", {
    Color = ColorSequence.new(COL.cyan, COL.violet),
    Transparency = NumberSequence.new(0.55, 0.92),
    Rotation = 30,
}, shellStroke)

----------------------------------------------------------------------------
-- header
----------------------------------------------------------------------------

local header = create("Frame", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundTransparency = 1,
    Active = true,
}, shell)

create("TextLabel", {
    Position = UDim2.fromOffset(14, 6),
    Size = UDim2.new(1, -90, 0, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "recon " .. CONFIG.version,
}, header)

local modeLabel = create("TextLabel", {
    Position = UDim2.fromOffset(14, 24),
    Size = UDim2.new(1, -90, 0, 14),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = COL.green,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "SAFE",
}, header)

local collapseButton = create("TextButton", {
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -78, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "–",
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 8) }, collapseButton)

local closeButton = create("TextButton", {
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -42, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 18,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 8) }, closeButton)

----------------------------------------------------------------------------
-- drag
----------------------------------------------------------------------------

do
    local dragging = false
    local dragStart = Vector2.zero
    local origin = UDim2.new(0, 8, 0, 8)

    -- a dedicated strip, so a tap on collapse/close never starts a drag.
    -- the original bound drag to the whole header and every button tap nudged
    -- the panel.
    local dragZone = create("Frame", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, -84, 1, 0),
        BackgroundTransparency = 1,
        Active = true,
        ZIndex = 3,
    }, header)

    track(dragZone.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            origin = panel.Position
        end
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            panel.Position = UDim2.new(
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

----------------------------------------------------------------------------
-- status
----------------------------------------------------------------------------

local statusBox = create("Frame", {
    Position = UDim2.fromOffset(10, 46),
    Size = UDim2.new(1, -20, 0, 44),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
}, shell)
create("UICorner", { CornerRadius = UDim.new(0, 10) }, statusBox)

local statusStroke = create("UIStroke", {
    Color = COL.cyan,
    Transparency = 0.6,
    Thickness = 1,
}, statusBox)

local statusTitle = create("TextLabel", {
    Position = UDim2.fromOffset(10, 3),
    Size = UDim2.new(1, -20, 0, 19),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = COL.cyan,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "IDLE",
}, statusBox)

local statusSub = create("TextLabel", {
    Position = UDim2.fromOffset(10, 22),
    Size = UDim2.new(1, -20, 0, 15),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "ready",
}, statusBox)

local function setStatus(title, sub, color)
    statusTitle.Text = title
    statusTitle.TextColor3 = color or COL.cyan
    statusStroke.Color = color or COL.cyan
    statusSub.Text = sub or ""
end

----------------------------------------------------------------------------
-- log
----------------------------------------------------------------------------

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 94),
    Size = UDim2.new(1, 0, 1, -94 - 176),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = COL.sub,
    ScrollBarImageTransparency = 0.55,
}, shell)

create("UIPadding", {
    PaddingLeft = UDim.new(0, 10),
    PaddingRight = UDim.new(0, 10),
    PaddingTop = UDim.new(0, 2),
    PaddingBottom = UDim.new(0, 6),
}, logScroll)

create("UIListLayout", {
    Padding = UDim.new(0, 1),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, logScroll)

local orderCount = 0
local renderedLines = 0
local logLines = {}

local function addLine(text, color)
    text = tostring(text)
    table.insert(logLines, text)
    if #logLines > CONFIG.maxLogLines then
        table.remove(logLines, 1)
    end

    orderCount = orderCount + 1
    renderedLines = renderedLines + 1

    local label = create("TextLabel", {
        Size = UDim2.new(1, -4, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = color or COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = text,
        LayoutOrder = orderCount,
    }, logScroll)
    pcall(function()
        label.AutomaticSize = Enum.AutomaticSize.Y
    end)

    if renderedLines > 420 then
        for _, child in ipairs(logScroll:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
                renderedLines = renderedLines - 1
                break
            end
        end
    end

    task.defer(function()
        if logScroll and logScroll.Parent then
            pcall(function()
                logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
            end)
        end
    end)
end

local function addRule(text)
    orderCount = orderCount + 1
    renderedLines = renderedLines + 1
    create("TextLabel", {
        Size = UDim2.new(1, -4, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "── " .. string.upper(tostring(text)) .. " ──",
        LayoutOrder = orderCount,
    }, logScroll)
end

----------------------------------------------------------------------------
-- report store
----------------------------------------------------------------------------

local report = {
    meta = {},
    env = {},
    services = {},
    instances = {},
    remotes = {},
    scriptHits = {},
    captured = {},
    connections = {},
    probes = {},
    interestingProbes = {},
    geometry = {},
    replicated = {},
    gui = {},
    protection = {},
    character = {},
    scripts = {},
    hints = {},
    counts = {},
}

local function safeName(inst)
    local ok, name = pcall(function()
        return inst:GetFullName()
    end)
    return ok and name or "?"
end

local function safeClass(inst)
    local ok, class = pcall(function()
        return inst.ClassName
    end)
    return ok and class or "?"
end

local function safeParent(inst)
    local ok, parent = pcall(function()
        return inst.Parent
    end)
    return ok and parent or nil
end

local function yieldEvery(index)
    if index % CONFIG.yieldEvery == 0 then
        task.wait()
    end
end

----------------------------------------------------------------------------
-- risk model
----------------------------------------------------------------------------

local RISK = {
    give = 30, grant = 30, reward = 26, claim = 24, redeem = 24,
    admin = 40, ban = 38, kick = 32, kickplayer = 34,
    teleport = 20, damage = 24, kill = 28, spawn = 20,
    buy = 20, purchase = 20, sell = 18, refund = 24, trade = 24,
    money = 24, cash = 24, coin = 22, gem = 22, currency = 24,
    stat = 14, level = 14, xp = 14, exp = 12,
    item = 14, inventory = 18, save = 18, load = 18,
    unlock = 24, code = 18, promo = 20,
    speed = 18, walk = 14, jump = 14, fly = 18, noclip = 24,
    dev = 14, debug = 20, test = 10, cheat = 40,
    set = 12, update = 8, equip = 10, fire = 10, shoot = 10,
    hit = 12, client = 6, remote = 4, event = 4,
    luck = 18, boost = 16, multiplier = 18, chance = 16,
    sellall = 24, autosell = 24, sellfish = 20,
    enchant = 16, upgrade = 16, craft = 16, forge = 16,
    daily = 16, reward2 = 16, spin = 20, crate = 20, egg = 18,
    quest = 14, finishquest = 18, givequest = 22,
    pronounce = 4, settings = 4,
}

local function riskScore(class, name)
    local lower = string.lower(tostring(name))
    local score = 0
    for word, value in pairs(RISK) do
        if string.find(lower, word, 1, true) then
            score = score + value
        end
    end
    if class == "RemoteFunction" then
        score = score + 12
    end
    if class == "UnreliableRemoteEvent" then
        score = score + 3
    end
    if lower == "event" or lower == "remote" then
        score = score - 6
    end
    return math.max(0, score)
end

----------------------------------------------------------------------------
-- service index
----------------------------------------------------------------------------

-- explicit list, because a truncated GetDescendants can silently drop a
-- whole service and that is exactly how v1 lost ReplicatedStorage
local SERVICE_NAMES = {
    "ReplicatedStorage", "ReplicatedFirst", "Workspace", "Players",
    "Lighting", "StarterGui", "StarterPack", "StarterPlayer",
    "SoundService", "TextChatService", "Chat", "Teams", "JointsService",
    "ProximityPromptService", "TweenService", "MaterialService",
    "PathfindingService", "ServerStorage", "ServerScriptService",
    "TeleportService", "TestService", "VirtualUser", "LocalizationService",
    "ContentProvider", "AssetService", "GuiService", "HapticService",
}

local function collectServices()
    addRule("services")

    local out = {}
    local seen = {}

    local ok, children = pcall(function()
        return game:GetChildren()
    end)
    if ok and children then
        for _, svc in ipairs(children) do
            seen[svc] = true
            table.insert(out, {
                name = safeName(svc),
                class = safeClass(svc),
                source = "child",
                readable = (function()
                    local fine = pcall(function()
                        return svc.Name
                    end)
                    return fine
                end)(),
            })
        end
    end

    for _, name in ipairs(SERVICE_NAMES) do
        local okSvc, svc = pcall(function()
            return game:GetService(name)
        end)
        if okSvc and svc and not seen[svc] then
            seen[svc] = true
            table.insert(out, {
                name = name,
                class = safeClass(svc),
                source = "getservice",
                readable = (function()
                    local fine = pcall(function()
                        return svc.Name
                    end)
                    return fine
                end)(),
            })
        end
    end

    table.sort(out, function(a, b)
        return a.name < b.name
    end)

    report.services = out
    addLine(("%d services indexed"):format(#out), COL.cyan)

    local readable = 0
    for _, svc in ipairs(out) do
        if svc.readable then
            readable = readable + 1
        end
    end
    addLine(("%d readable from the client"):format(readable), COL.sub)

    return out
end

----------------------------------------------------------------------------
-- instance walk, per service
----------------------------------------------------------------------------

local INTERESTING = {
    RemoteEvent = true,
    UnreliableRemoteEvent = true,
    RemoteFunction = true,
    BindableEvent = true,
    BindableFunction = true,
    ModuleScript = true,
    Script = true,
    LocalScript = true,
    ClickDetector = true,
    ProximityPrompt = true,
    Tool = true,
}

local walkStats = {
    visited = 0,
    remotes = 0,
    scripts = 0,
    modules = 0,
}

local walkResults = {
    remotes = {},
    scripts = {},
    modules = {},
    byClass = {},
}

local function walkService(service, serviceName)
    if not service then
        return
    end

    local ok, list = pcall(function()
        return service:GetDescendants()
    end)

    if not ok or not list then
        addLine(("  %s: walk failed"):format(serviceName), COL.amber)
        return
    end

    local limit = math.min(#list, CONFIG.walkCap)
    addLine(("  %s: %d"):format(serviceName, #list), COL.dim)

    for i = 1, limit do
        local inst = list[i]
        walkStats.visited = walkStats.visited + 1

        local class = safeClass(inst)
        walkResults.byClass[class] = (walkResults.byClass[class] or 0) + 1

        if INTERESTING[class] then
            if class == "RemoteEvent" or class == "UnreliableRemoteEvent"
                or class == "RemoteFunction" or class == "BindableEvent"
                or class == "BindableFunction" then
                walkStats.remotes = walkStats.remotes + 1
                table.insert(walkResults.remotes, {
                    inst = inst,
                    class = class,
                    path = safeName(inst),
                    service = serviceName,
                })
            elseif class == "ModuleScript" then
                walkStats.modules = walkStats.modules + 1
                if #walkResults.modules < 1200 then
                    table.insert(walkResults.modules, {
                        inst = inst,
                        path = safeName(inst),
                        service = serviceName,
                    })
                end
            elseif class == "Script" or class == "LocalScript" then
                walkStats.scripts = walkStats.scripts + 1
                if #walkResults.scripts < 1200 then
                    table.insert(walkResults.scripts, {
                        inst = inst,
                        class = class,
                        path = safeName(inst),
                        service = serviceName,
                    })
                end
            end
        end

        yieldEvery(i)
    end
end

local function walkAll(services)
    addRule("instance walk")

    walkStats.visited = 0
    walkStats.remotes = 0
    walkStats.scripts = 0
    walkStats.modules = 0
    walkResults.remotes = {}
    walkResults.scripts = {}
    walkResults.modules = {}
    walkResults.byClass = {}

    local order = {}

    for _, name in ipairs(SERVICE_NAMES) do
        for _, svc in ipairs(services) do
            if svc.name == name then
                table.insert(order, svc)
                break
            end
        end
    end

    for _, svc in ipairs(services) do
        local already = false
        for _, picked in ipairs(order) do
            if picked.name == svc.name then
                already = true
                break
            end
        end
        if not already then
            table.insert(order, svc)
        end
    end

    for _, svc in ipairs(order) do
        local ok, service = pcall(function()
            return game:GetService(svc.name)
        end)
        if ok and service then
            walkService(service, svc.name)
        end
    end

    -- nil instances: remotes that exist but are not parented to anything
    if has("getnilinstances") then
        local nilList = call(fetch("getnilinstances"))
        if type(nilList) == "table" then
            addLine(("  nil instances: %d"):format(#nilList), COL.dim)
            for i, inst in ipairs(nilList) do
                local class = safeClass(inst)
                if INTERESTING[class] then
                    if class == "RemoteEvent" or class == "UnreliableRemoteEvent"
                        or class == "RemoteFunction" or class == "BindableEvent"
                        or class == "BindableFunction" then
                        table.insert(walkResults.remotes, {
                            inst = inst,
                            class = class,
                            path = safeName(inst),
                            service = "<nil>",
                        })
                    end
                end
                yieldEvery(i)
            end
        end
    end

    report.counts.visited = walkStats.visited
    report.counts.remotes = walkStats.remotes
    report.counts.scripts = walkStats.scripts
    report.counts.modules = walkStats.modules

    addLine(("%d instances, %d remotes, %d scripts, %d modules"):format(
        walkStats.visited, walkStats.remotes,
        walkStats.scripts, walkStats.modules), COL.green)
end

----------------------------------------------------------------------------
-- script string mining
----------------------------------------------------------------------------

local STRING_MIN = 3
local STRING_MAX = 48

-- identifier harvest. the per-byte version of this was O(n) in lua and made a
-- 900-script pass take minutes; gmatch does the same walk inside the C string
-- library and finishes a blob in microseconds.
local function harvestIdentifiers(blob, cap, into)
    into = into or {}
    if type(blob) ~= "string" or #blob == 0 then
        return into
    end

    if #blob > CONFIG.bytecodeCap then
        blob = string.sub(blob, 1, CONFIG.bytecodeCap)
    end

    local seen = 0
    for token in string.gmatch(blob, "[%a_][%w_]*") do
        local length = #token
        if length >= STRING_MIN and length <= STRING_MAX then
            if not into[token] then
                into[token] = 0
                seen = seen + 1
                if seen >= cap then
                    break
                end
            end
            into[token] = into[token] + 1
        end
    end

    return into
end

-- game logic lives in a handful of containers; everything else is engine or
-- third-party noise. decompiling costs milliseconds per script, so spend the
-- budget where the remote names actually are and bytecode-mine the rest.
local PRIORITY_CONTAINERS = {
    "ReplicatedStorage", "ReplicatedFirst", "StarterPlayer", "StarterGui",
    "PlayerScripts", "StarterPack", "Players",
}

local function isPriorityPath(path)
    for _, container in ipairs(PRIORITY_CONTAINERS) do
        if string.find(path, container, 1, true) then
            return true
        end
    end
    return false
end

local function mineScripts()
    addRule("script mining")

    local sources = {}

    local entries = {}
    for _, entry in ipairs(walkResults.scripts) do
        table.insert(entries, entry)
    end
    for _, entry in ipairs(walkResults.modules) do
        table.insert(entries, entry)
    end

    local priority = {}
    local rest = {}
    for _, entry in ipairs(entries) do
        if isPriorityPath(entry.path) then
            table.insert(priority, entry)
        else
            table.insert(rest, entry)
        end
    end

    -- decompile first: real source beats bytecode strings every time
    if has("decompile") then
        local decompileFn = fetch("decompile")
        local budget = CONFIG.decompileCap

        local function decompileAll(list)
            for i, entry in ipairs(list) do
                if budget <= 0 then
                    return
                end
                budget = budget - 1
                local ok, source = pcall(decompileFn, entry.inst)
                if ok and type(source) == "string" and #source > 0 then
                    table.insert(sources, {
                        path = entry.path,
                        kind = "decompile",
                        body = source,
                    })
                end
                if i % 8 == 0 then
                    task.wait()
                end
            end
        end

        decompileAll(priority)
        decompileAll(rest)
    end

    addLine(("%d bodies decompiled"):format(#sources), COL.sub)

    -- bytecode fallback: the constant pool holds every string literal, and it
    -- is one cheap call per script, so this covers the whole tree
    if has("getscriptbytecode") then
        local bytecodeFn = fetch("getscriptbytecode")
        local budget = CONFIG.bytecodeScriptCap

        for i, entry in ipairs(entries) do
            if budget <= 0 then
                break
            end
            budget = budget - 1
            local ok, blob = pcall(bytecodeFn, entry.inst)
            if ok and type(blob) == "string" and #blob > 0 then
                table.insert(sources, {
                    path = entry.path,
                    kind = "bytecode",
                    body = blob,
                })
            end
            yieldEvery(i)
        end
    end

    addLine(("%d script bodies captured"):format(#sources), COL.cyan)

    -- pull every identifier-shaped string constant
    local strings = {}
    local stringCount = 0

    for i, source in ipairs(sources) do
        local chunk = harvestIdentifiers(source.body, 6000, {})
        for token, count in pairs(chunk) do
            local record = strings[token]
            if not record then
                record = { count = 0, sources = {} }
                strings[token] = record
                stringCount = stringCount + 1
            end
            record.count = record.count + count
            if #record.sources < 5 then
                record.sources[#record.sources + 1] = source.path
            end
        end
        yieldEvery(i)
    end

    addLine(("%d distinct identifiers"):format(stringCount), COL.sub)

    -- cross reference against the remote list
    local byName = {}
    for _, entry in ipairs(walkResults.remotes) do
        local ok, shortName = pcall(function()
            return entry.inst.Name
        end)
        if ok and shortName then
            byName[shortName] = byName[shortName] or {}
            table.insert(byName[shortName], entry)
        end
    end

    local hits = {}
    for identifier, record in pairs(strings) do
        if byName[identifier] then
            table.insert(hits, {
                name = identifier,
                matches = #byName[identifier],
                sources = record.sources,
                known = true,
            })
        else
            local score = riskScore("RemoteEvent", identifier)
            if score >= 20 then
                table.insert(hits, {
                    name = identifier,
                    matches = 0,
                    sources = record.sources,
                    known = false,
                    risk = score,
                })
            end
        end
    end

    table.sort(hits, function(a, b)
        if a.known ~= b.known then
            return a.known
        end
        if (a.risk or 0) == (b.risk or 0) then
            return a.name < b.name
        end
        return (a.risk or 0) > (b.risk or 0)
    end)

    report.scriptHits = {}
    for i = 1, math.min(200, #hits) do
        local hit = hits[i]
        table.insert(report.scriptHits, {
            name = hit.name,
            known = hit.known,
            matches = hit.matches,
            risk = hit.risk or 0,
            sources = hit.sources,
        })
    end

    report.counts.identifiers = stringCount
    report.counts.scriptHits = #report.scriptHits

    local unknown = 0
    for _, hit in ipairs(hits) do
        if not hit.known and (hit.risk or 0) >= 20 then
            unknown = unknown + 1
            if unknown <= 25 then
                addLine(("  name-only  %-28s risk %d"):format(hit.name, hit.risk), COL.amber)
            end
        end
    end
    if unknown > 0 then
        addLine(("%d suspicious names with no instance — likely runtime remotes"):format(
            unknown), COL.violet)
    end
end

----------------------------------------------------------------------------
-- runtime capture
----------------------------------------------------------------------------

local capture = {
    active = false,
    records = {},
    hook = nil,
    original = nil,
    count = 0,
}

local function startCapture()
    if capture.active then
        return true
    end
    if not has("hookmetamethod") or not has("getnamecallmethod") then
        addLine("no hookmetamethod — runtime capture unavailable", COL.amber)
        return false
    end

    local hookFn = fetch("hookmetamethod")
    local methodFn = fetch("getnamecallmethod")

    local wrapper = function(self, ...)
        local method = methodFn()
        if method == "FireServer" or method == "InvokeServer"
            or method == "FireAllClients" or method == "InvokeClient" then
            local okType, kind = pcall(typeof, self)
            if okType and kind == "Instance" then
                local okName, shortName = pcall(function()
                    return self.Name
                end)
                local okClass, class = pcall(function()
                    return self.ClassName
                end)
                if okName and okClass then
                    local full = safeName(self)
                    local key = full .. "|" .. method
                    local record = capture.records[key]
                    if not record then
                        record = {
                            path = full,
                            name = shortName,
                            class = class,
                            method = method,
                            count = 0,
                            first = os.clock(),
                        }
                        capture.records[key] = record
                        capture.count = capture.count + 1
                    end
                    record.count = record.count + 1
                end
            end
        end
        return capture.original(self, ...)
    end

    local ok, original = pcall(hookFn, game, "__namecall", wrapper)
    if not ok or type(original) ~= "function" then
        addLine("capture hook failed", COL.danger)
        return false
    end

    capture.original = original
    capture.wrapper = wrapper
    capture.active = true
    return true
end

local function restoreNamecall()
    if not capture.wrapper then
        return true
    end

    -- put the real method back. three paths because executors differ: the
    -- metatable write, hookfunction on the wrapper, then give up and leave it
    -- (the wrapper is a pass-through once capture.active is false, so a failed
    -- restore costs speed, not behaviour)
    local restored = false

    if has("getrawmetatable") and has("setreadonly") then
        local setreadonly = fetch("setreadonly")
        local ok = pcall(function()
            local mt = fetch("getrawmetatable")(game)
            if mt and rawget(mt, "__namecall") == capture.wrapper then
                setreadonly(mt, false)
                rawset(mt, "__namecall", capture.original)
                setreadonly(mt, true)
                restored = true
            end
        end)
        restored = restored or ok
    end

    if not restored and has("hookfunction") then
        local ok = pcall(fetch("hookfunction"), capture.wrapper, capture.original)
        restored = ok
    end

    if not restored and has("hookmetamethod") then
        pcall(fetch("hookmetamethod"), game, "__namecall", capture.original)
        restored = true
    end

    if restored then
        capture.wrapper = nil
    end
    return restored
end

local function stopCapture()
    if not capture.active then
        return
    end
    capture.active = false
    restoreNamecall()
end

local function captureSummary()
    local list = {}
    for _, record in pairs(capture.records) do
        table.insert(list, record)
    end
    table.sort(list, function(a, b)
        if a.count == b.count then
            return a.path < b.path
        end
        return a.count > b.count
    end)

    report.captured = {}
    for i = 1, math.min(200, #list) do
        local record = list[i]
        table.insert(report.captured, {
            path = record.path,
            class = record.class,
            method = record.method,
            count = record.count,
        })
    end

    report.counts.captured = #report.captured
    return #list
end

----------------------------------------------------------------------------
-- connection mapping
----------------------------------------------------------------------------

local function mapConnections()
    addRule("connections")

    if not has("getconnections") then
        addLine("getconnections unavailable", COL.amber)
        return
    end

    local connectionsFn = fetch("getconnections")
    local mapped = 0
    local listening = 0

    for i, entry in ipairs(walkResults.remotes) do
        local signal = nil
        local okSignal = pcall(function()
            if entry.class == "RemoteEvent" or entry.class == "UnreliableRemoteEvent" then
                signal = entry.inst.OnClientEvent
            elseif entry.class == "RemoteFunction" then
                signal = entry.inst.OnClientInvoke
            elseif entry.class == "BindableEvent" then
                signal = entry.inst.Event
            end
        end)

        if okSignal and signal then
            local list = call(connectionsFn, signal)
            if type(list) == "table" then
                mapped = mapped + 1
                if #list > 0 then
                    listening = listening + 1
                    entry.hasListener = true
                end
                entry.connections = #list
            end
        end
        yieldEvery(i)
    end

    report.counts.mapped = mapped
    report.counts.listening = listening
    addLine(("%d signals mapped, %d with client handlers"):format(mapped, listening),
        COL.green)
end

----------------------------------------------------------------------------
-- rank
----------------------------------------------------------------------------

local function rankRemotes()
    addRule("ranking")

    local list = {}

    for _, entry in ipairs(walkResults.remotes) do
        local ok, shortName = pcall(function()
            return entry.inst.Name
        end)
        shortName = ok and shortName or "?"

        local score = riskScore(entry.class, shortName)

        if entry.connections and entry.connections > 0 then
            score = score + 8
        end
        if entry.service == "ReplicatedStorage" then
            score = score + 6
        end
        if entry.service == "<nil>" then
            score = score + 10
        end
        if capture.records[entry.path .. "|FireServer"] then
            score = score + 15
        end
        if capture.records[entry.path .. "|InvokeServer"] then
            score = score + 15
        end

        table.insert(list, {
            path = entry.path,
            class = entry.class,
            service = entry.service,
            risk = score,
            connections = entry.connections or -1,
            live = (capture.records[entry.path .. "|FireServer"] ~= nil)
                or (capture.records[entry.path .. "|InvokeServer"] ~= nil),
            inst = entry.inst,
        })
    end

    table.sort(list, function(a, b)
        if a.risk == b.risk then
            return a.path < b.path
        end
        return a.risk > b.risk
    end)

    local stored = {}
    for i = 1, math.min(400, #list) do
        local entry = list[i]
        table.insert(stored, {
            path = entry.path,
            class = entry.class,
            service = entry.service,
            risk = entry.risk,
            connections = entry.connections,
            live = entry.live,
        })
    end

    report.remotes = stored
    report.counts.ranked = #stored

    for i = 1, math.min(14, #list) do
        local entry = list[i]
        local color = entry.risk >= 45 and COL.danger
            or entry.risk >= 25 and COL.amber
            or COL.sub
        addLine(("[%d]%s %s"):format(entry.risk, entry.live and " *" or "  ", entry.path), color)
    end

    rankRemotes.list = list
end

----------------------------------------------------------------------------
-- safe probe
----------------------------------------------------------------------------

local PROBE_DENY = {
    ban = true, kick = true, admin = true, shutdown = true,
    delete = true, wipe = true, reset = true, report = true,
    purchase = true, buy = true, robux = true, premium = true,
}

local function isProbeSafe(entry)
    local lower = string.lower(entry.path)
    for word in pairs(PROBE_DENY) do
        if string.find(lower, word, 1, true) then
            return false
        end
    end

    -- never poke another player's tool stack: those remotes are server-owned
    -- and invoking them is the one thing that reads as interference, not recon
    if CONFIG.safeMode then
        local prefix = "players."
        local rest = string.sub(lower, 1, #prefix) == prefix
            and string.sub(lower, #prefix + 1) or nil
        if rest then
            local owner = string.match(rest, "^([^%.]+)")
            local me = string.lower(lp.Name)
            if owner and owner ~= me then
                return false
            end
        end
        if string.find(lower, "^workspace%.") then
            local owner = string.match(lower, "^workspace%.([^%.]+)")
            if owner and owner ~= string.lower(lp.Name) then
                -- workspace.<otherplayer>.* is another character's tree
                local known = false
                for _, plr in ipairs(Players:GetPlayers()) do
                    if string.lower(plr.Name) == owner then
                        known = true
                        break
                    end
                end
                if known then
                    return false
                end
            end
        end
    end

    return true
end

local function timedInvoke(remote, timeout, args)
    local finished = false
    local result = nil

    task.spawn(function()
        local ok, value = pcall(function()
            return remote:InvokeServer(unpack(args))
        end)
        result = { ok = ok, value = value }
        finished = true
    end)

    local deadline = os.clock() + timeout
    while not finished and os.clock() < deadline do
        task.wait(0.03)
    end

    if not finished then
        return false, "timeout"
    end
    return result.ok, result.value
end

local function describeValue(value, depth)
    depth = depth or 0
    local kind = typeof(value)
    if kind == "Instance" then
        return "Instance(" .. safeName(value) .. ")"
    elseif kind == "table" then
        if depth > 1 then
            return "{…}"
        end
        local parts = {}
        local shown = 0
        for key, item in pairs(value) do
            shown = shown + 1
            if shown > 6 then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(key) .. "=" .. describeValue(item, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif kind == "string" then
        if #value > 48 then
            return ("%q…"):format(string.sub(value, 1, 45))
        end
        return ("%q"):format(value)
    end
    return tostring(value)
end

local function jitter()
    local span = CONFIG.probeJitterMax - CONFIG.probeJitterMin
    task.wait(CONFIG.probeJitterMin + math.random() * span)
end

local parseProbes  -- forward declared: probeRemotes calls it before its body

local function probeRemotes()
    addRule("probe")

    local list = (rankRemotes.list or {})
    local results = {}
    local attempted = 0

    for _, entry in ipairs(list) do
        if attempted >= CONFIG.probeCap then
            break
        end
        if entry.class == "RemoteFunction" and isProbeSafe(entry) then
            attempted = attempted + 1
            setStatus("PROBING", ("%d/%d"):format(attempted, math.min(#list, CONFIG.probeCap)),
                COL.violet)

            jitter()

            local ok, value = timedInvoke(entry.inst, CONFIG.probeTimeout, {})
            local record = {
                path = entry.path,
                ok = ok,
                result = ok and describeValue(value) or tostring(value),
                risk = entry.risk,
            }
            table.insert(results, record)

            if ok then
                local text = tostring(record.result)
                if string.find(text, "^false") or string.find(text, "nil") then
                    addLine(("  checked   %s"):format(entry.path), COL.sub)
                else
                    addLine(("  RETURNS   %s -> %s"):format(entry.path, text), COL.green)
                end
            elseif tostring(value) == "timeout" then
                addLine(("  timeout   %s"):format(entry.path), COL.amber)
            else
                addLine(("  error     %s"):format(entry.path), COL.dim)
            end
        end
    end

    report.probes = results
    parseProbes(results)
    addLine(("%d RemoteFunctions probed"):format(#results), COL.cyan)
end

function parseProbes(results)
    local interesting = {}
    for _, record in ipairs(results) do
        if record.ok then
            local text = tostring(record.result)
            if text ~= "nil" and not string.find(text, "^false") then
                table.insert(interesting, record)
            end
        end
    end
    report.interestingProbes = interesting
end

----------------------------------------------------------------------------
-- replicated storage deep pass
----------------------------------------------------------------------------

-- the one thing v1 could not answer: "does ReplicatedStorage actually contain
-- remotes on the client?" this pass walks it from the root, children-first,
-- with no cap and no shared budget, and records the top-level child list so the
-- answer is visible in the report even when the subtree is empty.
local function scanReplicatedStorage()
    addRule("replicated storage")

    local data = {
        topLevel = {},
        total = 0,
        remotes = {},
        modules = {},
        containers = {},
    }

    local rs = nil
    local okRs, service = pcall(function()
        return game:GetService("ReplicatedStorage")
    end)
    if okRs and service then
        rs = service
    end

    if not rs then
        addLine("ReplicatedStorage not reachable", COL.danger)
        report.replicated = data
        return
    end

    local okChildren, children = pcall(function()
        return rs:GetChildren()
    end)
    if okChildren and children then
        for _, child in ipairs(children) do
            local class = safeClass(child)
            table.insert(data.topLevel, { name = child.Name, class = class })
            if class == "Folder" or class == "Model" then
                table.insert(data.containers, child.Name)
            end
        end
    end

    table.sort(data.topLevel, function(a, b)
        return a.name < b.name
    end)

    addLine(("%d top-level children in ReplicatedStorage"):format(#data.topLevel),
        #data.topLevel > 0 and COL.green or COL.amber)

    local okAll, descendants = pcall(function()
        return rs:GetDescendants()
    end)

    if okAll and descendants then
        data.total = #descendants
        for i, inst in ipairs(descendants) do
            local class = safeClass(inst)
            if class == "RemoteEvent" or class == "UnreliableRemoteEvent"
                or class == "RemoteFunction" or class == "BindableEvent"
                or class == "BindableFunction" then
                local path = safeName(inst)
                table.insert(data.remotes, { path = path, class = class })
                local already = false
                for _, entry in ipairs(walkResults.remotes) do
                    if entry.inst == inst then
                        already = true
                        break
                    end
                end
                if not already then
                    table.insert(walkResults.remotes, {
                        inst = inst,
                        class = class,
                        path = path,
                        service = "ReplicatedStorage",
                    })
                end
            elseif class == "ModuleScript" then
                table.insert(data.modules, safeName(inst))
            end
            yieldEvery(i)
        end
    end

    report.replicated = data

    addLine(("%d descendants, %d remotes, %d modules"):format(
        data.total, #data.remotes, #data.modules),
        #data.remotes > 0 and COL.green or COL.amber)

    for i = 1, math.min(12, #data.remotes) do
        addLine("  rs  " .. data.remotes[i].path, COL.sub)
    end
end

----------------------------------------------------------------------------
-- gui pass
----------------------------------------------------------------------------

local function scanGui()
    addRule("gui")

    local playerGui = lp:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return
    end

    local buttons = {}
    local inputs = {}
    local guiRemotes = {}

    local ok, list = pcall(function()
        return playerGui:GetDescendants()
    end)
    if not (ok and list) then
        return
    end

    for i, inst in ipairs(list) do
        local class = safeClass(inst)

        if inst:IsA("TextButton") or inst:IsA("ImageButton") then
            if #buttons < 160 then
                local okText, text = pcall(function()
                    return inst.Text
                end)
                table.insert(buttons, {
                    path = safeName(inst),
                    text = (okText and text) or "",
                })
            end
        elseif class == "TextBox" then
            if #inputs < 60 then
                table.insert(inputs, safeName(inst))
            end
        elseif class == "RemoteEvent" or class == "RemoteFunction" then
            if #guiRemotes < 60 then
                table.insert(guiRemotes, {
                    path = safeName(inst),
                    class = class,
                })
            end
        end

        yieldEvery(i)
    end

    report.gui = {
        buttons = buttons,
        inputs = inputs,
        remotes = guiRemotes,
    }

    addLine(("%d buttons, %d text boxes, %d gui remotes"):format(
        #buttons, #inputs, #guiRemotes), COL.cyan)
end

----------------------------------------------------------------------------
-- protection pass
----------------------------------------------------------------------------

local PROTECT_WORDS = {
    "anticheat", "anti_cheat", "anti-cheat", "detect", "filter", "guard",
    "secure", "verify", "validate", "kick", "ban", "punish", "report",
    "integrity", "checksum", "hash", "signature", "watch", "monitor",
    "teleportdetector", "speedcheck", "flycheck", "exploit",
}

local function scanProtection()
    addRule("protection")

    local hits = {}

    local function consider(inst, path)
        local lower = string.lower(path)
        for _, word in ipairs(PROTECT_WORDS) do
            if string.find(lower, word, 1, true) then
                if #hits < 160 then
                    table.insert(hits, {
                        path = path,
                        class = safeClass(inst),
                        word = word,
                    })
                end
                return
            end
        end
    end

    for _, entry in ipairs(walkResults.scripts) do
        consider(entry.inst, entry.path)
    end
    for _, entry in ipairs(walkResults.modules) do
        consider(entry.inst, entry.path)
    end

    report.protection = hits

    addLine(("%d scripts with a protection-shaped name"):format(#hits),
        #hits > 0 and COL.amber or COL.sub)

    for i = 1, math.min(10, #hits) do
        addLine("  " .. hits[i].path, COL.dim)
    end
end

----------------------------------------------------------------------------
-- geometry pass
----------------------------------------------------------------------------

local function scanGeometry()
    addRule("geometry")

    local data = {
        hitboxes = {},
        prompts = {},
        detectors = {},
        tools = {},
        parts = 0,
        unanchored = 0,
    }

    local ok, list = pcall(function()
        return workspace:GetDescendants()
    end)
    if not (ok and list) then
        return
    end

    local limit = math.min(#list, CONFIG.walkCap)

    for i = 1, limit do
        local inst = list[i]
        local class = safeClass(inst)

        if inst:IsA("BasePart") then
            data.parts = data.parts + 1
            local okAnchored, anchored = pcall(function()
                return inst.Anchored
            end)
            if okAnchored and not anchored then
                data.unanchored = data.unanchored + 1
            end

            local okName, shortName = pcall(function()
                return inst.Name
            end)
            local lower = string.lower(okName and shortName or "")

            if (string.find(lower, "hitbox", 1, true)
                or string.find(lower, "damage", 1, true)) and #data.hitboxes < 100 then
                table.insert(data.hitboxes, safeName(inst))
            end
        elseif class == "ProximityPrompt" and #data.prompts < 120 then
            table.insert(data.prompts, {
                path = safeName(inst),
                action = (function()
                    local okText, text = pcall(function()
                        return inst.ActionText
                    end)
                    return okText and text or ""
                end)(),
            })
        elseif class == "ClickDetector" and #data.detectors < 80 then
            table.insert(data.detectors, safeName(inst))
        elseif class == "Tool" and #data.tools < 120 then
            table.insert(data.tools, safeName(inst))
        end

        yieldEvery(i)
    end

    report.geometry = data
    addLine(("%d parts, %d unanchored, %d prompts, %d detectors"):format(
        data.parts, data.unanchored, #data.prompts, #data.detectors), COL.cyan)
end

----------------------------------------------------------------------------
-- executor + character
----------------------------------------------------------------------------

local function scanEnvironment()
    addRule("environment")

    local env = {
        executor = tostring(call(fetch("identifyexecutor")) or "unknown"),
        features = {},
    }

    local featureNames = {
        "writefile", "readfile", "isfile", "isfolder", "makefolder", "listfiles",
        "hookmetamethod", "hookfunction", "getrawmetatable", "setreadonly", "getconnections",
        "getnilinstances", "getinstances", "getloadedmodules", "getscripts",
        "getscriptbytecode", "decompile", "getgc", "getreg",
        "fireclickdetector", "firetouchinterest", "fireproximityprompt",
        "request", "http_request", "queue_on_teleport", "getcustomasset",
        "setfpscap", "gethui", "setrenderproperty",
    }

    for _, name in ipairs(featureNames) do
        env.features[name] = has(name)
    end

    report.env = env
    addLine(("executor: %s"):format(env.executor), COL.green)

    local missing = {}
    for _, name in ipairs(featureNames) do
        if not env.features[name] then
            table.insert(missing, name)
        end
    end
    if #missing > 0 then
        addLine(("missing: %s"):format(table.concat(missing, ", ")), COL.dim)
    end
end

local function scanCharacter()
    local data = {
        character = nil,
        tools = {},
        backpack = {},
        leaderstats = {},
        attributes = {},
        humanoid = {},
    }

    local char = lp.Character
    if char then
        data.character = safeName(char)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            data.humanoid = {
                health = hum.Health,
                maxHealth = hum.MaxHealth,
                walkSpeed = hum.WalkSpeed,
            }
        end
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") then
                table.insert(data.tools, safeName(child))
            end
        end
    end

    local backpack = lp:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") then
                table.insert(data.backpack, safeName(child))
            end
        end
    end

    local stats = lp:FindFirstChild("leaderstats")
    if stats then
        for _, child in ipairs(stats:GetChildren()) do
            local okValue, value = pcall(function()
                return child.Value
            end)
            table.insert(data.leaderstats, {
                name = child.Name,
                class = safeClass(child),
                value = okValue and tostring(value) or "?",
            })
        end
    end

    local okAttrs, attrs = pcall(function()
        return lp:GetAttributes()
    end)
    if okAttrs and attrs then
        for key, value in pairs(attrs) do
            data.attributes[key] = tostring(value)
        end
    end

    report.character = data
end

----------------------------------------------------------------------------
-- hints
----------------------------------------------------------------------------

local function buildHints()
    local hints = {}

    for _, entry in ipairs(report.remotes or {}) do
        if entry.risk >= 30 then
            table.insert(hints, ("risk %d  %s  %s"):format(
                entry.risk, entry.class, entry.path))
        end
        if entry.live then
            table.insert(hints, ("live     %s  %s"):format(entry.class, entry.path))
        end
    end

    for _, record in ipairs(report.captured or {}) do
        if record.count >= 3 then
            table.insert(hints, ("hot      %s  x%d"):format(record.path, record.count))
        end
    end

    for _, hit in ipairs(report.scriptHits or {}) do
        if not hit.known and hit.risk >= 25 then
            table.insert(hints, ("ghost    %s  risk %d"):format(hit.name, hit.risk))
        end
    end

    for _, record in ipairs(report.interestingProbes or {}) do
        table.insert(hints, ("returns  %s"):format(record.path))
    end

    local rs = report.replicated or {}
    local rsTop = #(rs.topLevel or {})
    if rsTop == 0 then
        table.insert(hints, "rs-empty   ReplicatedStorage has no children on this client")
    else
        table.insert(hints, ("rs         %d top-level, %d remotes, %d modules"):format(
            rsTop, #(rs.remotes or {}), #(rs.modules or {})))
    end

    report.hints = hints
end

----------------------------------------------------------------------------
-- save
----------------------------------------------------------------------------

local function buildTextReport()
    local out = {}
    local function line(text)
        table.insert(out, tostring(text))
    end

    local meta = report.meta or {}

    line("recon " .. CONFIG.version)
    line(("generated %s"):format(meta.generated or "?"))
    line(("place %s   job %s"):format(meta.place or "?", meta.job or "?"))
    line(("executor %s   safe %s"):format(
        tostring((report.env or {}).executor), tostring(CONFIG.safeMode)))
    line(("elapsed %.2fs"):format(meta.elapsed or 0))
    line("")

    line(("instances %d   remotes %d   scripts %d   modules %d"):format(
        meta.visited or 0, meta.remotes or 0, meta.scripts or 0, meta.modules or 0))
    line(("captured %d   probed %d   identifiers %d"):format(
        meta.captured or 0, #(report.probes or {}), meta.identifiers or 0))
    line("")

    line("== HINTS ==")
    for _, hint in ipairs(report.hints or {}) do
        line(hint)
    end
    line("")

    line("== TOP CANDIDATES ==")
    for i = 1, math.min(30, #(report.remotes or {})) do
        local entry = report.remotes[i]
        line(("[%3d] %-20s %s"):format(entry.risk, entry.class, entry.path))
    end
    line("")

    line("== ALL REMOTES ==")
    for _, entry in ipairs(report.remotes or {}) do
        local source = entry.service or "nil"
        local conn = entry.connections
        local connText = conn and tostring(conn) or "-1"
        line(("%-20s %-14s conn=%-4s %s"):format(
            entry.class, source, connText, entry.path))
    end
    line("")

    line("== HIDDEN (unparented) ==")
    for _, entry in ipairs(report.remotes or {}) do
        if entry.service == "<nil>" then
            line(("%-20s %s"):format(entry.class, entry.path))
        end
    end
    line("")

    line("== REPLICATED STORAGE ==")
    local rs = report.replicated or {}
    local top = rs.topLevel or {}
    line(("%d top-level children   %d descendants   %d remotes   %d modules"):format(
        #top, rs.total or 0, #(rs.remotes or {}), #(rs.modules or {})))
    for _, child in ipairs(top) do
        line(("child   %-20s %s"):format(child.class, child.name))
    end
    for _, entry in ipairs(rs.remotes or {}) do
        line(("remote  %-20s %s"):format(entry.class, entry.path))
    end
    line("")

    line("== RUNTIME CAPTURED ==")
    for _, record in ipairs(report.captured or {}) do
        line(("%-12s x%-4d %s"):format(record.method, record.count, record.path))
    end
    line("")

    line("== GHOST NAMES (script strings, no instance) ==")
    for _, hit in ipairs(report.scriptHits or {}) do
        if not hit.known then
            line(("risk %-3d %s"):format(hit.risk, hit.name))
        end
    end
    line("")

    line("== PROBE RESULTS ==")
    for _, record in ipairs(report.probes or {}) do
        line(("%s -> %s"):format(record.path, tostring(record.result)))
    end
    line("")

    line("== GEOMETRY ==")
    local geo = report.geometry or {}
    line(("parts %d  unanchored %d  prompts %d  detectors %d"):format(
        geo.parts or 0, geo.unanchored or 0,
        #(geo.prompts or {}), #(geo.detectors or {})))
    for _, prompt in ipairs(geo.prompts or {}) do
        line(("prompt  %-40s %s"):format(prompt.action, prompt.path))
    end
    line("")

    line("== GUI ==")
    local gui = report.gui or {}
    for _, button in ipairs(gui.buttons or {}) do
        line(("button  %s  [%s]"):format(button.path, button.text))
    end
    for _, path in ipairs(gui.inputs or {}) do
        line("input   " .. path)
    end
    for _, entry in ipairs(gui.remotes or {}) do
        line(("gui-rm  %-20s %s"):format(entry.class, entry.path))
    end
    line("")

    line("== CHARACTER ==")
    local char = report.character or {}
    line(("character %s"):format(tostring(char.character)))
    for _, tool in ipairs(char.tools or {}) do
        line("equipped " .. tool)
    end
    for _, tool in ipairs(char.backpack or {}) do
        line("backpack " .. tool)
    end
    for _, stat in ipairs(char.leaderstats or {}) do
        line(("stat %s = %s"):format(stat.name, stat.value))
    end
    line("")

    line("== PROTECTION ==")
    for _, entry in ipairs(report.protection or {}) do
        line(("%-16s %s"):format(entry.class, entry.path))
    end

    return table.concat(out, "\n")
end

local function ensureFolder()
    local makefolder = fetch("makefolder")
    local isfolder = fetch("isfolder")
    if not makefolder or not isfolder then
        return false
    end
    pcall(function()
        if not isfolder(CONFIG.folder) then
            makefolder(CONFIG.folder)
        end
    end)
    return true
end

local lastSaved = nil

local function saveReport()
    local writefile = fetch("writefile")
    if not writefile then
        if has("setclipboard") then
            pcall(fetch("setclipboard"), buildTextReport())
            setStatus("COPIED", "no writefile — clipboard instead", COL.amber)
        else
            setStatus("NO WRITEFILE", "cannot save", COL.danger)
        end
        return nil
    end

    ensureFolder()

    report.meta.generated = os.date("%Y-%m-%d %H:%M:%S")
    report.meta.version = CONFIG.version

    local stamp = os.date("%Y%m%d_%H%M%S")
    local base = ("%s/recon_%s"):format(CONFIG.folder, stamp)

    local okJson, json = pcall(function()
        return HttpService:JSONEncode(report)
    end)
    if okJson and json then
        pcall(writefile, base .. ".json", json)
    end

    local okText, text = pcall(buildTextReport)
    if okText and text then
        pcall(writefile, base .. ".txt", text)
    end

    lastSaved = base

    -- a one-line index so you can find the newest run without listing files
    pcall(writefile, ("%s/latest.txt"):format(CONFIG.folder), base)

    addLine(("saved %s.json"):format(base), COL.green)
    addLine(("saved %s.txt"):format(base), COL.green)
    setStatus("SAVED", base, COL.green)

    return base
end

----------------------------------------------------------------------------
-- automation
----------------------------------------------------------------------------

local busy = false
local captureTimer = nil

local function finishMeta(started)
    -- counts come from the live lists, not from the walk counter, so remotes
    -- found later by the ReplicatedStorage pass are included
    report.counts.remotes = #(walkResults.remotes or {})
    report.counts.scripts = #(walkResults.scripts or {})
    report.counts.modules = #(walkResults.modules or {})

    report.meta = {
        place = tostring(game.PlaceId),
        job = tostring(game.JobId),
        generated = os.date("%Y-%m-%d %H:%M:%S"),
        version = CONFIG.version,
        elapsed = os.clock() - started,
        visited = report.counts.visited or 0,
        remotes = report.counts.remotes or 0,
        scripts = report.counts.scripts or 0,
        modules = report.counts.modules or 0,
        captured = report.counts.captured or 0,
        identifiers = report.counts.identifiers or 0,
        safeMode = CONFIG.safeMode,
        player = lp.Name,
        players = (function()
            local ok, count = pcall(function()
                return #Players:GetPlayers()
            end)
            return ok and count or 0
        end)(),
    }
end

local function runPipelineInner(options, started)
    setStatus("RUNNING", "environment", COL.cyan)

    pcall(function()
        scanEnvironment()
    end)

    setStatus("RUNNING", "services", COL.cyan)
    local services = nil
    pcall(function()
        services = collectServices()
    end)

    setStatus("RUNNING", "instance walk", COL.cyan)
    pcall(function()
        walkAll(services or {})
    end)

    -- must run before mining and connection mapping: it is the pass that
    -- guarantees ReplicatedStorage is covered even if the bulk walk was capped
    setStatus("RUNNING", "replicated storage", COL.cyan)
    pcall(scanReplicatedStorage)

    setStatus("RUNNING", "script mining", COL.cyan)
    pcall(mineScripts)

    setStatus("RUNNING", "connections", COL.cyan)
    pcall(mapConnections)

    pcall(scanGui)
    pcall(scanProtection)
    pcall(scanGeometry)
    pcall(scanCharacter)

    if options.capture ~= false then
        setStatus("CAPTURING", ("%ds — play the game"):format(CONFIG.captureWindow), COL.violet)
        addRule(("capture %ds"):format(CONFIG.captureWindow))
        local ok = startCapture()
        if ok then
            local deadline = os.clock() + CONFIG.captureWindow
            while os.clock() < deadline do
                task.wait(0.25)
                setStatus("CAPTURING",
                    ("%d remotes seen"):format(capture.count), COL.violet)
            end
            stopCapture()
            local total = captureSummary()
            addLine(("%d distinct remotes observed live"):format(total), COL.green)
        end
    end

    setStatus("RUNNING", "ranking", COL.cyan)
    pcall(rankRemotes)

    if options.probe ~= false then
        setStatus("PROBING", "remote functions", COL.violet)
        pcall(probeRemotes)
    end

    pcall(buildHints)
    finishMeta(started)

    if CONFIG.autoSave then
        pcall(saveReport)
    end

    local elapsed = os.clock() - started
    setStatus("DONE", ("%.1fs · %d remotes · %d live"):format(
        elapsed, report.counts.remotes or 0, report.counts.captured or 0), COL.green)
    addLine(("pipeline finished in %.1fs"):format(elapsed), COL.green)
end

local function runPipeline(options)
    if busy then
        return
    end
    busy = true

    local started = os.clock()
    local ok, err = pcall(runPipelineInner, options or {}, started)

    if not ok then
        -- a pass that blows up must never leave the bench locked
        addLine(("pipeline error: %s"):format(tostring(err)), COL.danger)
        setStatus("ERROR", tostring(err), COL.danger)
        pcall(function()
            report.meta.generated = os.date("%Y-%m-%d %H:%M:%S")
        end)
    end

    if busy then
        busy = false
    end
end

----------------------------------------------------------------------------
-- buttons
----------------------------------------------------------------------------

local PAD = 10
local HEADER_H = 44
local STATUS_Y = 46
local STATUS_H = 44
local BUTTON_H = 36
local BUTTON_GAP = 6

local buttonArea = create("Frame", {
    Position = UDim2.new(0, PAD, 1, 0),
    Size = UDim2.new(1, -PAD * 2, 0, 0),
    BackgroundTransparency = 1,
}, shell)

-- a grid, not a list. the old UIListLayout laid all six buttons in one
-- horizontal row at 50% width each, which is 300% of the container — that is
-- exactly the crossed/overlapping layout. a grid wraps into real rows.
local buttonGrid = create("UIGridLayout", {
    CellSize = UDim2.new(0.5, -4, 0, BUTTON_H),
    CellPadding = UDim2.new(0, BUTTON_GAP, 0, BUTTON_GAP),
    FillDirection = Enum.FillDirection.Horizontal,
    FillDirectionMaxCells = 2,
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Top,
}, buttonArea)

pcall(function()
    buttonGrid.Wraps = true
end)

local function makeButton(text, accent, order)
    -- size is owned by the grid; setting it here would fight the layout
    local button = create("TextButton", {
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.86,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = order,
    }, buttonArea)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, button)
    create("UIStroke", { Color = accent, Transparency = 0.55, Thickness = 1 }, button)
    return button
end

local autoButton = makeButton("AUTO", COL.cyan, 1)
local deepButton = makeButton("DEEP", COL.blue, 2)
local captureButton = makeButton("CAPTURE", COL.violet, 3)
local probeButton = makeButton("PROBE", COL.amber, 4)
local safeButton = makeButton("SAFE: ON", COL.green, 5)
local saveButton = makeButton("SAVE", COL.green, 6)

autoButton.Activated:Connect(function()
    task.spawn(function()
        if busy then
            setStatus("BUSY", "pipeline already running", COL.amber)
            return
        end
        runPipeline({ capture = true, probe = true })
    end)
end)

deepButton.Activated:Connect(function()
    task.spawn(function()
        if busy then
            setStatus("BUSY", "pipeline already running", COL.amber)
            return
        end
        runPipeline({ capture = false, probe = true })
    end)
end)

captureButton.Activated:Connect(function()
    if busy then
        return
    end
    if capture.active then
        stopCapture()
        local total = captureSummary()
        addLine(("capture stopped — %d remotes"):format(total), COL.green)
        setStatus("CAPTURED", ("%d remotes"):format(total), COL.green)
        return
    end
    if startCapture() then
        setStatus("CAPTURING", ("%ds"):format(CONFIG.captureWindow), COL.violet)
        addLine("capture armed. play normally.", COL.violet)
        if captureTimer then
            pcall(function()
                captureTimer:Disconnect()
            end)
        end
        task.delay(CONFIG.captureWindow, function()
            if capture.active then
                stopCapture()
                local total = captureSummary()
                addLine(("capture complete — %d remotes"):format(total), COL.green)
                setStatus("CAPTURED", ("%d remotes"):format(total), COL.green)
            end
        end)
    end
end)

probeButton.Activated:Connect(function()
    task.spawn(function()
        if busy then
            return
        end
        busy = true
        pcall(rankRemotes)
        pcall(probeRemotes)
        pcall(buildHints)
        busy = false
    end)
end)

safeButton.Activated:Connect(function()
    CONFIG.safeMode = not CONFIG.safeMode
    safeButton.Text = CONFIG.safeMode and "SAFE: ON" or "SAFE: OFF"
    modeLabel.Text = CONFIG.safeMode and "SAFE" or "LOUD"
    modeLabel.TextColor3 = CONFIG.safeMode and COL.green or COL.danger
    addLine(("safe mode %s"):format(CONFIG.safeMode and "on" or "off"),
        CONFIG.safeMode and COL.green or COL.danger)
end)

saveButton.Activated:Connect(function()
    pcall(saveReport)
end)

----------------------------------------------------------------------------
-- collapse
----------------------------------------------------------------------------

local collapsed = false
local LOG_MIN = 70

local function relayout()
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)

    local width = math.min(360, math.max(240, viewport.X - 16))
    local height = math.min(math.max(viewport.Y - 16, 220), 640)

    -- 1-column is 246px of buttons. on a short viewport that is more than the
    -- whole panel, so fall back to the 2-column grid even when narrow —
    -- 120px buttons still fit "SAFE: ON" at text size 12
    local oneColumnHeight = 6 * BUTTON_H + 5 * BUTTON_GAP
    local needsTwoColumns = (height - HEADER_H - 110) < oneColumnHeight

    local twoColumns = width >= 300 or needsTwoColumns
    buttonGrid.FillDirectionMaxCells = twoColumns and 2 or 1
    buttonGrid.CellSize = twoColumns
        and UDim2.new(0.5, -4, 0, BUTTON_H)
        or UDim2.new(1, 0, 0, BUTTON_H)

    local rows = twoColumns and 3 or 6
    local gridHeight = rows * BUTTON_H + (rows - 1) * BUTTON_GAP
    buttonArea.Size = UDim2.new(1, -PAD * 2, 0, gridHeight)

    if collapsed then
        panel.Size = UDim2.fromOffset(width, HEADER_H)
        statusBox.Visible = false
        logScroll.Visible = false
        buttonArea.Visible = false
    else
        panel.Size = UDim2.fromOffset(width, height)
        statusBox.Visible = true
        logScroll.Visible = true
        buttonArea.Visible = true

        buttonArea.Position = UDim2.new(0, PAD, 1, -(gridHeight + PAD))

        local buttonTop = height - gridHeight - PAD
        local logTop = STATUS_Y + STATUS_H + 4
        local logHeight = buttonTop - 6 - logTop

        -- short viewport: drop the status strip and hand the space to the log
        if logHeight < LOG_MIN and height < 340 then
            statusBox.Visible = false
            logTop = HEADER_H + 2
            logHeight = buttonTop - 6 - logTop
        end

        logScroll.Position = UDim2.fromOffset(0, logTop)
        logScroll.Size = UDim2.new(1, 0, 0, math.max(40, logHeight))
    end

    local scale = math.min(
        (viewport.X - 8) / width,
        (viewport.Y - 8) / height,
        1
    )
    fitScale.Scale = math.clamp(scale, 0.45, 1)

    local abs = panel.AbsolutePosition
    if abs.X < 0 or abs.Y < 0
        or abs.X + width * fitScale.Scale > viewport.X
        or abs.Y + height * fitScale.Scale > viewport.Y then
        panel.Position = UDim2.fromOffset(8, 8)
    end
end

local function fitToViewport()
    relayout()
end

pcall(relayout)

collapseButton.Activated:Connect(function()
    collapsed = not collapsed
    collapseButton.Text = collapsed and "+" or "–"
    pcall(relayout)
end)

closeButton.Activated:Connect(function()
    panel.Visible = false
end)

do
    local camera = workspace.CurrentCamera
    if camera then
        track(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            pcall(fitToViewport)
        end))
    end
    track(UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(function()
        pcall(fitToViewport)
    end))
end

----------------------------------------------------------------------------
-- boot
----------------------------------------------------------------------------

do
    addRule("recon " .. CONFIG.version)
    addLine("AUTO runs the whole pipeline and saves.", COL.text)
    addLine("DEEP skips the capture window and just scans.", COL.text)
    addLine("CAPTURE records remotes the game fires.", COL.violet)
    addLine("PROBE invokes RemoteFunctions with jitter.", COL.violet)
    addLine("SAFE keeps RemoteEvents untouched.", COL.green)
    setStatus("READY", "tap AUTO", COL.cyan)
end

-- no auto-start. a script that installs a __namecall hook the instant it is
-- injected is the loudest thing you can do; one tap on AUTO is still hands-off.

----------------------------------------------------------------------------
-- teardown
----------------------------------------------------------------------------

local function cleanup()
    for _, conn in ipairs(connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(connections)
    if screen then
        pcall(function()
            screen:Destroy()
        end)
        screen = nil
    end
end

_G.__recon2_cleanup = cleanup
