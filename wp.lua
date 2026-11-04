--[[
    wp.lua — weapon recon with a panel
    scans replicated services for anything that could carry a weapon grant,
    a loadout change, or a fire call. results land in the panel, not the
    console — because mobile executors usually don't give you a console.

    ui:
      floating launcher (bottom left) opens/closes the panel
      X button closes (Activated, so touch works)
      SCAN    — full read-only sweep
      PROBE   — calls RemoteFunctions with no args, reports the error shape
      COPY    — copies the whole log to clipboard
      CLEAR   — empties the log

    read-only. the only call that touches the game is the PROBE pass,
    and that's opt-in.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__wplua_cleanup) == "function" then
    pcall(_G.__wplua_cleanup)
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
        TweenInfo.new(time or 0.16, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        goal
    )
    tw:Play()
    return tw
end

-- config

local KEYWORDS = {
    "weapon", "gun", "fire", "shoot", "equip", "give",
    "unlock", "loadout", "inventory", "arm", "class", "kit",
    "purchase", "buy", "store", "shop", "grant", "select",
}

local MAX_PRINT = 200
local MAX_LINES = 900

local COL = {
    bg = Color3.fromRGB(14, 16, 24),
    text = Color3.fromRGB(236, 240, 250),
    sub = Color3.fromRGB(148, 157, 180),
    dim = Color3.fromRGB(110, 118, 142),
    cyan = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    pink = Color3.fromRGB(255, 122, 198),
    green = Color3.fromRGB(124, 240, 178),
    amber = Color3.fromRGB(255, 196, 108),
    danger = Color3.fromRGB(255, 108, 122),
}

local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

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
    if child.Name == "wplua" then
        pcall(function()
            child:Destroy()
        end)
    end
end

screen = Instance.new("ScreenGui")
screen.Name = "wplua"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9998
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = guiParent

-- panel

local panel = create("Frame", {
    Name = "panel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(340, 566),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

local fitScale = create("UIScale", { Scale = 1 }, panel)

local shadow = create("Frame", {
    Position = UDim2.fromOffset(0, 10),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.6,
    BorderSizePixel = 0,
    ZIndex = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 22) }, shadow)

local body = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.1,
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
    Transparency = NumberSequence.new(0.3, 1),
    Rotation = 140,
}, orbA)

local orbB = create("Frame", {
    Position = UDim2.new(1, -80, 1, -70),
    Size = UDim2.fromOffset(170, 170),
    BackgroundColor3 = COL.pink,
    BackgroundTransparency = 0.68,
    BorderSizePixel = 0,
    ZIndex = 1,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbB)
create("UIGradient", {
    Color = ColorSequence.new(COL.pink, COL.violet),
    Transparency = NumberSequence.new(0.45, 1),
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
    Size = UDim2.new(1, 0, 0, 54),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    ZIndex = 3,
}, body)

local dragZone = create("Frame", {
    Size = UDim2.new(1, -60, 1, 0),
    BackgroundTransparency = 1,
    Active = true,
    ZIndex = 3,
}, header)

local logo = create("Frame", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.fromOffset(14, 13),
    BackgroundColor3 = COL.violet,
    BorderSizePixel = 0,
}, dragZone)
create("UICorner", { CornerRadius = UDim.new(0, 9) }, logo)
create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 40 }, logo)

local logoDot = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(11, 11),
    BackgroundColor3 = Color3.fromRGB(14, 16, 24),
    BorderSizePixel = 0,
    ZIndex = 5,
}, logo)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, logoDot)

create("TextLabel", {
    Position = UDim2.fromOffset(52, 11),
    Size = UDim2.fromOffset(180, 17),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "wp.lua",
    ZIndex = 4,
}, dragZone)

create("TextLabel", {
    Position = UDim2.fromOffset(52, 29),
    Size = UDim2.fromOffset(200, 13),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "weapon recon · read only",
    ZIndex = 4,
}, dragZone)

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
create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.8, Thickness = 1 }, closeButton)

track(closeButton.MouseEnter:Connect(function()
    tween(closeButton, { BackgroundTransparency = 0.78 }, 0.12)
end))
track(closeButton.MouseLeave:Connect(function()
    tween(closeButton, { BackgroundTransparency = 0.9 }, 0.12)
end))

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

makeDraggable(panel, dragZone)

-- log

local logBuffer = {}

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 54),
    Size = UDim2.new(1, 0, 1, -206),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = COL.sub,
    ScrollBarImageTransparency = 0.5,
    ZIndex = 2,
}, body)

create("UIPadding", {
    PaddingLeft = UDim.new(0, 12),
    PaddingRight = UDim.new(0, 12),
    PaddingTop = UDim.new(0, 4),
    PaddingBottom = UDim.new(0, 8),
}, logScroll)

create("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, logScroll)

local lineCount = 0
local orderCount = 0

local function addLine(text, color)
    text = tostring(text)
    if #text > 400 then
        text = string.sub(text, 1, 400) .. "…"
    end

    orderCount = orderCount + 1
    lineCount = lineCount + 1

    local label = create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = color or COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = text,
        LayoutOrder = orderCount,
        ZIndex = 3,
    }, logScroll)

    label.AutomaticSize = Enum.AutomaticSize.Y

    table.insert(logBuffer, text)

    if lineCount > MAX_LINES then
        local first = logScroll:GetChildren()
        for _, child in ipairs(first) do
            if child:IsA("TextLabel") then
                child:Destroy()
                lineCount = lineCount - 1
                break
            end
        end
    end

    task.defer(function()
        if logScroll and logScroll.Parent then
            logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.AbsoluteCanvasSize.Y))
        end
    end)
end

local function addRule(title)
    orderCount = orderCount + 1
    lineCount = lineCount + 1
    create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "── " .. string.upper(title) .. " ──",
        LayoutOrder = orderCount,
        ZIndex = 3,
    }, logScroll)
    table.insert(logBuffer, "\n== " .. string.upper(title) .. " ==")
end

local function clearLog()
    for _, child in ipairs(logScroll:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end
    table.clear(logBuffer)
    lineCount = 0
    orderCount = 0
end

-- buttons

local function makeButton(parent, text, accent, width)
    local btn = create("TextButton", {
        Size = UDim2.new(width or 0.5, -6, 0, 34),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.86,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        ZIndex = 4,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, btn)
    create("UIStroke", {
        Color = accent,
        Transparency = 0.55,
        Thickness = 1,
    }, btn)

    track(btn.MouseEnter:Connect(function()
        tween(btn, { BackgroundTransparency = 0.72 }, 0.12)
    end))
    track(btn.MouseLeave:Connect(function()
        tween(btn, { BackgroundTransparency = 0.86 }, 0.12)
    end))

    return btn
end

local buttonRow = create("Frame", {
    Position = UDim2.new(0, 12, 1, -164),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 8),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonRow)

local scanButton = makeButton(buttonRow, "SCAN", COL.cyan, 0.5)
scanButton.LayoutOrder = 1
local probeButton = makeButton(buttonRow, "PROBE", COL.violet, 0.5)
probeButton.LayoutOrder = 2

local buttonRow2 = create("Frame", {
    Position = UDim2.new(0, 12, 1, -124),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 8),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonRow2)

local copyButton = makeButton(buttonRow2, "COPY LOG", COL.green, 0.5)
copyButton.LayoutOrder = 1
local clearButton = makeButton(buttonRow2, "CLEAR", COL.danger, 0.5)
clearButton.LayoutOrder = 2

local buttonRow3 = create("Frame", {
    Position = UDim2.new(0, 12, 1, -84),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 8),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonRow3)

local hookButton = makeButton(buttonRow3, "HOOK", COL.amber, 0.5)
hookButton.LayoutOrder = 1
local sendButton = makeButton(buttonRow3, "SEND", COL.pink, 0.5)
sendButton.LayoutOrder = 2

-- weapon name input, feeds SEND

local inputBox = create("TextBox", {
    Position = UDim2.new(0, 12, 1, -46),
    Size = UDim2.new(1, -24, 0, 26),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.92,
    BorderSizePixel = 0,
    Font = Enum.Font.Code,
    TextSize = 12,
    TextColor3 = COL.text,
    PlaceholderColor3 = COL.dim,
    PlaceholderText = "weapon name — e.g. ARP",
    Text = "",
    ClearTextOnFocus = false,
    ZIndex = 3,
}, body)
create("UICorner", { CornerRadius = UDim.new(0, 9) }, inputBox)
create("UIStroke", { Color = COL.violet, Transparency = 0.6, Thickness = 1 }, inputBox)

-- status bar

local statusText = create("TextLabel", {
    Position = UDim2.new(0, 12, 1, -18),
    Size = UDim2.new(1, -24, 0, 14),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "idle · nothing scanned yet",
    ZIndex = 3,
}, body)

local function setStatus(text, color)
    statusText.Text = text
    statusText.TextColor3 = color or COL.dim
end

-- scan engine

local function matches(text)
    if type(text) ~= "string" then
        return false
    end
    local lower = string.lower(text)
    for _, word in ipairs(KEYWORDS) do
        if string.find(lower, word, 1, true) then
            return true
        end
    end
    return false
end

local function isRemote(obj)
    return obj:IsA("RemoteEvent")
        or obj:IsA("RemoteFunction")
        or obj:IsA("UnreliableRemoteEvent")
end

local function runScan()
    setStatus("scanning…", COL.cyan)

    local candidates = {}
    local seenPath = {}
    local scanned = 0
    local cutOff = false

    local function walk(root)
        if not root then
            return
        end
        local ok, descendants = pcall(function()
            return root:GetDescendants()
        end)
        if not ok or not descendants then
            return
        end

        for _, obj in ipairs(descendants) do
            scanned = scanned + 1
            if scanned > 60000 then
                cutOff = true
                return
            end
            if isRemote(obj) then
                local parentPath = obj.Parent and obj.Parent:GetFullName() or ""
                if matches(obj.Name) or matches(parentPath) then
                    local path = obj:GetFullName()
                    if not seenPath[path] then
                        seenPath[path] = true
                        table.insert(candidates, {
                            object = obj,
                            kind = obj.ClassName,
                            path = path,
                        })
                    end
                end
            end
        end
    end

    local okRS, rs = pcall(function()
        return ReplicatedStorage
    end)
    if okRS then
        walk(rs)
    end

    for _, serviceName in ipairs({ "Workspace", "StarterPlayer" }) do
        local ok, service = pcall(function()
            return game:GetService(serviceName)
        end)
        if ok and service then
            walk(service)
        end
    end

    addRule("scan")
    addLine(("scanned %d instances · %d candidates"):format(scanned, #candidates),
        #candidates > 0 and COL.green or COL.amber)
    if cutOff then
        addLine("hit the 60k instance cap — results may be partial", COL.amber)
    end

    if #candidates > 0 then
        addRule("candidates")
        for i, entry in ipairs(candidates) do
            if i > MAX_PRINT then
                addLine(("… and %d more"):format(#candidates - MAX_PRINT), COL.dim)
                break
            end
            addLine(("[%02d] %s"):format(i, entry.path),
                entry.kind == "RemoteFunction" and COL.amber or COL.cyan)
            addLine("      " .. entry.kind, COL.dim)
        end
    else
        addLine("no weapon-shaped remotes replicated to the client.", COL.amber)
    end

    -- equipped
    addRule("equipped")
    local char = lp.Character
    local equippedCount = 0
    if char then
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Tool") then
                equippedCount = equippedCount + 1
                addLine("tool: " .. obj.Name, COL.text)
                for _, child in ipairs(obj:GetDescendants()) do
                    if isRemote(child) then
                        addLine(("   remote %s %s"):format(child.ClassName, child.Name), COL.sub)
                    end
                end
            end
        end
    end
    if equippedCount == 0 then
        addLine("nothing equipped", COL.dim)
    end

    -- backpack
    addRule("backpack")
    local backpack = lp:FindFirstChildOfClass("Backpack")
    local packCount = 0
    if backpack then
        for _, obj in ipairs(backpack:GetChildren()) do
            if obj:IsA("Tool") then
                packCount = packCount + 1
                addLine("tool: " .. obj.Name, COL.text)
            end
        end
    end
    if packCount == 0 then
        addLine("empty", COL.dim)
    end

    -- verdict
    addRule("verdict")
    local hasGrant, hasFire, hasEquip, hasLoadout, hasRemoteFunc = false, false, false, false, false
    for _, entry in ipairs(candidates) do
        local name = string.lower(entry.object.Name)
        if entry.kind == "RemoteFunction" then
            hasRemoteFunc = true
        end
        if string.find(name, "loadout") then
            hasLoadout = true
        end
        if string.find(name, "give") or string.find(name, "grant")
            or string.find(name, "unlock") or string.find(name, "buy")
            or string.find(name, "purchase") then
            hasGrant = true
        elseif string.find(name, "fire") or string.find(name, "shoot") then
            hasFire = true
        elseif string.find(name, "equip") or string.find(name, "select") then
            hasEquip = true
        end
    end

    if hasGrant then
        addLine("grant-shaped remote exists — ownership is still server-side.", COL.green)
        addLine("HOOK first: watch whether it fires → or arrives ←.", COL.sub)
    elseif hasLoadout then
        addLine("loadout remotes exist. direction decides everything:", COL.cyan)
        addLine("  ← arriving = server pushing your loadout. read-only, no unlock.", COL.sub)
        addLine("  → leaving  = client asking. that one is worth testing.", COL.sub)
        addLine("run HOOK, change a weapon, see which way the arrow points.", COL.sub)
    elseif hasFire then
        addLine("fire-shaped remotes only. no unlock path in this build.", COL.amber)
        addLine("open question: does the server trust fire without an ownership check?", COL.sub)
    elseif hasEquip then
        addLine("equip-shaped remotes only. a swap, not an unlock.", COL.amber)
    else
        addLine("nothing weapon-shaped replicated. inventory is fully server-side.", COL.amber)
        addLine("there is no client-side unlock path here.", COL.sub)
    end

    if hasRemoteFunc then
        addLine("RemoteFunctions present — those leak what the server expects.", COL.cyan)
    end

    setStatus(("%d candidates · %d equipped · %d in pack"):format(
        #candidates, equippedCount, packCount
    ), #candidates > 0 and COL.green or COL.amber)

    return candidates
end

-- probe engine
-- InvokeServer yields forever when the server never answers (BanWeapon did
-- exactly that on your scan), so every call runs on its own thread with a
-- hard timeout. A hang is reported as NO RESPONSE, not silence.

local function probeWithTimeout(remote, timeout)
    local done = false
    local ok = false
    local result

    task.spawn(function()
        ok, result = pcall(function()
            return remote:InvokeServer()
        end)
        done = true
    end)

    local deadline = os.clock() + (timeout or 2)
    while not done and os.clock() < deadline do
        task.wait(0.05)
    end

    if not done then
        return false, "NO RESPONSE (hung, server never replied)", true
    end
    return ok, result, false
end

local function runProbe(candidates)
    candidates = candidates or {}
    if #candidates == 0 then
        addRule("probe")
        addLine("nothing to probe — run SCAN first.", COL.amber)
        setStatus("probe skipped · no candidates", COL.amber)
        return
    end

    setStatus("probing…", COL.violet)
    addRule("probe")

    local probed = 0
    for _, entry in ipairs(candidates) do
        if entry.kind == "RemoteFunction" then
            probed = probed + 1
            local ok, result, hung = probeWithTimeout(entry.object, 2)
            local verdict
            local color
            if hung then
                verdict = tostring(result)
                color = COL.amber
            elseif ok then
                verdict = "RETURNED " .. tostring(result)
                color = COL.green
            else
                local message = tostring(result)
                verdict = "ERROR " .. message
                local lower = string.lower(message)
                if string.find(lower, "authoriz")
                    or string.find(lower, "permission")
                    or string.find(lower, "not allowed")
                    or string.find(lower, "banned") then
                    color = COL.danger
                elseif string.find(lower, "argument")
                    or string.find(lower, "missing")
                    or string.find(lower, "nil") then
                    color = COL.amber
                else
                    color = COL.sub
                end
            end
            addLine(entry.path, COL.text)
            addLine("   " .. verdict, color)
        end
    end

    if probed == 0 then
        addLine("no RemoteFunctions in the candidate list — nothing to probe.", COL.dim)
        setStatus("probe done · 0 RemoteFunctions", COL.dim)
    else
        setStatus(("probed %d RemoteFunctions"):format(probed), COL.violet)
    end
end

-- hook engine
-- outgoing RemoteEvent calls can't be observed without replacing the method.
-- hookfunction does that. everything after the hook is the original call, so
-- the game keeps working normally while the panel logs what it sent.

local hooked = {}
local captured = {}
local hookActive = false

-- values are dumped recursively — a bare "{table}" is useless when the
-- table IS the answer (SetLoadout's payload is the whole loadout).

local DESCRIBE_DEPTH = 3
local DESCRIBE_WIDTH = 6

local function describeValue(value, depth)
    local kind = typeof and typeof(value) or type(value)

    if kind == "string" then
        if #value > 60 then
            return string.format("%q…", string.sub(value, 1, 60))
        end
        return string.format("%q", value)
    elseif kind == "Instance" then
        return value:GetFullName()
    elseif kind == "number" or kind == "boolean" or kind == "nil" then
        return tostring(value)
    elseif kind == "CFrame" then
        return "(cframe)"
    elseif kind == "Vector3" then
        return string.format("(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
    elseif kind == "Vector2" then
        return string.format("(%.1f, %.1f)", value.X, value.Y)
    elseif kind == "EnumItem" then
        return tostring(value)
    elseif kind == "table" then
        if depth <= 0 then
            return "{…}"
        end
        local parts = {}
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            if count > DESCRIBE_WIDTH then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(key) .. "=" .. describeValue(item, depth - 1))
        end
        if count == 0 then
            return "{}"
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return tostring(value)
end

local function describeArgs(...)
    local count = select("#", ...)
    if count == 0 then
        return "()"
    end
    local parts = {}
    for i = 1, math.min(count, 8) do
        table.insert(parts, describeValue((select(i, ...)), DESCRIBE_DEPTH))
    end
    return "(" .. count .. ") " .. table.concat(parts, ", ")
end

local hookRemoteCount = 0
local outboundCount = 0

local function hookRemote(entry)
    local remote = entry.object
    if hooked[remote] then
        return false
    end

    if type(hookfunction) ~= "function" then
        return false
    end

    local ok = pcall(function()
        local original = remote.FireServer
        local replacement = function(self, ...)
            local args = { ... }
            captured[remote] = args
            outboundCount = outboundCount + 1
            addLine(("→ %s %s"):format(remote.Name, describeArgs(...)), COL.pink)
            return original(self, ...)
        end
        hookfunction(original, replacement)
    end)

    if ok then
        hooked[remote] = true
        hookRemoteCount = hookRemoteCount + 1
    end
    return ok
end

local function startHook(candidates)
    candidates = candidates or {}

    if type(hookfunction) ~= "function" then
        addRule("hook")
        addLine("this executor has no hookfunction. hooking is unavailable.", COL.danger)
        return
    end

    addRule("hook")

    -- hook EVERY remote, not just the keyword matches. the call you care
    -- about may be named something the scan never flagged.
    local all = {}
    local okDesc, descendants = pcall(function()
        return ReplicatedStorage:GetDescendants()
    end)
    if okDesc and descendants then
        for _, obj in ipairs(descendants) do
            if obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent") then
                table.insert(all, { object = obj, kind = obj.ClassName })
            end
        end
    end
    -- candidates from a scan outside ReplicatedStorage still count
    for _, entry in ipairs(candidates) do
        if entry.kind == "RemoteEvent" and not hooked[entry.object] then
            local already = false
            for _, existing in ipairs(all) do
                if existing.object == entry.object then
                    already = true
                    break
                end
            end
            if not already then
                table.insert(all, entry)
            end
        end
    end

    for _, entry in ipairs(all) do
        hookRemote(entry)
    end

    -- incoming traffic is only logged for the candidates, so the panel
    -- stays readable when unrelated systems chatter
    for _, entry in ipairs(candidates) do
        if entry.kind == "RemoteEvent" and not entry.listening then
            entry.listening = true
            track(entry.object.OnClientEvent:Connect(function(...)
                addLine(("← %s %s"):format(entry.object.Name, describeArgs(...)), COL.cyan)
            end))
        end
    end

    hookActive = true
    addLine(("hooked %d remotes (all of them)."):format(hookRemoteCount), COL.green)
    addLine("→ you sent · ← server sent", COL.dim)
    addLine("if → stays at 0, the client never calls a remote.", COL.amber)
    setStatus(("hooked %d · → 0"):format(hookRemoteCount), COL.amber)
end

-- send engine
-- fires one captured call back out with the weapon name swapped, so a
-- loadout remote can be tested without guessing its argument shape.

local function findRemote(needle)
    local lowerNeedle = string.lower(needle)
    for path, args in pairs(captured) do
        if string.find(string.lower(path.Name), lowerNeedle, 1, true) then
            return path, args
        end
    end
    return nil, nil
end

local function runSend()
    local name = inputBox.Text
    if name == nil or name == "" then
        setStatus("type a weapon name first", COL.amber)
        return
    end
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    addRule("send")
    addLine(("target weapon: %s"):format(name), COL.text)

    if outboundCount == 0 then
        addLine("warning: HOOK has seen 0 outgoing remote calls.", COL.amber)
        addLine("that means the client may never talk to the server directly —", COL.sub)
        addLine("everything you saw was the server pushing state down.", COL.sub)
        addLine("firing a remote the server doesn't listen to does nothing.", COL.sub)
    end

    local loadoutRemote = ReplicatedStorage:FindFirstChild("DataRemotes")
        and ReplicatedStorage.DataRemotes:FindFirstChild("SetLoadout")

    if not loadoutRemote then
        addLine("DataRemotes.SetLoadout not found — run SCAN.", COL.amber)
        setStatus("send failed · no SetLoadout", COL.danger)
        return
    end

    -- replay the captured shape if we have one, otherwise try the common
    -- single-string form
    local _, capturedArgs = findRemote("setloadout")
    local payload
    if capturedArgs and #capturedArgs > 0 then
        payload = {}
        for i, value in ipairs(capturedArgs) do
            payload[i] = value
        end
        local replaced = false
        for i = #payload, 1, -1 do
            if type(payload[i]) == "string" then
                payload[i] = name
                replaced = true
                break
            end
        end
        if not replaced then
            table.insert(payload, name)
        end
        addLine("replaying captured arg shape:", COL.sub)
    else
        payload = { name }
        addLine("no capture yet — sending the single-string form:", COL.sub)
    end

    addLine("  " .. describeArgs(unpack(payload)), COL.dim)

    local ok, err = pcall(function()
        loadoutRemote:FireServer(unpack(payload))
    end)
    if ok then
        addLine("sent. watch your equipped tool on respawn.", COL.green)
        setStatus("sent · check loadout", COL.green)
    else
        addLine("failed: " .. tostring(err), COL.danger)
        setStatus("send failed", COL.danger)
    end
end

-- wiring

local lastCandidates = {}

scanButton.Activated:Connect(function()
    clearLog()
    lastCandidates = runScan() or {}
end)

probeButton.Activated:Connect(function()
    runProbe(lastCandidates)
end)

hookButton.Activated:Connect(function()
    if hookActive then
        addRule("hook")
        addLine("already hooked " .. tostring(#hooked) .. " remotes", COL.amber)
        return
    end
    startHook(lastCandidates)
end)

sendButton.Activated:Connect(function()
    runSend()
end)

-- [[placeholder removed]]

copyButton.Activated:Connect(function()
    local payload = table.concat(logBuffer, "\n")
    if payload == "" then
        setStatus("nothing to copy", COL.amber)
        return
    end

    local ok = pcall(function()
        if type(setclipboard) == "function" then
            setclipboard(payload)
            return true
        end
        return false
    end)

    if ok and type(setclipboard) == "function" then
        setStatus(("copied %d chars to clipboard"):format(#payload), COL.green)
    else
        setStatus("setclipboard unavailable — select text manually", COL.danger)
    end
end)

clearButton.Activated:Connect(function()
    clearLog()
    setStatus("cleared", COL.dim)
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

closeButton.Activated:Connect(function()
    setOpen(false)
end)

-- launcher

local float = create("Frame", {
    Name = "float",
    Size = UDim2.fromOffset(56, 56),
    Position = UDim2.fromOffset(20, 300),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.12,
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

create("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    Text = "wp",
    ZIndex = 3,
}, float)

local floatRing = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(34, 34),
    BackgroundTransparency = 1,
    ZIndex = 2,
}, float)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, floatRing)
create("UIStroke", {
    Color = COL.cyan,
    Transparency = 0.5,
    Thickness = 1.5,
}, floatRing)

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
    fitScale.Scale = math.clamp(math.min((vp.X - 24) / 340, (vp.Y - 24) / 566), 0.55, 1)
end

fit()
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
    end
end

-- boot

addRule("ready")
addLine("wp.lua armed. tap SCAN to sweep.", COL.cyan)
addLine("lobby first, then 1v1. skip ranked.", COL.sub)
addLine("then HOOK, play a round, read the arrows.", COL.amber)
addLine("type a weapon name + SEND to test SetLoadout.", COL.pink)
setStatus("idle · tap SCAN", COL.dim)
setOpen(true)

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

_G.__wplua_cleanup = cleanup
