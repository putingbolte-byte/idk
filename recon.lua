--[[
    recon.lua — full-surface recon dump for Delta

    scans everything the client can reach and writes the result to your
    workspace folder as both JSON and a readable report.

    what it collects:
      · executor environment — which APIs you actually have
      · every service and whether it is readable
      · every RemoteEvent / RemoteFunction / UnreliableRemoteEvent /
        BindableEvent reachable from the client
      · hidden instances (getnilinstances) — remotes that are not parented
      · client-side connection counts — a remote the client listens to is
        leaking data back
      · risky remote names, scored and ranked
      · workspace geometry: hitboxes, kill bricks, unpinned parts, click
        detectors, proximity prompts, humanoids with odd speeds
      · PlayerGui tree and every button that looks like a fire control
      · your character, backpack, tools and any remotes inside them
      · protector / anti-cheat signatures
      · optional safe probe (RemoteFunction invoke with timeout)
      · optional aggressive probe (RemoteEvent fire) — two taps to arm

    everything is pcall'd, every traversal is capped and yields, so it
    finishes in seconds and never hangs on one bad instance.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__recon_cleanup) == "function" then
    pcall(_G.__recon_cleanup)
end

local CONFIG = {
    maxScan = 120000,
    yieldEvery = 400,
    reportFolder = "recon",
    probeTimeout = 1.2,
    probeGap = 0.06,
    autoScanOnBoot = true,
}

local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then
            pcall(function()
                inst[k] = v
            end)
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local COL = {
    bg = Color3.fromRGB(12, 14, 21),
    text = Color3.fromRGB(236, 240, 250),
    sub = Color3.fromRGB(148, 157, 180),
    dim = Color3.fromRGB(104, 112, 136),
    cyan = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    green = Color3.fromRGB(124, 240, 178),
    amber = Color3.fromRGB(255, 196, 108),
    danger = Color3.fromRGB(255, 108, 122),
}

-- ui parent

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
    if child.Name == "recon" then
        pcall(function()
            child:Destroy()
        end)
    end
end

local screen = Instance.new("ScreenGui")
screen.Name = "recon"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9995
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    screen.Parent = guiParent
end)

local panel = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(380, 620),
    BackgroundTransparency = 1,
}, screen)

local fitScale = create("UIScale", { Scale = 1 }, panel)

local shadow = create("Frame", {
    Position = UDim2.fromOffset(0, 9),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.62,
    BorderSizePixel = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, shadow)

local body = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.04,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)

local bodyStroke = create("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.84,
    Thickness = 1,
}, body)
create("UIGradient", {
    Color = ColorSequence.new(COL.cyan, COL.violet),
    Transparency = NumberSequence.new(0.5, 0.9),
    Rotation = 35,
}, bodyStroke)

-- header

local header = create("Frame", {
    Size = UDim2.new(1, 0, 0, 46),
    BackgroundTransparency = 1,
    Active = true,
}, body)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 7),
    Size = UDim2.fromOffset(240, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "recon",
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 25),
    Size = UDim2.fromOffset(280, 14),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "every remote, every surface, saved to workspace",
}, header)

local closeButton = create("TextButton", {
    Size = UDim2.fromOffset(36, 36),
    Position = UDim2.new(1, -10, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 22,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)

do
    local dragging = false
    local dragStart
    local dragOrigin

    track(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            dragOrigin = panel.Position
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
end

-- status strip

local statusBar = create("Frame", {
    Position = UDim2.fromOffset(12, 48),
    Size = UDim2.new(1, -24, 0, 46),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
}, body)
create("UICorner", { CornerRadius = UDim.new(0, 12) }, statusBar)

local statusStroke = create("UIStroke", {
    Color = COL.cyan,
    Transparency = 0.55,
    Thickness = 1,
}, statusBar)

local statusTitle = create("TextLabel", {
    Position = UDim2.fromOffset(12, 3),
    Size = UDim2.new(1, -24, 0, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.cyan,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "IDLE",
}, statusBar)

local statusSub = create("TextLabel", {
    Position = UDim2.fromOffset(12, 23),
    Size = UDim2.new(1, -24, 0, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "ready",
}, statusBar)

local function setStatus(title, sub, color)
    statusTitle.Text = title
    statusTitle.TextColor3 = color or COL.cyan
    statusStroke.Color = color or COL.cyan
    statusSub.Text = sub or ""
end

-- log

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 100),
    Size = UDim2.new(1, 0, 1, -300),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = COL.sub,
    ScrollBarImageTransparency = 0.5,
}, body)

create("UIPadding", {
    PaddingLeft = UDim.new(0, 12),
    PaddingRight = UDim.new(0, 12),
    PaddingTop = UDim.new(0, 2),
    PaddingBottom = UDim.new(0, 8),
}, logScroll)

create("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, logScroll)

local orderCount = 0
local lineCount = 0
local logLines = {}

local function addLine(text, color)
    text = tostring(text)
    table.insert(logLines, text)
    if #logLines > 800 then
        table.remove(logLines, 1)
    end

    orderCount = orderCount + 1
    lineCount = lineCount + 1

    local label = create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = color or COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = text,
        LayoutOrder = orderCount,
    }, logScroll)
    pcall(function()
        label.AutomaticSize = Enum.AutomaticSize.Y
    end)

    if lineCount > 500 then
        for _, child in ipairs(logScroll:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
                lineCount = lineCount - 1
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
    lineCount = lineCount + 1
    create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "── " .. string.upper(tostring(text)) .. " ──",
        LayoutOrder = orderCount,
    }, logScroll)
end

-- report store

local report = {
    meta = {},
    executor = {},
    services = {},
    remotes = {},
    hidden = {},
    probes = {},
    geometry = {},
    gui = {},
    character = {},
    protection = {},
    ranked = {},
    counts = {},
}

-- keyword risk table

local RISK = {
    ["give"] = 30, ["grant"] = 30, ["reward"] = 28, ["claim"] = 26,
    ["redeem"] = 26, ["admin"] = 40, ["ban"] = 40, ["kick"] = 34,
    ["teleport"] = 22, ["damage"] = 26, ["kill"] = 30, ["spawn"] = 22,
    ["buy"] = 22, ["purchase"] = 22, ["sell"] = 20, ["refund"] = 26,
    ["money"] = 26, ["cash"] = 26, ["coin"] = 24, ["gem"] = 24,
    ["currency"] = 26, ["stat"] = 16, ["level"] = 16, ["xp"] = 16,
    ["item"] = 16, ["inventory"] = 20, ["save"] = 20, ["load"] = 20,
    ["trade"] = 26, ["gift"] = 26, ["unlock"] = 26, ["code"] = 20,
    ["speed"] = 20, ["walk"] = 16, ["jump"] = 16, ["fly"] = 20,
    ["dev"] = 16, ["debug"] = 22, ["test"] = 10, ["cheat"] = 40,
    ["set"] = 14, ["update"] = 10, ["equip"] = 12, ["fire"] = 12,
    ["shoot"] = 12, ["hit"] = 14, ["client"] = 8, ["remote"] = 6,
}

local function riskScore(class, name)
    local lower = string.lower(name)
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
        score = score + 4
    end
    if string.find(lower, "server", 1, true) then
        score = score + 10
    end
    return score
end

-- helpers

local function safeName(inst)
    local ok, name = pcall(function()
        return inst:GetFullName()
    end)
    return ok and name or "<unknown>"
end

local function safeClass(inst)
    local ok, class = pcall(function()
        return inst.ClassName
    end)
    return ok and class or "<unknown>"
end

local function safeParent(inst)
    local ok, parent = pcall(function()
        return inst.Parent
    end)
    return ok and parent or nil
end

-- executor globals are not always mirrored into _G, so grab them directly.
-- referencing an undefined global is legal and yields nil.
local GLOBALS = {
    identifyexecutor = identifyexecutor,
    writefile = writefile,
    readfile = readfile,
    isfile = isfile,
    isfolder = isfolder,
    makefolder = makefolder,
    listfiles = listfiles,
    setclipboard = setclipboard,
    hookmetamethod = hookmetamethod,
    getrawmetatable = getrawmetatable,
    setreadonly = setreadonly,
    getconnections = getconnections,
    getnilinstances = getnilinstances,
    getinstances = getinstances,
    getloadedmodules = getloadedmodules,
    getscripts = getscripts,
    getscriptbytecode = getscriptbytecode,
    decompile = decompile,
    fireclickdetector = fireclickdetector,
    firetouchinterest = firetouchinterest,
    fireproximityprompt = fireproximityprompt,
    request = request,
    http_request = http_request,
    queue_on_teleport = queue_on_teleport,
    getcustomasset = getcustomasset,
    setfpscap = setfpscap,
    gethui = gethui,
    saveinstance = saveinstance,
}

local function api(name)
    if type(GLOBALS[name]) == "function" then
        return true
    end
    local ok, value = pcall(function()
        return _G[name]
    end)
    return ok and type(value) == "function"
end

local function call(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

local function yieldIf(index)
    if index % CONFIG.yieldEvery == 0 then
        task.wait()
    end
end

-- section 1: executor

local function scanExecutor()
    addRule("executor")

    local env = {
        executor = call(function()
            return identifyexecutor()
        end) or "unknown",
        writefile = api("writefile"),
        readfile = api("readfile"),
        isfolder = api("isfolder"),
        makefolder = api("makefolder"),
        listfiles = api("listfiles"),
        setclipboard = api("setclipboard"),
        hookmetamethod = api("hookmetamethod"),
        getrawmetatable = api("getrawmetatable"),
        setreadonly = api("setreadonly"),
        getconnections = api("getconnections"),
        getnilinstances = api("getnilinstances"),
        getinstances = api("getinstances"),
        getloadedmodules = api("getloadedmodules"),
        getscripts = api("getscripts"),
        getscriptbytecode = api("getscriptbytecode"),
        decompile = api("decompile"),
        fireclickdetector = api("fireclickdetector"),
        firetouchinterest = api("firetouchinterest"),
        fireproximityprompt = api("fireproximityprompt"),
        request = api("request") or api("http_request"),
        queue_on_teleport = api("queue_on_teleport"),
        getcustomasset = api("getcustomasset"),
        setfpscap = api("setfpscap"),
        gethui = api("gethui"),
        saveinstance = api("saveinstance"),
    }

    report.executor = env

    addLine(("executor: %s"):format(tostring(env.executor)), COL.green)
    for _, key in ipairs({
        "writefile", "getconnections", "getnilinstances", "getinstances",
        "hookmetamethod", "getrawmetatable", "getloadedmodules", "getscripts",
        "getscriptbytecode", "decompile", "fireclickdetector",
        "fireproximityprompt", "request", "gethui",
    }) do
        if env[key] then
            addLine(("  + %s"):format(key), COL.sub)
        end
    end
end

-- section 2: services

local function scanServices()
    addRule("services")

    local list = {}
    local ok, children = pcall(function()
        return game:GetChildren()
    end)
    if ok and children then
        for _, svc in ipairs(children) do
            local name = safeName(svc)
            local class = safeClass(svc)
            local readable = false
            pcall(function()
                local _ = svc.Name
                readable = true
            end)
            table.insert(list, {
                name = name,
                class = class,
                readable = readable,
                childCount = (function()
                    local okCount, count = pcall(function()
                        return #svc:GetChildren()
                    end)
                    return okCount and count or 0
                end)(),
            })
        end
    end

    table.sort(list, function(a, b)
        return a.name < b.name
    end)

    report.services = list
    addLine(("%d services"):format(#list), COL.cyan)
end

-- section 3: remotes

local REMOTE_CLASSES = {
    RemoteEvent = true,
    UnreliableRemoteEvent = true,
    RemoteFunction = true,
    BindableEvent = true,
    BindableFunction = true,
}

local function connectionCount(signal)
    if not api("getconnections") then
        return -1
    end
    local conns = call(function()
        return getconnections(signal)
    end)
    if type(conns) == "table" then
        return #conns
    end
    return -1
end

local function describeRemote(inst)
    local class = safeClass(inst)
    local name = safeName(inst)
    local parent = safeParent(inst)

    local okName, shortName = pcall(function()
        return inst.Name
    end)

    local entry = {
        name = okName and shortName or "?",
        class = class,
        path = name,
        parent = parent and safeName(parent) or nil,
        risk = riskScore(class, okName and shortName or "?"),
        children = 0,
        connections = -1,
        location = "tree",
    }

    pcall(function()
        entry.children = #inst:GetChildren()
    end)

    pcall(function()
        if class == "RemoteEvent" or class == "UnreliableRemoteEvent" then
            entry.connections = connectionCount(inst.OnClientEvent)
        elseif class == "RemoteFunction" then
            entry.connections = connectionCount(inst.OnClientInvoke)
        elseif class == "BindableEvent" then
            entry.connections = connectionCount(inst.Event)
        end
    end)

    return entry
end

local function scanRemotes()
    addRule("remotes")

    local seen = {}
    local found = {}

    local ok, list = pcall(function()
        return game:GetDescendants()
    end)
    if not (ok and list) then
        addLine("descendant walk failed", COL.danger)
        return
    end

    local total = #list
    local scanLimit = math.min(total, CONFIG.maxScan)
    addLine(("walking %d of %d instances"):format(scanLimit, total), COL.dim)

    for i = 1, scanLimit do
        local inst = list[i]
        local class = safeClass(inst)
        if REMOTE_CLASSES[class] and not seen[inst] then
            seen[inst] = true
            local entry = describeRemote(inst)
            table.insert(found, entry)
        end
        yieldIf(i)
    end

    -- hidden instances: remotes that exist but are not parented anywhere
    if api("getnilinstances") then
        local nilList = call(function()
            return getnilinstances()
        end)
        if type(nilList) == "table" then
            addLine(("getnilinstances: %d"):format(#nilList), COL.dim)
            for i, inst in ipairs(nilList) do
                local class = safeClass(inst)
                if REMOTE_CLASSES[class] and not seen[inst] then
                    seen[inst] = true
                    local entry = describeRemote(inst)
                    entry.location = "nil"
                    table.insert(found, entry)
                    table.insert(report.hidden, entry)
                end
                yieldIf(i)
            end
        end
    end

    table.sort(found, function(a, b)
        if a.risk == b.risk then
            return a.path < b.path
        end
        return a.risk > b.risk
    end)

    report.remotes = found

    local byClass = {}
    for _, entry in ipairs(found) do
        byClass[entry.class] = (byClass[entry.class] or 0) + 1
    end
    report.counts.remotes = #found
    report.counts.hidden = #report.hidden

    addLine(("%d remotes  (%d hidden)"):format(#found, #report.hidden), COL.green)
    for class, count in pairs(byClass) do
        addLine(("  %s: %d"):format(class, count), COL.sub)
    end

    -- top candidates
    addRule("top candidates")
    for i = 1, math.min(12, #found) do
        local entry = found[i]
        if entry.risk > 0 then
            local color = entry.risk >= 40 and COL.danger
                or entry.risk >= 22 and COL.amber
                or COL.sub
            addLine(("[%d] %s"):format(entry.risk, entry.path), color)
        end
    end
end

-- section 4: geometry

local function scanGeometry()
    addRule("geometry")

    local hits = {
        hitboxes = {},
        killParts = {},
        clickDetectors = {},
        proximityPrompts = {},
        fastHumanoids = {},
        touchTransmitters = {},
        unanchored = 0,
        totalParts = 0,
    }

    local ok, list = pcall(function()
        return workspace:GetDescendants()
    end)
    if not (ok and list) then
        addLine("workspace walk failed", COL.danger)
        return
    end

    local limit = math.min(#list, CONFIG.maxScan)

    for i = 1, limit do
        local inst = list[i]
        local class = safeClass(inst)

        local okName, shortName = pcall(function()
            return inst.Name
        end)
        local lower = string.lower(okName and shortName or "")

        if inst:IsA("BasePart") then
            hits.totalParts = hits.totalParts + 1
            if not inst.Anchored then
                hits.unanchored = hits.unanchored + 1
            end

            if string.find(lower, "hitbox", 1, true)
                or string.find(lower, "damage", 1, true)
                or string.find(lower, "hitpart", 1, true) then
                if #hits.hitboxes < 80 then
                    table.insert(hits.hitboxes, safeName(inst))
                end
            end

            if string.find(lower, "kill", 1, true)
                or string.find(lower, "lava", 1, true)
                or string.find(lower, "void", 1, true) then
                if #hits.killParts < 40 then
                    table.insert(hits.killParts, safeName(inst))
                end
            end
        elseif class == "ClickDetector" then
            if #hits.clickDetectors < 60 then
                table.insert(hits.clickDetectors, safeName(inst))
            end
        elseif class == "ProximityPrompt" then
            if #hits.proximityPrompts < 60 then
                table.insert(hits.proximityPrompts, {
                    path = safeName(inst),
                    action = tostring(inst.ActionText),
                    object = tostring(inst.ObjectText),
                })
            end
        elseif class == "Humanoid" then
            local okSpeed, speed = pcall(function()
                return inst.WalkSpeed
            end)
            if okSpeed and speed and speed > 20 then
                if #hits.fastHumanoids < 40 then
                    local parent = safeParent(inst)
                    table.insert(hits.fastHumanoids, {
                        path = parent and safeName(parent) or "?",
                        speed = speed,
                    })
                end
            end
        elseif class == "TouchTransmitter" then
            if #hits.touchTransmitters < 40 then
                table.insert(hits.touchTransmitters, safeName(inst))
            end
        end

        yieldIf(i)
    end

    report.geometry = hits

    addLine(("%d parts, %d unanchored"):format(hits.totalParts, hits.unanchored), COL.cyan)
    addLine(("hitboxes: %d · click detectors: %d · prompts: %d"):format(
        #hits.hitboxes, #hits.clickDetectors, #hits.proximityPrompts), COL.sub)
end

-- section 5: gui

local function scanGui()
    addRule("gui")

    local found = {
        buttons = {},
        textboxes = {},
        screens = 0,
    }

    local roots = {}
    local playerGui = lp:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        table.insert(roots, playerGui)
    end
    if api("gethui") then
        local hui = call(function()
            return gethui()
        end)
        if hui then
            table.insert(roots, hui)
        end
    end

    local seen = {}
    for _, root in ipairs(roots) do
        local ok, list = pcall(function()
            return root:GetDescendants()
        end)
        if ok and list then
            for i, inst in ipairs(list) do
                if not seen[inst] then
                    seen[inst] = true
                    local class = safeClass(inst)
                    if class == "ScreenGui" then
                        found.screens = found.screens + 1
                    elseif class == "TextButton" or class == "ImageButton" then
                        if #found.buttons < 120 then
                            table.insert(found.buttons, {
                                path = safeName(inst),
                                text = inst:IsA("TextButton") and tostring(inst.Text) or "",
                                visible = inst.Visible,
                            })
                        end
                    elseif class == "TextBox" then
                        if #found.textboxes < 40 then
                            table.insert(found.textboxes, safeName(inst))
                        end
                    end
                    yieldIf(i)
                end
            end
        end
    end

    report.gui = found
    addLine(("%d screens, %d buttons, %d textboxes"):format(
        found.screens, #found.buttons, #found.textboxes), COL.cyan)
end

-- section 6: character

local function scanCharacter()
    addRule("character")

    local data = {
        character = nil,
        humanoid = {},
        tools = {},
        backpack = {},
        leaderstats = {},
        attributes = {},
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
                jumpPower = hum.JumpPower,
                hipHeight = hum.HipHeight,
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
            table.insert(data.leaderstats, {
                name = child.Name,
                class = safeClass(child),
                value = tostring(child.Value),
            })
        end
    end

    local okAttrs, attrs = pcall(function()
        return lp:GetAttributes()
    end)
    if okAttrs and attrs then
        for name, value in pairs(attrs) do
            data.attributes[name] = tostring(value)
        end
    end

    report.character = data

    addLine(("tools: %d equipped, %d in backpack"):format(
        #data.tools, #data.backpack), COL.cyan)
    addLine(("leaderstats: %d"):format(#data.leaderstats), COL.sub)
end

-- section 7: protection

local PROTECTORS = {
    "anticheat", "anti-cheat", "anti_cheat", "anticheatt", "ac_",
    "kylua", "kohls", "adonis", "hd_admin", "kohl", "guardian",
    "sentry", "sentinel", "watchdog", "filter", "shield", "detector",
    "vanguard", "punk", "fortress", "bastion",
}

local function scanProtection()
    addRule("protection")

    local hits = {}
    local ok, list = pcall(function()
        return game:GetDescendants()
    end)
    if not (ok and list) then
        return
    end

    local limit = math.min(#list, CONFIG.maxScan)
    for i = 1, limit do
        local inst = list[i]
        local class = safeClass(inst)
        if class == "Script" or class == "LocalScript" or class == "ModuleScript" then
            local lower = string.lower(inst.Name)
            for _, word in ipairs(PROTECTORS) do
                if string.find(lower, word, 1, true) then
                    if #hits < 60 then
                        table.insert(hits, {
                            path = safeName(inst),
                            class = class,
                        })
                    end
                    break
                end
            end
        end
        yieldIf(i)
    end

    report.protection = hits
    if #hits == 0 then
        addLine("no obvious protector names found", COL.green)
    else
        for _, hit in ipairs(hits) do
            addLine(("  %s"):format(hit.path), COL.amber)
        end
    end
end

-- section 8: safe probe

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
        task.wait(0.04)
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
        local n = 0
        for k, v in pairs(value) do
            n = n + 1
            if n > 6 then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. describeValue(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif kind == "string" then
        if #value > 40 then
            return ("%q…"):format(string.sub(value, 1, 37))
        end
        return ("%q"):format(value)
    end
    return tostring(value)
end

local function runProbe()
    local targets = {}
    for _, entry in ipairs(report.remotes) do
        if entry.class == "RemoteFunction" then
            table.insert(targets, entry)
        end
    end

    if #targets == 0 then
        addLine("no RemoteFunctions to probe", COL.amber)
        setStatus("NO TARGETS", "no RemoteFunction found", COL.amber)
        return
    end

    addRule(("probing %d RemoteFunctions"):format(#targets))
    setStatus("PROBING", ("%d RemoteFunctions"):format(#targets), COL.violet)

    local results = {}

    for i, entry in ipairs(targets) do
        -- resolve by path
        local resolved = nil
        pcall(function()
            local node = game
            for part in string.gmatch(entry.path, "[^%.]+") do
                if not node then
                    break
                end
                node = node:FindFirstChild(part)
            end
            resolved = node
        end)

        if resolved then
            local ok, value = timedInvoke(resolved, CONFIG.probeTimeout, {})
            local record = {
                path = entry.path,
                ok = ok,
                result = ok and describeValue(value) or tostring(value),
            }
            table.insert(results, record)

            if not ok and tostring(value) == "timeout" then
                addLine(("  TIMEOUT  %s"):format(entry.path), COL.amber)
            elseif ok then
                local color = COL.green
                if string.find(tostring(record.result), "false", 1, true) then
                    color = COL.sub
                end
                addLine(("  OK       %s -> %s"):format(entry.path, record.result), color)
            else
                addLine(("  ERR      %s -> %s"):format(entry.path, record.result), COL.danger)
            end
        end

        task.wait(CONFIG.probeGap)
    end

    report.probes = results
    setStatus("PROBED", ("%d functions"):format(#results), COL.green)
end

-- section 9: aggressive

local aggressiveArmed = false

local function runAggressive()
    if not aggressiveArmed then
        aggressiveArmed = true
        setStatus("ARMED — TAP AGAIN", "fires every RemoteEvent once. risky.", COL.danger)
        addLine("aggressive probe armed. tap AGGRESSIVE again to fire.", COL.danger)
        task.delay(8, function()
            aggressiveArmed = false
        end)
        return
    end
    aggressiveArmed = false

    local targets = {}
    for _, entry in ipairs(report.remotes) do
        if entry.class == "RemoteEvent" or entry.class == "UnreliableRemoteEvent" then
            table.insert(targets, entry)
        end
    end

    if #targets == 0 then
        addLine("no RemoteEvents to fire", COL.amber)
        return
    end

    addRule(("firing %d RemoteEvents"):format(#targets))
    setStatus("FIRING", ("%d events"):format(#targets), COL.danger)

    local results = {}
    for i, entry in ipairs(targets) do
        local resolved = nil
        pcall(function()
            local node = game
            for part in string.gmatch(entry.path, "[^%.]+") do
                if not node then
                    break
                end
                node = node:FindFirstChild(part)
            end
            resolved = node
        end)

        if resolved then
            local ok, err = pcall(function()
                resolved:FireServer()
            end)
            table.insert(results, {
                path = entry.path,
                ok = ok,
                error = ok and nil or tostring(err),
            })
            if not ok then
                addLine(("  ERROR  %s"):format(entry.path), COL.danger)
                addLine(("    %s"):format(tostring(err)), COL.dim)
            end
        end
        task.wait(CONFIG.probeGap)
    end

    report.probes = report.probes or {}
    for _, record in ipairs(results) do
        table.insert(report.probes, {
            path = record.path,
            ok = record.ok,
            result = record.error or "fired",
            kind = "aggressive",
        })
    end

    setStatus("FIRED", ("%d events"):format(#results), COL.amber)
end

-- save

local function ensureFolder()
    if not api("makefolder") or not api("isfolder") then
        return false
    end
    return (call(function()
        if not isfolder(CONFIG.reportFolder) then
            makefolder(CONFIG.reportFolder)
        end
        return true
    end)) == true
end

local function buildTextReport()
    local out = {}
    local function line(text)
        table.insert(out, text)
    end

    line("recon report")
    line(("generated %s"):format(os.date("%Y-%m-%d %H:%M:%S")))
    line(("place %s  job %s"):format(tostring(game.PlaceId), tostring(game.JobId)))
    line(("executor %s"):format(tostring(report.executor.executor)))
    line("")

    line(("remotes: %d  (%d hidden)"):format(
        report.counts.remotes or 0, report.counts.hidden or 0))
    line("")

    line("== HINTS ==")
    for _, hint in ipairs(report.hints or {}) do
        line(hint)
    end
    line("")

    line("== TOP CANDIDATES ==")
    local shown = 0
    for _, entry in ipairs(report.remotes) do
        if entry.risk > 0 and shown < 60 then
            shown = shown + 1
            line(("[%3d] %-20s %s"):format(entry.risk, entry.class, entry.path))
        end
    end
    if shown == 0 then
        line("none scored")
    end
    line("")

    line("== ALL REMOTES ==")
    for _, entry in ipairs(report.remotes) do
        line(("%-20s %-10s conn=%d  %s"):format(
            entry.class, entry.location, entry.connections, entry.path))
    end
    line("")

    if #report.hidden > 0 then
        line("== HIDDEN (unparented) ==")
        for _, entry in ipairs(report.hidden) do
            line(("%-20s %s"):format(entry.class, entry.path))
        end
        line("")
    end

    if #report.probes > 0 then
        line("== PROBES ==")
        for _, record in ipairs(report.probes) do
            line(("%s -> %s"):format(record.path, tostring(record.result)))
        end
        line("")
    end

    line("== GEOMETRY ==")
    line(("parts %d  unanchored %d"):format(
        report.geometry.totalParts or 0, report.geometry.unanchored or 0))
    for _, path in ipairs(report.geometry.hitboxes or {}) do
        line("hitbox  " .. path)
    end
    for _, path in ipairs(report.geometry.clickDetectors or {}) do
        line("click   " .. path)
    end
    line("")

    line("== GUI ==")
    for _, button in ipairs(report.gui.buttons or {}) do
        line(("button  %s  [%s]"):format(button.path, button.text))
    end
    line("")

    line("== CHARACTER ==")
    line(("character %s"):format(tostring(report.character.character)))
    for _, tool in ipairs(report.character.tools or {}) do
        line("equipped " .. tool)
    end
    for _, tool in ipairs(report.character.backpack or {}) do
        line("backpack " .. tool)
    end
    for _, stat in ipairs(report.character.leaderstats or {}) do
        line(("stat %s = %s"):format(stat.name, stat.value))
    end
    line("")

    line("== PROTECTION ==")
    if #report.protection == 0 then
        line("none found")
    else
        for _, hit in ipairs(report.protection) do
            line(("%-12s %s"):format(hit.class, hit.path))
        end
    end

    return table.concat(out, "\n")
end

local lastSavedPath = nil

local function saveReport()
    if not api("writefile") then
        setStatus("NO WRITEFILE", "executor cannot save", COL.danger)
        addLine("writefile missing — copying to clipboard instead", COL.amber)
        if api("setclipboard") then
            pcall(function()
                setclipboard(buildTextReport())
            end)
            setStatus("COPIED", "report on clipboard", COL.green)
        end
        return
    end

    ensureFolder()

    local stamp = os.date("%Y%m%d_%H%M%S")
    local base = ("%s/recon_%s"):format(CONFIG.reportFolder, stamp)

    local okJson, json = pcall(function()
        return HttpService:JSONEncode(report)
    end)

    if okJson and json then
        pcall(function()
            writefile(base .. ".json", json)
        end)
    end

    local okText, text = pcall(buildTextReport)
    if okText and text then
        pcall(function()
            writefile(base .. ".txt", text)
        end)
    end

    lastSavedPath = base

    if api("isfile") then
        local exists = call(function()
            return isfile(base .. ".json")
        end)
        addLine(("saved: %s.json (%s)"):format(base,
            exists and "confirmed" or "unverified"), COL.green)
    else
        addLine(("saved: %s.json"):format(base), COL.green)
    end

    addLine(("saved: %s.txt"):format(base), COL.green)
    setStatus("SAVED", base, COL.green)
end

-- full run

local scanning = false

local function scanAll()
    if scanning then
        return
    end
    scanning = true
    setStatus("SCANNING", "walking the tree", COL.cyan)

    local started = os.clock()

    local steps = {
        { "executor", scanExecutor },
        { "services", scanServices },
        { "remotes", scanRemotes },
        { "geometry", scanGeometry },
        { "gui", scanGui },
        { "character", scanCharacter },
        { "protection", scanProtection },
    }

    for _, step in ipairs(steps) do
        setStatus("SCANNING", step[1], COL.cyan)
        local ok, err = pcall(step[2])
        if not ok then
            addLine(("section %s failed: %s"):format(step[1], tostring(err)), COL.danger)
        end
        task.wait()
    end

    -- ranked hints, human readable, straight into the JSON
    report.hints = {}
    for i = 1, math.min(20, #report.remotes) do
        local entry = report.remotes[i]
        if entry.risk >= 22 then
            table.insert(report.hints, ("risk %d  %s  %s"):format(
                entry.risk, entry.class, entry.path))
        end
    end
    for _, entry in ipairs(report.hidden) do
        table.insert(report.hints, ("hidden  %s  %s"):format(entry.class, entry.path))
    end
    for _, prompt in ipairs(report.geometry.proximityPrompts or {}) do
        table.insert(report.hints, ("prompt  " .. tostring(prompt.path)))
    end
    for _, detector in ipairs(report.geometry.clickDetectors or {}) do
        table.insert(report.hints, ("click   " .. tostring(detector)))
    end

    report.meta = {
        place = tostring(game.PlaceId),
        job = tostring(game.JobId),
        generated = os.date("%Y-%m-%d %H:%M:%S"),
        elapsed = os.clock() - started,
        players = (function()
            local ok, count = pcall(function()
                return #Players:GetPlayers()
            end)
            return ok and count or 0
        end)(),
    }

    local elapsed = os.clock() - started
    setStatus("DONE", ("%.2fs · %d remotes"):format(
        elapsed, report.counts.remotes or 0), COL.green)
    addLine(("scan finished in %.2fs"):format(elapsed), COL.green)

    pcall(saveReport)

    scanning = false
end

-- buttons

local function makeButton(parent, text, accent, order)
    local btn = create("TextButton", {
        Size = UDim2.new(0.5, -5, 0, 44),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.84,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = order,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, btn)
    create("UIStroke", { Color = accent, Transparency = 0.55, Thickness = 1 }, btn)
    return btn
end

local buttonArea = create("Frame", {
    Position = UDim2.new(0, 12, 1, -200),
    Size = UDim2.new(1, -24, 0, 150),
    BackgroundTransparency = 1,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 6),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonArea)

local scanButton = makeButton(buttonArea, "SCAN", COL.cyan, 1)
local probeButton = makeButton(buttonArea, "PROBE", COL.violet, 2)
local aggressiveButton = makeButton(buttonArea, "AGGRESSIVE", COL.danger, 3)
local saveButton = makeButton(buttonArea, "SAVE", COL.green, 4)
local copyButton = makeButton(buttonArea, "COPY", COL.amber, 5)
local clearButton = makeButton(buttonArea, "CLEAR", COL.dim, 6)

scanButton.Activated:Connect(function()
    scanAll()
end)

probeButton.Activated:Connect(function()
    if scanning then
        return
    end
    task.spawn(function()
        pcall(runProbe)
    end)
end)

aggressiveButton.Activated:Connect(function()
    if scanning then
        return
    end
    pcall(runAggressive)
end)

saveButton.Activated:Connect(function()
    pcall(saveReport)
end)

copyButton.Activated:Connect(function()
    if not api("setclipboard") then
        setStatus("NO CLIPBOARD", "executor cannot copy", COL.danger)
        return
    end
    local ok, text = pcall(buildTextReport)
    if ok and text then
        pcall(function()
            setclipboard(text)
        end)
        setStatus("COPIED", ("%d chars"):format(#text), COL.green)
    end
end)

clearButton.Activated:Connect(function()
    table.clear(logLines)
    for _, child in ipairs(logScroll:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end
    lineCount = 0
    setStatus("CLEARED", "log emptied", COL.cyan)
end)

-- boot

do
    addRule("recon")
    addLine("SCAN builds the report. SAVE writes it to workspace.", COL.text)
    addLine("PROBE invokes RemoteFunctions with a timeout.", COL.text)
    addLine("AGGRESSIVE fires every RemoteEvent. two taps to arm.", COL.amber)
end

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 16) / 380, (vp.Y - 16) / 620), 0.55, 1)
end

pcall(fit)
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            pcall(fit)
        end))
    end
end

closeButton.Activated:Connect(function()
    panel.Visible = false
end)

if CONFIG.autoScanOnBoot then
    task.spawn(function()
        task.wait(0.4)
        pcall(scanAll)
    end)
end

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

_G.__recon_cleanup = cleanup
